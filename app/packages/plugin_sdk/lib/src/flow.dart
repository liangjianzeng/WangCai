/// 声明式流程契约（L1 的一部分 + 内核解释器要遵守的语义）。
///
/// 设计来源：DSH `dsh-workflow` 的 `WorkflowMeta{name,description,whenToUse,phases}` 与
/// `WorkflowResult{value, stopReason: 'completed'|'cancelled'|'error', error, agentsStarted}`。
/// 为什么坚持三态闭集：本仓有"迭代一两下就停却显示完成"的血泪教训（AGENTS.md 2026-09-27），
/// **不允许"半途而废当成功"** —— 没走完就是没走完。
library;

/// 流程终局（闭集，绝不允许第四个值"看起来成功"）。
enum FlowStopReason { completed, cancelled, error }

/// 一个步骤原语（白名单）。`trust == declarative` 的插件**只能**用这些，这就是它的全部能力面。
///
/// 新增原语是**平台级变更**：必须同时给出所需权限、失败码集合、conformance 用例、面板说明。
enum FlowStepOp {
  capture, // 拍照/相册取图 → List<String> imagePaths
  llmExtract, // 一次性带图/文本补全 → 结构化内容（prompt.md 决定语义）
  review, // 让用户确认/编辑中间结果（词表 chips）
  askParams, // 向用户要参数（间隔秒数…），可写回 config
  speakSequence, // 按序朗读（能力实现负责单代次与缓存）
  store, // 读写插件分域存储
  export, // 导出产物（练习单/文本）
  agentHandoff, // 交给智能体续跑（可选，需 network/llm 权限）
}

extension FlowStepOpWire on FlowStepOp {
  String get wireName => switch (this) {
        FlowStepOp.capture => 'capture',
        FlowStepOp.llmExtract => 'llm_extract',
        FlowStepOp.review => 'review',
        FlowStepOp.askParams => 'ask_params',
        FlowStepOp.speakSequence => 'speak_sequence',
        FlowStepOp.store => 'store',
        FlowStepOp.export => 'export',
        FlowStepOp.agentHandoff => 'agent_handoff',
      };

  /// 该原语隐含需要的权限（校验器据此做"声明齐全"检查，缺了就在 boot 期报错而不是跑到一半炸）。
  Set<String> get impliedPermissions => switch (this) {
        FlowStepOp.capture => const {'camera', 'photo_library'},
        FlowStepOp.llmExtract => const {'llm:chat'},
        FlowStepOp.review => const {},
        FlowStepOp.askParams => const {},
        FlowStepOp.speakSequence => const {'tts', 'network'},
        FlowStepOp.store => const {'storage:plugin'},
        FlowStepOp.export => const {'file_export'},
        FlowStepOp.agentHandoff => const {'network'},
      };

  /// 该原语**真正读**的 `params` 键；`null` = 开放集（多余的键另有用途，不能判"未知"）。
  ///
  /// 为什么要有这张表：作者把键写错（`label` 写成 `title`、`names` 写成 `params`）时，
  /// 运行时不会报错，只会**静默忽略** —— 用户看不出区别，作者也查不出来。
  /// **必须与 `flow_runner` 的读取一一对应**：runner 新读一个键，这里同时补，
  /// 否则写得对的插件会被 validate 误报。
  Set<String>? get knownParamKeys => switch (this) {
        FlowStepOp.capture => const {'maxCount', 'preferCamera', 'alwaysAsk'},
        // `llm_extract` 的多余键是 `prompt.md` 里的变量（`{{count}}` 那一层），不是拼错 —— 开放集。
        FlowStepOp.llmExtract => null,
        FlowStepOp.review => const {'title'},
        FlowStepOp.askParams => const {'names'},
        // 注意**没有 `gapSeconds`**：runner 读的是 `gapParam`（默认值就叫 "gapSeconds"）这个名字，
        // 然后去 `ask_params` 问到的值与 config 里取值 —— 在步骤里写 `"gapSeconds": "{{config.gapSeconds}}"`
        // 是"往一个没人读的键里填值"的装饰品，所以它必须被 `unknownOpParam` 提醒出来。
        FlowStepOp.speakSequence => const {
          'items',
          'voice',
          'gapParam',
          'repeatPerItem',
          'withNote',
        },
        FlowStepOp.store => const {'key', 'value'},
        FlowStepOp.export => const {'filename', 'content', 'withNote'},
        FlowStepOp.agentHandoff => const {'prompt'},
      };
}

/// 该原语在**这条具体流程里**真正需要的权限。
///
/// `llm_extract` 是唯一要看上下文的：有图（流程里有 `capture` 步，或步骤参数
/// `useImages: true`）才用得到视觉；纯文本进出的插件（中英默写卡）不该被强迫
/// 声明 `llm:vision` —— 平台不能逼作者要他用不到的权限，那是权限膨胀的开始。
extension FlowStepOpImplied on FlowStepOp {
  Set<String> impliedPermissionsIn({required bool hasImages}) {
    if (this != FlowStepOp.llmExtract) return impliedPermissions;
    return hasImages ? const {'llm:vision'} : const {'llm:chat'};
  }
}

FlowStepOp? flowStepOpFromWire(String s) {
  for (final op in FlowStepOp.values) {
    if (op.wireName == s) return op;
  }
  return null;
}

