/// 工作区侧的「动手」动作：连接 / 建远端目录 / 建并激活工作区 / 浏览远端目录。
///
/// 为什么抽出来：连接成功后的引导（设置页向导）、聊天里的工作区面板
/// （home_screen）、工作区对话框的目录浏览要用**同一套**逻辑。以前这些
/// 只活在设置页私有方法里（`_autoCreateRemoteDir`），聊天页想复用只能再抄
/// 一份，必然漂移。
///
/// 铁律沿用：连接一律走 `SshEnvironmentService.connect`（内部会先
/// `resolveSshSecrets` 回填凭据）；远端命令**不再**多包一层 `sh -c`
/// （dartssh2 `client.run` 本身就是经远程 bash 执行）。
library;

import 'package:flutter/foundation.dart'
    show debugPrint, visibleForTesting;

import 'dev_controller.dart';
import 'ssh/ssh_credentials.dart';
import 'ssh/ssh_diagnostics.dart';
import 'ssh/ssh_environment.dart';
import 'workspace.dart';

/// shell 单引号转义（路径含空格/引号不许炸）。
String _sq(String s) => "'${s.replaceAll("'", r"'\''")}'";

/// 该工作区该用哪份 SSH 连接配置：
/// 绑定 id 命中 > 当前正连着的 > 第一份配置完整的（与工具层回落顺序一致）。
SshConfig? pickSshConfigForWorkspace(
    DevWorkspace ws, List<SshConfig> configs) {
  final id = ws.sshConfigId?.trim() ?? '';
  if (id.isNotEmpty) {
    final bound = configs.where((c) => c.id == id).firstOrNull;
    if (bound != null) return bound;
  }
  final active = SshEnvironmentService.instance.activeConfig;
  if (active != null &&
      (id.isEmpty || active.id == id) &&
      SshEnvironmentService.instance.isConnected) {
    return active;
  }
  return configs.where((c) => c.isComplete).firstOrNull;
}

/// 为工作区建立 SSH 连接。成功返回 null，失败返回**可直接给用户看**的原因。
Future<String?> connectWorkspace(
    DevWorkspace ws, List<SshConfig> configs) async {
  if (!ws.isRemote) return null;
  final cfg = pickSshConfigForWorkspace(ws, configs);
  if (cfg == null) {
    return '还没有可用的连接配置：先到 设置 → 开发者 里添加远程电脑/Termux 连接';
  }
  final ssh = SshEnvironmentService.instance;
  try {
    await ssh.connect(cfg);
  } catch (e) {
    return '连接失败：$e';
  }
  return ssh.isConnected ? null : (ssh.lastError ?? '连接失败（原因未知）');
}

/// 在远端建 `~/projects/<安全名>` 并返回绝对路径（失败返回 null）。
Future<String?> ensureRemoteProjectDir(String name) async {
  final ssh = SshEnvironmentService.instance;
  final safe = sanitizeWorkspaceDirName(name);
  if (safe.isEmpty) return null;
  String home;
  try {
    home =
        (await ssh.run('echo \$HOME', timeout: const Duration(seconds: 30)))
                ?.trim() ??
            '';
  } catch (e) {
    debugPrint('[Dev] \$HOME 读取失败: $e');
    return null;
  }
  if (home.isEmpty) return null;
  final dir = '$home/projects/$safe';
  try {
    final out = await ssh.run('mkdir -p ${_sq(dir)} && echo OK',
        timeout: const Duration(seconds: 30));
    if ((out?.trim() ?? '') != 'OK') return null;
  } catch (e) {
    debugPrint('[Dev] 建远端目录失败: $e');
    return null;
  }
  return dir;
}

