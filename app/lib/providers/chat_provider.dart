import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data' show Uint8List;
import 'package:dio/dio.dart';
import 'package:flutter/foundation.dart' show debugPrint;
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';
import '../models/chat_message.dart';
import '../models/conversation.dart';
import '../models/turn_trace.dart';

import '../agent/agent.dart';
import '../agent/dev/dev.dart'
    show DevSessionController, buildDevContext, sanitizeWorkspaceDirName;
import '../agent/dev/tools/ssh_tools.dart' show readRemoteAgentsMd;
import '../agent/dev/workspace.dart' show DevWorkspace;
import '../agent/web_search/web_search_provider.dart';
import '../agent/context_eng/compaction.dart' show DeterministicCompaction;
import '../agent/context_eng/token_estimate.dart' show estimateContextTokens;
import '../tts/edge_tts_service.dart' show EdgeTtsService;
import '../agent/loop/agent.dart'
    show ReactLoopAgent, TurnEndReason, TurnEndReasonKind;
import '../agent/loop/config.dart' as loopConfig;
import '../agent/capability.dart';
import '../models/model_catalog.dart' show ModelCatalog;
import '../agent/llm/adapter.dart'
    show LlmAdapter, ProviderKind, GenerateOptions;
import '../agent/llm/local_adapter.dart' show LocalEngineAdapter;
import '../agent/llm/openai_adapter.dart' show OpenAiAdapter;
import '../agent/protocol/protocol_selector.dart' show selectProtocol;
import '../agent/protocol/prompt_json_protocol.dart' show PromptJsonProtocol;
import '../agent/protocol/native_tool_protocol.dart' show NativeToolProtocol;
import '../agent/subagents/in_process.dart' show InProcessSubagentProvider;
import '../agent/subagents/subagent_tool.dart'
    show createSubagentTool, createSubagentSendMessageTool;
import '../agent/hooks/hooks.dart' show AgentHooks;
import '../agent/skills/load_skill_tool.dart' show createLoadSkillTool;
import '../agent/skills/save_skill_tool.dart' show createSaveSkillTool;
import '../agent/builtin_tools/memory_tool.dart' show readGlobalMemorySnapshot;
import '../agent/builtin_tools/ask_user_tool.dart' show createAskUserTool;
import '../agent/builtin_tools/goal_tools.dart'
    show createGoalTools, createExitPlanTool, createPlanStepUpdateTool;
import '../agent/mcp/mcp_client.dart' show fetchMcpTools;
import '../agent/goal/goal_store.dart'
    show GoalStore, GoalStatus, GoalAction, decideGoalAction;
import '../agent/builtin_tools/run_code_tool.dart' show createRunCodeTool;
import '../agent/skills/provider.dart' show SkillProvider, loadUserSkills;
import '../agent/skills/skill.dart' show loadBuiltinSkills;
import '../agent/agents_md/agents_md.dart' show loadAgentsMd;
import '../agent/session/store.dart'
    show
        JsonlSessionStore,
        kAgentTraceMessagePrefix,
        encodeAgentTraceMessage,
        planStorageCompaction;
import '../agent/session/event.dart'
    show kEventAssistantMessage, kEventCompactionSummary;
import '../agent/metrics/turn_metrics.dart'
    show TurnMetrics, TurnMetricsStore;
import '../agent/session/trace_export.dart' as trace_export;
import '../models/api_model.dart';
import '../services/inference_service.dart';
import '../services/long_image_service.dart';
import '../services/attachment_service.dart'
    show
        PreparedAttachment,
        buildAttachmentPromptBlock,
        kMaxAttachments,
        prepareAttachment;
import '../services/openai_service.dart';
import '../services/settings_service.dart';
import '../services/storage_service.dart';
import 'agent_approval.dart'
    show sandboxApproverProvider, toolPreApproverProvider;
import 'agent_state_provider.dart'
    show agentUiStateProvider, UiTimelineThinking, UiTimelineTool;
import 'shared_providers.dart'
    show inferenceServiceProvider, openAiServiceProvider;
import 'settings_provider.dart' show settingsProvider;
import '../services/app_bridge.dart' show AppBridge;
import 'context_usage_provider.dart' show contextUsageProvider;

// Re-export for other files that need these types.
export 'model_provider.dart'
    show ModelManagerNotifier, ModelState, ModelLifecyclePhase;

// Import model_managerProvider so ChatNotifier can reference it without circular imports.
import 'model_provider.dart';

// ---------------------------------------------------------------------------
// Services (singletons)
// ---------------------------------------------------------------------------

final storageServiceProvider =
    Provider<StorageService>((ref) => StorageService());

// ---------------------------------------------------------------------------
// Model selection — the currently active model ID
// ---------------------------------------------------------------------------

/// Currently selected model ID. Defaults to Qwen3.5-2B (MTP) which is the
/// recommended balance of quality, speed and memory usage for most phones.
///
/// ⚠️ 这只是 UI 层的"上次选中"占位，**不得**作为隐式加载触发器：
/// 用户没勾默认模型时，任何路由都不许拿它去 loadModel（2026-09-29
/// 修复"智能体对话莫名自动加载本地模型"——占位 id 曾被兜底路径当真）。
final currentModelIdProvider =
    StateProvider<String>((ref) => 'qwen3.5-2b-mtp-ud-q4_k_xl');

// ---------------------------------------------------------------------------
// 生成路由决策（纯函数，可机检）
// ---------------------------------------------------------------------------

/// 一次生成的路由计划。
class GenerationRoutePlan {
  final bool useApi;

  /// 本地路线应加载/使用的模型 id（useApi=false 时非空）。
  final String? localModelId;

  /// 非空 = 无法路由（调用方应直接把该文案返回给用户，不得再触发加载）。
  final String? error;

  const GenerationRoutePlan._(this.useApi, this.localModelId, this.error);
  const GenerationRoutePlan.api() : this._(true, null, null);
  const GenerationRoutePlan.local(String id) : this._(false, id, null);
  const GenerationRoutePlan.failure(String message)
      : this._(false, null, message);
}

/// 路由规则（普通聊天与智能体"跟随默认"共用）：
///
/// - **无本地意图**（当前没加载任何模型 且 未勾选默认模型）→ 有激活 API 走
///   API；没有 API 也不许隐式加载本地模型——出厂占位 id 不是用户意图，
///   由此修复"没勾默认却莫名加载 qwen 占位模型、把 API 驱动带偏"的 bug。
/// - **有本地意图** → local-first：目标 = 已加载模型 > 默认勾选 > 上次选中；
///   本地加载失败再回退 API（由调用方执行，回退语义与此前一致）。
GenerationRoutePlan planGenerationRoute({
  required InferenceSettings settings,
  required bool localLoaded,
  required String? loadedModelId,
  required String fallbackModelId,
}) {
  final defaultId = settings.defaultModelId;
  final hasDefault = defaultId != null && defaultId.isNotEmpty;
  if (!localLoaded && !hasDefault) {
    final activeApi = settings.activeApiModel();
    if (activeApi != null) return const GenerationRoutePlan.api();
    return const GenerationRoutePlan.failure(
        '[未配置任何模型：请在 设置→模型管理 勾选默认模型，或在 设置→API 接入 配置并启用]');
  }
  final target = localLoaded
      ? (loadedModelId ?? (hasDefault ? defaultId : fallbackModelId))
      : (hasDefault ? defaultId : fallbackModelId);
  return GenerationRoutePlan.local(target);
}

/// 显式本地驱动（智能体 agentModelSource='local'）的目标模型 id：
/// agentModelId > 默认勾选 > 已加载模型；返回 null = 无明确本地意图，
/// 调用方必须报错而不是隐式加载出厂占位模型。
String? resolveExplicitLocalTarget({
  required String? agentModelId,
  required String? defaultModelId,
  required bool localLoaded,
  required String? loadedModelId,
}) {
  if (agentModelId != null && agentModelId.isNotEmpty) return agentModelId;
  if (defaultModelId != null && defaultModelId.isNotEmpty)
    return defaultModelId;
  if (localLoaded) return loadedModelId;
  return null;
}

// ---------------------------------------------------------------------------
// Conversations
// ---------------------------------------------------------------------------

final conversationsProvider =
    StateNotifierProvider<ConversationsNotifier, List<Conversation>>((ref) {
  return ConversationsNotifier(ref.read(storageServiceProvider));
});

class ConversationsNotifier extends StateNotifier<List<Conversation>> {
  final StorageService _storage;
  Completer<void>? _loadCompleter;
  ConversationsNotifier(this._storage) : super([]) {
    _ensureLoaded();
  }

  /// Load conversations from storage exactly once. Multiple callers can await
  /// the same future without triggering duplicate queries.
  Future<void> _ensureLoaded() {
    if (_loadCompleter == null) {
      _loadCompleter = Completer<void>();
      _storage.getAllConversations().then((list) {
        state = list;
        _loadCompleter!.complete();
      }).catchError((e) {
        _loadCompleter!.completeError(e);
      });
    }
    return _loadCompleter!.future;
  }

  Future<void> ensureLoaded() => _ensureLoaded();

  Future<void> create({String title = '新对话'}) async {
    final conv = await _storage.createConversation(title: title);
    state = [conv, ...state];
  }

  Future<void> delete(String id) async {
    await _storage.deleteConversation(id);
    // 计划按会话管理（2026-10-25 用户定案）：会话删除 → 计划文件随删。
    unawaited(() async {
      try {
        final base = await getApplicationSupportDirectory();
        await GoalStore(baseDir: '${base.path}/goals').deletePlan(id);
      } catch (_) {}
    }());
    state = state.where((c) => c.id != id).toList();
  }

  /// 用更新后的元信息替换 state 中的对应会话（标题 / 消息条数变化）。
  void update(Conversation updated) {
    state = state.map((c) => c.id == updated.id ? updated : c).toList();
  }
}

/// 当前打开的会话 id（没有就是 null）。
///
/// 以前这里挂的是 `StateProvider<Conversation?>` 且**全仓没人写过它** —— 一个永远为 null 的死状态。
/// 插件平台的 `agent_handoff` 需要知道「交接进哪一串对话」，于是把它换成 id 并由 home_screen 唯一入口写：
/// 判「哪一串是对话页正在看的」只能有一个真源，别让每个接缝各自猜。
final currentConversationIdProvider = StateProvider<String?>((ref) => null);

final messagesProvider = StreamProvider.autoDispose
    .family<List<ChatMessage>, String>((ref, convId) async* {
  final storage = ref.read(storageServiceProvider);
  // Yield the current messages immediately.
  yield await storage.getAllMessages(convId);

  // Then poll for changes every 500ms to pick up new messages.
  while (true) {
    await Future.delayed(const Duration(milliseconds: 500));
    yield await storage.getAllMessages(convId);
  }
});

// ---------------------------------------------------------------------------
// Generation state
// ---------------------------------------------------------------------------

final isGeneratingProvider = StateProvider<bool>((ref) => false);

/// 各会话正在执行回合（convId → 是否本地路线）。多会话并发的唯一真相：
/// 槽位门控计数、模型卸载前停全部都以它为准。
/// ⚠️ UI 判「当前会话生成中」必须用 **containsKey(convId)**——map 的值是
/// 「是否本地路线」（true=本地/false=API），不是生成标志；用 `map[id] ?? false`
/// 会把 API 档执行中的回合误判成空闲（composer 停止键消失、只剩麦克风，
/// 真机实锤 bug，2026-10-07）。
final runningTurnsProvider =
    StateProvider<Map<String, bool>>((ref) => const {});

/// 一条待用户回答的提问（ask_user_question 工具发起，回合挂起等待）。
class AgentPendingQuestion {
  final String question;
  final List<String> options;

  /// 回答通道：UI 点选项/提交文本后 complete(答案)；跳过/取消 complete(null)。
  final Completer<String?> completer;

  const AgentPendingQuestion({
    required this.question,
    required this.options,
    required this.completer,
  });
}

/// 各会话待回答提问（convId → 提问）。UI 在输入区上方渲染卡片；
/// 回合取消/停止时由 stopGeneration 以 null 兜底完成，防工具挂死。
final agentPendingQuestionProvider =
    StateProvider<Map<String, AgentPendingQuestion>>((ref) => const {});

/// 槽位门控纯函数（可测）：能否在现有活跃回合之上再开一个回合。
/// 返回 null = 允许；否则为拒绝文案（直接作为 sendMessage 返回值）。
///
/// 规则：① 本地引擎（权重+KV）单实例 → 本地回合彼此互斥，与槽位无关；
/// ② 总活跃回合数不得超过并发会话槽位（API 会话可真正并行）。
String? checkTurnAdmission({
  required int activeCount,
  required bool activeHasLocal,
  required bool newIsLocal,
  required int slots,
}) {
  if (newIsLocal && activeHasLocal) {
    return '[本地模型同一时间只能执行一个会话：请等待其他会话完成，'
        '或到对应会话点停止]';
  }
  if (activeCount >= slots) {
    return '[并发槽位已满（$activeCount/$slots）：其他会话正在执行，'
        '请等待完成或到对应会话点停止]';
  }
  return null;
}

/// 一个正在执行的回合（多会话并发下的句柄）。
class _ActiveTurn {
  /// 是否本地路线：本地回合彼此互斥（引擎单实例）。路由确定后回填。
  bool local = false;

  /// 智能体回合的主循环（可 cancel）；普通聊天为 null。
  ReactLoopAgent? agent;

  /// 已进入生成阶段（顶部注册只占槽位；路由/模型就绪后才进 UI 生成态）。
  bool started = false;

  /// 用户主动停止：API 侧 cancel 抛 DioException 时静默用。
  bool userCancelled = false;
}

// ---------------------------------------------------------------------------
// Chat logic — model loading + streaming completion
// ---------------------------------------------------------------------------

/// 本地原生视觉是否可用。原生层已集成 mtmd（mmproj 投影器 + 图像编码），
/// 故本地路线按「支持视觉」处理：当前消息图片路径传给原生引擎编码后送入。
/// 历史带图消息仍只取文本（原生只支持单张当前图），天然安全。
const bool kLocalVisionSupported = true;

class ChatNotifier extends StateNotifier<bool> {
  final InferenceService _inference;
  final StorageService _storage;
  final Ref _ref;
  final JsonlSessionStore _sessionStore = JsonlSessionStore();

  /// Which conversation currently occupies the native KV cache. When the user
  /// switches to a different conversation we must reset the cache so the OLD
  /// chat doesn't bleed into the new one (multi-turn append-only caching).
  String? _currentKvConvId;

  /// 当前 KV 缓存是否装载的是智能体模式上下文（含系统提示词/工具轮）。
  /// 同一会话内「智能体 ↔ 普通聊天」模式切换时必须 resetContext，
  /// 否则普通聊天会续跑在被大提示词污染的 KV 上（prefill 白白翻倍）。
  bool _currentKvWasAgentMode = false;

  /// 当前 KV 缓存装载的智能体人格 id（系统提示词前缀组成部分）。
  /// 同一会话内切换人格必须 resetContext，否则新人格回合会续跑在
  /// 旧人格系统提示词的 KV 前缀上（提示词错配）。
  String? _currentKvPersonaId;

  /// 上次智能体回合的系统提示词档位 key（精简/完整切换 → 必须 resetContext，
  /// 与人格同一类坑：系统提示前缀变了还续跑旧 KV = 提示词错配答非所问）。
  String? _currentKvPromptTierKey;

  /// 活跃回合表（多会话并发）：convId → 回合句柄。
  /// sendMessage 顶部同步注册占位（防双开竞态），finally 注销。
  final Map<String, _ActiveTurn> _activeTurns = {};

