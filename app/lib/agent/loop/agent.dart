/// 智能体主循环（Phase 1）—— 对照 DSH `ReactLoopAgent`。
///
/// 结构（对照 DSH 主循环 Part 7）：
/// - 外层 `turn` 循环：一个 turn = 用户输入 → 最终回答（或失败/中断）。
///   用户消息是 turn 的唯一入口（`kick`）。
/// - 内层 `step` 循环：一个 step = 一次模型请求（llm 调用）。
///   step 内：`step/start` → 构建请求 → `llm/step` → `assistant/message`
///   → 若有工具 → 逐工具 `tool/call`+执行+`tool/result` → `step/end`。
/// - 失败瀑布（Part 9.9）：模型失败 → 落 `assistant/attempt`（log-only，
///   模型不可见）→ 跑 `CompactionPlugin`（CONTEXT_WINDOW_EXCEEDED）/
///   `LlmRetry`（瞬态）→ success 才 `{kind:retry}`（同一 step 重试）。
/// - 取消（Part 14.6）：`abortController`；`cancel()` 中止当前 step；
///   `turn/end {reason:interrupted}`；`assistant/message` 标 `interrupted:true`
///   才允许后续接话。
///
/// **G12 不变量**：请求历史只能来自 [SessionLog.deriveModelMessages]（纯投影，
/// 不手工构造）；系统提示以 `system/message` 节点入 log；工具段属 header。
library;

import 'dart:async';
import 'dart:convert' show jsonEncode;

import 'package:flutter/foundation.dart' show debugPrint;

import '../llm/adapter.dart';
import '../session/session.dart';
import 'config.dart';
import 'failure.dart';
import '../context_eng/spill.dart';
import '../context_eng/token_estimate.dart';
import '../sandbox.dart';
import '../tool_definition.dart';
import '../tool_registry.dart';
import '../tools/guard.dart';
import '../tools/pipeline.dart';
import '../tools/tool_executor.dart';
import '../tool_activity.dart' show AgentToolActivityCallback, ToolActivity;
import '../hooks/hooks.dart' show AgentHooks, PreStepContext;
import '../skills/provider.dart' show SkillProvider;

/// 智能体相位（DSH `AgentPhase`）。
enum AgentPhase {
  idle,
  running,
}

/// turn 结束原因。
enum TurnEndReasonKind {
  completed,   // 模型给出最终回答
  error,       // 瀑布终态失败
  interrupted, // 用户取消
  maxSteps,    // 达到 maxStepsPerTurn 上限（仍在调用工具）
  blocked,     // 用户输入等待（Phase 4+）
  user,        // 用户主动结束
}

/// turn 结束原因（含详情）。
final class TurnEndReason {
  final TurnEndReasonKind kind;
  final String? detail;
  const TurnEndReason(this.kind, {this.detail});
}

/// 当前相位/计数状态（UI 可查询）。
final class AgentPhaseState {
  final AgentPhase phase;
  final int turn;
  final int step;
  const AgentPhaseState(this.phase, this.turn, this.step);
}

/// 主循环（ReactLoopAgent）。
class ReactLoopAgent {
  final SessionLog _session;
  final LlmAdapter _adapter;
  final ToolRegistry _registry;
  final AgentConfig _config;
  final String _modelId;
  final ProviderKind _providerKind;
  final String _systemPrompt;
  final String? _sessionPath;

  final AgentSandboxApprover? _sandboxApprover;

  /// Phase 5 hooks（agent/pre-step、tools/result）。
  final AgentHooks? _hooks;
  /// Phase 5 skills（注入 `<available_skills>`）。
  final SkillProvider? _skills;
  /// Phase 5 AGENTS.md guidance（注入 workspace:guidance section）。
  final String? _agentsMd;
  /// 环境快照（当前时间等），注入系统提示最末（cache 友好；null = 不注入）。
  final String? _environmentNote;

  /// 环境快照提供者（P1-C prompt-cache 友好形态）：每个 step 边界取一次，
  /// 内容变化才以**尾部 user 消息**注入（追加不破坏前缀）。
  /// 与 [environmentNote]（系统提示内嵌，构造期一次性）二选一：
  /// provider 形态下系统提示逐字节稳定，API prompt cache 整段命中；
  /// 环境变化（时间桶滚动）只在上下文末尾追加一小段。
  final String Function()? _environmentNoteProvider;
  String? _lastEnvNote;

  /// 通用重复调用守护（DSH repeat-tool-reminder 语义）：同一工具本回合
  /// 调用次数命中 [kRepeatReminderSteps] 时，在结果尾部追加渐进提醒，
  /// 逼模型收敛（配合签名去重的"回缓存"双保险）。
  static const Set<int> kRepeatReminderSteps = {3, 5, 8};

  final ToolExecutor _executor;
  final LlmRetry _retry;
  final CompactionPlugin _compaction;
  /// 六段流水线（guard/pre/post/spill 集成）；Phase 2。
  late final ToolPipeline _pipeline;

  /// 工具执行活动回调（UI 展示用）：工具开始/成功/失败均触发，
  /// 对齐旧 `runAgent` 的 [AgentToolActivityCallback]。
  final AgentToolActivityCallback? _onToolActivity;