/// 列出远端某目录下的**子目录**（绝对路径，已排序）。`~` 会展开成远端家目录。
///
/// 用 `ls -1p` 而不是 `find`：`-p` 给目录补尾斜杠，一次调用即可筛目录，
/// 对端只要有个 POSIX 的 ls 就能用（Windows OpenSSH 自带 OpenSSH 的 ls 实现）。
Future<List<String>> listRemoteDirs({String path = '~'}) async {
  final ssh = SshEnvironmentService.instance;
  var target = path.trim().isEmpty ? '~' : path.trim();
  if (target == '~' || target.startsWith('~/') || target == r'$HOME') {
    final home =
        (await ssh.run('echo \$HOME', timeout: const Duration(seconds: 30)))
                ?.trim() ??
            '';
    if (home.isEmpty) return const [];
    target = target == '~' || target == r'$HOME'
        ? home
        : '$home/${target.substring(2)}';
  }
  final out = await ssh.run('ls -1p ${_sq(target)}',
      timeout: const Duration(seconds: 30));
  if (out == null) return const [];
  final dirs = out
      .split('\n')
      .map((l) => l.trim())
      .where((l) => l.endsWith('/') && l != '/')
      .map((l) {
    final name = l.substring(0, l.length - 1);
    if (name.isEmpty || name == '.') return '';
    // 以 .. 开头的条目一律丢（防越界跳转被当成目录）。
    if (name.startsWith('.')) return '';
    final base = target.endsWith('/') ? target.substring(0, target.length - 1) : target;
    return '$base/$name';
  })
      .where((s) => s.isNotEmpty)
      .toList()
    ..sort();
  return dirs;
}

/// 建一个工作区并**立刻激活**（连接成功后的一键开工）。
Future<DevWorkspace> createAndActivateWorkspace({
  required String name,
  required WorkspaceBackend backend,
  String? remotePath,
  String? sshConfigId,
  bool gitManaged = false,
}) async {
  final ws = DevWorkspace(
    id: 'ws_${DateTime.now().millisecondsSinceEpoch}',
    name: name.trim().isEmpty ? '新工作区' : name.trim(),
    backend: backend,
    remotePath: (remotePath ?? '').trim().isEmpty ? null : remotePath!.trim(),
    sshConfigId: (sshConfigId ?? '').trim().isEmpty ? null : sshConfigId,
    gitManaged: gitManaged,
  );
  final dev = DevSessionController.instance;
  await dev.upsertWorkspace(ws);
  await dev.switchWorkspace(ws.id);
  return ws;
}

/// 后端 → 图标/文案（设置页与聊天页共用，别各写一份）。
String workspaceBackendLabel(WorkspaceBackend backend) => switch (backend) {
      WorkspaceBackend.localApp => '本地沙盒',
      WorkspaceBackend.embedded => '内嵌工具沙箱',
      WorkspaceBackend.termux => 'Termux（手机 Linux）',
      WorkspaceBackend.remotePc => '远程电脑',
    };

// ---------------------------------------------------------------------------
// 「目录有就用、没有就建」（2026-10-27 用户定案）
//
// 现象：工作区记录在、电脑上的目录不在（手输过路径 / 换机器 / 目录被删 /
// 建工作区时没填路径），于是**每发一条消息**第一个 ssh_* 工具就报
// `bash: cd: ...: No such file or directory` 或 `未配置远端路径（remotePath）`。
// 工作区目录是智能体的工作现场，不在就该就地创建，而不是把errno甩给用户。
// ---------------------------------------------------------------------------

/// 未填远端路径时的占位根目录（`~` 交给远端 shell 展开，无需先连上再问 \$HOME）。
String defaultRemoteProjectPathPlaceholder(String name) {
  final safe = sanitizeWorkspaceDirName(name);
  return '~/projects/${safe.isEmpty ? 'workspace' : safe}';
}

/// 绝对化的缺省目录：`<home>/projects/<安全名>`。
String defaultRemoteProjectPath(String home, String name) {
  final h = home.trim().replaceAll(RegExp(r'/+$'), '');
  final safe = sanitizeWorkspaceDirName(name);
  final dir = 'projects/${safe.isEmpty ? 'workspace' : safe}';
  return h.isEmpty ? dir : '$h/$dir';
}

/// 已确认存在的远端工作区目录（`configId|绝对路径`），避免每次工具调用都 mkdir。
///
/// 失效策略：连接由"未连"转"已连"时整体清空（换了机器/换了会话都要重验）；
/// 会话中途目录被人删掉也饿不死——`remoteCdPrefix` 在每条命令前自带 `mkdir -p`。
final Set<String> _ensuredRemoteDirs = <String>{};
bool _wasConnected = false;

/// 测试用：清掉"已建目录"缓存。
@visibleForTesting
void clearEnsuredRemoteDirsCache() {
  _ensuredRemoteDirs.clear();
  _wasConnected = false;
}

