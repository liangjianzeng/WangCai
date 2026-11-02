/// 持久目标 / 计划（一等实体）与无人值守续跑（DSH goal-round-driver 语义）。
///
/// 2026-10-06 计划实体化：GoalState 从「一段目标文本」升级为**结构化计划**
/// ——title + goal（完整计划文本）+ steps[]（每步 title/detail/verify/status），
/// goal_set 创建无步骤计划（纯文本目标），exit_plan 批准创建带步骤计划；
/// plan_update 工具执行期推进步骤状态，驱动器续跑消息带增量进度，
/// 设置页/计划面板直接读取渲染（查看/更新状态闭环）。
/// 按会话持久化 `ApplicationSupport/goals/<convId>.json`，跨回合存活；
/// 旧 JSON（无 steps/id 字段）自动兼容。
library;

import 'dart:convert';
import 'dart:io';

/// 目标状态。
enum GoalStatus { active, done, cancelled, expired }

/// 计划步骤状态。
enum PlanStepStatus { pending, running, done, failed }

/// 计划步骤（结构化；exit_plan 批准产出，plan_update 推进状态）。
class PlanStep {
  final String title;
  final String detail;
  final String verify;
  final PlanStepStatus status;

  const PlanStep({
    required this.title,
    this.detail = '',
    this.verify = '',
    this.status = PlanStepStatus.pending,
  });

  Map<String, dynamic> toJson() => {
        'title': title,
        if (detail.isNotEmpty) 'detail': detail,
        if (verify.isNotEmpty) 'verify': verify,
        'status': status.name,
      };

  factory PlanStep.fromJson(Map<String, dynamic> m) => PlanStep(
        title: m['title'] as String? ?? '',
        detail: m['detail'] as String? ?? '',
        verify: m['verify'] as String? ?? '',
        status: PlanStepStatus.values.firstWhere(
          (s) => s.name == m['status'],
          orElse: () => PlanStepStatus.pending,
        ),
      );

  PlanStep copyWith({PlanStepStatus? status}) => PlanStep(
        title: title,
        detail: detail,
        verify: verify,
        status: status ?? this.status,
      );

  String get statusBadge => switch (status) {
        PlanStepStatus.pending => '○',
        PlanStepStatus.running => '◐',
        PlanStepStatus.done => '✓',
        PlanStepStatus.failed => '✗',
      };
}

/// 一个会话的持久目标 / 计划。
class GoalState {
  /// 计划 id（`plan_<conv>_<ms>`；固定 id 的对话内计划卡用）。
  final String id;

  /// 短标题（面板/卡片/续跑消息用；goal_set 时取目标文本前 24 字）。
  final String title;

  /// 完整目标 / 计划文本（模型上下文语义）。
  final String goal;

  /// 结构化步骤（无步骤 = 纯文本目标，与旧版行为一致）。
  final List<PlanStep> steps;

  /// 已用续跑轮数（不含设定目标的那一回合）。
  final int rounds;

  /// 续跑轮数上限。
  final int maxRounds;

  final GoalStatus status;

  /// 来源：`user`（模型 goal_set）或 `plan`（计划模式 exit_plan 批准）。
  final String origin;
  final int createdAtMs;
  final int updatedAtMs;

  const GoalState({
    this.id = '',
    this.title = '',
    required this.goal,
    this.steps = const [],
    required this.rounds,
    required this.maxRounds,
    required this.status,
    required this.origin,
    required this.createdAtMs,
    this.updatedAtMs = 0,
  });

  bool get isActive => status == GoalStatus.active;
  bool get exhausted => rounds >= maxRounds;

  Map<String, dynamic> toJson() => {
        if (id.isNotEmpty) 'id': id,
        if (title.isNotEmpty) 'title': title,
        'goal': goal,
        if (steps.isNotEmpty)
          'steps': [for (final s in steps) s.toJson()],
        'rounds': rounds,
        'maxRounds': maxRounds,
        'status': status.name,
        'origin': origin,
        'createdAt': createdAtMs,
        if (updatedAtMs > 0) 'updatedAt': updatedAtMs,
      };

  factory GoalState.fromJson(Map<String, dynamic> m) => GoalState(
        id: m['id'] as String? ?? '',
        title: m['title'] as String? ?? '',
        goal: m['goal'] as String? ?? '',
        steps: (m['steps'] as List<dynamic>?)
                ?.map((e) =>
                    PlanStep.fromJson((e as Map).cast<String, dynamic>()))
                .toList() ??
            const [],
        rounds: (m['rounds'] as num?)?.toInt() ?? 0,
        maxRounds: (m['maxRounds'] as num?)?.toInt() ?? 8,
        status: GoalStatus.values.firstWhere(
          (s) => s.name == m['status'],
          orElse: () => GoalStatus.active,
        ),
        origin: m['origin'] as String? ?? 'user',
        createdAtMs: (m['createdAt'] as num?)?.toInt() ?? 0,
        updatedAtMs: (m['updatedAt'] as num?)?.toInt() ?? 0,
      );