  /// P0 遥测：回合指标落盘（ApplicationSupport/metrics/turn_metrics.jsonl）。
  /// 循环零侵入——指标在回合结束后从 SessionLog 纯派生。
  TurnMetricsStore? _metricsStore;

  /// P0 轨迹：每回合自动落盘的目录缓存（ApplicationSupport/traces）。
  String? _traceDir;

  /// P1-D 技能目录冻结缓存：convId → 目录文本。同一会话内技能目录文本
  /// 不变（系统提示稳定保 API prompt cache / 本地 KV 前缀），技能集变化
  /// 延迟到会话切换生效；FIFO 容量 32 防泄漏。
  final Map<String, String> _skillDirectoryCache = {};

  /// P1-A goal 存储（ApplicationSupport/goals/）与上一回合终止原因。
  GoalStore? _goalStoreCache;
  final Map<String, String> _lastTurnEndReason = {};

  Future<GoalStore> _goalStore() async {
    _goalStoreCache ??= GoalStore(
        baseDir:
            '${(await getApplicationSupportDirectory()).path}/goals');
    return _goalStoreCache!;
  }

  void _registerTurn(String conversationId, _ActiveTurn turn) {
    _activeTurns[conversationId] = turn;
    _syncRunningState();
  }

  void _unregisterTurn(String conversationId) {
    if (_activeTurns.remove(conversationId) == null) return;
    _syncRunningState();
  }

  /// 门控拒绝：文案落一条 assistant 消息（sendMessage 返回值无人消费，
  /// 只有落库用户才能在对话里看到被拒原因）。
  Future<String> _rejectTurn(String conversationId, String message) async {
    await _storage.saveMessage(ChatMessage(
      id: 'gate_${DateTime.now().millisecondsSinceEpoch}',
      conversationId: conversationId,
      role: MessageRole.assistant,
      content: message,
    ));
    await _refreshConversationMeta(conversationId);
    return message;
  }

  /// 把活跃回合投影到 runningTurnsProvider / isGeneratingProvider /
  /// ChatNotifier.state（任意生成中）。started=false 的占位回合不进 UI 态。
  void _syncRunningState() {
    final map = <String, bool>{
      for (final e in _activeTurns.entries)
        if (e.value.started) e.key: e.value.local,
    };
    _ref.read(runningTurnsProvider.notifier).state = map;
    _ref.read(isGeneratingProvider.notifier).state = map.isNotEmpty;
    state = map.isNotEmpty;
    _updateInferenceRefreshRate();
  }

  /// GPU 推理防闪纹（2026-10-07 小米13 定案）：本地回合的模型加载 + prefill
  /// 瞬时显存带宽会挤占显示供帧（Adreno UMA 闪条纹）。回合存在期间锁
  /// 60Hz（DPU 供帧带宽减半），回合结束恢复跟随系统。API 回合不占 GPU
  /// 引擎、CPU 后端无此现象，均不介入。
  void _updateInferenceRefreshRate() {
    try {
      final s = _ref.read(settingsProvider);
      if (!s.inferenceLimitRefreshRate) return;
      final gpuTurnActive = _activeTurns.values
          .any((t) => !t.started || t.local); // 未定路由的占位按 GPU 预判
      if (s.gpuBackend == 'cpu') {
        if (_rateLimitEngaged) {
          _rateLimitEngaged = false;
          AppBridge.setPreferredRefreshRate(0);
        }
        return;
      }
      if (gpuTurnActive && !_rateLimitEngaged) {
        _rateLimitEngaged = true;
        AppBridge.setPreferredRefreshRate(60).then((ok) => debugPrint(
            '[ChatNotifier] [refresh-rate] engage 60Hz ok=$ok '
            'backend=${s.gpuBackend}'));
      } else if (!gpuTurnActive && _rateLimitEngaged) {
        _rateLimitEngaged = false;
        AppBridge.setPreferredRefreshRate(0).then((ok) =>
            debugPrint('[ChatNotifier] [refresh-rate] restore ok=$ok'));
      }
    } catch (e) {
      debugPrint('[ChatNotifier] refresh-rate limit failed: $e');
    }
  }

  bool _rateLimitEngaged = false;

  ChatNotifier(this._ref, this._inference, this._storage) : super(false);

  /// Ensure the correct model is loaded before sending a message.
  /// Uses [modelManagerProvider] so that loading state is visible in UI.
  Future<bool> ensureModelLoaded(String modelId) async {
    debugPrint('[ChatNotifier] ensureModelLoaded called, modelId=$modelId');
    // Delegate to ModelManagerNotifier — it handles unload-previous + state.
    final manager = _ref.read(modelManagerProvider.notifier);

    if (manager.state.isLoaded && manager.currentModelId == modelId) {
      debugPrint(
          '[ChatNotifier] Model $modelId already loaded, skipping reload');
      return true;
    }

    debugPrint(
        '[ChatNotifier] Reloading model: $modelId (isLoaded=${manager.state.isLoaded}, currentId=${manager.modelId})');
    // If a different model is loaded, we still go through loadModel which
    // handles the unload-then-load flow.
    return await manager.loadModel(modelId);
  }

  /// 回合中转向（P2-B1，DSH `steer` 语义）：当前会话有运行中的智能体回合时，
  /// 把 [text] 作为用户插话注入该回合的下一个 step（模型下一条请求即看到，
  /// 不打断执行）；没有运行中的回合则回退为正常 sendMessage（新开回合）。
  Future<String> steerTurn(String conversationId, String text) async {
    final trimmed = text.trim();
    if (trimmed.isEmpty) return '';
    final agent = _activeTurns[conversationId]?.agent;
    if (agent == null || !agent.isRunning) {
      return sendMessage(conversationId, text);
    }
    // 插话对用户可见（普通 user 气泡落库）；模型侧由 loop 在 step 边界
    // 以「[用户插话] …」user 事件投喂，跨回合不入历史（同 trace 口径）。
    await _storage.saveMessage(ChatMessage(
      id: 'steer_${DateTime.now().millisecondsSinceEpoch}',
      conversationId: conversationId,
      role: MessageRole.user,
      content: trimmed,
    ));
    await _refreshConversationMeta(conversationId);
    agent.steer(trimmed);
    return '（已作为插话转入执行中的回合）';
  }

  /// 回答 ask_user_question 的挂起提问（UI 卡片提交/点选项/跳过时调用）。
  /// [answer] 为 null = 用户跳过；提问不存在时静默忽略。
  void answerPendingQuestion(String conversationId, String? answer) {
    final notifier = _ref.read(agentPendingQuestionProvider.notifier);
    final pending = notifier.state[conversationId];
    if (pending == null) return;
    notifier.state = {
      ...notifier.state,
    }..remove(conversationId);
    if (!pending.completer.isCompleted) {
      pending.completer.complete(answer);
    }
  }

  /// Send a message to the currently loaded model.
  /// Automatically ensures the correct model is loaded first via ModelManager.
  ///
  /// [imagePaths] 多图（≤10，首张即 [imagePath]）；[attachmentPaths] 智能体
  /// 附件（≤5，仅智能体模式消费——普通聊天引擎无文件阅读能力，忽略并提示）。
  /// 自动播报（Edge TTS，设置开启时）：回复落库后朗读；失败静默不打断聊天。
  void _maybeAutoSpeak(String conversationId, String text) {
    final settings = _ref.read(settingsProvider);
    if (!settings.edgeTtsEnabled || !settings.edgeTtsAutoSpeak) return;
    if (text.trim().isEmpty) return;
    unawaited(EdgeTtsService.instance.speak(
      text,
      key: 'auto-$conversationId',
      voice: settings.edgeTtsVoice,
      rate: settings.edgeTtsRate,
      pitch: settings.edgeTtsPitch,
      volume: settings.edgeTtsVolume,
    ));
  }

  Future<String> sendMessage(    String conversationId,
    String prompt, {
    String? imagePath,
    List<String>? imagePaths,
    List<String>? attachmentPaths,
    String? audioPath,
  }) async {    // 槽位门控 + 顶部同步占位（注册与检查之间无 await，防双开竞态）。
    // 路由未定时先按纯槽位计数预检；路由确定后再补「本地互斥」校验。
    final settings = _ref.read(settingsProvider);
    // 新消息发出 → 停掉正在进行的播报（避免旧回答声音与新提问交叠）。
    unawaited(EdgeTtsService.instance.stop());
    final admission = checkTurnAdmission(
      activeCount: _activeTurns.length,
      activeHasLocal: false,
      newIsLocal: false,
      slots: settings.agentMaxConcurrentTurns,
    );
    if (admission != null) return _rejectTurn(conversationId, admission);
    final turn = _ActiveTurn();
    _registerTurn(conversationId, turn);
    String response;
    try {
      response = await _dispatchMessage(conversationId, prompt, turn,
          imagePath: imagePath,
          imagePaths: imagePaths,
          attachmentPaths: attachmentPaths,
          audioPath: audioPath);
    } finally {
      _unregisterTurn(conversationId);
    }
    // P1-A goal 无人值守续跑驱动器：回合正常结束后检查持久目标——
    // 未完成则自动开续跑回合（递归经 sendMessage 展开，深度 = 剩余轮数）。
    // 在注销后调用：续跑回合重新走注册/门控（本地互斥同样生效）。
    await _driveGoalIfNeeded(conversationId, settings);
    return response;
  }

  /// P1-A goal 驱动器：目标活跃 + 上回合 completed → 续跑；
  /// 轮数耗尽 → 落一条可见提示并终结。失败/中断/等提问不自动续。
  Future<void> _driveGoalIfNeeded(
      String conversationId, InferenceSettings settings) async {
    try {
      final goal = await (await _goalStore()).load(conversationId);
      if (goal == null || !goal.isActive) return;
      // 用户有未回答的提问（ask_user/exit_plan 挂起）→ 不抢跑。
      if (_ref.read(agentPendingQuestionProvider)[conversationId] != null) {
        return;
      }
      // 只在上一回合正常完成后续跑（失败/中断交给用户处理）。
      if (_lastTurnEndReason[conversationId] != 'completed') return;
      final action = decideGoalAction(goal, turnCompleted: true);
      switch (action) {
        case GoalAction.none:
        case GoalAction.settle:
          return;
        case GoalAction.expire:
          final finished =
              await (await _goalStore()).finish(conversationId, GoalStatus.expired);
          await _storage.saveMessage(ChatMessage(
            id: 'goalfin_${DateTime.now().millisecondsSinceEpoch}',
            conversationId: conversationId,
            role: MessageRole.assistant,
            content: 'ℹ️ 目标续跑已达上限（${finished?.maxRounds ?? goal.maxRounds} 轮），'
                '自动停止。目标：${finished?.goal ?? goal.goal}\n'
                '如需继续，请发送「/plan <任务>」或直接下达下一步指示。',
          ));
          return;
        case GoalAction.continueTurn:
          final bumped = await (await _goalStore()).bumpRound(conversationId);
          final notice =
              '[目标续跑 ${bumped.rounds}/${bumped.maxRounds}] '
              '${bumped.progressText()}\n'
              '请继续推进（全部工具可用）：完成当前步骤立即 plan_step_update，'
              '再进入下一步；全部步骤完成后调用 goal_complete 总结收尾；'
              '某步确认失败用 plan_step_update 置 failed 并如实说明。';
          await _storage.saveMessage(ChatMessage(
            id: 'goalrun_${DateTime.now().millisecondsSinceEpoch}',
            conversationId: conversationId,
            role: MessageRole.user,
            content: notice,
          ));
          await sendMessage(conversationId, notice);
          return;
      }
    } catch (e) {
      debugPrint('[ChatNotifier] goal driver failed: $e');
    }
  }

  /// 模型视图预处理（切块发生在**发送时**，选图与 UI 全程只见原图）：
  /// 原图 → [LongImageService] 长图切块/缩放；宽度上限跟生成路线走
  /// （本地视觉塔 768 控 token/编码内存，API 视觉 1280）。
  /// 返回与 [originals] 相同长度且逐项相等时视为"无预处理"（visionPaths 存 null）。
  Future<List<String>> _prepareVisionPaths(
    List<String> originals, {
    required bool useApi,
  }) async {
    if (originals.isEmpty) return originals;
    try {
      return await LongImageService.prepareVisionImages(
        originals,
        widthCap: useApi ? 1280 : 768,
      );
    } catch (e) {
      debugPrint('[ChatNotifier] 视觉预处理失败（按原图发送）: $e');
      return originals;
    }
  }

  static bool _samePaths(List<String> a, List<String> b) {
    if (a.length != b.length) return false;
    for (var i = 0; i < a.length; i++) {
      if (a[i] != b[i]) return false;
    }
    return true;
  }

