/// 项目模型（桌面独立版 v0.0.3，设计 §12）—— 会话的归属层级。
///
/// 桌面智能体的标准形态（dsh / Claude-Code 风格）：会话不是平铺的聊天流水，
/// 而是**挂在项目下**的工作记录；项目携带一个**可选的工作目录**
/// （workspacePath），智能体的文件读写/命令执行都以它为真源。
///
/// 与 `DevWorkspace` 的关系（真源唯一纪律）：Project 是用户可见的唯一实体；
/// 激活项目时派生一个 `DevWorkspace`（backend=localApp，
/// localMirror=workspacePath）供工具层消费，杜绝"两套工作目录各自漂移"。
library;

import 'dart:math';

/// 项目记录。
final class Project {
  /// 内置默认项目 id（迁移旧平铺会话的落点；不可删除）。
  static const String kDefaultId = 'p_default';

  /// 内置默认项目名。
  static const String kDefaultName = '默认项目';

  final String id;
  final String name;

  /// 工作目录（本地绝对路径；智能体 shell/文件工具的 cwd 真源）。
  final String workspacePath;

  /// 可选：绑定的 SSH 连接配置 id（远程工作区语义，复用 DevWorkspace
  /// remotePc 的连接层；null = 纯本地项目）。
  final String? sshConfigId;

  final DateTime createdAt;

  /// 最近一次被激活/打开的时间（列表排序用）。
  final DateTime? lastOpenedAt;

  const Project({
    required this.id,
    required this.name,
    required this.workspacePath,
    this.sshConfigId,
    required this.createdAt,
    this.lastOpenedAt,
  });

  /// 是否内置默认项目（不可删、不可改工作目录以外的关键字段语义）。
  bool get isDefault => id == kDefaultId;

  /// 是否远程项目（文件/命令走 SSH）。
  bool get isRemote => (sshConfigId ?? '').isNotEmpty;

  Project copyWith({
    String? name,
    String? workspacePath,
    String? sshConfigId,
    DateTime? lastOpenedAt,
    bool clearSshConfigId = false,
  }) {
    return Project(
      id: id,
      name: name ?? this.name,
      workspacePath: workspacePath ?? this.workspacePath,
      sshConfigId:
          clearSshConfigId ? null : (sshConfigId ?? this.sshConfigId),
      createdAt: createdAt,
      lastOpenedAt: lastOpenedAt ?? this.lastOpenedAt,
    );
  }

  Map<String, dynamic> toJson() => {
        'id': id,
        'name': name,
        'workspacePath': workspacePath,
        if (sshConfigId != null && sshConfigId!.isNotEmpty)
          'sshConfigId': sshConfigId,
        'createdAt': createdAt.millisecondsSinceEpoch,
        if (lastOpenedAt != null)
          'lastOpenedAt': lastOpenedAt!.millisecondsSinceEpoch,
      };

  static Project? fromJson(Map<String, dynamic> json) {
    final id = (json['id'] as String?)?.trim();
    final name = (json['name'] as String?)?.trim();
    final workspacePath = (json['workspacePath'] as String?)?.trim();
    if (id == null || id.isEmpty || name == null || name.isEmpty) return null;
    // 没有工作目录的项目在桌面形态没有意义（工具层无处落脚）→ 丢弃。
    if (workspacePath == null || workspacePath.isEmpty) return null;
    final createdMs = json['createdAt'];
    return Project(
      id: id,
      name: name,
      workspacePath: workspacePath,
      sshConfigId: (json['sshConfigId'] as String?)?.trim(),
      createdAt: createdMs is int
          ? DateTime.fromMillisecondsSinceEpoch(createdMs)
          : DateTime.now(),
      lastOpenedAt: json['lastOpenedAt'] is int
          ? DateTime.fromMillisecondsSinceEpoch(json['lastOpenedAt'] as int)
          : null,
    );
  }
}

final _idRandom = Random();

/// 新项目 id：`p_<millis>_<rand8hex>`（天然路径安全，直接当目录名用）。
/// 随机尾缀不可省——Windows 时钟粒度粗（毫秒级），纯时间戳在同循环里会
/// 连发同值（测试实锤），不能只靠时间。
String newProjectId() {
  final ms = DateTime.now().millisecondsSinceEpoch;
  final r = _idRandom.nextInt(1 << 32).toRadixString(16).padLeft(8, '0');
  return 'p_${ms}_$r';
}

/// 目录名安全化（与 JsonlSessionStore._safe 同一策略：id 理论上已是
/// [newProjectId] 形态，这里兜底外部注入的怪 id 不进文件系统）。
String safeProjectDirName(String id) =>
    id.replaceAll(RegExp(r'[^A-Za-z0-9._-]'), '_');