/// 流程阶段（给 UI 显示"第 2/3 步：识别中…"）。
final class FlowPhase {
  const FlowPhase({required this.id, required this.title, this.optional = false});
  final String id;
  final String title;
  final bool optional;

  Map<String, dynamic> toJson() => {'id': id, 'title': title, if (optional) 'optional': true};

  static FlowPhase fromJson(Map<String, dynamic> j) => FlowPhase(
        id: j['id'] as String,
        title: (j['title'] as String?) ?? (j['id'] as String),
        optional: j['optional'] as bool? ?? false,
      );
}

/// 一步。[op] 是白名单动词；[params] 是动词的参数（字符串值支持 `{{config.x}}` / `{{steps.prev.field}}` 占位）。
final class FlowStep {
  const FlowStep({
    required this.id,
    required this.op,
    this.phase,
    this.params = const {},
    this.onFailure = FlowStepFailure.abort,
    this.timeoutSeconds,
  });

  final String id;
  final FlowStepOp op;
  final String? phase;
  final Map<String, dynamic> params;
  final FlowStepFailure onFailure;
  final int? timeoutSeconds;

  Map<String, dynamic> toJson() => {
        'id': id,
        'op': op.wireName,
        if (phase != null) 'phase': phase,
        if (params.isNotEmpty) 'params': params,
        if (onFailure != FlowStepFailure.abort) 'onFailure': onFailure.name,
        if (timeoutSeconds != null) 'timeoutSeconds': timeoutSeconds,
      };

  static FlowStep fromJson(Map<String, dynamic> j) => FlowStep(
        id: j['id'] as String,
        op: flowStepOpFromWire(j['op'] as String) ?? FlowStepOp.llmExtract,
        phase: j['phase'] as String?,
        params: Map<String, dynamic>.from((j['params'] as Map?) ?? const {}),
        onFailure: FlowStepFailure.values.firstWhere(
          (f) => f.name == j['onFailure'],
          orElse: () => FlowStepFailure.abort,
        ),
        timeoutSeconds: (j['timeoutSeconds'] as num?)?.toInt(),
      );
}

/// 步骤失败策略（**没有"静默跳过并继续"这一档**，防止假装成功）。
enum FlowStepFailure {
  /// 中止整条流程，终局 `error`（默认）。
  abort,

  /// 标记该步失败但继续；终局仍是 `error`，且面板列出跳过了哪些步。
  skipWithWarning,

  /// 取消（用户主动），终局 `cancelled`。
  cancel,
}

/// 流程声明（`plugin.json` 的 `flow`）。启动前校验：未知 op / 缺参数 / 未声明隐含权限 → 不加载。
final class FlowMeta {
  const FlowMeta({
    required this.name,
    required this.description,
    required this.whenToUse,
    required this.phases,
    required this.steps,
  });

  final String name;
  final String description;
  final String whenToUse;
  final List<FlowPhase> phases;
  final List<FlowStep> steps;

  Map<String, dynamic> toJson() => {
        'name': name,
        'description': description,
        'whenToUse': whenToUse,
        'phases': phases.map((p) => p.toJson()).toList(),
        'steps': steps.map((s) => s.toJson()).toList(),
      };

  static FlowMeta fromJson(Map<String, dynamic> j) => FlowMeta(
        name: (j['name'] as String?) ?? '',
        description: (j['description'] as String?) ?? '',
        whenToUse: (j['whenToUse'] as String?) ?? '',
        phases: ((j['phases'] as List?) ?? const [])
            .map((e) => FlowPhase.fromJson(Map<String, dynamic>.from(e as Map)))
            .toList(),
        steps: ((j['steps'] as List?) ?? const [])
            .map((e) => FlowStep.fromJson(Map<String, dynamic>.from(e as Map)))
            .toList(),
      );
}

/// 流程结果。三态 + 已完成步骤清单（面板"停在哪一步"直接读它）。
final class FlowResult {
  const FlowResult({
    required this.stopReason,
    this.value,
    this.error,
    this.completedSteps = const [],
    this.skippedSteps = const [],
    this.agentsStarted = 0,
  });

  factory FlowResult.completed({Object? value, List<String> completedSteps = const [], List<String> skippedSteps = const []}) =>
      FlowResult(stopReason: FlowStopReason.completed, value: value, completedSteps: completedSteps, skippedSteps: skippedSteps);

  factory FlowResult.cancelled({String? reason, List<String> completedSteps = const []}) => FlowResult(
        stopReason: FlowStopReason.cancelled,
        error: reason ?? '已取消',
        completedSteps: completedSteps,
      );

  factory FlowResult.failed({required String error, List<String> completedSteps = const [], List<String> skippedSteps = const []}) =>
      FlowResult(
        stopReason: FlowStopReason.error,
        error: error,
        completedSteps: completedSteps,
        skippedSteps: skippedSteps,
      );

  final FlowStopReason stopReason;
  final Object? value;
  final String? error;
  final List<String> completedSteps;
  final List<String> skippedSteps;

  /// `agentHandoff` 起了几个子代理（对齐 DSH `WorkflowResult.agentsStarted`）。
  final int agentsStarted;

  bool get isSuccess => stopReason == FlowStopReason.completed;
}