  Future<String> _dispatchMessage(
    String conversationId,
    String prompt,
    _ActiveTurn turn, {
    String? imagePath,
    List<String>? imagePaths,
    List<String>? attachmentPaths,
    String? audioPath,
  }) async {
    // 智能体模式：走工具循环（无工具时单轮直答，与普通聊天一致）。
    final settings = _ref.read(settingsProvider);
    if (settings.agentEnabled) {
      return _sendAgentMessage(conversationId, prompt,
          imagePath: imagePath,
          imagePaths: imagePaths,
          attachmentPaths: attachmentPaths,
          audioPath: audioPath,
          turn: turn);
    }
    if (attachmentPaths != null && attachmentPaths.isNotEmpty) {
      return '[文件附件仅智能体模式支持：请开启右上角智能体模式后再发送文件]';
    }

    var targetModelId = _ref.read(currentModelIdProvider);
    final activeApi = settings.activeApiModel();

    // 尊重用户选择：无本地意图（未加载模型且未勾选默认）→ 绝不自动加载
    // 本地模型，有激活 API 走 API、没有则明确报错指引；有本地意图才
    // local-first（本地不可用回退 API）。
    final managerState = _ref.read(modelManagerProvider);
    final plan = planGenerationRoute(
      settings: settings,
      localLoaded: managerState.isLoaded,
      loadedModelId: managerState.modelId,
      fallbackModelId: targetModelId,
    );
    if (plan.error != null) return plan.error!;
    var useApi = plan.useApi;
    if (plan.localModelId != null) {
      targetModelId = plan.localModelId!;
      final ok = await ensureModelLoaded(targetModelId);
      if (!ok && settings.activeApiModel() != null) {
        useApi = true; // 本地不可用 → 走 API 后备
      } else if (!ok) {
        return '[模型加载失败，请在设置中重新下载并加载]';
      }
    }
    // 路由已定 → 补本地互斥校验（本地引擎单实例，本地回合彼此互斥）。
    if (!useApi && _activeTurns.values.any((t) => t.local && t != turn)) {
      return _rejectTurn(
          conversationId,
          '[本地模型同一时间只能执行一个会话：请等待其他会话完成，'
          '或到对应会话点停止]');
    }
    turn.local = !useApi;
    turn.userCancelled = false;

    debugPrint(
        '[ChatNotifier] sendMessage: convId=$conversationId prompt="$prompt"'
        ' route=${useApi ? "API(${activeApi?.name})" : "local($targetModelId)"}');
    turn.started = true;
    _syncRunningState();

    // If this is a DIFFERENT conversation than what's in the native KV cache,
    // reset the cache first so the previous chat does not bleed in. (The KV
    // cache uses append-only multi-turn caching; a fresh conversation must start
    // from a clean cache.)
    // KV 归属本地引擎：仅本地路线管理（API 回合不动 KV 状态，避免把
    // 并行运行中的本地回合上下文重置掉）。
    if (!useApi) {
      var kvReset = false;
      if (_currentKvConvId != conversationId) {
        debugPrint(
            '[ChatNotifier] Conversation changed ($_currentKvConvId -> $conversationId): resetContext()');
        await _inference.resetContext();
        _currentKvConvId = conversationId;
        kvReset = true;
      } else if (_currentKvWasAgentMode) {
        // 智能体 → 普通聊天（模式切换）：KV 里是系统提示词 + 工具轮，必须重置，
        // 本轮以最小 prefill 重放纯对话历史。
        debugPrint('[ChatNotifier] Agent→plain mode switch: resetContext()');
        await _inference.resetContext();
        kvReset = true;
      }
      // resetContext 后 KV 归零：所有会话的占用快照（含本会话）已失效。
      if (kvReset) _ref.read(contextUsageProvider.notifier).clearLocal();
      _currentKvWasAgentMode = false;
      _currentKvPersonaId = null;
      _currentKvPromptTierKey = null;
    }

    try {
      // Step 2: Save user message first (so it's available in history for template)
      // 用户视图（imagePaths=原图）入库展示；模型视图（长图切块/缩放）单独
      // 计算存 visionPaths——切片对用户不可见，只在发给模型时使用。
      final originals = imagePaths ??
          (imagePath != null ? [imagePath] : const <String>[]);
      final vision = await _prepareVisionPaths(originals, useApi: useApi);
      final visionChanged = !_samePaths(vision, originals);
      final userMsg = ChatMessage(
        id: DateTime.now().millisecondsSinceEpoch.toString(),
        conversationId: conversationId,
        role: MessageRole.user,
        content: prompt,
        imagePath: imagePath,
        imagePaths: imagePaths,
        visionPaths: visionChanged ? vision : null,
        audioPath: audioPath,
      );
      debugPrint('[ChatNotifier] Saving user message...');
      await _storage.saveMessage(userMsg);
      // 及时刷新会话元信息：标题（取自首条用户提问）+ 消息条数，让会话列表
      // 不再是一成不变的「新对话 / 0条」。
      await _refreshConversationMeta(conversationId);

      // Step 3: Build chat history JSON from all messages in this conversation.
      // 排除智能体工具活动消息（🔧 前缀）—— 它们仅用于 UI 展示，不入模型上下文。
      final allMessages =
          await _storage.getMessages(conversationId, limit: 200);
      // 压缩游标生效：游标前的旧文本轮不入上下文（投影级压缩）。
      final messagesForTemplate = <Map<String, String>>[
        for (final msg in _messagesForModelContext(allMessages))
          {'role': msg.role.name, 'content': msg.content},
      ];
      final messagesJson = jsonEncode(messagesForTemplate);
      debugPrint(
          '[ChatNotifier] Chat history: ${messagesForTemplate.length} msgs, jsonLen=${messagesJson.length}');

      // Step 4: Stream completion from native inference engine (with chatml template)
      String fullResponse = '';

      // Create the assistant message up-front (empty + streaming) so the bubble
      // appears immediately and grows as tokens arrive — this lets the chat view
      // follow the stream in real time instead of waiting for the full reply.
      final assistantId =
          (DateTime.now().millisecondsSinceEpoch + 1).toString();
      var assistantMsg = ChatMessage(
        id: assistantId,
        conversationId: conversationId,
        role: MessageRole.assistant,
        content: '',
        isStreaming: true,
      );
      await _storage.saveMessage(assistantMsg);

      final manager = _ref.read(modelManagerProvider.notifier);
      try {
        debugPrint('[ChatNotifier] Calling completionWithMessages...');
        manager.appendInferenceLog(
          '请求 | 提示 ${prompt.length} 字 | 历史 ${messagesForTemplate.length} 条'
          ' | maxTokens=2048 temp=0.7 topP=0.9${imagePath != null ? ' [带图]' : ''}',
        );

        final startTime = DateTime.now();
        var tokenCount = 0;
        DateTime? firstTokenTime;

        // Route the completion source: local engine vs OpenAI-compatible API.
        // Both expose a Stream<String>, so the thinking-filter / persist logic
        // below consumes them uniformly.
        final Stream<String> stream;
        if (useApi) {
          // API 路线：按该 API 的视觉能力构建消息。
          //  - 支持视觉 → 历史/当前带图消息转 content-parts（base64 image_url）；
          //  - 不支持视觉 → 图片剥离为纯文本（`[图片]` 占位），绝不发送原始图。
          final apiVision = activeApi!.visionCapable;
          final apiMessages = await OpenAiService.buildMessages(
            allMessages,
            visionCapable: apiVision,
          );
          if (imagePath != null && !apiVision) {
            debugPrint('[ChatNotifier] 当前图片已剥离（该 API 未开启视觉支持）');
            manager.appendInferenceLog('⚠️ 当前图片已剥离：该 API 模型未开启视觉支持');
          }
          manager.appendInferenceLog(
            '请求(API) | ${activeApi.name} | ${activeApi.model}'
            ' | 历史 ${apiMessages.length} 条'
            ' | maxTokens=${activeApi.effectiveMaxTokens}'
            ' temp=${activeApi.effectiveTemperature}'
            ' ${apiVision ? '带图' : '文本'}',
          );
          stream = _ref.read(openAiServiceProvider).chatCompletion(
                config: activeApi,
                messages: apiMessages,
                temperature: activeApi.effectiveTemperature,
                maxTokens: activeApi.effectiveMaxTokens,
              );
        } else {
          // 本地路线：原生已集成 mtmd 视觉（多图：长图切块/多图上传一次全送，
          // 原生按序逐张编码）。当前消息图片路径直接传给原生引擎
          // （mmproj 已加载则编码送图；未加载则该模型仅文本，原生自动忽略）。
          // 历史带图消息本就只取文本，天然安全。
          final localImages = vision;
          if (localImages.isNotEmpty) {
            debugPrint('[ChatNotifier] 本地路线携带图片 ${localImages.length} 张');
            manager.appendInferenceLog(
                '请求 | 携带图片 ${localImages.length} 张'
                '${visionChanged && localImages.length > 1 ? '（含长图切块）' : ''}');
          }
          if (audioPath != null) {
            debugPrint('[ChatNotifier] 本地路线携带语音: $audioPath');
            manager.appendInferenceLog('请求 | 携带语音消息 🎤');
          }
          stream = _inference.completionWithMessages(
            prompt: prompt,
            messagesJson: messagesJson,
            imagePath: vision.isNotEmpty ? vision.first : imagePath,
            imagePaths: localImages.isNotEmpty ? localImages : null,
            audioPath: audioPath,
            maxTokens:
                1024, // on-device cap: large token budgets make long runs unbearable
            temperature: 0.7,
            topP: 0.9,
          );
        }

        debugPrint('[ChatNotifier] Listening to token stream...');
        // 过滤「用户主动停止」产生的 DioException：点停止时 API 会抛
        // [request cancelled]，属正常停止信号，静默丢弃而非当成发送失败。
        final tokenStream = _suppressUserCancelled(stream, turn);

        // --- Streaming thinking-tag filter (stateful, token-by-token) ---
        // `visible` holds the response shown to the user. Anything inside
        // <think>...</think> is routed to `thinking` and dropped from output.
        // Tag handling runs as tokens arrive, so we never surface raw
        // reasoning, and a stream that ends inside an unclosed <thinking> block
        // simply discards that incomplete block.
        final visible = StringBuffer();
        final thinking = StringBuffer();
        var inThinking = false;
        // 思考流快照节流推 UI（2026-10-25 用户需求）：简单聊天也显示
        // 「思考中…」自动展开卡，回合结束收起。
        final agentUi = _ref.read(agentUiStateProvider.notifier);
        var lastThinkingPush = DateTime.now();

        // Drop a dangling partial thinking-tag fragment at the very end of the
        // output (e.g. the stream ended mid-token with "<thi" or "</think").
        String stripDanglingTag(String s) {
          final lastLt = s.lastIndexOf('<');
          if (lastLt < 0) return s;
          final tail = s.substring(lastLt);
          final partialOpen = '<think>'.startsWith(tail) && tail != '<think>';
          final partialClose =
              '</think>'.startsWith(tail) && tail != '</think>';
          if (partialOpen || partialClose) return s.substring(0, lastLt);
          return s;
        }

        var lastStreamSave = DateTime.now();

        await for (final token in tokenStream) {
          if (token.isEmpty) continue;

          tokenCount++;
          firstTokenTime ??= DateTime.now();

          if (inThinking) {
            thinking.write(token);
            final nowThink = DateTime.now();
            if (nowThink.difference(lastThinkingPush).inMilliseconds >= 120) {
              lastThinkingPush = nowThink;
              agentUi.setThinking(conversationId, thinking.toString());
            }
            final closeIdx = thinking.toString().indexOf('</think>');
            if (closeIdx >= 0) {
              // Everything after the closing tag becomes visible output.
              final after =
                  thinking.toString().substring(closeIdx + '</think>'.length);
              thinking.clear();
              visible.write(after);
              inThinking = false;
            }
            // else: still inside thinking — the token is already discarded.
          } else {
            visible.write(token);
            final openIdx = visible.toString().indexOf('<think>');
            if (openIdx >= 0) {
              // Keep pre-tag text in `visible`; move the tag + the rest into
              // `thinking` so subsequent tokens are discarded.
              final before = visible.toString().substring(0, openIdx);
              final rest = visible.toString().substring(openIdx);
              visible.clear();
              visible.write(before);
              thinking.write(rest);
              inThinking = true;
            }
          }

          // Periodically persist the visible (thinking-filtered) content so the
          // bubble updates live and the UI can scroll to follow the stream.
          final now = DateTime.now();
          if (now.difference(lastStreamSave).inMilliseconds >= 150) {
            lastStreamSave = now;
            assistantMsg = assistantMsg.copyWith(content: visible.toString());
            await _storage.saveMessage(assistantMsg);
          }
        }

        // Final pass after the stream ends.
        final String rawResponse;
        if (inThinking) {
          // Stream ended inside an unclosed <thinking> block — drop it entirely.
          // Text emitted before the tag (already in `visible`) is kept.
          rawResponse = visible.toString();
        } else {
          // Safety net: strip any complete thinking blocks that slipped through
          // (malformed/overlapping tags), then remove a dangling tag fragment.
          rawResponse = stripDanglingTag(visible
              .toString()
              .replaceAll(RegExp(r'<think>.*?</think>', dotAll: true), ''));
        }

        fullResponse = rawResponse.trim();
        final preview =
            fullResponse.substring(0, fullResponse.length.clamp(0, 50));
        debugPrint(
            '[ChatNotifier] Stream done, len=${fullResponse.length}, response="$preview${fullResponse.length > 50 ? "..." : ""}"');

        final totalMs = DateTime.now().difference(startTime).inMilliseconds;
        final firstTokenMs = firstTokenTime != null
            ? firstTokenTime.difference(startTime).inMilliseconds
            : 0;

        // Use the REAL token count + pure generation time from native so the
        // displayed tok/s matches the native logcat line exactly (Dart used to
        // count emitted characters over wall-clock time that also included the
        // prompt prefill, so it always read lower than the native number).
        // API 后备路径没有原生 stats，改用 Dart 计数 + 总墙钟估算。
        int realTokens = tokenCount;
        double genMs = 0.0;
        int visionMs = 0;
        int audioMs = 0;
        // 本地路线：原生 getInferenceStats 附带 KV 缓存占比（kv_used/kv_ctx）。
        Map<String, dynamic> genStats = {};
        if (!useApi) {
          try {
            genStats = await _inference.getInferenceStats();
          } catch (_) {}
          realTokens = (genStats['n_gen'] as num?)?.toInt() ?? tokenCount;
          genMs = (genStats['t_gen_ms'] as num?)?.toDouble() ?? 0.0;
          visionMs = (genStats['t_vision_ms'] as num?)?.toInt() ?? 0;
          audioMs = (genStats['t_audio_ms'] as num?)?.toInt() ?? 0;
        }
        final tokensPerSec = genMs > 0
            ? realTokens * 1000 / genMs
            : (totalMs > 0 ? realTokens * 1000 / totalMs : 0.0);

        manager.appendInferenceLog(
          '响应 | $realTokens tokens | 首token ${firstTokenMs}ms | 生成 ${genMs.round()}ms'
          '${visionMs > 0 ? ' | 视觉 ${visionMs}ms' : ''}'
          '${audioMs > 0 ? ' | 听音 ${audioMs}ms' : ''} | 总耗时 ${totalMs}ms'
          ' | ${tokensPerSec.toStringAsFixed(1)} tok/s | 输出 ${fullResponse.length} 字',
        );

        // Step 5: Persist final assistant message (clear streaming flag).
        assistantMsg = assistantMsg.copyWith(
          content: fullResponse,
          isStreaming: false,
          inferenceStats: InferenceStats(
            firstTokenMs: firstTokenMs,
            totalMs: totalMs,
            tokPerSec: tokensPerSec,
            visionMs: visionMs,
            audioMs: audioMs,
          ),
        );
        await _storage.saveMessage(assistantMsg);
        // 回复落地后再刷新一次消息条数（流式占位消息已收尾）。
        await _refreshConversationMeta(conversationId);
        _maybeAutoSpeak(conversationId, fullResponse);

        // 上下文占用：API 接入（usage.prompt_tokens）走 _updateContextUsage；
        // 本地路线走原生 KV 缓存占比（kv_used/kv_ctx）。
        if (useApi) {
          final usage = _ref.read(openAiServiceProvider).lastUsage;
          final prompt = usage?['prompt_tokens'] as num?;
          if (prompt != null) {
            await _updateContextUsage(
              conversationId,
              usedTokens: prompt.toInt(),
              api: activeApi,
            );
          }
        } else {
          _updateLocalContextUsage(conversationId, genStats);
        }
        unawaited(_maybeAutoCompact(conversationId));

        return fullResponse;
      } catch (e) {
        debugPrint('[ChatNotifier] Stream error: $e');
        manager.appendInferenceLog('响应异常 | error=$e');
        // Update the same streaming message with the error content.
        assistantMsg =
            assistantMsg.copyWith(content: '[Error: $e]', isStreaming: false);
        await _storage.saveMessage(assistantMsg);
        return fullResponse;
      }
    } finally {
      debugPrint('[ChatNotifier] sendMessage done, isGenerating=false');
      _syncRunningState(); // 真正的注销由 sendMessage 顶层 finally 统一做
    }
  }

  /// 智能体模式发送消息：路由（本地/API）→ 新主循环 → 最终回答持久化。
  ///
  /// 工具轮的活动消息（🔧）逐工具独立落库，供对话内嵌工作流展示与
  /// 历史回合回看；循环内部的历史（含工具结果回填）不落库，避免污染存储。
  Future<String> _sendAgentMessage(
    String conversationId,
    String prompt, {
    String? imagePath,
    List<String>? imagePaths,
    List<String>? attachmentPaths,
    String? audioPath,
    required _ActiveTurn turn,
  }) async {
    final settings = _ref.read(settingsProvider);
    return _sendAgentMessageNew(
      conversationId,
      prompt,
      imagePath: imagePath,
      imagePaths: imagePaths,
      attachmentPaths: attachmentPaths,
      audioPath: audioPath,
      settings: settings,
      turn: turn,
    );
  }