  AgentPhaseState _phase = AgentPhaseState(AgentPhase.idle, 0, 0);
  Completer<void>? _cancelCompleter;
  bool _cancelCompleted = false;

  /// 本轮最终答案：仅本轮 append 的末条 assistant/message 内容。
  /// **失败时为空串**——绝不穿透回历史里的旧 assistant（否则会把上一轮
  /// 回复冒充成本轮回复显示，看起来像"模型只会这一句"）。
  String _turnAnswer = '';
  String? _turnError;

  /// 上一步是否执行了工具调用（WP3b 分阶段预算档位依据；
  /// 每 step 开始重置，工具执行后置真）。
  bool _lastStepHadToolResults = false;

  /// 下一次请求强制不思考（思考失控后的那次重试专用，一次性，构建请求时消费）。
  /// 由失败瀑布在授予 thinkingOverflow 重试时置真。
  bool _forceNoThinkingNext = false;

  String get lastTurnAnswer => _turnAnswer;
  String? get lastTurnError => _turnError;

  ReactLoopAgent({
    required SessionLog session,
    required LlmAdapter adapter,
    required ToolRegistry registry,
    AgentConfig? config,
    required String modelId,
    required ProviderKind providerKind,
    required String systemPrompt,
    String? sessionPath,
    AgentSandboxApprover? sandboxApprover,
    Future<String?> Function()? workspaceResolver,
    AgentToolActivityCallback? onToolActivity,
    LlmRetry? retry,
    CompactionPlugin? compaction,
    // ---- Phase 2：流水线扩展 ----
    List<ToolGuard>? guards,
    List<ToolPreExecuteListener>? preListeners,
    ToolPreExecuteApprover? preApprover,
    List<PostExecuteListener>? postListeners,
    SpillStore? spillStore,
    int? spillMaxInlineTokens,
    // ---- Phase 5：hooks ----
    AgentHooks? hooks,
    // ---- Phase 5：skills + AGENTS.md ----
    SkillProvider? skills,
    String? agentsMd,
    // ---- 环境快照（当前时间等）：置于系统提示**最末**（skills/AGENTS.md
    // 之后）——稳定前缀在前、易变快照在后，API 端 prompt cache 友好
    // （DSH section ordering）；local 档不传，系统提示逐字节稳定保 KV。
    String? environmentNote,
    // ---- P1-C：环境快照提供者（每 step 尾部注入，保前缀稳定）----
    String Function()? environmentNoteProvider,
  })  : _session = session,
        _adapter = adapter,
        _registry = registry,
        _config = config ?? AgentConfig(),
        _modelId = modelId,
        _providerKind = providerKind,
        _systemPrompt = systemPrompt,
        _sessionPath = sessionPath,
        _sandboxApprover = sandboxApprover,
        _onToolActivity = onToolActivity,
        _hooks = hooks,
        _skills = skills,
        _agentsMd = agentsMd,
        _environmentNote = environmentNote,
        _environmentNoteProvider = environmentNoteProvider,
        _executor = ToolExecutor(
          registry: registry,
          modelId: modelId,
          timeout: (config ?? AgentConfig()).toolTimeout,
          sandboxApprover: sandboxApprover,
          workspaceResolver: workspaceResolver,
        ),
        _retry = retry ??
            LlmRetry(
              maxRetries: providerKind == ProviderKind.local ? 3 : 5,
              initialDelay: const Duration(milliseconds: 500),
              maxDelay: const Duration(seconds: 10),
              // 空响应计入可重试档（两条路线都要，有界不循环）：
              // - API：思考型模型可能把 max_tokens 耗在推理上导致 content 为空
              //   （EMPTY_RESPONSE，设计文档 §5.4）；
              // - 本地：4B 模型常在思考中途直接 EOS（思考块未闭合被丢弃 → 空
              //   响应），重试一次通常能产出正式回答（2026-09-29 真机观察到，
              //   曾把 web_search 回合误判成"执行失败"）。
              retryEmptyResponse: true,
            ),
        _compaction = compaction ?? const NoCompactionPlugin() {
    // 系统提示以 system/message 节点入 log（turn 0 前一次性，幂等）。
    // Phase 5：注入 <available_skills>（skills）+ workspace:guidance（AGENTS.md）。
    // load_skill 仅 API 档注册：本地档注入文本不得提及 load_skill（教唆调用
    // 不存在的工具），按注册表实际可见性门控。
    String systemContent = _systemPrompt;
    if (_skills != null) {
      // 教唆门控按注册表实际可见性：load_skill/save_skill 未注册的路线
      // 不在提示里提（防指向不存在的工具）。
      final visibleNames =
          _registry.visibleFor(_modelId).map((t) => t.name).toSet();
      final skillText = _skills.availableSkillsText(
        loadSkillAvailable: visibleNames.contains('load_skill'),
        saveSkillAvailable: visibleNames.contains('save_skill'),
      );
      if (skillText.trim().isNotEmpty) {
        systemContent += '\n\n$skillText';
      }
    }
    if (_agentsMd != null) {
      final am = _agentsMd.trim();
      if (am.isNotEmpty) {
        systemContent += '\n\n<workspace:guidance>\n$am\n</workspace:guidance>';
      }
    }
    // 环境快照恒置系统提示最末：稳定前缀（身份/规则/工具/技能/AGENTS.md）
    // 在前、易变快照在后，API 端 prompt cache 命中率最大化（DSH section
    // ordering 思想）。local 档不传 → 系统提示逐字节稳定，KV 前缀复用。
    final env = _environmentNote?.trim();
    if (env != null && env.isNotEmpty) {
      systemContent += '\n\n【环境】$env';
    }

    _session.append(
      kEventSystemMessage,
      {'content': systemContent},
      source: const {'kind': 'system'},
    );
    // Phase 2：构建六段流水线（guard/pre/post/spill 集成）。
    _pipeline = ToolPipeline(
      executor: _executor,
      guards: guards ?? const <ToolGuard>[],
      preListeners: preListeners,
      preApprover: preApprover,
      postListeners: postListeners,
      spill: spillStore != null
          ? Spill(
              maxInlineTokens: spillMaxInlineTokens ?? 4096,
              store: spillStore,
            )
          : null,
      sessionLog: _session,
    );
  }