  /// 已完成步骤数。
  int get doneCount =>
      steps.where((s) => s.status == PlanStepStatus.done).length;

  /// 当前（第一个未完成）步骤下标；全部完成返回 -1。
  int get currentStepIndex {
    for (var i = 0; i < steps.length; i++) {
      if (steps[i].status != PlanStepStatus.done &&
          steps[i].status != PlanStepStatus.failed) {
        return i;
      }
    }
    return -1;
  }

  /// 进度摘要文本（续跑消息 / 计划卡共用）。
  String progressText() {
    if (steps.isEmpty) return '目标：$goal';
    final buf = StringBuffer('计划「${title.isEmpty ? '未命名' : title}」'
        '进度 $doneCount/${steps.length}：');
    final cur = currentStepIndex;
    for (var i = 0; i < steps.length; i++) {
      final s = steps[i];
      buf.write('\n${s.statusBadge} ${i + 1}. ${s.title}'
          '${i == cur ? ' ← 本轮先做这步' : ''}');
      if (i == cur && s.verify.isNotEmpty) {
        buf.write('（验证：${s.verify}）');
      }
    }
    if (cur == -1) {
      buf.write('\n所有步骤已完成，请调用 goal_complete 总结收尾');
    }
    return buf.toString();
  }

  /// 对话内计划卡文本（固定 id 消息内容；plan_update 后重写同 id 实现活卡）。
  String planCardText() {
    final buf = StringBuffer('📋 计划：${title.isEmpty ? '未命名' : title}');
    buf.write('\n状态：${switch (status) {
      GoalStatus.active => '执行中（续跑 $rounds/$maxRounds 轮）',
      GoalStatus.done => '已完成',
      GoalStatus.cancelled => '已取消',
      GoalStatus.expired => '轮数耗尽',
    }}');
    if (steps.isEmpty) {
      buf.write('\n目标：$goal');
    } else {
      buf.write('\n目标：${goal.length > 120 ? '${goal.substring(0, 120)}…' : goal}');
      // 卡内只留标题与状态徽标——detail/verify 属面板详情，进卡只会啰嗦
      // 且每回合白耗 prefill token。
      for (var i = 0; i < steps.length; i++) {
        buf.write('\n${steps[i].statusBadge} ${i + 1}. ${steps[i].title}');
      }
    }
    return buf.toString();
  }

  GoalState copyWith({
    String? title,
    String? goal,
    List<PlanStep>? steps,
    int? rounds,
    int? maxRounds,
    GoalStatus? status,
    String? origin,
  }) =>
      GoalState(
        id: id,
        title: title ?? this.title,
        goal: goal ?? this.goal,
        steps: steps ?? this.steps,
        rounds: rounds ?? this.rounds,
        maxRounds: maxRounds ?? this.maxRounds,
        status: status ?? this.status,
        origin: origin ?? this.origin,
        createdAtMs: createdAtMs,
        updatedAtMs: DateTime.now().millisecondsSinceEpoch,
      );
}

/// 驱动器决策（纯函数，可测）。
enum GoalAction {
  /// 无目标或目标不活跃 → 不续跑。
  none,

  /// 续跑一个回合（第 [GoalState.rounds]+1 轮）。
  continueTurn,

  /// 轮数耗尽 → 标记 expired 并提示。
  expire,

  /// 目标已 done/cancelled → 清理并提示。
  settle,
}

/// 纯决策函数：回合结束后，目标处于当前状态时下一步做什么。
/// [turnCompleted] = 本回合是否正常完成（completed）；失败/中断的回合
/// 不自动续跑（用户可能正在处理故障）。
GoalAction decideGoalAction(GoalState? goal, {required bool turnCompleted}) {
  if (goal == null || !goal.isActive) {
    return goal != null && !goal.isActive ? GoalAction.settle : GoalAction.none;
  }
  if (!turnCompleted) return GoalAction.none;
  if (goal.exhausted) return GoalAction.expire;
  return GoalAction.continueTurn;
}

/// 目标存储：按会话一文件（JSON）。
class GoalStore {
  final String baseDir;

  GoalStore({required this.baseDir});

  File _fileOf(String conversationId) {
    final safe = conversationId.replaceAll(RegExp(r'[^\w-]'), '_');
    return File('$baseDir/goal_$safe.json');
  }