  /// 智能体模式发送（Phase 0+ 重写，唯一实现）：事件源 [ReactLoopAgent] +
  /// [EngineLlmAdapter]（local/API 双路，共用文本协议）。
  ///
  /// 用户可见行为：
  /// - 模型路由（local/api/默认兜底）；
  /// - KV 缓存策略（会话切换 resetContext）；
  /// - 历史从 SQLite 读（排除 🔧 工具活动消息）→ [JsonlSessionStore.importFromMessages]；
  /// - 流式占位 + 工具活动（[_AgentActivitySession]，逐工具落库）；
  /// - 最终回答持久化 + 返回。
  Future<String> _sendAgentMessageNew(
    String conversationId,
    String prompt, {
    String? imagePath,
    List<String>? imagePaths,
    List<String>? attachmentPaths,
    String? audioPath,
    required InferenceSettings settings,
    required _ActiveTurn turn,
  }) async {
    // ---- 附件注入（WP-A）：≤5 个，解析→工作区→prompt 指引 ----
    var effectivePrompt = prompt;
    List<PreparedAttachment> prepared = const [];
    if (attachmentPaths != null && attachmentPaths.isNotEmpty) {
      final errors = <String>[];
      for (final path in attachmentPaths.take(kMaxAttachments)) {
        final (att, error) = await prepareAttachment(conversationId, path);
        if (att != null) {
          prepared = [...prepared, att];
        } else if (error != null) {
          errors.add(error);
        }
      }
      if (prepared.isEmpty) {
        return '[附件全部无法导入：${errors.join("；")}]';
      }
      effectivePrompt = '$prompt${buildAttachmentPromptBlock(prepared)}';
      if (errors.isNotEmpty) {
        effectivePrompt = '$effectivePrompt\n[部分附件导入失败：${errors.join("；")}]';
      }
    }
    // 视觉输入上限 10 张：模型视图（原图→长图切块）在路由确定后计算，
    // 见下方 firstImage/droppedImages。

    // ---- 模型路由（与旧路径一致）----
    var useApi = false;
    ApiModelConfig? activeApi;
    var targetModelId = _ref.read(currentModelIdProvider);

    if (settings.agentModelSource == 'api') {
      for (final m in settings.apiModels) {
        if (m.id == settings.agentModelId) {
          activeApi = m;
          break;
        }
      }
      if (activeApi == null) {
        return '[智能体配置的 API 模型不存在，请在设置中重新选择]';
      }
      useApi = true;
    } else if (settings.agentModelSource == 'local') {
      // 显式本地驱动：只认用户明确指定过的 id（agentModelId > 默认勾选 >
      // 已加载模型）；都没有 → 明确报错，绝不隐式加载出厂占位模型
      //（无默认勾选不许自动加载，API 驱动场景曾被它带偏）。
      final managerState = _ref.read(modelManagerProvider);
      final intended = resolveExplicitLocalTarget(
        agentModelId: settings.agentModelId,
        defaultModelId: settings.defaultModelId,
        localLoaded: managerState.isLoaded,
        loadedModelId: managerState.modelId,
      );
      if (intended == null || intended.isEmpty) {
        return '[智能体驱动=本地模型，但未指定具体模型：'
            '请在 设置→智能体→驱动模型 重新选择，或改为跟随默认/API]';
      }
      targetModelId = intended;
      final ok = await ensureModelLoaded(targetModelId);
      if (!ok) {
        return '[模型加载失败，请在设置中重新下载并加载]';
      }
      useApi = false;
    } else {
      // 跟随默认：与普通聊天同一套路由规则（planGenerationRoute）。
      final managerState = _ref.read(modelManagerProvider);
      final plan = planGenerationRoute(
        settings: settings,
        localLoaded: managerState.isLoaded,
        loadedModelId: managerState.modelId,
        fallbackModelId: targetModelId,
      );
      if (plan.error != null) return plan.error!;
      useApi = plan.useApi;
      if (plan.useApi) {
        activeApi = settings.activeApiModel();
      } else {
        targetModelId = plan.localModelId!;
        final ok = await ensureModelLoaded(targetModelId);
        if (!ok) {
          final fallback = settings.activeApiModel();
          if (fallback != null) {
            useApi = true;
            activeApi = fallback;
          } else {
            return '[模型加载失败，请在设置中重新下载并加载]';
          }
        }
      }
    }
    // 路由已定 → 补本地互斥校验（本地引擎单实例，本地回合彼此互斥）。
    if (!useApi && _activeTurns.values.any((t) => t.local && t != turn)) {
      return _rejectTurn(
          conversationId,
          '[本地模型同一时间只能执行一个会话：请等待其他会话完成，'
          '或到对应会话点停止]');
    }
    turn.local = !useApi;
    // ---- 模型视图（发送时才切块；UI/存储的 imagePaths 永远是原图）----
    // 上限 10 张指**模型视图**张数（长图切块后可能超），超出部分不发送，
    // 如实告知模型；用户视角始终只有自己选的那几张图。
    final originals = imagePaths ??
        (imagePath != null ? [imagePath] : const <String>[]);
    final vision = await _prepareVisionPaths(originals, useApi: useApi);
    final visionChanged = !_samePaths(vision, originals);
    final firstImage = vision.isNotEmpty ? vision.first : imagePath;
    final visionImageCount = vision.isNotEmpty
        ? vision.length
        : (imagePath != null ? 1 : 0);
    final droppedImages = visionImageCount > 10 ? visionImageCount - 10 : 0;
    // 多图本地降级：本地引擎视觉仅支持单张（native 单图），如实告知模型。
    if (droppedImages > 0) {
      effectivePrompt = '$effectivePrompt\n[注意：共上传 $visionImageCount 张图片，'
          '超出 10 张上限的 $droppedImages 张未发送]';
    }
    debugPrint('[ChatNotifier] new-agent route='
        '${useApi ? "API(${activeApi?.name})" : "local($targetModelId)"}');

    // ---- P1-A 计划模式：'/plan ' 前缀（仅 API 档）----
    // 本回合 = 只读规划：注册表收窄为只读工具 + exit_plan 审批工具；
    // 批准后计划落为持久目标，goal 驱动器自动接管执行。
    var planMode = false;
    if (useApi && effectivePrompt.startsWith('/plan')) {
      planMode = true;
      effectivePrompt = effectivePrompt.substring('/plan'.length).trim();
      if (effectivePrompt.isEmpty) {
        return '[计划模式用法：/plan <任务描述>，'
            '例如「/plan 重构登录模块并补齐测试」]';
      }
    }

    turn.started = true;
    _syncRunningState();

    // ---- 构建组件（复用旧路径共享件）----
    // 智能体模型标识：本地=模型 id；API=API 模型名。工具可见性过滤、
    // 协议选择、系统提示渲染、子代理都按它走——此前 API 路线沿用本地模型
    // id，协议指令/工具清单全被本地模型"张冠李戴"。
    final agentModelKey =
        useApi ? (activeApi?.model ?? targetModelId) : targetModelId;

    // ---- 提示词档位（2026-10-27 K90 真机定案）----
    // API 档保持现状（full，逐字节不变）；本地小模型走精简档：短纪律 +
    // 工具白名单 + 不注入技能目录/AGENTS.md。真机教训：Ling-3.0-tiny 在
    // 4580 token 系统提示下整回合不调工具、编造「已查询到天气/文件已保存」。
    // 判不准（目录里没有该模型、大小未知）时保守走 full —— 宁可不瘦，
    // 也不悄悄改坏大模型的表现。
    int? agentModelSizeBytes;
    if (!useApi) {
      try {
        for (final c in await ModelCatalog.load()) {
          if (c.id == targetModelId) {
            agentModelSizeBytes = c.sizeBytes;
            break;
          }
        }
      } catch (_) {}
    }
    final promptTier = resolveAgentPromptTier(
      modelId: agentModelKey,
      useApi: useApi,
      mode: settings.agentPromptTierMode,
      sizeBytes: agentModelSizeBytes,
    );
    final compactPrompt = promptTier == AgentPromptTier.compact;
    // KV 失效判据：档位判定结果 + 用户设置模式一起算 key（同 key = 系统提示
    // 前缀逐字节相同 = 允许续跑 KV）。
    final promptTierKey =
        '${settings.agentPromptTierMode}:${promptTier.name}:${compactPrompt ? 'core' : 'all'}';

    // 会话切换时重置原生 KV 缓存（沿用现有策略）。
    // 激活人格是系统提示词前缀的组成部分：同会话内切换人格也必须重置。
    // KV 归属本地引擎：仅本地路线管理（API 回合不动 KV 状态，避免把
    // 并行运行中的本地回合上下文重置掉）。
    final personaId = settings.activePersonaId;
    if (!useApi) {
      var kvReset = false;
      if (_currentKvConvId != conversationId) {
        debugPrint(
            '[ChatNotifier] new-agent conversation changed: resetContext()');
        await _inference.resetContext();
        _currentKvConvId = conversationId;
        kvReset = true;
      } else if (!_currentKvWasAgentMode) {
        // 普通聊天 → 智能体（模式切换）：KV 是纯对话上下文，需重置后
        // 由主循环带系统提示词/工具协议重建。
        debugPrint('[ChatNotifier] plain→agent mode switch: resetContext()');
        await _inference.resetContext();
        kvReset = true;
      } else if (_currentKvPromptTierKey != promptTierKey) {
        // 同会话切换提示词档位（设置里改「提示词档位」或换了判定结果）：
        // 系统提示前缀整个变了，KV 续跑 = 旧提示词接着生成，必答非所问。
        debugPrint('[ChatNotifier] prompt tier switch ($_currentKvPromptTierKey '
            '-> $promptTierKey): resetContext()');
        await _inference.resetContext();
        kvReset = true;
      } else if (_currentKvPersonaId != personaId) {
        // 同会话切换人格：系统提示词前缀变了，KV 续跑会提示词错配。
        debugPrint('[ChatNotifier] persona switch ($_currentKvPersonaId -> '
            '$personaId): resetContext()');
        await _inference.resetContext();
        kvReset = true;
      }
      // resetContext 后 KV 归零：所有会话的占用快照（含本会话）已失效。
      if (kvReset) _ref.read(contextUsageProvider.notifier).clearLocal();
      _currentKvWasAgentMode = true;
      _currentKvPersonaId = personaId;
      _currentKvPromptTierKey = promptTierKey;
    }


    // Skills：内置（rank 100）+ 用户目录 ApplicationSupport/skills（rank 200）。
    // 提前构建（与 load_skill 工具注册、agent 注入共用同一实例）。
    final userSkills = await loadUserSkills();
    final skillProvider = userSkills.isEmpty
        ? SkillProvider()
        : SkillProvider(skills: [...loadBuiltinSkills(), ...userSkills]);
    // P1-D 技能目录冻结：同一会话沿用首次生成的目录文本（系统提示逐字节
    // 稳定，prompt cache/KV 前缀不因增删技能破掉）；load_skill 注册表用
    // 实时技能集，新增技能本会话内仍可按名拉取，只是目录不刷新。
    if (skillProvider.count > 0) {
      if (_skillDirectoryCache.containsKey(conversationId)) {
        skillProvider.frozenDirectoryText =
            _skillDirectoryCache[conversationId];
      } else {
        if (_skillDirectoryCache.length >= 32) {
          _skillDirectoryCache
              .remove(_skillDirectoryCache.keys.first);
        }
        _skillDirectoryCache[conversationId] =
            skillProvider.availableSkillsText(
                loadSkillAvailable: true, saveSkillAvailable: true);
      }
    }


    final registry = _buildAgentRegistry(settings, agentModelKey,
        conversationId: conversationId);
    // 精简档工具白名单：用户没为该模型显式配过工具时才自动收窄
    // （配过 = 尊重用户选择，不越权改写）。收窄后 python/shell/run_code
    // 这类"把 tiny 带成假装在 Linux 干活"的重型工具既不进提示也调不到。
    if (compactPrompt && settings.agentToolsFor(agentModelKey).isEmpty) {
      registry.restrictModel(agentModelKey,
          allow: kAgentCompactCoreTools.toSet());
    }
    // P2-B MCP：远程 server 工具注册（仅 API 档；enabled 逐个拉取，
    // 失败 server 静默跳过不阻断回合）。注册在计划模式收窄之前，
    // 只读 MCP 工具可进计划模式白名单。
    if (useApi) {
      for (final server in settings.mcpServers) {
        if (!server.enabled) continue;
        try {
          final tools = await fetchMcpTools(server);
          final existing = registry.all.map((t) => t.name).toSet();
          for (final t in tools) {
            if (!existing.contains(t.name)) registry.register(t);
          }
        } catch (e) {
          debugPrint('[MCP] server "${server.name}" 拉取失败，跳过: $e');
        }
      }
    }
    // P1-A 计划模式：注册表收窄为「只读 + exit_plan」——复用并行安全声明
    //（副作用工具恒声明不安全），计划回合模型想执行修改类操作也调不到。
    if (planMode) {
      final readOnly = registry
          .visibleFor(agentModelKey)
          .where((t) => t.isConcurrencySafe?.call(const {}) ?? true)
          .map((t) => t.name)
          .toSet();
      registry.restrictUser(allow: {...readOnly, 'exit_plan'});
    }
    // 技能双工具（两条路线都注册，2026-10-01 P1-4）：
    // - load_skill：本地档此前"省 prefill 不开"导致技能目录可见却拿不到
    //   正文（技能=装饰品）；工具定义 prefill 成本远小于技能失效。
    // - save_skill：模型自主沉淀可复用流程（对话内创建，即时生效）。
    // 精简档例外（2026-10-27）：目录本身就不注入，双工具留着只是白烧 prefill。
    if (!compactPrompt && skillProvider.count > 0) {
      registry.register(createLoadSkillTool(skillProvider));
      registry.register(createSaveSkillTool(skillProvider));
    }

    // ask_user_question（P2-B2，DSH tool-ask-user）：缺信息/需确认时向用户
    // 提问，回合挂起等待；回答通道挂 agentPendingQuestionProvider → UI 卡片。
    // P1-A：exit_plan 审批走同一提问通道。
    Future<String?> askUser(String question, List<String> options) {
      final notifier = _ref.read(agentPendingQuestionProvider.notifier);
      final completer = Completer<String?>();
      notifier.state = {
        ...notifier.state,
        conversationId: AgentPendingQuestion(
          question: question,
          options: options,
          completer: completer,
        ),
      };
      return completer.future;
    }

    registry.register(createAskUserTool(ask: askUser));

    // P1-A goal 工具（无人值守续跑）+ 计划模式 exit_plan：仅 API 档注册
    // （本地小模型自驱多回合收敛性差，goal 驱动只给 API 档）。
    if (useApi) {
      final goalStore = await _goalStore();
      final goalMaxRounds = settings.agentGoalMaxRounds.clamp(1, 20);
      // 计划实体化：计划变化 → 重写对话内固定 id 的「📋 计划」活卡
      // （saveMessage upsert 同 id；内容含步骤状态，模型历史可见，UI 可回看）。
      void onPlanChanged(String cardText) {
        unawaited(_storage.saveMessage(ChatMessage(
          id: 'plan_$conversationId',
          conversationId: conversationId,
          role: MessageRole.assistant,
          content: cardText,
        )));
      }

      for (final t in createGoalTools(
        store: goalStore,
        conversationId: conversationId,
        maxRounds: goalMaxRounds,
        onPlanChanged: onPlanChanged,
      )) {
        registry.register(t);
      }
      registry.register(createPlanStepUpdateTool(
        store: goalStore,
        conversationId: conversationId,
        onPlanChanged: onPlanChanged,
      ));
      if (planMode) {
        registry.register(createExitPlanTool(
          store: goalStore,
          conversationId: conversationId,
          maxRounds: goalMaxRounds,
          ask: askUser,
          onPlanChanged: onPlanChanged,
        ));
      }
    }

    // run_code（P3-1，DSH PTC 语义）：仅 API 档注册——编排型编程子调用
    // 超出端侧小模型能力且耗 prefill；API 模型写编排程序是净收益。
    if (useApi) {
      registry.register(createRunCodeTool(callTool: (name, args) async {
        final matches = registry
            .visibleFor(agentModelKey)
            .where((t) => t.name == name)
            .toList();
        if (matches.isEmpty) {
          return ToolResult.error(
              '未知工具：$name（run_code 只能调用本回合已注册的其他工具）');
        }
        try {
          return await matches.first.execute(args);
        } catch (e) {
          return ToolResult.error('工具 "$name" 执行异常: $e');
        }
      }));
    }

    // 能力快照（Phase 3）：API 声明原生工具调用 → selectProtocol 选出
    // NativeToolProtocol（tools 进请求体）；本地走 prompt-json 文本协议。
    final capsBase = _engineCapabilitiesFor(agentModelKey, activeApi);
    // 精简档：一步只发一个工具调用（tiny 同时吐两个调用块基本必解析失败），
    // 并把工具清单渲染切成"一行一名 + 描述首句"。
    final caps = compactPrompt
        ? capsBase.copyWith(maxParallelToolCalls: 1)
        : capsBase;
    final protocol = selectProtocol(
        [NativeToolProtocol(), PromptJsonProtocol(compact: compactPrompt)],
        caps);
    // 激活人格（标准 = null，行为不变）；注入系统提示词身份段与人设段。
    final persona = settings.activePersona();
    var systemPrompt = buildSystemPrompt(
      modelName: useApi ? (activeApi?.name ?? 'API 模型') : targetModelId,
      registry: registry,
      protocol: protocol,
      modelId: agentModelKey,
      personaName: persona?.name,
      personaPrompt: persona?.prompt,
      // 任务执行纪律段（P2-A2）：仅 API 档——local 档系统提示必须逐字节
      // 稳定保 KV 前缀复用（与环境快照同一取舍）。
      taskDiscipline: useApi,
      // 档位：full 与旧版逐字节一致；compact 是本地小模型精简档。
      tier: promptTier,
    );
    // P1-A 计划模式系统段：只读规划纪律（exit_plan 前不动任何修改类操作）。
    if (planMode) {
      systemPrompt = '$systemPrompt\n\n'
          '【计划模式】本回合是只读规划回合，纪律如下：\n'
          '1. 可用工具仅限只读/查询类，修改与执行类工具已被禁用；\n'
          '2. 先充分调研（读文件/搜索/查状态），再产出完整执行计划；\n'
          '3. 计划完成后调用 exit_plan 提交用户审批（plan 参数 = 结构化'
          '计划：目标 / 步骤清单 / 每步验证方式 / 风险）；\n'
          '4. 被拒绝时按用户意见修订后可再次提交；批准前不做任何修改尝试；\n'
          '5. 用户批准后系统会自动开启执行回合，你只需一两句话确认开始。';
    }
    // ---- Dev Agent：开发模式注入 DevContext（工作区/计划/记忆/开发循环）----
    // 注入失败静默跳过（不阻断回合）；关闭 = 零注入零回归。
    if (settings.devModeEnabled) {
      try {
        // devWorkspaceId 是历史上的"只写不读"存放位，这里当恢复种子传进去，
        // 老用户配过的激活工作区不会因换了落盘位置而丢（DevStore 值优先）。
        await DevSessionController.instance.init(
            preferredActiveId: settings.devWorkspaceId);
        final devContext = await buildDevContext(
          workspaceId: DevSessionController.instance.activeWorkspaceId,
          taskId: DevSessionController.instance.activeTaskId,
        );
        if (devContext.trim().isNotEmpty) {
          systemPrompt = '$systemPrompt\n\n$devContext';
        }
      } catch (e) {
        debugPrint('[Dev] context build failed: $e');
      }
    }
    // ---- 用户记忆自动注入（DSH AGENTS.md 承担"用户偏好"的等价物）----
    // 全局记忆前 8 条注入系统提示，模型跨会话记得用户偏好/事实。
    // 内容只在 memory_set 后变化，不破坏逐回合系统提示的稳定性。
    if (settings.agentMemoryEnabled) {
      try {
        final mem = await readGlobalMemorySnapshot();
        if (mem.isNotEmpty) {
          final buf = StringBuffer('【用户记忆】以下是此前记住的用户偏好与事实，回答时遵循：');
          for (final e in mem) {
            buf.write('\n- ${e.key}: ${e.value}');
          }
          systemPrompt = '$systemPrompt\n\n$buf';
        }
      } catch (e) {
        debugPrint('[Memory] snapshot read failed: $e');
      }
    }
    // 双场景档：local/API 各自一套循环参数（API 档吃满云端预算，
    // local 档维持端侧省 token 策略）；档内数值仍可在设置里改。
    final agentProfile = settings.agentProfileFor(useApi: useApi);
    final newConfig = loopConfig.AgentConfig(
      maxStepsPerTurn: agentProfile.maxRounds,
      maxTokensPerRound: agentProfile.tokensPerRound,
      temperature: agentProfile.temperature,
      toolTimeout: Duration(milliseconds: agentProfile.toolTimeoutMs),
      allowParallelTools: agentProfile.allowParallelTools,
      maxParallel: agentProfile.maxParallel,
      // 主动压缩/分阶段预算（WP3 消费）：local 档由 agentNctx 派生；
      // API 档用独立预算设置（默认 32768 tok），配置了端点 contextWindow
      // 时取 min（×7/8 留生成余量）——长会话 proactive 压缩不再缺位。
      contextTokenBudget: useApi
          ? _apiContextTokenBudget(settings, activeApi)
          : (settings.agentNctx * 3) ~/ 4,
      maxTokensFinalRound: useApi ? null : 2048,
      // 思考失控治理：工具决策步默认不思考（端侧思考独白几乎都发生在那一步）。
      thinkingOnToolSteps: settings.agentThinkingOnToolSteps,
    );
    // 按路由选 adapter（local/API），各自冻结能力快照。
    // 思考失控守卫阈值共用一份设置（WP4：可调，默认 6000 字）。
    final LlmAdapter engine = useApi
        ? OpenAiAdapter(
            protocol: protocol,
            capabilities: caps,
            openAi: _ref.read(openAiServiceProvider),
            apiModel: activeApi,
            maxThinkingChars: settings.agentThinkingMaxChars,
          )
        : LocalEngineAdapter(
            inference: _inference,
            protocol: protocol,
            capabilities: caps,
            maxThinkingChars: settings.agentThinkingMaxChars,
            // 强制不思考后要知道该恢复成什么（用户的全局思考开关）。
            thinkingEnabled: settings.enableThinking,
          );

    // [NewAgent] 新 seam 活跃标记（验证 Phase 3 代码路径；验证后可删）
    debugPrint(
      '[NewAgent] seam=active route=$useApi '
      'adapter=${useApi ? 'OpenAiAdapter' : 'LocalEngineAdapter'} '
      'protocol=${protocol.id} model=$agentModelKey caps=$caps',
    );

    // ---- 历史 → 事件日志（导入，log-only 标记）----
    // 🔧 轨迹信封（kAgentTraceMessagePrefix 前缀）要放行：importFromMessages
    // 会把它还原成真实 assistant(toolCalls)/tool/result 事件（WP1a）；
    // 其余 🔧 活动消息（纯 UI 用）照旧排除。
    final allMessages = await _storage.getMessages(conversationId, limit: 200);
    final history = _messagesForModelContext(allMessages);
    final sessionLog =
        _sessionStore.importFromMessages(conversationId, history);

    // Phase 6：UI 活动状态订阅本 turn 事件流（工具卡片/压缩/重试/徽章）。
    _ref.read(agentUiStateProvider.notifier).attach(conversationId, sessionLog);

    // ---- 子代理接缝（Phase 4）：in-process spawn/fork/fan-out ----
    // 复用当前 registry/系统提示；adapter 可指定专用（更便宜）API 配置
    // （P3-2 按步路由：重活/子任务走低价模型，主回答走主模型）。
    // 子代理审批恒 `never`（自动拒绝沙箱升级，恒 workspace-write）。
    // 本地档精简（2026-10-05）：仅 API 档注册——端侧小模型自驱多回合
    // 收敛性差，子代理定义的 prefill 成本是净损失。
    if (settings.agentSubagentEnabled && useApi) {
      // 专用子代理模型：设置指定 + 存在 + 与主模型不同才单独建 adapter。
      LlmAdapter subagentEngine = engine;
      final subApiId = settings.agentSubagentApiModelId;
      if (useApi && subApiId.isNotEmpty && subApiId != activeApi?.id) {
        ApiModelConfig? subApi;
        for (final m in settings.apiModels) {
          if (m.id == subApiId) {
            subApi = m;
            break;
          }
        }
        if (subApi != null) {
          subagentEngine = OpenAiAdapter(
            protocol: protocol,
            capabilities: caps,
            openAi: _ref.read(openAiServiceProvider),
            apiModel: subApi,
            maxThinkingChars: settings.agentThinkingMaxChars,
          );
        }
      }
      final subagentProvider = InProcessSubagentProvider(
        adapter: subagentEngine,
        registry: registry,
        modelId: agentModelKey,
        providerKind: useApi ? ProviderKind.api : ProviderKind.local,
        systemPrompt: systemPrompt,
        parentSession: sessionLog,
      );
      // 注册 subagent 工具（每 turn 新建 registry → 无同名冲突）。
      // 后台子代理完成 → 通知转投父回合 step 收件箱（下一 step 模型可见）
      // + 落一条 🔔 可见消息（不入模型上下文，上下文走收件箱）。
      registry.register(createSubagentTool(
        subagentProvider,
        onBackgroundDone: (notice) {
          turn.agent?.injectNotice(notice);
          unawaited(_storage.saveMessage(ChatMessage(
            id: 'bgsub_${DateTime.now().millisecondsSinceEpoch}',
            conversationId: conversationId,
            role: MessageRole.assistant,
            content: '🔔 $notice',
          )));
        },
      ));
      // send_message 续轮（DSH tool-subagent-control）：向可续轮子代理
      // 追加指令再跑一回合。
      registry.register(createSubagentSendMessageTool(subagentProvider));
    }

    // 保存用户消息（UI 立即可见）。存储用**原图**（imagePaths，用户视角完整
    // 图片）；模型视图（切块序列）存 visionPaths，历史重发模型上下文时用。
    final userMsg = ChatMessage(
      id: DateTime.now().millisecondsSinceEpoch.toString(),
      conversationId: conversationId,
      role: MessageRole.user,
      content: prompt,
      imagePath: imagePath,
      imagePaths: imagePaths,
      visionPaths: visionChanged ? vision : null,
      attachments: prepared.map((a) => a.displayName).toList(),
      audioPath: audioPath,
    );
    await _storage.saveMessage(userMsg);
    await _refreshConversationMeta(conversationId);

    // ---- 流式占位 + 活动会话（与旧路径共享 UI 契约）----
    final tokenController = StreamController<String>.broadcast();
    // 思考流（agent 模式单独展示）：adapter 推全量快照，节流后落 UI state。
    final thinkingController = StreamController<String>.broadcast();
    final agentUi = _ref.read(agentUiStateProvider.notifier);
    var lastThinkingPush = DateTime.now();
    final thinkingSub = thinkingController.stream.listen((thinking) {
      if (thinking.isEmpty) return;
      final now = DateTime.now();
      if (now.difference(lastThinkingPush).inMilliseconds < 120) return;
      lastThinkingPush = now;
      agentUi.setThinking(conversationId, thinking);
    });
    // WP5：生成过程状态流（toolgen|chars|preview）——工具调用参数生成期
    // 可见流/思考流都为空，UI 靠它显示"正在生成工具调用参数…已 N 字"。
    final statusController = StreamController<String>.broadcast();
    final statusSub = statusController.stream.listen((line) {
      if (!line.startsWith('toolgen|')) return;
      final parts = line.split('|');
      final chars = int.tryParse(parts.length > 1 ? parts[1] : '') ?? 0;
      final preview = parts.length > 2 ? parts[2] : '';
      agentUi.setToolGen(conversationId, chars: chars, preview: preview);
    });
    final session = _AgentActivitySession(
      conversationId: conversationId,
      storage: _storage,
    );
    final assistantId = (DateTime.now().millisecondsSinceEpoch + 1).toString();
    var assistantMsg = ChatMessage(
      id: assistantId,
      conversationId: conversationId,
      role: MessageRole.assistant,
      content: '',
      isStreaming: true,
    );
    await _storage.saveMessage(assistantMsg);

    // 消费替换式 visible text → 周期持久化（节流）。
    StreamSubscription<String>? sub;
    var _lastSave = DateTime.now();
    sub = tokenController.stream.listen((visible) async {
      if (visible.isEmpty || visible.length == assistantMsg.content.length) {
        return;
      }
      final now = DateTime.now();
      // 与旧路径一致的节流（150ms）；此前误用秒级导致流式文字迟迟不更新。
      if (now.difference(_lastSave).inMilliseconds >= 150) {
        final next = assistantMsg.copyWith(content: visible);
        assistantMsg = next;
        await _storage.saveMessage(next).catchError((_) {});
        _lastSave = now;
      }
    });

    // ---- Phase 5：hooks / skills / AGENTS.md ----
    // AGENTS.md：全局 + 工作区（Dev 模式开启时按激活工作区解析本地路径；
    // 远端工作区暂不注入远端 AGENTS.md，Phase D 补 SFTP 读取）。
    String? agentsMdText;
    try {
      String? workspacePath;
      if (settings.devModeEnabled) {
        final wsId = DevSessionController.instance.activeWorkspaceId;
        final docs = await getApplicationDocumentsDirectory();
        workspacePath = wsId == DevWorkspace.kDefaultId
            ? p.join(docs.path, 'workspace')
            : p.join(docs.path, 'workspace', 'projects',
                sanitizeWorkspaceDirName(wsId));
      }
      final agentsMd = await loadAgentsMd(workspacePath: workspacePath);
      agentsMdText = agentsMd.content;
      // P2-D2：远端工作区叠加远端 AGENTS.md（SFTP 读取；失败静默降级）。
      final remoteMd = await readRemoteAgentsMd(
          DevSessionController.instance.activeWorkspaceId,
          settings.sshConfigs);
      if (remoteMd != null && remoteMd.trim().isNotEmpty) {
        agentsMdText = agentsMdText.trim().isEmpty
            ? remoteMd
            : '$agentsMdText\n\n$remoteMd';
      }
    } catch (_) {
      // 上下文注入是"锦上添花"，任何失败都必须静默降级、照常发送。
      // **必须裸 catch**：dartssh2 的 SftpStatusError 不实现 Exception，
      // 旧版写 `on Exception` ⇒ 远端没有 AGENTS.md 就把整条消息发送打死
      // （真机「发送失败: SftpStatusError: No such file(code 2)」+ 对话区空气泡）。
    }
    // Hooks（默认：模型缓存 guard 已在 guard.dart；pre-step 暂无内置 reject）。
    final hooks = AgentHooks();
    // ---- P1-B：压缩摘要走便宜模型（按步模型路由的压缩分支）----
    // 仅 API 档：模型链 = 专用压缩模型 > 子代理模型 > 主模型；摘要失败/
    // 超时由压缩插件内部回退确定性 digest（压缩永不因摘要模型失败）。
    Future<String?> Function(String)? llmSummarizer;
    if (useApi && settings.agentCompactEnabled) {
      var compApiId = settings.agentCompressionApiModelId;
      if (compApiId.isEmpty) compApiId = settings.agentSubagentApiModelId;
      ApiModelConfig? compApi;
      if (compApiId.isNotEmpty && compApiId != activeApi?.id) {
        for (final m in settings.apiModels) {
          if (m.id == compApiId) {
            compApi = m;
            break;
          }
        }
      }
      final compEngine = compApi != null
          ? OpenAiAdapter(
              protocol: protocol,
              capabilities: caps,
              openAi: _ref.read(openAiServiceProvider),
              apiModel: compApi,
              maxThinkingChars: settings.agentThinkingMaxChars,
            )
          : engine;
      final compModelName = compApi?.model ?? agentModelKey;
      llmSummarizer = (prompt) async {
        final r = await compEngine.generate(GenerateOptions(
          provider: ProviderKind.api,
          messages: [
            {'role': 'system', 'content': '你是上下文压缩摘要器，只输出摘要本身。'},
            {'role': 'user', 'content': prompt},
          ],
          tools: const [],
          temperature: 0.2,
          maxTokens: 1024,
          modelId: compModelName,
        ));
        return r.text;
      };
    }
    // ---- 主循环 ----
    final agent = ReactLoopAgent(
      session: sessionLog,
      adapter: engine,
      registry: registry,
      config: newConfig,
      modelId: agentModelKey,
      providerKind: useApi ? ProviderKind.api : ProviderKind.local,
      systemPrompt: systemPrompt,
      onToolActivity: session.update,
      sandboxApprover: _ref.read(sandboxApproverProvider),
      // Dev Agent：开发模式注入工作区解析器（文件/ssh 工具跟随激活工作区）。
      workspaceResolver: settings.devModeEnabled
          ? DevSessionController.instance.resolveActiveWorkspaceId
          : null,
      // Phase 6：pre-execute `ask` → 审批确认框（ApprovalDialog）。
      preApprover: _ref.read(toolPreApproverProvider),
      hooks: hooks,
      // 精简档（本地小模型）不注入技能目录与 AGENTS.md：两者都是常驻
      // prefill，tiny 模型从中得到的收益为负（实测：注入即答非所问）。
      skills: compactPrompt ? null : skillProvider,
      agentsMd: compactPrompt ? null : agentsMdText,
      // 环境快照（当前时间）：仅 API 档。P1-C 改为**尾部注入**形态——
      // provider 每 step 取一次，内容变化才以尾部 user 消息追加；系统提示
      // 逐字节稳定，API prompt cache 不再因时间快照每回合全段破缓存。
      environmentNoteProvider:
          useApi ? () => _formatEnvironmentNote() : null,
      // 上下文压缩（确定性裁剪 + P1-B LLM 摘要）：设置可关；关 = 超限直接
      // 走失败终止。摘要模型失败时插件内部回退确定性摘要。
      compaction: settings.agentCompactEnabled
          ? DeterministicCompaction(llmSummarizer: llmSummarizer)
          : null,
      // 超长工具输出溢写：写 ApplicationSupport/agent_spill/，模型侧留摘要。
      spillStore: settings.agentSpillEnabled ? _writeSpillFile : null,
    );
    turn.agent = agent;
    String answer = '';
    TurnEndReason? reason;
    // 推理日志：本轮路由与请求规模（「推理日志」页可见，配合排障）。
    final logManager = _ref.read(modelManagerProvider.notifier);
    logManager.appendInferenceLog(
      '智能体请求 | ${useApi ? "API(${activeApi?.name})" : "本地($targetModelId)"} '
      '事件数=${sessionLog.eventsCount}',
    );
    // 提示词体量可观测（2026-10-27 K90 事故复盘）：此前系统提示无声涨到
    // 19507 字符（4580 token）没人看得见，tiny 模型直接答非所问。现在每
    // 回合把"档位 + 字符数 + 工具数 + 技能/AGENTS.md 开关"打进推理日志。
    final mdLen = (agentsMdText ?? '').trim().length;
    // 同步进 logcat：无线 adb 排障时不必爬 UI 就能看到体量（grep AgentPrompt）。
    debugPrint('[AgentPrompt] tier=${compactPrompt ? "compact" : "full"} '
        'systemChars=${systemPrompt.length} '
        'tools=${registry.visibleFor(agentModelKey).length} '
        'skills=${compactPrompt ? 0 : skillProvider.count} agentsMd=$mdLen '
        'model=$agentModelKey');
    logManager.appendInferenceLog(
      '智能体提示词 | 档位=${compactPrompt ? "精简" : "完整"}'
      ' | 系统提示 ${systemPrompt.length} 字符'
      ' | 工具 ${registry.visibleFor(agentModelKey).length}'
      ' | 技能=${compactPrompt ? "关" : skillProvider.count}'
      ' | AGENTS.md=${compactPrompt ? "关" : (mdLen == 0 ? "无" : "$mdLen 字")}',
    );
    if (compactPrompt &&
        systemPrompt.length > kAgentPromptCompactBudgetChars) {
      logManager.appendInferenceLog(
        '⚠️ 精简档系统提示 ${systemPrompt.length} 字符，已超预算 '
        '${kAgentPromptCompactBudgetChars}——小模型会重新滑向答非所问，'
        '请检查人格设定/工具白名单/技能与 AGENTS.md 是否被手动打开',
      );
    }
    try {
      reason = await agent.kick(
        effectivePrompt,
        imagePath: firstImage,
        // 模型视图 = 切块序列（上限 10 张，超出已在 effectivePrompt 如实告知）；
        // 用户消息本体（imagePaths）仍是原图，两者互不影响。
        imagePaths: vision.isNotEmpty
            ? (droppedImages > 0 ? vision.sublist(0, 10) : vision)
            : imagePaths,
        audioPath: audioPath,
        onToken: tokenController,
        onThinking: thinkingController,
        onStatus: statusController,
      );
      // 只取**本轮**产出的答案；失败时为空——绝不回退历史旧回复冒充本回复。
      answer = agent.lastTurnAnswer;
      _lastTurnEndReason[conversationId] = reason.kind.name;
      debugPrint('[ChatNotifier] new-agent done: reason=${reason.kind.name}, '
          'answer len=${answer.length}');
      // 压缩可观测：本回合 compaction/summary 事件 → 推理日志（此前压缩
      // 只有一条 debugPrint，release 里用户/开发者都查不到"压没压"）。
      try {
        final compactions = [
          for (final e in sessionLog.rawEvents)
            if (e.type == kEventCompactionSummary) e,
        ];
        if (compactions.isNotEmpty) {
          final last = compactions.last;
          final summaryLen =
              ((last.data['content'] as String?) ?? '').length;
          logManager.appendInferenceLog(
            '上下文压缩 | 本回合 ${compactions.length} 次 | '
            '来源=${last.data['provider'] ?? '?'} | 摘要 $summaryLen 字',
          );
        }
      } catch (_) {}
      // P0 遥测：回合指标从日志纯派生（循环零侵入），JSONL 落盘。
      try {
        final metrics =
            TurnMetrics.fromLog(sessionLog, agent.phaseState.turn);
        if (metrics != null) {
          _metricsStore ??= TurnMetricsStore(
              baseDir:
                  '${(await getApplicationSupportDirectory()).path}/metrics');
          await _metricsStore!.record(metrics);
        }
      } catch (e) {
        debugPrint('[ChatNotifier] metrics record failed: $e');
      }
      // P0 轨迹：设置开启时整份会话轨迹落 JSONL（回放/评估/排障用）。
      if (settings.agentTraceExportEnabled) {
        try {
          _traceDir ??=
              '${(await getApplicationSupportDirectory()).path}/traces';
          final f = await trace_export.writeTraceFile(sessionLog,
              baseDir: _traceDir!, conversationId: conversationId);
          logManager.appendInferenceLog('轨迹已落盘 | ${f.path}');
        } catch (e) {
          debugPrint('[ChatNotifier] trace export failed: $e');
        }
      }
    } catch (e, s) {
      answer = agent.lastTurnAnswer;
      debugPrint('[ChatNotifier] new-agent error: $e\n$s');
    } finally {
      // 收尾（无论正常/异常/取消）：重置 UI 生成态 + 清 agent 引用 + 收流。
      turn.agent = null;
      _syncRunningState(); // 真正的注销由 sendMessage 顶层 finally 统一做
      // Phase 6：停止订阅本 turn 事件流（状态保留供面板展示本轮末态）。
      _ref.read(agentUiStateProvider.notifier).detach(conversationId);
      agentUi.setToolGen(conversationId, chars: 0); // WP5：清工具参数生成提示
      sub?.cancel();
      await thinkingSub.cancel();
      await statusSub.cancel();
      tokenController.close();
      unawaited(thinkingController.close());
      unawaited(statusController.close());
    }

    // 最终占位文本 = 本轮最终回答（turn 末位 assistant/message）。
    // 本轮没产出答案（失败/异常）→ 明确报错误文案，绝不拿历史旧回复冒充。
    final turnFailed = reason?.kind != TurnEndReasonKind.completed;
    if (answer.isEmpty && turnFailed) {
      final detail = agent.lastTurnError;
      answer = '⚠️ 本轮执行失败${detail != null ? '：$detail' : ''}'
          '（详见推理日志）';
      logManager.appendInferenceLog('本轮失败 | ${detail ?? '未知错误'}');
    }
    // 达到最大轮数仍在调工具：明确告知"没做完"而不是假装完成。
    if (reason?.kind == TurnEndReasonKind.maxSteps) {
      logManager.appendInferenceLog(
        '达到最大轮数上限（${settings.agentMaxRounds}）仍未产出最终回答，'
        '可在设置中调大「工具循环最大轮数」',
      );
      answer = answer.isEmpty
          ? 'ℹ️ 工具循环达到最大轮数（${settings.agentMaxRounds}），任务未完成。'
              '可在设置中调大「工具循环最大轮数」后重试。'
          : '$answer\n\nℹ️（注意：达到最大轮数上限，任务可能未完成）';
    }
    // 智能体回答的指标：本地路线取原生末步（答案步）的 n_gen/t_gen_ms，
    // 与普通聊天同一口径（tok/s 与推理日志一致）；API 路线无原生 stats，
    // 保持不显示。首 Tok 对多步回合无单步语义，置 0 → 界面省略首Tok。
    InferenceStats? answerStats;
    // 本地路线：原生 getInferenceStats 同时携带 KV 缓存占比字段
    // （kv_used / kv_ctx），供输入框上下文占用圈展示本地上下文占用。
    Map<String, dynamic> genStats = {};
    if (!useApi) {
      try {
        genStats = await _inference.getInferenceStats();
      } catch (_) {}
      final n = (genStats['n_gen'] as num?)?.toInt() ?? 0;
      final gms = (genStats['t_gen_ms'] as num?)?.toDouble() ?? 0.0;
      if (n > 0 && gms > 0) {
        answerStats = InferenceStats(
          firstTokenMs: 0,
          totalMs: gms.round(),
          tokPerSec: n * 1000 / gms,
        );
      }
    }
    // WP2e：API 路线 token 用量观测（前缀缓存命中评估打底；
    // usage 由 SSE 末块透传 → LlmResult.usage → assistant 事件）。
    if (useApi) {
      Map<String, dynamic>? usage;
      for (final e in sessionLog.rawEvents) {
        final u = e.data['usage'];
        if (e.type == kEventAssistantMessage && u is Map<String, dynamic>) {
          usage = u;
        }
      }
      // 兜底：SSE 末块 usage 已被 service 层统一捕获（lastUsage），
      // 事件链缺失（如流被提前取消）时用它——两条链同一数据源。
      usage ??= _ref.read(openAiServiceProvider).lastUsage;
      if (usage != null) {
        logManager.appendInferenceLog(
          'API 用量 | prompt=${usage['prompt_tokens'] ?? '?'} '
          'completion=${usage['completion_tokens'] ?? '?'}'
          '${usage['prompt_cache_hit_tokens'] != null ? ' 缓存命中=${usage['prompt_cache_hit_tokens']}' : ''}',
        );
        debugPrint('[ChatNotifier] API usage: prompt='
            '${usage['prompt_tokens'] ?? '?'} window=${activeApi?.contextWindow}');
        // API 接入：回合结束更新上下文占用（prompt_tokens = 当前上下文已占用）。
        final prompt = usage['prompt_tokens'] as num?;
        if (prompt != null) {
          await _updateContextUsage(
            conversationId,
            usedTokens: prompt.toInt(),
            api: activeApi,
          );
        }
      }
    } else {
      // 本地路线：KV 缓存占比（已占用位置 kv_used / 上下文窗口 kv_ctx）。
      _updateLocalContextUsage(conversationId, genStats);
    }
    unawaited(_maybeAutoCompact(conversationId));
    // 思考存档落库（kind=thinking，仅 UI 展示不入模型上下文）：turn 事件流
    // 结束时各步思考已全部归档到 UI 状态（thinkingHistory），逐块存为过程
    // 痕迹消息——此前思考只存在于 live 状态，回合完成后即消失、无法回看。
    // timestamp 取回答前偏移，保证排序为 [工具活动] → [思考存档] → [回答]。
    final finishedThinking = List<String>.from(
        agentUi.state[conversationId]?.thinkingHistory ?? const []);
    for (var i = 0; i < finishedThinking.length; i++) {
      final block = finishedThinking[i].trim();
      if (block.isEmpty) continue;
      await _storage.saveMessage(ChatMessage(
        id: '${assistantMsg.id}-think-$i',
        conversationId: conversationId,
        role: MessageRole.assistant,
        content: '💭 $block',
        isStreaming: false,
        timestamp:
            assistantMsg.timestamp.subtract(Duration(milliseconds: 3 + i)),
        kind: MessageKind.thinking,
      ));
    }
    // turnTrace UI 信封（2026-10-25 重构 P0）：把 live 事件流的**真实交错
    // 顺序**（timeline：思考/工具）落成一条 notice 消息，历史回合据此走与
    // live 相同的渲染管线，不再靠散消息重排猜顺序。工具项引用落库的 🔧
    // 消息 id（toolData 已带结构化数据，无需反解析字符串）。
    {
      final uiState = agentUi.state[conversationId];
      final trace = <TurnUiItem>[];
      final toolIds = session.writtenIds;
      for (final marker in uiState?.timeline ?? const []) {
        switch (marker) {
          case UiTimelineThinking(:final index):
            if (index >= 0 && index < finishedThinking.length) {
              final block = finishedThinking[index].trim();
              if (block.isNotEmpty) trace.add(TurnUiItem.think(block));
            }
          case UiTimelineTool(:final index):
            // timeline 的工具序号与落库 writtenIds 同序（都按 tool/call 顺序）。
            if (index >= 0 && index < toolIds.length) {
              trace.add(TurnUiItem.tool(toolIds[index]));
            }
        }
      }
      // timeline 之外的兜底：错误行（turn error reason）。
      final err = uiState?.lastError;
      if (err != null && err.isNotEmpty) trace.add(TurnUiItem.error(err));
      final traceContent = encodeTurnUiTrace(trace);
      if (traceContent != null) {
        await _storage.saveMessage(ChatMessage(
          id: '${assistantMsg.id}-uitrace',
          conversationId: conversationId,
          role: MessageRole.assistant,
          content: traceContent,
          timestamp:
              assistantMsg.timestamp.subtract(const Duration(milliseconds: 2)),
          kind: MessageKind.notice,
          noticeCode: 'turnTrace',
        ));
      }
    }
    // WP1a：本轮工具轮轨迹以信封消息落库，下一轮导入时还原为真实
    // assistant(toolCalls)/tool/result 事件——修"turn 间失忆"（模型每轮
    // 忘掉上一轮调过什么工具）。createdAt 置于最终回答之前 1ms，
    // 保证导入顺序 = 工具轮轨迹 → 最终回答（createdAt ASC 排序）。
    final traceContent = encodeAgentTraceMessage(sessionLog);
    if (traceContent != null) {
      await _storage.saveMessage(ChatMessage(
        id: '${assistantMsg.id}-trace',
        conversationId: conversationId,
        role: MessageRole.assistant,
        content: traceContent,
        timestamp:
            assistantMsg.timestamp.subtract(const Duration(milliseconds: 1)),
      ));
    }
    assistantMsg = assistantMsg.copyWith(
      content: answer,
      isStreaming: false,
      inferenceStats: answerStats,
    );
    await _storage.saveMessage(assistantMsg);
    await _refreshConversationMeta(conversationId);
    _maybeAutoSpeak(conversationId, answer);
    return answer;
  }