  AgentPhaseState get phaseState => _phase;

  bool get isRunning => _phase.phase == AgentPhase.running;

  /// 只读访问会话日志（诊断/测试/持久化用）。
  SessionLog get session => _session;

  /// 最终回答：log 中最后一条 model-visible assistant/message 的 content。
  /// 工具循环的每一步都追加一条 assistant/message；最终无工具调用那步的
  /// content 即最终回答。turn 无 assistant 消息（直接失败/中断）时返回空串。
  String get lastAssistantContent {
    final messages = _session.deriveModelMessages();
    for (var i = messages.length - 1; i >= 0; i--) {
      final m = messages[i];
      if (m['role'] == 'assistant') {
        final c = m['content'];
        if (c is String) return c;
      }
    }
    return '';
  }

  /// 启动一个 turn：用户输入 → 最终回答（或失败/中断）。
  Future<TurnEndReason> kick(
    String userMessage, {
    String? imagePath,
    List<String>? imagePaths,
    String? audioPath,
    StreamController<String>? onToken,
    StreamController<String>? onThinking,
    StreamController<String>? onStatus,
  }) async {
    if (_phase.phase != AgentPhase.idle) {
      throw StateError('agent is running; cancel() first');
    }
    // 回合计时（结束日志用）：真机排障需要"回合跑了多久、几步"的基线。
    final turnWatch = Stopwatch()..start();
    _cancelCompleter = Completer<void>();
    _cancelCompleted = false;
    _turnAnswer = '';
    _turnError = null;
    _lastStepHadToolResults = false;
    // 回合内重复调用去重（2026-09-30 定案）：端侧 2B 模型拿到结果后常原样
    // 重发同一调用不收敛。签名 → 首次结果缓存，回合开始时清空。
    _turnToolCallCache.clear();
    _turnToolCallCounts.clear();
    _clearInbox();
    // imagePath 入事件（store.dart importFromMessages 同款键名）：API 路线
    // 无状态，每个 step 重放历史时都要把图片重发；不入 log 则后续 step 丢图。
    final userSeq = _session.append(
      kEventUserMessage,
      {
        'content': userMessage,
        if (imagePath != null) 'imagePath': imagePath,
        // 多图（多图上传/长图切块）：本地与 API 路线均全量发送
        // （本地原生按序逐张编码；API 由投影/adapter 转多个 image_url part）。
        if (imagePaths != null && imagePaths.length > 1)
          'imagePaths': imagePaths,
      },
      source: const {'kind': 'user'},
    );
    final turn = _phase.turn + 1;
    _phase = AgentPhaseState(AgentPhase.running, turn, 0);
    _session.append(kEventTurnStart, {'turn': turn, 'userSeq': userSeq});

    var step = 0;
    var reason = TurnEndReasonKind.completed;
    bool turnDone = false;
    // 步数预算（P2-A1，DSH goal-round-driver 语义）：撞 [maxStepsPerTurn]
    // 不死停——合成收尾提示追加预算再给 [maxWrapups] 轮收敛机会；
    // 剩余步数 ≤2 时先注入收敛警告，逼模型提前收尾。
    var stepBudget = _config.maxStepsPerTurn;
    var wrapupsUsed = 0;
    var warnedBudget = -1;
    try {
      while (!turnDone) {
        // 用户取消可能在工具执行中途触发 —— 在 step 边界检查，尽快收 turn。
        if (_cancelCompleted) {
          reason = TurnEndReasonKind.interrupted;
          turnDone = true;
          break;
        }
        if (step >= stepBudget) {
          if (wrapupsUsed < _config.maxWrapups) {
            wrapupsUsed++;
            stepBudget += _config.wrapupSteps;
            _appendTurnGuidance(
                '[系统] 工具循环步数已达上限，本回合进入收尾阶段'
                '（追加 ${_config.wrapupSteps} 步预算）：请基于已完成的工具'
                '结果与进展，立即汇总并给出最终回答；未完成的部分明确说明'
                '（已完成什么、还差什么、建议下一步）。不要再发起新的'
                '大规模工具调用。');
            continue;
          }
          reason = TurnEndReasonKind.maxSteps;
          break;
        }
        final remaining = stepBudget - step;
        if (remaining <= 2 && warnedBudget != stepBudget) {
          warnedBudget = stepBudget;
          _appendTurnGuidance(
              '[系统] 工具循环剩余步数不多（约 $remaining 步）：'
              '若已有足够信息，请立即给出最终回答；若必须继续调用工具，'
              '只做完成任务必需的关键调用。');
        }
        step++;
        // 新 step：重置本步重试预算（同一 step 内最多 maxRetries 次重试）。
        _retry.reset();
        // steer/通知收件箱（DSH next-step inbox 语义）：排队的插话与
        // 系统通知在本 step 请求前落为 user 消息，模型下一条请求即看到。
        _drainInbox();
        // P1-C：环境快照尾部注入（内容变化才追加，见方法注释）。
        _maybeInjectEnvironmentNote();
        _session.append(kEventStepStart, {'turn': turn, 'step': step});
        // WP3a：主动压缩前置——估算投影 token，超预算先裁剪，
        // 不等撞 nctx/服务端硬墙（被动压缩只救得了 CONTEXT_WINDOW_EXCEEDED）。
        if (_config.contextTokenBudget != null) {
          await _maybeCompactProactively(turn, step);
        }
        // Phase 5：agent/pre-step hook（可否决本 step；reject → turn 结束）。
        if (_hooks != null) {
          final preCtx = PreStepContext(
            turn: turn,
            step: step,
            modelId: _modelId,
            history: _session.deriveModelMessages(),
          );
          final proceed = await _hooks.shouldProceed(preCtx);
          if (!proceed) {
            reason = TurnEndReasonKind.error;
            turnDone = true;
            break;
          }
        }
        bool retryStep = true;
        while (retryStep) {
          try {
            final options =
                _buildRequest(turn, step, imagePath, audioPath,
                    onStatus: onStatus, imagePaths: imagePaths);
            debugPrint('[AgentStep] t$turn s$step request '
                '(events=${_session.eventsCount})');
            final result = await _adapter.generate(
                options,
                onToken: onToken,
                onThinking: onThinking,
                cancel: _cancelCompleter,
            );
            _appendAssistant(turn, step, result);
            if (!result.hasToolCalls) {
              debugPrint('[AgentStep] t$turn s$step answer '
                  '${result.text.length} chars');
              _turnAnswer = result.text; // 本轮最终回答（无工具那步）
              turnDone = true;
              break; // 无工具调用 → turn 完成（最终回答）
            }
            // 有工具 → 逐工具执行；成功后进入下一个 step。
            debugPrint('[AgentStep] t$turn s$step tools='
                '${result.toolCalls.map((c) => c.name).toList()}');
            await _executeToolCalls(turn, step, result.toolCalls);
            _lastStepHadToolResults = true;
            if (_cancelCompleted) {
              reason = TurnEndReasonKind.interrupted;
              turnDone = true;
            }
            retryStep = false;
            break;
          } on LlmFailure catch (f) {
            // 用户已按停止：被中止的请求常以 LlmFailure 形态到达（API 侧
            // request cancelled / 本地 stopGeneration 打断流）。这**不是瞬态错误**，
            // 绝不能进重试瀑布——否则按下停止后循环自己又发起一次生成，用户看到的
            // 就是"停止按钮一点卵用都没有"（2026-10-24 定案，回归见
            // test/agent/stop_generation_test.dart）。
            if (_cancelCompleted) {
              debugPrint('[AgentStep] t$turn s$step 已取消，failure '
                  '${f.code.name} 不进重试 → interrupted');
              reason = TurnEndReasonKind.interrupted;
              turnDone = true;
              break;
            }
            // 失败 → 落 assistant/attempt（log-only，模型不可见）→ 跑瀑布。
            debugPrint('[AgentStep] t$turn s$step failure '
                '${f.code.name}: ${f.message}');
            _appendAttempt(turn, step, f);
            _turnError = f.message;
            final decision = await _handleFailure(turn, step, f);
            if (decision.kind == FailureDecisionKind.retry) {
              retryStep = true; // 同一 step 重试（_retries 已累加）
            } else {
              if (decision.detail != null) {
                _turnError = '${f.message}（${decision.detail}）';
              }
              reason = TurnEndReasonKind.error;
              turnDone = true;
              break;
            }
          } on AgentCancelledException catch (_) {
            reason = TurnEndReasonKind.interrupted;
            turnDone = true;
            break;
          }
        }
        _session.append(kEventStepEnd, {'turn': turn, 'step': step});
      }
    } finally {
      _session.append(kEventTurnEnd, {'turn': turn, 'reason': reason.name});
      debugPrint('[AgentStep] t$turn end reason=${reason.name} steps=$step '
          'elapsed=${(turnWatch.elapsedMilliseconds / 1000).toStringAsFixed(1)}s');
      _phase = AgentPhaseState(AgentPhase.idle, turn, step);
      final c = _cancelCompleter;
      if (c != null && !_cancelCompleted) {
        _cancelCompleted = true;
        c.complete();
      }
      _cancelCompleter = null;
    }
    return TurnEndReason(reason);
  }