  Future<GoalState?> load(String conversationId) async {
    try {
      final f = _fileOf(conversationId);
      if (!await f.exists()) return null;
      final m = jsonDecode(await f.readAsString()) as Map<String, dynamic>;
      final goal = GoalState.fromJson(m);
      // 已终结的目标读出即清理（一次性文件语义）。
      if (!goal.isActive) {
        await f.delete();
        return null;
      }
      return goal;
    } on Exception {
      return null;
    }
  }

  /// 全量计划（跨会话，2026-10-25 用户需求：左栏计划面板按时间倒序浏览
  /// 各历史会话的计划，完成与否可见；会话删除时计划随删）。
  /// 返回 (conversationId, GoalState)；坏文件跳过。
  Future<List<(String, GoalState)>> listAll() async {
    final dir = Directory(baseDir);
    if (!dir.existsSync()) return const [];
    final out = <(String, GoalState)>[];
    for (final f in dir.listSync()) {
      final name = f.path.split(Platform.pathSeparator).last;
      if (!name.startsWith('goal_') || !name.endsWith('.json')) continue;
      final conv = name.substring(5, name.length - 5);
      try {
        final m = jsonDecode(await (f as File).readAsString())
            as Map<String, dynamic>;
        out.add((conv, GoalState.fromJson(m)));
      } catch (_) {}
    }
    out.sort((a, b) => b.$2.updatedAtMs.compareTo(a.$2.updatedAtMs));
    return out;
  }

  /// 删除某会话的计划文件（会话删除时随删；无文件静默）。
  Future<void> deletePlan(String conversationId) async {
    final f = _fileOf(conversationId);
    if (await f.exists()) await f.delete();
  }

  Future<void> save(String conversationId, GoalState goal) async {
    final dir = Directory(baseDir);
    if (!await dir.exists()) await dir.create(recursive: true);
    await _fileOf(conversationId).writeAsString(jsonEncode(goal.toJson()));
  }

  /// 设定/更新目标（goal_set / exit_plan 批准共用）。
  /// [title]/[steps] 为计划实体化扩展：exit_plan 传结构化步骤；
  /// goal_set 不传（纯文本目标，title 取文本前 24 字）。
  Future<GoalState> setGoal(
    String conversationId, {
    required String goalText,
    required int maxRounds,
    required String origin,
    String? title,
    List<PlanStep> steps = const [],
  }) async {
    final existing = await load(conversationId);
    final now = DateTime.now().millisecondsSinceEpoch;
    final GoalState goal;
    if (existing != null && existing.isActive) {
      goal = existing.copyWith(
        goal: goalText,
        title: title ?? existing.title,
        steps: steps.isNotEmpty ? steps : existing.steps,
        maxRounds: maxRounds,
        origin: origin,
      );
    } else {
      goal = GoalState(
        id: 'plan_${conversationId.replaceAll(RegExp(r'[^\w-]'), '_')}_$now',
        title: title ?? (goalText.length > 24 ? goalText.substring(0, 24) : goalText),
        goal: goalText,
        steps: steps,
        rounds: 0,
        maxRounds: maxRounds,
        status: GoalStatus.active,
        origin: origin,
        createdAtMs: now,
        updatedAtMs: now,
      );
    }
    await save(conversationId, goal);
    return goal;
  }

  /// 推进步骤状态（plan_update 工具 / 计划面板手动勾选共用）。
  /// 步骤下标 1-based（模型视角自然计数）。返回错误信息（null = 成功）。
  Future<String?> updateStep(
    String conversationId, {
    required int stepIndex,
    required PlanStepStatus status,
  }) async {
    final g = await load(conversationId);
    if (g == null) return '当前没有活跃计划';
    if (stepIndex < 1 || stepIndex > g.steps.length) {
      return '步骤序号越界（1~${g.steps.length}，共 ${g.steps.length} 步）';
    }
    final steps = [...g.steps];
    steps[stepIndex - 1] = steps[stepIndex - 1].copyWith(status: status);
    await save(conversationId, g.copyWith(steps: steps));
    return null;
  }

  /// 推进一轮（续跑前调用）。
  Future<GoalState> bumpRound(String conversationId) async {
    final g = await load(conversationId);
    if (g == null) {
      throw StateError('no active goal for $conversationId');
    }
    final next = g.copyWith(rounds: g.rounds + 1);
    await save(conversationId, next);
    return next;
  }

  /// 终结目标（complete/cancel/expire 共用）；返回终结前快照。
  Future<GoalState?> finish(
    String conversationId,
    GoalStatus status,
  ) async {
    final g = await load(conversationId);
    if (g == null) return null;
    final finished = g.copyWith(status: status);
    final f = _fileOf(conversationId);
    if (await f.exists()) await f.delete();
    return finished;
  }
}
