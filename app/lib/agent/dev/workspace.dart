/// 开发工作区模型（Dev Agent Phase A）—— 一个可操作目录的"身份"。
///
/// 现有 `documents/workspace` 根目录退化为 `default` 工作区实例
/// （backend=localApp），旧行为零回归。用户新建的项目是独立工作区，
/// 本地镜像落在 `documents/workspace/projects/<id>/`，远端工作区
/// （Termux / 远程 PC）以 [remotePath] 指路、经 SSH/SFTP 访问。
library;

/// 工作区后端：决定文件工具/命令的物理执行位置。
enum WorkspaceBackend {
  /// app 沙盒内（documents/workspace 及 projects/<id> 本地镜像）。
  localApp,

  /// 内嵌工具沙箱（app 私有 dev 目录 + 系统 toybox/mksh + jniLibs 工具 +
  /// JGit 进程内 git）。本地执行、无 SSH；文件即本地镜像目录。
  embedded,

  /// 手机上的 Termux Linux 用户态（127.0.0.1:8022）。
  termux,

  /// 远程电脑（OpenSSH/WSL），同一连接层、host 指 PC。
  remotePc;

  /// 是否远端后端（需要 SSH 配置与远端路径）。
  bool get isRemoteBackend =>
      this == WorkspaceBackend.termux || this == WorkspaceBackend.remotePc;
}

/// 工作区内部参数键：ToolExecutor 执行前注入当前激活工作区 id
/// （对齐 `_sandboxMode` 模式；模型不感知该键）。
const String kWorkspaceIdArgKey = '_workspaceId';

/// 读取工具执行参数中的工作区 id（无键时默认 null = default 工作区）。
String? effectiveWorkspaceOf(Map<String, dynamic> args) =>
    args[kWorkspaceIdArgKey] as String?;

/// 开发工作区。
final class DevWorkspace {
  /// 默认工作区 id（app workspace 根目录；不落盘）。
  static const String kDefaultId = 'default';

  /// 默认工作区常量（行为与旧版完全一致）。
  static const DevWorkspace defaultWorkspace = DevWorkspace(
    id: kDefaultId,
    name: '默认工作区',
    backend: WorkspaceBackend.localApp,
  );

  final String id;
  final String name;
  final WorkspaceBackend backend;
  final String? remotePath;
  final String? localMirror;

  /// 绑定的 SSH 连接配置 id（仅远端后端；空 = 使用当前/默认配置）。
  final String? sshConfigId;

  final bool gitManaged;
  final String? repoUrl;
  final String? currentBranch;
  final DateTime? lastSyncedAt;

  const DevWorkspace({
    required this.id,
    required this.name,
    this.backend = WorkspaceBackend.localApp,
    this.remotePath,
    this.localMirror,
    this.sshConfigId,
    this.gitManaged = false,
    this.repoUrl,
    this.currentBranch,
    this.lastSyncedAt,
  });

  /// 是否默认工作区（旧行为路径）。
  bool get isDefault => id == kDefaultId;

  /// 是否远端后端（文件/命令经 SSH/SFTP）。
  bool get isRemote =>
      backend == WorkspaceBackend.termux || backend == WorkspaceBackend.remotePc;

  DevWorkspace copyWith({
    String? name,
    WorkspaceBackend? backend,
    String? remotePath,
    String? localMirror,
    String? sshConfigId,
    bool? gitManaged,
    String? repoUrl,
    String? currentBranch,
    DateTime? lastSyncedAt,
    bool clearRemotePath = false,
    bool clearLocalMirror = false,
    bool clearSshConfigId = false,
    bool clearRepoUrl = false,
    bool clearBranch = false,
  }) {
    return DevWorkspace(
      id: id,
      name: name ?? this.name,
      backend: backend ?? this.backend,
      remotePath: clearRemotePath ? null : (remotePath ?? this.remotePath),
      localMirror: clearLocalMirror ? null : (localMirror ?? this.localMirror),
      sshConfigId:
          clearSshConfigId ? null : (sshConfigId ?? this.sshConfigId),
      gitManaged: gitManaged ?? this.gitManaged,
      repoUrl: clearRepoUrl ? null : (repoUrl ?? this.repoUrl),
      currentBranch: clearBranch ? null : (currentBranch ?? this.currentBranch),
      lastSyncedAt: lastSyncedAt ?? this.lastSyncedAt,
    );
  }

  Map<String, dynamic> toJson() => {
        'id': id,
        'name': name,
        'backend': backend.name,
        if (remotePath != null) 'remotePath': remotePath,
        if (localMirror != null) 'localMirror': localMirror,
        if (sshConfigId != null && sshConfigId!.isNotEmpty) 'sshConfigId': sshConfigId,
        'gitManaged': gitManaged,
        if (repoUrl != null) 'repoUrl': repoUrl,
        if (currentBranch != null) 'currentBranch': currentBranch,
        if (lastSyncedAt != null) 'lastSyncedAt': lastSyncedAt!.toIso8601String(),
      };

  static DevWorkspace? fromJson(Map<String, dynamic> json) {
    final id = (json['id'] as String?)?.trim();
    final name = (json['name'] as String?)?.trim();
    if (id == null || id.isEmpty || name == null || name.isEmpty) return null;
    final backend = WorkspaceBackend.values
        .where((b) => b.name == json['backend'])
        .firstOrNull;
    if (backend == null) return null;
    return DevWorkspace(
      id: id,
      name: name,
      backend: backend,
      remotePath: (json['remotePath'] as String?)?.trim(),
      localMirror: (json['localMirror'] as String?)?.trim(),
      sshConfigId: (json['sshConfigId'] as String?)?.trim(),
      gitManaged: (json['gitManaged'] as bool?) ?? false,
      repoUrl: (json['repoUrl'] as String?)?.trim(),
      currentBranch: (json['currentBranch'] as String?)?.trim(),
      lastSyncedAt: switch (json['lastSyncedAt'] as String?) {
        null => null,
        final s => DateTime.tryParse(s),
      },
    );
  }
}

/// 目录名安全化（文件系统友好；对齐 skills 目录 sanitize 思路）。
String sanitizeWorkspaceDirName(String name) {
  var s = name.trim().replaceAll(RegExp(r'[\\/:*?"<>|.]'), '-');
  s = s.replaceAll(RegExp(r'\s+'), '-');
  return s.replaceAll(RegExp(r'^-+|-+$'), '');
}