  /// 取消当前 turn/step（DSH Part 14.6）。
  /// 完成取消 completer（adapter 内与流竞跑）并通知 adapter 停生成。
  Future<void> cancel([String? reason]) async {
    // **无条件**先置位：步与步之间（工具执行中、状态回调里、还没发起下一次
    // generate）取消时 _cancelCompleter 为 null，旧实现那时什么都不做，
    // _cancelCompleted 仍是 false → 下一步的取消检查放行 → 用户按了停止，
    // 循环自己接着往下跑（"停止按钮一点卵用都没有"的根因之一）。
    _cancelCompleted = true;
    final c = _cancelCompleter;
    if (c != null && !c.isCompleted) c.complete();
    _adapter.cancel();
  }

  /// G12：构建请求 —— 历史只能来自 [deriveModelMessages]。
  GenerateOptions _buildRequest(
    int turn,
    int step,
    String? imagePath,
    String? audioPath, {
    StreamController<String>? onStatus,
    List<String>? imagePaths,
  }) {
    final messages = _session.deriveModelMessages();
    final tools = _registry.visibleFor(_modelId);
    // WP3b 分阶段预算：工具结果回填后的步更可能是"组织最终回答"，
    // 小模型写回答比写工具调用耗 token 多——用更大的 finalRound 预算
    // 降截断率；工具调用步维持紧预算防过度生成。API 档 finalRound=null
    // 恒用统一大预算。
    final maxTokens =
        (_lastStepHadToolResults && _config.maxTokensFinalRound != null)
            ? _config.maxTokensFinalRound!
            : _config.maxTokensPerRound;
    // 思考失控治理（两条来源，任一命中本步就不思考）：
    // ① 工具决策步默认关思考——那一步只需产出一个工具调用，长思考纯属烧端侧
    //    预算，且实测是思考独白失控的高发区（[_config.thinkingOnToolSteps] 可放开）；
    // ② 上一步因思考失控被止损后的那次重试——同一模型同一配置原样重发必然再次失控。
    final forceNoThinking =
        _forceNoThinkingNext || (!_config.thinkingOnToolSteps && !_lastStepHadToolResults);
    _forceNoThinkingNext = false;
    final options = GenerateOptions(
      provider: _providerKind,
      messages: messages,
      tools: tools,
      temperature: _config.temperature,
      maxTokens: maxTokens,
      modelId: _modelId,
      imagePath: imagePath,
      audioPath: audioPath,
      imagePaths: imagePaths,
      onStatus: onStatus,
      forceNoThinking: forceNoThinking,
    );
    // G12 不变量（开发期 assert）：独立重建比对，请求必须能纯投影自 log。
    assert(
      _validateRebuild(messages),
      'G12: 请求与独立重建不一致（turn=$turn, step=$step）',
    );
    return options;
  }