/// 确保远端工作区目录存在（**有就直接用，没有就创建**）。
///
/// 前置：已连接（未连接返回 `root=null, error=null` = 不表态，交给调用方）。
/// 做三件事：① `~`/空路径 → 用 `echo $HOME` 绝对化；② `mkdir -p` 建目录；
/// ③ 路径被补全/改写时**回写工作区记录**（省得每次再猜，也让 SFTP 工具能拿到绝对路径）。
/// 返回 `root`（就绪后的绝对路径）或 `error`（可直接给用户看的原因）。
Future<({String? root, String? error})> ensureWorkspaceRemoteDir(
    DevWorkspace ws) async {
  if (!ws.isRemote) return (root: null, error: null);
  final ssh = SshEnvironmentService.instance;
  if (!ssh.isConnected) {
    _wasConnected = false;
    return (root: null, error: null);
  }
  if (!_wasConnected) _ensuredRemoteDirs.clear();
  _wasConnected = true;

  var root = (ws.remotePath ?? '').trim();
  var needPersist = false;
  String? home;
  Future<String> homeDir() async => home ??=
      (await ssh.run('echo \$HOME', timeout: const Duration(seconds: 20)))
              ?.trim() ??
          '';
  if (root.isEmpty || root == '~' || root.startsWith('~/')) {
    final h = await homeDir();
    if (h.isEmpty) {
      return (root: null, error: '读不到远端家目录：连接可能已断开，请重连后重试');
    }
    root = root.isEmpty
        ? defaultRemoteProjectPath(h, ws.name)
        : (root == '~' ? h : '$h/${root.substring(2)}');
    needPersist = true;
  }
  final key = '${ssh.activeConfig?.id ?? ''}|$root';
  if (!_ensuredRemoteDirs.contains(key)) {
    String? out;
    try {
      out = (await ssh.run('mkdir -p ${_sq(root)} && echo OK',
              timeout: const Duration(seconds: 20)))
          ?.trim();
    } catch (e) {
      debugPrint('[Dev] 建工作区目录失败 $root: $e');
      return (root: null, error: '创建远端工作区目录 $root 失败：$e');
    }
    if (out != 'OK') {
      return (
        root: null,
        error: '远端工作区目录 $root 不存在且自动创建失败：'
            '检查该路径权限/是否被同名文件占用，或在设置里换一个可写路径'
      );
    }
    _ensuredRemoteDirs.add(key);
    debugPrint('[Dev] 工作区「${ws.name}」远端目录就绪：$root');
  }
  if (needPersist) {
    try {
      await DevSessionController.instance
          .upsertWorkspace(ws.copyWith(remotePath: root));
    } catch (e) {
      debugPrint('[Dev] 工作区目录回填失败（不影响本次执行）: $e');
    }
  }
  return (root: root, error: null);
}


/// 「在当前已连接的电脑上开工」：建 `~/projects/<name>` + 工作区 + 立刻激活。
///
/// 成功返回 `(工作区, 远端目录)`；失败返回 `(null, 可直接给用户看的原因)`。
/// 设置页向导与聊天页共用同一条路径（Termux 连接自动按 termux 后端建）。
Future<({DevWorkspace? ws, String dir})> createWorkspaceOnActiveConnection(
    String name) async {
  final trimmed = name.trim();
  if (trimmed.isEmpty) return (ws: null, dir: '请填工作区名称');
  final ssh = SshEnvironmentService.instance;
  final cfg = ssh.activeConfig;
  if (cfg == null || !ssh.isConnected) {
    return (
      ws: null,
      dir: '还没有已连接的开发环境：先在 设置 → 开发者 里连上远程电脑/Termux'
          '（远程电脑用账号密码就能连）'
    );
  }
  final backend = sshTargetKindOf(cfg) == SshTargetKind.termux
      ? WorkspaceBackend.termux
      : WorkspaceBackend.remotePc;
  final dir = await ensureRemoteProjectDir(trimmed);
  if (dir == null) {
    return (ws: null, dir: '建目录失败：远端连接可能已断开，重连后再试');
  }
  final ws = await createAndActivateWorkspace(
    name: trimmed,
    backend: backend,
    remotePath: dir,
    sshConfigId: cfg.id,
  );
  return (ws: ws, dir: dir);
}