  /// 构建 agent 工具注册表：全量内置工具 → 联网类按配置移除 → 按模型过滤。
  ///
  /// 核心工具（get_time/calculator/todo/note/unit_converter/memory/文件类）
  /// 引擎能力快照（Phase 3 能力驱动协议选择依据，对应 [PreparedLlmCall.capabilities]）。
  ///
  /// 端侧简化：当前为**静态声明**（模型目录暂不承载 capability 字段）。
  /// - **api**：OpenAI 兼容 → 原生工具调用可用（nativeToolCall）。
  /// - **local**：Spark/Qwen 系给 `toolTemplate: spark-xml`（为 xml-tool 协议
  ///   预留）；其余本地模型全默认（prompt-json 兜底）。
  ///
  /// 后续增强：模型目录加 capability 字段 + 引擎运行时探测
  /// （`EngineCapabilities.resolve(declared:, probed:)`）替换本静态映射，
  /// 协议选择（`selectProtocol`）即自动跟随能力变化，无需改调用方。
  EngineCapabilities _engineCapabilitiesFor(
    String modelId,
    ApiModelConfig? activeApi,
  ) {
    if (activeApi != null) {
      // API 路线：OpenAI 兼容，原生工具调用 + 并行（API 侧能力较松）。
      return const EngineCapabilities(
        nativeToolCall: true,
        maxParallelToolCalls: 5,
      );
    }
    // 本地路线：静态声明。Spark/Qwen 系标 xml 模板；Ling（Bailing V3）系
    // 标 bailing-v3（tool 结果保留 role:tool → OBSERVATION 渲染 + 原生
    // 闭合标签调用格式）；其余默认 prompt-json。
    final lower = modelId.toLowerCase();
    final isXmlFamily = ['spark', 'qwen', 'tongyi'].any(lower.contains);
    final isBailingV3 = lower.startsWith('ling');
    return EngineCapabilities(
      toolTemplate: isXmlFamily
          ? 'spark-xml'
          : (isBailingV3 ? 'bailing-v3' : null),
      maxParallelToolCalls: 2,
    );
  }