  /// 独立重建比对：从 log 再派生一次，逐条比对结构。
  bool _validateRebuild(List<Map<String, dynamic>> messages) {
    final rebuilt = _session.deriveModelMessages();
    if (rebuilt.length != messages.length) return false;
    final allowedRoles = {'system', 'user', 'assistant', 'tool'};
    for (var i = 0; i < rebuilt.length; i++) {
      final a = rebuilt[i];
      final b = messages[i];
      if (a['role'] != b['role']) return false;
      if (!(allowedRoles.contains(a['role']))) {
        return false;
      }
      if (a['content'] != b['content']) return false;
      final ac = a['tool_calls'] as List?;
      final bc = b['tool_calls'] as List?;
      if (ac?.length != bc?.length) return false;
      if (bc is List && bc.isNotEmpty) {
        for (final tc in bc) {
          if (tc is! Map<String, dynamic>) return false;
          final tcM = tc;
          final id = (tcM['id'] ?? tcM['call_id']) as String?;
          final name = (tcM['name'] ?? tcM['function_name']) as String?;
          if (id == null || name == null) return false;
        }
      }
      if (a['role'] == 'tool' && a['tool_call_id'] == null) return false;
    }
    return true;
  }

  void _appendAssistant(int turn, int step, LlmResult result) {
    final encodedCalls = <Map<String, dynamic>>[];
    for (final call in result.toolCalls) {
      encodedCalls.add({
        'call_id': call.id,
        'name': call.name,
        'arguments': call.arguments,
      });
    }
    _session.append(kEventAssistantMessage, {
      'content': result.text,
      'toolCalls': encodedCalls,
      'turn': turn,
      'step': step,
      // API 路线 token 用量（SSE 末块 usage；本地恒 null 不落键）。
      if (result.usage != null) 'usage': result.usage,
    });
  }

