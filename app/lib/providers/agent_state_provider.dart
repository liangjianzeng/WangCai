/// Phase 6 UI 状态（设计文档 §12.2）—— 订阅 SessionLog 事件流的 reducer。
///
/// 数据流（§12.4）：ReactLoopAgent 追加事件 → SessionLog.events →
/// [AgentUiStateNotifier] 归约 → UI 组件（工具卡片/压缩横幅/重试指示/徽章）。
///
/// 端侧简化：状态是**本 turn 活动视图**（tool 卡片在下一 turn attach 时清空；
/// 历史回看仍走消息列表投影）。不改变 SessionLog 唯一真相源地位。
library;

import 'dart:async';

import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../agent/session/event.dart';
import '../agent/session/log.dart';

/// 工具卡片状态。
enum ToolUiStatus { executing, done, failed }

/// 单个工具活动（tool/call + tool/result 归并）。
final class ToolActivityUi {
  final String callId;
  final String name;
  final Map<String, dynamic> arguments;
  ToolUiStatus status;
  String? result;
  bool isError;

  ToolActivityUi({
    required this.callId,
    required this.name,
    required this.arguments,
    this.status = ToolUiStatus.executing,
    this.result,
    this.isError = false,
  });
}

/// 时间线标记：本 turn 内某个元素何时出现（真实执行次序）。
/// 归约器按事件到达顺序追加；AgentTurnBlock 依此交错渲染思考存档与工具卡
/// （用户反馈：工具调用和思考的位置经常不按执行顺序呈现）。
sealed class UiTimelineMarker {
  const UiTimelineMarker();
}

/// 第 [index] 个思考存档（对应 [AgentUiState.thinkingHistory]）。
final class UiTimelineThinking extends UiTimelineMarker {
  final int index;
  const UiTimelineThinking(this.index);
}

/// 第 [index] 个工具卡（对应 [AgentUiState.tools]）。
final class UiTimelineTool extends UiTimelineMarker {
  final int index;
  const UiTimelineTool(this.index);
}

/// UI 状态快照（§12.2 AgentState 的端侧形态）。
final class AgentUiState {
  final bool running;
  final int turn;
  final int step;
  final List<ToolActivityUi> tools;

  /// >0：正在 llm-retry（第 N 次）。
  final int retryAttempt;

  /// 本 turn 发生过 compaction/summary（CompactionBanner）。
  final bool compacted;

  /// turn/end 的失败原因（error 时展示；completed 清空）。
  final String? lastError;

  /// 本 turn 思考流快照（adapter onThinking 推送的全量文本；
  /// 每个新 turn attach 时清空）。空串 = 本轮无思考输出。
  final String thinking;

  /// 已完成步骤的思考块存档：step 边界（kEventStepStart/turn end）把当时的
  /// thinking 快照落档并清空流式缓冲——工作流里每一步的思考都以折叠条
  /// 保留，下一步思考另起新卡流式（用户要求：过程可回看）。
  final List<String> thinkingHistory;

  /// 与 [thinkingHistory] 平行的各步思考耗时（null = 未知/历史无数据），
  /// 供存档卡显示「思考 - 持续了X秒」（用户定案：避免空洞的"思考 1/2/3"）。
  final List<Duration?> thinkingDurations;

  /// 执行顺序时间线：思考落档/工具卡加入的真实次序（live 回合渲染依据）。
  final List<UiTimelineMarker> timeline;

  /// 工具调用参数生成中（WP5）：非 null = 模型正在流式输出工具调用块
  /// （可见流与思考流都是空的，没有它 UI 只能干转圈）。
  /// 记录已生成字符数与开头预览。
  final ({int chars, String preview})? toolGen;

  const AgentUiState({
    this.running = false,
    this.turn = 0,
    this.step = 0,
    this.tools = const [],
    this.retryAttempt = 0,
    this.compacted = false,
    this.lastError,
    this.thinking = '',
    this.thinkingHistory = const [],
    this.thinkingDurations = const [],
    this.timeline = const [],
    this.toolGen,
  });

