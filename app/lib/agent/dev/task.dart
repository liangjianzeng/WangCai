/// 开发任务与计划模型（Dev Agent Phase C）—— 会话之上的"开发闭环"。
///
/// 一个任务 = 元数据 + 关联会话引用 + 状态机 + 可选计划。
/// 会话（SessionLog）保持"对话"，任务把多个会话串成一次开发闭环。
library;

/// 任务状态机。
enum DevTaskStatus {
  planning,
  implementing,
  verifying,
  done,
  blocked,
}

/// 开发任务。
final class DevTask {
  final String id;
  final String title;
  final String? workspaceId;
  final List<String> sessionIds;
  final DevTaskStatus status;
  final DevPlan? plan;
  final DateTime createdAt;
  final DateTime updatedAt;

  const DevTask({
    required this.id,
    required this.title,
    this.workspaceId,
    this.sessionIds = const [],
    this.status = DevTaskStatus.planning,
    this.plan,
    required this.createdAt,
    required this.updatedAt,
  });

  DevTask copyWith({
    String? title,
    String? workspaceId,
    List<String>? sessionIds,
    DevTaskStatus? status,
    DevPlan? plan,
    DateTime? updatedAt,
    bool clearWorkspace = false,
  }) {
    return DevTask(
      id: id,
      title: title ?? this.title,
      workspaceId: clearWorkspace ? null : (workspaceId ?? this.workspaceId),
      sessionIds: sessionIds ?? this.sessionIds,
      status: status ?? this.status,
      plan: plan ?? this.plan,
      createdAt: createdAt,
      updatedAt: updatedAt ?? this.updatedAt,
    );
  }

  Map<String, dynamic> toJson() => {
        'id': id,
        'title': title,
        if (workspaceId != null) 'workspaceId': workspaceId,
        'sessionIds': sessionIds,
        'status': status.name,
        if (plan != null) 'plan': plan!.toJson(),
        'createdAt': createdAt.toIso8601String(),
        'updatedAt': updatedAt.toIso8601String(),
      };

  static DevTask? fromJson(Map<String, dynamic> json) {
    final id = (json['id'] as String?)?.trim();
    final title = (json['title'] as String?)?.trim();
    if (id == null || id.isEmpty || title == null || title.isEmpty) return null;
    final status = DevTaskStatus.values
        .where((s) => s.name == json['status'])
        .firstOrNull;
    final plan = json['plan'] is Map<String, dynamic>
        ? DevPlan.fromJson(json['plan'] as Map<String, dynamic>)
        : null;
    return DevTask(
      id: id,
      title: title,
      workspaceId: (json['workspaceId'] as String?)?.trim(),
      sessionIds: [
        for (final s in (json['sessionIds'] as List?) ?? const [])
          if (s is String && s.isNotEmpty) s,
      ],
      status: status ?? DevTaskStatus.planning,
      plan: plan,
      createdAt: DateTime.tryParse(json['createdAt'] as String? ?? '') ??
          DateTime.now(),
      updatedAt: DateTime.tryParse(json['updatedAt'] as String? ?? '') ??
          DateTime.now(),
    );
  }
}

/// 计划步骤。
final class DevPlanStep {
  final String id;
  final String title;
  final String detail;
  final String? verify;
  final bool done;

  const DevPlanStep({
    required this.id,
    required this.title,
    this.detail = '',
    this.verify,
    this.done = false,
  });

  DevPlanStep copyWith({bool? done}) =>
      DevPlanStep(id: id, title: title, detail: detail, verify: verify, done: done ?? this.done);

  Map<String, dynamic> toJson() => {
        'id': id,
        'title': title,
        'detail': detail,
        if (verify != null) 'verify': verify,
        'done': done,
      };

  static DevPlanStep? fromJson(Map<String, dynamic> json) {
    final id = (json['id'] as String?)?.trim();
    final title = (json['title'] as String?)?.trim();
    if (id == null || id.isEmpty || title == null || title.isEmpty) return null;
    return DevPlanStep(
      id: id,
      title: title,
      detail: (json['detail'] as String?)?.trim() ?? '',
      verify: (json['verify'] as String?)?.trim(),
      done: (json['done'] as bool?) ?? false,
    );
  }
}

/// 开发计划：有序步骤 + 当前进行位置。
final class DevPlan {
  final List<DevPlanStep> steps;
  final int currentStep;

  const DevPlan({this.steps = const [], this.currentStep = 0});

  /// 第一个未完成步骤的索引；全部完成返回 steps.length。
  int get nextPendingIndex {
    for (var i = 0; i < steps.length; i++) {
      if (!steps[i].done) return i;
    }
    return steps.length;
  }

  bool get allDone => steps.isNotEmpty && nextPendingIndex == steps.length;

  DevPlan copyWith({List<DevPlanStep>? steps, int? currentStep}) => DevPlan(
      steps: steps ?? this.steps, currentStep: currentStep ?? this.currentStep);

  Map<String, dynamic> toJson() => {
        'steps': [for (final s in steps) s.toJson()],
        'currentStep': currentStep,
      };

  static DevPlan? fromJson(Map<String, dynamic> json) {
    final raw = json['steps'] as List?;
    if (raw == null) return null;
    return DevPlan(
      steps: [
        for (final s in raw)
          if (s is Map<String, dynamic>) DevPlanStep.fromJson(s),
      ].whereType<DevPlanStep>().toList(),
      currentStep: (json['currentStep'] as num?)?.toInt() ?? 0,
    );
  }
}