  /// WP3a 主动压缩：估算当前投影 token（content 字符数/4，与
  /// Spill.estimateTokens 同口径，tool_calls 每条粗估 40 字符），
  /// 超预算 → 走与 contextWindowExceeded 相同的确定性压缩路径
  /// （decide 内部自行追加 compaction/summary + 影子遮蔽）。
  /// 无可裁（decide 非 success）不致命——真超限仍由失败瀑布兜底。
  Future<void> _maybeCompactProactively(int turn, int step) async {
    final budget = _config.contextTokenBudget!;
    final messages = _session.deriveModelMessages();
    // 中文加权估算（context_eng/token_estimate）：旧 chars/4 口径对中文
    // 低估 ~3 倍，主动压缩迟迟不触发直到撞服务端硬墙。
    final estTokens = estimateContextTokens(messages);
    if (estTokens <= budget) return;
    final result = await _compaction.decide(
      ref: SessionRef(_session),
      turn: turn,
      step: step,
      reason: 'proactive: 估算约 $estTokens tok 超预算 $budget（主动前置压缩）',
    );
    final stats = result.stats;
    if (result.kind == CompactionResultKind.success) {
      debugPrint('[AgentStep] t$turn s$step proactive compaction: '
          '~$estTokens > $budget；压缩后 ~${stats?.afterTokens ?? '?'} tok');
    }
  }

  /// 失败 → 落 assistant/attempt（log-only，模型不可见）。
  void _appendAttempt(int turn, int step, LlmFailure f) {
    _session.append(kEventAssistantAttempt, {
      'turn': turn,
      'step': step,
      'code': f.code.name,
      'content': f.message,
    });
  }

  /// 失败瀑布（DSH Part 9.9）：compaction → llm-retry → giveUp。
  Future<FailureDecision> _handleFailure(
    int turn,
    int step,
    LlmFailure f,
  ) async {
    // 0. 已取消：任何失败都不再重试，也不再走压缩（压缩会改写会话并再发一次
    //    请求 = 用户喊停后仍在烧 token）。
    if (_cancelCompleted) {
      return const FailureDecision(FailureDecisionKind.giveUp,
          detail: '用户已停止');
    }
    // 1. compaction（CONTEXT_WINDOW_EXCEEDED）：仅当已推进 generation 才 retry。
    //    压缩事件（compaction/summary）由 [DeterministicCompaction.decide]
    //    内部以 [SessionLog.replace] 追加（shadow 旧区 + 摘要），此处不再重复。
    if (f.isContextWindowExceeded) {
      final result = await _compaction.decide(
        ref: SessionRef(_session),
        turn: turn,
        step: step,
        reason: f.message,
      );
      if (result.kind == CompactionResultKind.success) {
        return const FailureDecision(FailureDecisionKind.retry);
      }
    }
    // 2. llm-retry（瞬态错误，有界 + 退避）。
    if (_retry.isRetryable(f)) {
      _session.append(kEventLlmRetry, {
        'turn': turn,
        'step': step,
        'retries': _retry.retries,
        'code': f.code.name,
        'message': f.message,
      });
      // WP1b：模型可见的失败原因注记（surface）。重试不再原样重发——
      // 下次请求投影出 [上次尝试失败:...] 提示，模型先反思再修正。
      // 截断 200 字防长报错撑上下文（deriveModelMessages 每 (turn,step)
      // 只留最新一条）。
      _session.append(kEventAssistantFailureNote, {
        'turn': turn,
        'step': step,
        'code': f.code.name,
        'content': f.message.length > 200
            ? '${f.message.substring(0, 200)}…'
            : f.message,
      });
      final delay = await _retry.maybeBackoff(f);
      if (delay == null) {
        return const FailureDecision(FailureDecisionKind.giveUp,
            detail: 'llm-retry exhausted');
      }
      // 思考失控的重试必须换条件：本次请求强制不思考（见 _buildRequest）。
      if (_retry.takeForceNoThinking()) _forceNoThinkingNext = true;
      debugPrint('[AgentStep] t$turn s$step retry ${_retry.retries}/'
          '${_retry.maxRetries} in ${delay.inMilliseconds}ms');
      return const FailureDecision(FailureDecisionKind.retry);
    }
    // 3. 默认 → 终态失败。
    return const FailureDecision(FailureDecisionKind.giveUp);
  }

  /// 回合内重复调用去重缓存：`name+args` 签名 → 首次 ToolResult。
  /// kick 时清空（每回合独立）。重复调用不再真执行，回缓存结果 +
  /// 收敛提示，逼模型直接回答。
  final Map<String, ToolResult> _turnToolCallCache = {};

  /// 本回合各工具调用计数（重复守护用），kick 时清空。
  final Map<String, int> _turnToolCallCounts = {};

  // ---- steer / 通知收件箱（DSH next-step inbox 语义）----
  // [steer] 用户回合中插话（下一条模型请求即看到，不新开回合）；
  // [injectNotice] 系统产生的通知（如后台子代理完成），同样搭下一 step。
  // 队列在 step 边界统一 drain 为 user 消息事件（模型可见、log 溯源）；
  // kick 时清空（跨回合残留的插话没有意义——回合已结束，用户重发即可）。
  final List<String> _steerQueue = [];
  final List<String> _noticeQueue = [];

  /// 回合中转向：用户插话进入**当前回合**的下一个 step（DSH `steer`）。
  /// 不唤醒、不新开回合——仅当回合仍在跑时生效；agent idle 时调用方
  /// 应直接走正常 sendMessage。
  void steer(String text) {
    final t = text.trim();
    if (t.isNotEmpty) _steerQueue.add(t);
  }