  bool get hasActivity =>
      running || tools.isNotEmpty || lastError != null || compacted;

  bool get hasThinking => thinking.isNotEmpty;

  AgentUiState copyWith({
    bool? running,
    int? turn,
    int? step,
    List<ToolActivityUi>? tools,
    int? retryAttempt,
    bool? compacted,
    String? lastError,
    bool clearError = false,
    String? thinking,
    List<String>? thinkingHistory,
    List<Duration?>? thinkingDurations,
    List<UiTimelineMarker>? timeline,
    ({int chars, String preview})? toolGen,
    bool clearToolGen = false,
  }) =>
      AgentUiState(
        running: running ?? this.running,
        turn: turn ?? this.turn,
        step: step ?? this.step,
        tools: tools ?? this.tools,
        retryAttempt: retryAttempt ?? this.retryAttempt,
        compacted: compacted ?? this.compacted,
        lastError: clearError ? null : (lastError ?? this.lastError),
        thinking: thinking ?? this.thinking,
        thinkingHistory: thinkingHistory ?? this.thinkingHistory,
        thinkingDurations: thinkingDurations ?? this.thinkingDurations,
        timeline: timeline ?? this.timeline,
        toolGen: clearToolGen ? null : (toolGen ?? this.toolGen),
      );
}

/// 事件 → 状态归约器。状态**按会话（convId）分键**：多会话并发（槽位）
/// 时每个回合的事件流互不串台，UI 取当前会话自己的快照。
/// attach(convId, log) 订阅该会话回合事件；detach(convId) 只停订阅、
/// 保留末态（面板在 turn 结束后仍显示本轮活动）。
class AgentUiStateNotifier extends StateNotifier<Map<String, AgentUiState>> {
  AgentUiStateNotifier() : super(const {});

  /// 每会话事件订阅（detach 后移除；末态留在 state map 里）。
  final Map<String, StreamSubscription<SessionEvent>> _subs = {};

  /// 每会话归约上下文（当前思考块起点等）。
  final Map<String, _TurnCtx> _ctx = {};

  bool _has(String convId) => state.containsKey(convId);

  AgentUiState _entry(String convId) =>
      state[convId] ?? const AgentUiState();

  void _put(String convId, AgentUiState s) {
    state = {...state, convId: s};
  }

  /// 思考流推送（adapter 全量快照）。节流由调用方（chat_provider）负责，
  /// 这里直接落 state——事件频率低（流 delta 聚合后）。
  void setThinking(String convId, String text) {
    if (!mounted || !_has(convId)) return;
    final cur = _entry(convId);
    if (cur.thinking == text) return;
    final ctx = _ctx.putIfAbsent(convId, _TurnCtx.new);
    ctx.thinkingStart ??= (text.isNotEmpty) ? DateTime.now() : null;
    _put(convId, cur.copyWith(thinking: text));
  }

  /// 工具调用参数生成进度（WP5）。chars==0 → 清除。
  void setToolGen(String convId, {required int chars, String preview = ''}) {
    if (!mounted || !_has(convId)) return;
    final cur = _entry(convId);
    if (chars <= 0) {
      if (cur.toolGen == null) return;
      _put(convId, cur.copyWith(clearToolGen: true));
      return;
    }
    _put(convId, cur.copyWith(toolGen: (chars: chars, preview: preview)));
  }

  void attach(String convId, SessionLog log) {
    detachSub(convId);
    _ctx[convId] = _TurnCtx();
    _put(convId, const AgentUiState());
    _subs[convId] = log.events.listen((e) => onEvent(convId, e));
  }

  /// 停订阅并**保留末态**（面板在 turn 结束后仍显示本轮活动）。
  void detach(String convId) {
    detachSub(convId);
    _ctx.remove(convId);
  }

  /// 仅取消事件订阅（attach 重入时用，不动状态与上下文）。
  void detachSub(String convId) {
    _subs.remove(convId)?.cancel();
  }

  @override
  void dispose() {
    for (final sub in _subs.values) {
      sub.cancel();
    }
    _subs.clear();
    _ctx.clear();
    super.dispose();
  }