  /// 更新某会话 API 接入模型的上下文占用（上下文占用圈数据源）。
  ///
  /// [usedTokens] = 当前发送给模型的上下文 token 数（usage.prompt_tokens）。
  /// 槽位优先 API `/v1/models` 拉取的 `n_ctx`（30min 缓存），拉不到时回退
  /// 配置 [ApiModelConfig.contextWindow]；两者都无 → 无数据，UI 不显示。
  Future<void> _updateContextUsage(
    String conversationId, {
    required int usedTokens,
    required ApiModelConfig? api,
  }) async {
    if (api == null) return;
    final service = _ref.read(openAiServiceProvider);

    int? window;
    String source = '';
    // 优先实测槽位（fetchContextWindow 带 30min 缓存，非每轮拉）。
    final fetched = await service.fetchContextWindow(api);
    if (fetched != null && fetched > 0) {
      window = fetched;
      source = '实测';
    } else if (api.contextWindow != null && api.contextWindow! > 0) {
      window = api.contextWindow;
      source = '配置';
    } else {
      // 兜底（2026-10-25 真机：云端 API 不报 n_ctx、contextWindow 未配置
      // → 窗口 null → 占用环恒 0）：用 API 上下文压缩预算作为窗口估计
      // ——那本来就是本 app 侧的有效上下文口径。
      final budget = _ref.read(settingsProvider).agentApiContextBudget;
      if (budget > 0) {
        window = budget;
        source = '预算';
      }
    }

    _ref.read(contextUsageProvider.notifier).update(
          conversationId,
          usedTokens: usedTokens,
          windowTokens: window,
          windowSource: source,
        );
  }