  /// 系统通知注入（DSH `inject`）：后台任务结果等运行时事件搭下一 step
  /// 进入模型上下文，不带用户语义。
  void injectNotice(String text) {
    final t = text.trim();
    if (t.isNotEmpty) _noticeQueue.add(t);
  }

  /// step 边界统一 drain：系统通知在前（任务事实），用户插话在后（最新
  /// 指令最靠近请求），模型按时间序读到。
  void _drainInbox() {
    while (_noticeQueue.isNotEmpty) {
      _session.append(
        kEventUserMessage,
        {'content': '[系统通知] ${_noticeQueue.removeAt(0)}'},
        source: const {'kind': 'notice'},
      );
    }
    while (_steerQueue.isNotEmpty) {
      _session.append(
        kEventUserMessage,
        {'content': '[用户插话] ${_steerQueue.removeAt(0)}'},
        source: const {'kind': 'steer'},
      );
    }
  }

  /// kick 时清空收件箱（上回合残留的插话/通知不再投喂）。
  void _clearInbox() {
    _steerQueue.clear();
    _noticeQueue.clear();
  }

  /// P1-C 环境快照尾部注入：每个 step 边界取一次 provider，内容与上次
  /// 相同（时间桶未滚动）不重复注入；变化才以尾部 user 消息追加——
  /// 追加不破坏既有前缀，系统提示保持逐字节稳定（API prompt cache
  /// 全段命中；旧 environmentNote 系统提示内嵌形态每个回合都破缓存，
  /// 此形态把它从 100% 破缓存降到每 10 分钟一次小追加）。
  void _maybeInjectEnvironmentNote() {
    final provider = _environmentNoteProvider;
    if (provider == null) return;
    String note;
    try {
      note = provider();
    } on Exception {
      return; // 提供者异常静默跳过（环境快照非关键路径）
    }
    final t = note.trim();
    if (t.isEmpty || t == _lastEnvNote) return;
    _lastEnvNote = t;
    _session.append(
      kEventUserMessage,
      {'content': '【环境】$t'},
      source: const {'kind': 'env-note'},
    );
  }

  /// 回合引导消息（收尾/收敛警告）：以 user 事件入 log，仅本回合内可见
  /// —— trace 信封只编码 assistant(toolCalls)/tool/result，下回合导入
  /// 自然消失，不污染跨回合历史。
  void _appendTurnGuidance(String content) {
    _session.append(
      kEventUserMessage,
      {'content': content},
      source: const {'kind': 'system-guidance'},
    );
  }

  /// 单次工具调用安全包装（流水线异常不逃逸，转 ToolResult）。
  Future<ToolResult> _safeExecute(ToolCall call) async {
    try {
      return await _pipeline.execute(call, _modelId);
    } catch (e) {
      return ToolResult.error('工具 "${call.name}" 流水线异常: $e');
    }
  }

  /// 工具调用签名（name + 规范化参数 JSON）；参数不可编码时退化 name。
  static String _toolCallSignature(ToolCall call) {
    try {
      return '${call.name}#${jsonEncode(call.arguments ?? const {})}';
    } catch (_) {
      return '${call.name}#';
    }
  }

  /// 执行一轮工具调用（tool/call → 执行 → tool/result）。
  ///
  /// Phase 2：走六段流水线 [ToolPipeline]；`allowParallelTools` 时按
  /// [config.maxParallel] 分批并发执行，否则串行。日志/ UI 始终按模型
  /// 调用顺序落 tool/call、tool/result（保持模型视角一致）。
  Future<void> _executeToolCalls(
    int turn,
    int step,
    List<ToolCall> calls,
  ) async {
    if (calls.isEmpty) return;

    // ---- 1. 先记 tool/call + 触发 executing（全部先记，保模型顺序）----
    for (final call in calls) {
      _session.append(kEventToolCall, {
        'callId': call.id,
        'name': call.name,
        'turn': turn,
        'step': step,
        // Phase 6：UI 工具卡片展示参数（可选属性，向后兼容）。
        'arguments': call.arguments ?? const <String, dynamic>{},
      });
      if (_onToolActivity != null) {
        await _onToolActivity(ToolActivity(name: call.name, status: 'executing'));
      }
    }

    // ---- 2. 执行：重复调用回缓存（不再真执行），只执行首次出现的调用 ----
    final results = List<ToolResult>.filled(calls.length, ToolResult(content: ''));
    final pendingIndex = <int>[];
    for (var i = 0; i < calls.length; i++) {
      final sig = _toolCallSignature(calls[i]);
      final cached = _turnToolCallCache[sig];
      if (cached != null) {
        results[i] = ToolResult(
          content: '${cached.content}\n'
              '[重复调用提示：本回合已执行过完全相同的调用，以上即当时结果。'
              '请直接依据已有结果回答用户，不要再重复调用工具]',
          isError: cached.isError,
        );
      } else {
        pendingIndex.add(i);
      }
    }
    if (pendingIndex.isNotEmpty) {
      final freshCalls = [for (final i in pendingIndex) calls[i]];
      final freshResults = await _runCalls(turn, step, freshCalls);
      for (var j = 0; j < pendingIndex.length; j++) {
        final i = pendingIndex[j];
        results[i] = freshResults[j];
        _turnToolCallCache[_toolCallSignature(calls[i])] = freshResults[j];
      }
    }

    // ---- 3. 按模型顺序记 tool/result + 触发 done/failed ----
    for (var i = 0; i < calls.length; i++) {
      final call = calls[i];
      final result = results[i];
      // 通用重复守护：计数命中 3/5/8 → 结果尾部追加渐进提醒（DSH
      // repeat-tool-reminder 语义，advisory 不阻断）。
      final n = (_turnToolCallCounts[call.name] ?? 0) + 1;
      _turnToolCallCounts[call.name] = n;
      var content = result.content;
      if (kRepeatReminderSteps.contains(n)) {
        content = '${content.isEmpty ? '' : '$content\n'}'
            '[提醒：这是本回合第 $n 次调用 ${call.name}。'
            '先检查上面已有的调用结果：结果已足够就直接回答用户；'
            '结果无效就换方法/换参数，不要继续重复同样的调用]';
      }
      _session.append(kEventToolResult, {
        'callId': call.id,
        'name': call.name,
        'turn': turn,
        'step': step,
        'content': content,
        'isError': result.isError,
      });
      // Phase 5：tools/result hook（read-only 同步通知）。
      _hooks?.notifyResult(call, result);
      if (_onToolActivity != null) {
        await _onToolActivity(
            ToolActivity(
                name: call.name,
                status: result.isError ? 'failed' : 'done',
                result: content));
      }
    }
  }