  /// 把当前流式思考快照落档（step 边界/turn 结束时调用），清空流式缓冲。
  /// 落档时顺带记录耗时（起点未知 → null），供存档卡显示"持续了X秒"；
  /// 并追加时间线标记（思考存档在**此刻**进入渲染序列，而不是一律排最前）。
  AgentUiState _finalizeThinking(AgentUiState s, _TurnCtx ctx) {
    if (s.thinking.isEmpty) return s;
    Duration? dur;
    if (ctx.thinkingStart != null) {
      dur = DateTime.now().difference(ctx.thinkingStart!);
      ctx.thinkingStart = null;
    }
    return s.copyWith(
      thinkingHistory: [...s.thinkingHistory, s.thinking],
      thinkingDurations: [...s.thinkingDurations, dur],
      timeline: [...s.timeline, UiTimelineThinking(s.thinkingHistory.length)],
      thinking: '',
    );
  }

  /// 事件归约（按会话键入；只产新 state，不改 log）。测试可直接调用。
  void onEvent(String convId, SessionEvent e) {
    if (!mounted) return;
    final ctx = _ctx.putIfAbsent(convId, _TurnCtx.new);
    var s = _entry(convId);
    switch (e.type) {
      case kEventTurnStart:
        s = AgentUiState(
          running: true,
          turn: (e.data['turn'] as num?)?.toInt() ?? s.turn,
        );
        break;
      case kEventStepStart:
        // step 边界：上一步的思考已结束 → 落档折叠，新 step 另起思考卡。
        s = _finalizeThinking(s, ctx).copyWith(
          step: (e.data['step'] as num?)?.toInt() ?? s.step);
        break;
      case kEventToolCall:
        final tools = [...s.tools, ToolActivityUi(
          callId: e.data['callId'] as String? ?? '',
          name: e.data['name'] as String? ?? '',
          arguments: (e.data['arguments'] as Map<String, dynamic>?) ??
              const {},
        )];
        s = s.copyWith(
          tools: tools,
          timeline: [...s.timeline, UiTimelineTool(tools.length - 1)],
        );
        break;
      case kEventToolResult:
        final callId = e.data['callId'] as String? ?? '';
        final isError = e.data['isError'] as bool? ?? false;
        final content = e.data['content'] as String? ?? '';
        final tools = [...s.tools];
        for (var i = tools.length - 1; i >= 0; i--) {
          // 从后向前找同 callId 的 executing 卡片（并行调用同名的场合）。
          if (tools[i].callId == callId) {
            tools[i]
              ..status = isError ? ToolUiStatus.failed : ToolUiStatus.done
              ..result = content
              ..isError = isError;
            break;
          }
        }
        s = s.copyWith(tools: tools);
        break;
      case kEventLlmRetry:
      case kEventLlmRetryStarted:
        s = s.copyWith(
            retryAttempt: (e.data['retries'] as num?)?.toInt() ??
                s.retryAttempt + 1);
        break;
      case kEventCompactionSummary:
        s = s.copyWith(compacted: true);
        break;
      case kEventTurnEnd:
        final kind = _reasonKind(e.data['reason']);
        s = _finalizeThinking(s, ctx).copyWith(
          running: false,
          retryAttempt: 0,
          lastError: kind == 'error' ? '本轮执行失败（见推理日志）' : null,
          clearError: kind != 'error',
        );
        break;
      default:
        return;
    }
    _put(convId, s);
  }

  /// reason 双形态兼容：主循环写 String（completed/...），崩溃修复写
  /// Map（{kind: ...}）。
  static String _reasonKind(Object? reason) {
    if (reason is String) return reason;
    if (reason is Map) return reason['kind'] as String? ?? '';
    return '';
  }
}

/// 单会话归约上下文。
class _TurnCtx {
  /// 当前思考块的起点（首个非空 thinking 推送时记录；落档后复位）。
  DateTime? thinkingStart;
}

final agentUiStateProvider =
    StateNotifierProvider<AgentUiStateNotifier, Map<String, AgentUiState>>(
        (ref) => AgentUiStateNotifier());