  /// 压缩摘要信封的 noticeCode（存储级投影压缩，2026-10-25）：
  /// 该消息在 UI 隐藏（notice 不渲染）、在模型上下文里作为 user 摘要恒入，
  /// 其 timestamp 即压缩游标——之前的旧文本轮不再进入模型上下文。
  static const String kCompactSummaryNotice = 'compactSummary';

  /// 最新压缩摘要信封（可能没有）：timestamp = 压缩游标。
  ChatMessage? _latestCompactSummary(List<ChatMessage> all) {
    ChatMessage? latest;
    for (final m in all) {
      if (m.noticeCode == kCompactSummaryNotice &&
          (latest == null || m.timestamp.isAfter(latest.timestamp))) {
        latest = m;
      }
    }
    return latest;
  }

  /// 模型上下文过滤（三路共用：简单聊天历史 / 智能体回合导入 / 占用估算）：
  /// 排除 UI 活动消息（放行 🔧TRACE 信封）+ 排除压缩游标之前的旧文本轮
  /// （UI 历史保留、模型不见）；压缩摘要信封恒入（只保留最新一份）。
  List<ChatMessage> _messagesForModelContext(List<ChatMessage> all) {
    final summary = _latestCompactSummary(all);
    final cursor = summary?.timestamp;
    return all.where((m) {
      if (m.content.isEmpty) return false;
      final isTrace = m.content.startsWith(kAgentTraceMessagePrefix);
      if (_isToolActivityMessage(m) && !isTrace) return false;
      if (m.noticeCode == kCompactSummaryNotice) return identical(m, summary);
      if (cursor != null && m.timestamp.isBefore(cursor)) return false;
      return true;
    }).toList();
  }

  /// 本地路线：更新某会话 KV 缓存占比（上下文占用圈数据源）。
  ///
  /// used = 原生 KV 缓存已占用位置数（kv_used，当前会话已解码进缓存的 token），
  /// window = 原生实际上下文窗口（kv_ctx = llama_n_ctx，含 oom-guard 裁剪后值）。
  /// 任一缺失 → 无数据，UI 不显示（fraction 为 null）。
  void _updateLocalContextUsage(
    String conversationId,
    Map<String, dynamic> genStats,
  ) {
    final used = genStats['kv_used'] as num?;
    final ctx = genStats['kv_ctx'] as num?;
    if (used == null || ctx == null || ctx <= 0) return;
    // 本地 KV 单实例：当前快照只对刚测量完的会话有效，清掉其它会话的
    // 陈旧值（切会话后旧占用圈仍显示是误导）。
    _ref
        .read(contextUsageProvider.notifier)
        .clearLocalExcept(conversationId);
    _ref.read(contextUsageProvider.notifier).update(
          conversationId,
          usedTokens: used.toInt(),
          windowTokens: ctx.toInt(),
          windowSource: '原生',
          isLocal: true,
        );
  }

  /// 启动/切会话时回填占用快照（估算口径）。
  ///
  /// 占用快照只在回合结束时更新（内存态），app 重启后圈圈会一直显示「—」；
  /// 这里按本地历史重估 used。窗口按首页占用圈同款路由规则：智能体 API 驱动 /
  /// 纯 API → API 槽位（fetchContextWindow 实测优先，回退配置 contextWindow），
  /// 本地 → contextSize 设置。
  /// ⚠️ 必须直读持久层 [SettingsService.load] 而非 settingsProvider：启动时
  /// provider 的异步 _load 未完成，读到默认设置会误判路由（真机踩坑：用户
  /// API 模型 256k 被显示成本地 contextSize 4096 的「估算」）。
  /// 已有快照的会话跳过（不覆盖回合实测值）；任何失败静默。
  Future<void> refreshUsageEstimate(String conversationId) async {
    try {
      if (conversationId.isEmpty) return;
      if (_ref.read(contextUsageProvider.notifier).hasUsage(conversationId)) {
        return;
      }
      final settings = await SettingsService().load();
      final hasLocalLoaded = _ref.read(modelManagerProvider).isLoaded;
      final hasDefault = settings.defaultModelId != null;
      // API 配置解析必须与回合路由同构（2026-10-25 修复：API 会话的占用
      // 窗口被回填成本地 contextSize）：智能体 API 档实际驱动模型 =
      // agentModelId 在 apiModels 里的配置（不是 activeApiModel()）——
      // 两者不一致时此前查不到 API 配置 → 落到本地 contextSize。
      ApiModelConfig? apiCfg;
      var apiRouted = false;
      if (settings.agentModelSource == 'api') {
        for (final m in settings.apiModels) {
          if (m.id == settings.agentModelId) {
            apiCfg = m;
            break;
          }
        }
        apiCfg ??= settings.activeApiModel();
        apiRouted = apiCfg != null;
      } else {
        apiCfg = settings.activeApiModel();
        apiRouted = apiCfg != null && !hasLocalLoaded && !hasDefault;
      }

      final all = await _storage.getMessages(conversationId, limit: 200);
      if (all.isEmpty) return;
      final log = _sessionStore
          .importFromMessages(conversationId, _messagesForModelContext(all));
      final est = estimateContextTokens(log.deriveModelMessages());
      if (est <= 0) return;

      int? window;
      var source = '';
      if (apiRouted && apiCfg != null) {
        final fetched = await _ref
            .read(openAiServiceProvider)
            .fetchContextWindow(apiCfg);
        if (fetched != null && fetched > 0) {
          window = fetched;
          source = '实测';
        } else if ((apiCfg.contextWindow ?? 0) > 0) {
          window = apiCfg.contextWindow;
          source = '配置';
        } else {
          final budget = settings.agentApiContextBudget;
          if (budget > 0) {
            window = budget;
            source = '预算';
          }
        }
      } else if (settings.contextSize > 0) {
        window = settings.contextSize;
        source = '配置';
      }
      if (window == null) return;
      _ref.read(contextUsageProvider.notifier).update(
            conversationId,
            usedTokens: est,
            windowTokens: window,
            windowSource: source,
          );
    } catch (e) {
      debugPrint('[ChatNotifier] refreshUsageEstimate failed: $e');
    }
  }

  /// 自动压缩（2026-10-25）：占用越过阈值（默认 80%，占用详情面板可拖）
  /// 时在回合结束后自动执行存储级压缩。回合执行中不触发（导入竞态）。
  Future<void> _maybeAutoCompact(String conversationId) async {
    final usage =
        _ref.read(contextUsageProvider.notifier).usageFor(conversationId);
    final fraction = usage?.fraction;
    if (fraction == null) return;
    final threshold = _ref.read(settingsProvider).autoCompactThreshold;
    if (fraction < threshold) return;
    if (_activeTurns.containsKey(conversationId)) return;
    final (envelopes, chars) = await manualCompact(conversationId);
    if (envelopes > 0) {
      _ref.read(modelManagerProvider.notifier).appendInferenceLog(
            '自动压缩 | 占用 ${(fraction * 100).round()}% ≥ 阈值 '
            '${(threshold * 100).round()}% | 移出 $envelopes 条 | 摘要 $chars 字',
          );
    }
  }

  /// 手动压缩（输入框占用圈 → 详情面板入口）。
  ///
  /// **存储级投影压缩**（2026-10-25 重写，此前只清 TRACE 信封、纯文本会话
  /// 永远 (0,0) 被 450 投诉"没有效果"）：
  /// - 文本轮：保留最近 6 条（≈3 轮）原样入上下文，更早的折叠成**一条压缩
  ///   摘要信封**（noticeCode=compactSummary，UI 不渲染、模型恒见）——其
  ///   timestamp 即压缩游标，旧文本轮经 [_messagesForModelContext] 出上下文，
  ///   **存储与 UI 历史原样保留**；
  /// - 工具轮：沿用 planStorageCompaction（保留最近一条信封，其余删除，
  ///   最早一条改写为摘要信封）；
  /// - 旧摘要信封删除合并（重复压缩不留多份）。
  ///
  /// 与回合内 DeterministicCompaction 的区别：那是内存投影，本方法持久。
  /// 返回 (移出上下文的消息数, 摘要字符数)；无可压缩内容返回 (0, 0)。
  Future<(int, int)> manualCompact(String conversationId) async {
    final all = await _storage.getMessages(conversationId, limit: 200);
    // ① 工具轮信封清理（保留最近一条）。
    final plan = planStorageCompaction(all);
    // ② 文本轮投影压缩：保留最近 6 条，更早的折叠。
    const keepRecent = 6;
    final summary = _latestCompactSummary(all);
    final cursor = summary?.timestamp;
    final textMsgs = all
        .where((m) =>
            m.content.isNotEmpty &&
            !_isToolActivityMessage(m) &&
            m.noticeCode != kCompactSummaryNotice &&
            (cursor == null || m.timestamp.isAfter(cursor)))
        .toList();
    final folded = textMsgs.length > keepRecent
        ? textMsgs.sublist(0, textMsgs.length - keepRecent)
        : <ChatMessage>[];
    if (plan == null && folded.isEmpty) return (0, 0);

    // ③ 写压缩摘要信封（若本轮有折叠文本；timestamp = 折叠边界之后 1ms，
    //   保证既覆盖全部折叠消息、又落在保留窗口之前）。
    var summaryChars = plan?.summaryChars ?? 0;
    String summaryText = plan?.summaryEnvelope ?? '';
    if (folded.isNotEmpty) {
      final boundary = folded.last.timestamp;
      final topics = [
        for (final m in folded)
          if (m.role == MessageRole.user)
            m.content.trim().split('\n').first
      ].take(5).map((t) => '「${t.length > 16 ? t.substring(0, 16) : t}」');
      summaryText = '【上下文已压缩】此前 ${folded.length} 条消息已移出模型'
          '上下文（聊天记录不受影响）。用户此前问过：${topics.join('、')}。'
          '如需细节请用户复述。';
      summaryChars = summaryText.length;
      await _storage.saveMessage(ChatMessage(
        id: '${boundary.millisecondsSinceEpoch + 1}-compact',
        conversationId: conversationId,
        role: MessageRole.user,
        kind: MessageKind.notice,
        noticeCode: kCompactSummaryNotice,
        content: summaryText,
        timestamp: boundary.add(const Duration(milliseconds: 1)),
      ));
    }

    // ④ 删除：旧 TRACE 信封（plan.deleteIds）+ 旧压缩摘要信封（合并）。
    final deleteIds = [
      ...?plan?.deleteIds,
      for (final m in all)
        if (m.noticeCode == kCompactSummaryNotice) m.id,
    ];
    if (deleteIds.isNotEmpty) {
      await _storage.deleteMessages(deleteIds);
    }

    // ⑤ 重估占用（用压缩后的模型上下文口径），窗口沿用原快照。
    final manager = _ref.read(modelManagerProvider.notifier);
    manager.appendInferenceLog(
      '手动压缩 | 移出上下文 ${deleteIds.length + folded.length} 条'
      '（工具信封 ${plan?.deleteIds.length ?? 0} + 旧文本 ${folded.length}）'
      ' | 摘要 $summaryChars 字',
    );
    final updated = await _storage.getMessages(conversationId, limit: 200);
    final log = _sessionStore
        .importFromMessages(conversationId, _messagesForModelContext(updated));
    final est = estimateContextTokens(log.deriveModelMessages());
    final prev =
        _ref.read(contextUsageProvider.notifier).usageFor(conversationId);
    if (prev?.windowTokens != null) {
      _ref.read(contextUsageProvider.notifier).update(
            conversationId,
            usedTokens: est,
            windowTokens: prev!.windowTokens,
            windowSource: '压缩后估算',
            isLocal: prev.isLocal,
          );
    }
    debugPrint('[ManualCompact] conv=$conversationId folded=${folded.length} '
        'deleted=${deleteIds.length} est=$est tok');
    return (deleteIds.length + folded.length, summaryChars);
  }