  /// 执行一批工具调用：`allowParallelTools` 则按 [AgentConfig.maxParallel]
  /// 分批并发（batch 内并发、batch 间串行，并发上限 = maxParallel），
  /// 否则串行。返回按 [calls] 顺序排列的 [ToolResult] 列表。
  ///
  /// P2-A 并发安全语义（DSH isConcurrencySafe 消费）：
  /// - 声明非并行安全（`concurrencySafeFor(args)==false`，默认）的调用
  ///   **独占一批**执行——写文件/发请求等有副作用的操作不与兄弟调用并发；
  /// - 回合被用户中断时，未完成的调用以**合成占位结果**回填（结果未知、
  ///   提示模型先核实再重试），与崩溃修复 closeOpenTurns 的合成回执同语义，
  ///   保证每个 tool/call 都有配对 tool/result（G 不变量）。
  Future<List<ToolResult>> _runCalls(
    int turn,
    int step,
    List<ToolCall> calls,
  ) async {
    final maxParallel = _config.allowParallelTools ? _config.maxParallel : 1;
    if (maxParallel <= 1 || calls.length <= 1) {
      return _runSerial(calls);
    }
    // 分批：非并行安全的调用独占一批；安全调用按 maxParallel 凑批。
    final batches = <List<ToolCall>>[];
    var safeBatch = <ToolCall>[];
    void flushSafe() {
      if (safeBatch.isEmpty) return;
      batches.add(safeBatch);
      safeBatch = <ToolCall>[];
    }

    for (final call in calls) {
      final def = _registry.lookup(call.name, modelId: _modelId);
      final safe = def?.concurrencySafeFor(call.arguments ?? const {}) ?? false;
      if (safe) {
        safeBatch.add(call);
        if (safeBatch.length >= maxParallel) flushSafe();
      } else {
        flushSafe();
        batches.add([call]);
      }
    }
    flushSafe();

    final results = <ToolResult>[];
    for (final batch in batches) {
      if (_cancelCompleted) {
        // 已中断：剩余批次全部合成占位（不再发起新执行）。
        results.addAll(batch.map(_interruptedPlaceholder));
        continue;
      }
      if (batch.length == 1) {
        results.add(await _safeExecute(batch.first));
        continue;
      }
      // 并发启动，按序收口；中断时未收口的以占位回填（后台 future 由
      // _safeExecute 自行捕获异常，不会被丢弃成 unhandled error）。
      final futures = batch.map(_safeExecute).toList();
      var completed = true;
      for (var i = 0; i < futures.length; i++) {
        if (_cancelCompleted && i > 0) {
          completed = false;
          break;
        }
        results.add(await futures[i]);
      }
      if (!completed) {
        for (var j = results.length; j < batch.length; j++) {
          results.add(_interruptedPlaceholder(batch[j]));
        }
      }
    }
    return results;
  }

  /// 串行路径：逐个执行；中断后剩余调用合成占位。
  Future<List<ToolResult>> _runSerial(List<ToolCall> calls) async {
    final results = <ToolResult>[];
    for (final call in calls) {
      if (_cancelCompleted) {
        results.add(_interruptedPlaceholder(call));
        continue;
      }
      results.add(await _safeExecute(call));
    }
    return results;
  }

  /// 中断占位结果：与 closeOpenTurns 合成回执同语义（结果未知、先核实）。
  static ToolResult _interruptedPlaceholder(ToolCall call) => ToolResult.error(
      '该调用（${call.name}）因回合被用户中断而未完成，执行结果未知；'
      '工具可能已部分生效，重试前请先核实状态');
}