  /// 溢写存储：超长工具输出落盘 `ApplicationSupport/agent_spill/`，
  /// 返回文件路径（模型侧摘要里带定位，可按需读取）。
  static Future<String> _writeSpillFile(Uint8List bytes) async {
    final base = await getApplicationSupportDirectory();
    final dir = Directory('${base.path}/agent_spill');
    if (!dir.existsSync()) dir.createSync(recursive: true);
    final file = File('${dir.path}/'
        'spill_${DateTime.now().microsecondsSinceEpoch}_${bytes.length}.bin');
    await file.writeAsBytes(bytes);
    return file.path;
  }

  /// 环境快照文案（API 档环境注入）：当前日期时间 + 星期。
  /// P1-C：分钟按 10 分钟桶化——同一桶内文案不变，主循环据此跳过重复
  /// 注入（时间快照的变化频率从每回合降到每 ≤10 分钟，尾部小追加）。
  static String _formatEnvironmentNote() {
    const weekdays = ['一', '二', '三', '四', '五', '六', '日'];
    final now = DateTime.now();
    final mm = now.month.toString().padLeft(2, '0');
    final dd = now.day.toString().padLeft(2, '0');
    final hh = now.hour.toString().padLeft(2, '0');
    final mi = (now.minute ~/ 10 * 10).toString().padLeft(2, '0');
    return '当前时间：${now.year}-$mm-$dd $hh:$mi（星期${weekdays[now.weekday - 1]}）';
  }

  /// API 档主动压缩预算（token 估算）：设置值为准；配置了端点
  /// contextWindow 时取 min（×7/8 留生成余量）。
  static int _apiContextTokenBudget(
    InferenceSettings settings,
    ApiModelConfig? api,
  ) {
    var budget = settings.agentApiContextBudget;
    final cw = api?.contextWindow;
    if (cw != null && cw > 0) {
      final derived = cw * 7 ~/ 8;
      if (derived < budget) budget = derived;
    }
    return budget;
  }

  /// 默认全启用；联网类（web_search/get_weather）由 [settings.webSearchEnabled]
  /// 控制；shell_exec 默认启用（端侧能力向强扩展，不做自我设限）。
  ToolRegistry _buildAgentRegistry(InferenceSettings settings, String modelId,
      {String? conversationId}) {
    final registry = ToolRegistry();
    // web_search 每回合调用上限来自设置（DSH max_uses 语义，默认 5）。
    // Dev Agent 工具组（git/plan/ssh/run_tests）：仅开发模式注册。
    for (final tool in createBuiltinTools(
        webSearchMaxSearchesPerTurn: settings.agentMaxSearchesPerTurn,
        includeDevTools: settings.devModeEnabled,
        devSshConfigs: settings.sshConfigs,
        // ADB 远程控制：独立开关（不受开发模式影响），目标机白名单来自设置。
        adbEnabled: settings.adbEnabled,
        adbTargets: settings.adbTargets,
        conversationId: conversationId,
        // todo_write 成功 → 对话内固定 id 的「☑ 任务清单」活卡 upsert
        //（用户有地方看进度；固定 id 反复重写不刷屏，模型历史可见）。
        // 清单本体也按会话隔离存储（v3）：不同会话各看各的清单。
        onTodosChanged: conversationId == null
            ? null
            : (items) => unawaited(_storage.saveMessage(ChatMessage(
                  id: 'todo_$conversationId',
                  conversationId: conversationId,
                  role: MessageRole.assistant,
                  content: renderTodoCardText(items),
                ))))) {
      registry.register(tool);
    }
    // 开发模式关闭兜底：不暴露任何 Dev 工具（零回归）。
    if (!settings.devModeEnabled) {
      for (final name in kDevToolNames) {
        registry.unregister(name);
      }
    } else {
      // P2-D1 Dev 工具逐组开关：git/ssh/plan/task/verify 五组独立开关。
      const groups = <String, List<String>>{
        'git': [
          'git_status',
          'git_diff',
          'git_log',
          'git_commit',
          'git_push',
          'git_clone', // L1 本地克隆（JGit）；漏列会导致关 git 组后它仍可见
        ],
        'ssh': ['ssh_exec', 'ssh_read_file', 'ssh_write_file'],
        'sync': ['workspace_sync'],
        'plan': ['plan_create', 'plan_update', 'plan_list'],
        'task': ['task_create', 'task_list'],
        'verify': ['run_tests'],
      };
      for (final entry in groups.entries) {
        if (!settings.devToolGroupEnabled(entry.key)) {
          for (final name in entry.value) {
            registry.unregister(name);
          }
        }
      }
    }

    // 联网搜索：把当前搜索 provider 注册到接缝（对齐 DSH ctx.web 的可插拔
    // 搜索能力）。web_search 工具只接接缝、不写死搜索源；替换搜索源无需改工具。
    // applySearXNGProviderFromSettings 内部按 webSearchDirectEnabled 切换
    // 端侧直连引擎 / SearXNG 实例（直连开关打开时优先级最高）。
    applySearXNGProviderFromSettings(settings);

    // 联网类工具（web_search/get_weather/fetch_url/data_api）：配置关闭时不可见。
    if (!settings.webSearchEnabled) {
      registry.unregister('web_search');
      registry.unregister('get_weather');
      registry.unregister('fetch_url');
      registry.unregister('data_api');
    }

    // shell 执行：用户设置关闭时不可见（默认开启，能力不设限）。
    if (!settings.agentShellEnabled) {
      registry.unregister('shell_exec');
    }

    // ADB 远程控制：关闭时彻底不可见（注册处已按开关过滤，这里兜底 ——
    // 与本文件其它能力开关同构，双保险成本为零）。
    if (!settings.adbEnabled) {
      registry.unregister('adb');
    }

    // python_exec：用户设置关闭时不可见（默认开启；无 Chaquopy 时工具优雅降级）。
    if (!settings.agentPythonEnabled) {
      registry.unregister('python_exec');
    }

    // 长期记忆：默认关闭（跨会话记忆可能积累偶发错误）；开启后才暴露
    // memory_set/memory_get，模型才能写入/读取持久化记忆。
    if (!settings.agentMemoryEnabled) {
      registry.unregister('memory_set');
      registry.unregister('memory_get');
    }

    // 按模型工具启用（设置层配置；空 = 不限制，全部可见）。
    final modelTools = settings.agentToolsFor(modelId);
    if (modelTools.isNotEmpty) {
      registry.restrictModel(modelId, allow: modelTools.toSet());
    }
    return registry;
  }

  /// Stop the current generation: cancels the token stream subscription and
  /// 刷新单个会话的元信息（标题 + 消息条数）并写库：
  /// - 标题：若仍为空/「新对话」，取第一条用户消息（截断到 ~24 字）作标题；
  /// - 消息条数：按数据库当前消息数重算，让列表「x 条」始终准确。
  Future<void> _refreshConversationMeta(String conversationId) async {
    try {
      final convs = _ref.read(conversationsProvider);
      Conversation? conv;
      for (final c in convs) {
        if (c.id == conversationId) {
          conv = c;
          break;
        }
      }
      if (conv == null) return;

      final msgs = await _storage.getAllMessages(conversationId);
      String? newTitle;
      if (conv.title.isEmpty || conv.title == '新对话') {
        for (final m in msgs) {
          if (m.role == MessageRole.user && m.content.isNotEmpty) {
            newTitle = m.content.length <= 24
                ? m.content
                : '${m.content.substring(0, 24)}…';
            break;
          }
        }
      }

      if (newTitle != null || msgs.length != conv.messageCount) {
        await _storage.updateConversation(
          id: conversationId,
          title: newTitle,
          messageCount: msgs.length,
        );
        _ref.read(conversationsProvider.notifier).update(Conversation(
              id: conv.id,
              title: newTitle ?? conv.title,
              modelId: conv.modelId,
              messageCount: msgs.length,
              createdAt: conv.createdAt,
              updatedAt: DateTime.now(),
            ));
      }
    } catch (e) {
      debugPrint('[ChatNotifier] refreshConversationMeta failed: $e');
    }
  }

  /// tells the native engine to set should_stop (or cancels the API SSE
  /// request for the API fallback path), which makes the completion loop
  /// 是否为智能体过程活动消息（工具/思考/信封等，仅 UI 展示不入模型上下文）。
  /// 类型化判定（2026-10-25）：新消息写 kind；旧 DB 行读取层已按前缀推断
  /// 填充 kind，此处不再做字符串前缀兜底。
  static bool _isToolActivityMessage(ChatMessage msg) =>
      msg.role == MessageRole.assistant &&
      msg.kind != MessageKind.text;

  /// return promptly. The streaming controller then closes, the
  /// `await for` in [sendMessage] ends, and isGenerating flips back to false.
  ///
  /// 多会话并发：[conversationId] 非空只停该会话的回合（聊天页停止按钮）；
  /// 为空停**全部**活跃回合（模型卸载前调用，避免引擎被并行回合占用）。
  Future<void> stopGeneration({String? conversationId}) async {
    // 停止生成的同时停掉播报（用户明确喊停，不应继续出声）。
    unawaited(EdgeTtsService.instance.stop());
    final ids = conversationId != null
        ? (_activeTurns.containsKey(conversationId)
            ? [conversationId]
            : const <String>[])
        : _activeTurns.keys.toList();
    for (final id in ids) {
      final turn = _activeTurns[id];
      if (turn == null) continue;
      // 标记为用户主动停止：API 侧取消会抛 [request cancelled]，
      // 由 [_suppressUserCancelled] 静默丢弃，避免误报「发送失败」。
      turn.userCancelled = true;
      // 挂起的提问以"用户未回答"兜底完成——否则 ask_user 工具会把回合
      // 挂死到超时，停止按钮看起来没反应。
      answerPendingQuestion(id, null);
      // 智能体回合：通知主循环取消（adapter.cancel 会中止 native/API 后端）。
      // 注意**不能**用 isRunning 当门槛：相位在工具执行/步间隙时 isRunning 为
      // false，旧写法会漏到这里以下的"普通聊天"分支——只停一次当前生成，主循环
      // 随后自己接着发起下一步（用户反馈"停止没反应"的根因之一）。
      // agent.cancel() 幂等，未开跑时调用也安全。
      final agent = turn.agent;
      if (agent != null) {
        debugPrint('[ChatNotifier] stopGeneration: cancel agent turn conv=$id');
        await agent.cancel();
        continue;
      }
      // 普通聊天：直接中止 native/API。
      if (turn.local) {
        await _inference.stopGeneration();
      } else {
        _ref.read(openAiServiceProvider).stop();
      }
    }
  }

  /// 过滤掉「用户主动停止」产生的 [DioException] 取消异常。
  /// 用户点停止时 API 会抛 `request cancelled`，属正常停止信号；仅在此情况
  /// 下静默丢弃，否则原样重抛由调用方兜底（真实网络/服务端错误仍会上报）。
  Stream<String> _suppressUserCancelled(
      Stream<String> source, _ActiveTurn turn) async* {
    try {
      await for (final token in source) {
        yield token;
      }
    } on DioException {
      if (turn.userCancelled) return;
      rethrow;
    }
  }
}

/// 工具活动会话：新主循环回合内，每次工具调用**独立落一条 🔧 活动消息**。
///
/// 存储约定（与 [_isToolActivityMessage] 匹配，历史回合步骤回看依赖）：
/// - executing：`🔧 正在调用 {name}…`
/// - done/failed：`🔧 {name} ✓/⚠️{summary}`
/// 活动消息 `isStreaming` 恒为 false（静态文本）；实时"执行中"状态由
/// agentUiStateProvider 事件流驱动，存储只负责可回看的步骤记录。
class _AgentActivitySession {
  final String conversationId;
  final StorageService storage;

  /// 本回合已落库的工具活动消息 id（按 tool/call 顺序）——turnTrace UI
  /// 信封的 tool 项引用它，历史回合按 id 取消息渲染。
  final List<String> writtenIds = [];

  var _seq = 0;

  _AgentActivitySession({
    required this.conversationId,
    required this.storage,
  });

  /// 更新活动消息（executing → 新建独立消息；done/failed → 对位更新）。
  /// 类型化落库（2026-10-25）：kind=toolActivity + 结构化 toolData；
  /// content 字符串按旧约定保留（旧版本渲染兼容，解析链路已不走它）。
  Future<void> update(ToolActivity activity) async {
    if (activity.status == 'executing') {
      final n = _seq++;
      final now = DateTime.now().millisecondsSinceEpoch;
      final msg = ChatMessage(
        id: 'agent_tool_${now}_${n}',
        conversationId: conversationId,
        role: MessageRole.assistant,
        content: '🔧 正在调用 ${activity.name}…',
        isStreaming: false,
        timestamp: DateTime.fromMillisecondsSinceEpoch(now + 1000 + n),
        kind: MessageKind.toolActivity,
        toolData: ToolActivityData(
            phase: 'executing', name: activity.name),
      );
      writtenIds.add(msg.id);
      await storage.saveMessage(msg);
      return;
    }
    // done/failed：新主循环固定顺序回调（同一步 tool/call 先全部触发
    // executing，随后按同一顺序触发 done/failed）→ 对位到最早"执行中"
    // 的 🔧 消息。
    final msgs = await storage.getAllMessages(conversationId);
    for (final m in msgs) {
      if (m.role == MessageRole.assistant &&
          m.kind == MessageKind.toolActivity &&
          // 新行看 toolData.phase；旧版本残留行（toolData 缺失）回退前缀。
          (m.toolData?.phase == 'executing' ||
              (m.toolData == null && m.content.startsWith('🔧 正在调用')))) {
        final mark = activity.isFailed ? '⚠️' : '✓';
        // export_file 的摘要必须保留完整 content:// URI——历史回合工具卡
        // 的「打开」按钮靠它（截断到 300 字保路径）。
        final summary = activity.name == 'export_file'
            ? _summarizeToolResult(activity.result, max: 300)
            : _summarizeToolResult(activity.result);
        await storage.saveMessage(m.copyWith(
          content: '🔧 ${activity.name} $mark$summary',
          isStreaming: false,
          toolData: ToolActivityData(
            phase: activity.isFailed ? 'failed' : 'done',
            name: activity.name,
            summary: summary,
            resultText: activity.result,
            isError: activity.isFailed,
          ),
        ));
        return;
      }
    }
  }
}

/// 工具结果摘要：多行/长文本压缩为单行，截断到 ~60 字符（UI 展示用）。
String _summarizeToolResult(String? result, {int max = 60}) {
  if (result == null || result.isEmpty) return '';
  final oneLine = result.replaceAll('\n', ' ').trim();
  return oneLine.length <= max ? oneLine : '${oneLine.substring(0, max - 3)}…';
}

final chatNotifierProvider = StateNotifierProvider<ChatNotifier, bool>((ref) {
  final inference = ref.read(inferenceServiceProvider);
  final storage = ref.read(storageServiceProvider);
  return ChatNotifier(ref, inference, storage);
});
