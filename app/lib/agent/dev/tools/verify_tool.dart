/// 验证循环工具（Dev Agent Phase C）—— 在工作区运行测试/构建。
///
/// 分派（L1 扩展）：远端后端（termux/remotePc）走 ssh 共享执行器（原路径）；
/// 本地后端（localApp/embedded/默认工作区）走内嵌沙箱执行器（dev_shell 同款，
/// PATH 前插 nativeLibraryDir）。默认 60s 超时（构建类任务）；输出截断 4000。
/// 失败 → 模型迭代修复 → 再跑；成功 → 接入层 tools/result hook 可推进计划。
library;

import '../../tool_definition.dart';
import '../safety.dart';
import '../ssh/ssh_credentials.dart' show SshConfig;
import '../workspace.dart';
import '../workspace_store.dart';
import 'embedded_tools.dart' show devShellRoot, executeDevShell;
import 'ssh_tools.dart' show sshRunInWorkspace;

/// bash 单引号转义（cwd 安全入 `cd '…' && …`）。
String _singleQuote(String s) => "'${s.replaceAll("'", r"'\''")}'";

/// 组装实际执行的命令（纯函数，可测）。
///
/// [root] 为空 = 本地内嵌沙箱（执行器已经在 `projects/<id>` 下起 sh，只需 `cd <cwd>`）；
/// 非空 = 远端，需要 `cd <root>/<cwd>`。
///
/// **回归锚点（可用性评估 P0-8）**：旧版本地分支写成 `'$cwd && $command'`，
/// 漏了 `cd `，于是 shell 把目录名当命令执行 → 带 cwd 的本地 `run_tests` 100% 失败。
String buildRunTestsCommand(
    {required String command, String cwd = '', String? root}) {
  String? dir;
  if (root != null && root.isNotEmpty) {
    final base = root.endsWith('/') ? root.substring(0, root.length - 1) : root;
    dir = cwd.isEmpty ? base : '$base/${cwd.replaceAll('\\', '/')}';
  } else if (cwd.isNotEmpty) {
    dir = cwd.replaceAll('\\', '/');
  }
  if (dir == null) return command;
  return 'cd ${_singleQuote(dir)} && $command';
}

/// cwd 必须是工作区内相对子目录（与 git 工具的 path jail 一致）。
String? cwdJailError(String cwd) {
  if (cwd.isEmpty) return null;
  final rel = cwd.replaceAll('\\', '/');
  if (rel.startsWith('/') || rel.split('/').contains('..')) {
    return 'cwd 必须是工作区内的相对子目录（不允许 .. 与绝对路径）';
  }
  return null;
}

/// run_tests：执行测试/构建命令。
ToolDefinition createRunTestsTool({List<SshConfig> sshConfigs = const []}) {
  return ToolDefinition(
    isConcurrencySafe: (_) => false, // 副作用工具：独占执行（P2-A）
    name: 'run_tests',
    description:
        '在当前工作区运行测试/构建命令，验证改动是否正确。'
        'command 为要执行的命令（如 "python -m pytest -q"、"npm test"、"flutter test"）；'
        '不传时返回常见约定并请模型补全。超时 60s，输出截断 4000 字符。'
        '失败请根据输出修复后重试，直到通过。',
    parameters: {
      'type': 'object',
      'properties': {
        'command': {'type': 'string', 'description': '测试/构建命令'},
        'cwd': {'type': 'string', 'description': '可选：相对当前工作区的目录'},
      },
      'required': ['command'],
    },
    timeout: const Duration(seconds: 60),
    execute: (args) async {
      final command = (args['command'] as String?)?.trim() ?? '';
      if (command.isEmpty) {
        return ToolResult.error('缺少 command 参数。常见约定：'
            'python 项目 "python -m pytest -q"，Node 项目 "npm test"，'
            'Flutter 项目 "flutter test"。请补全命令后重试');
      }
      final cwd = (args['cwd'] as String?)?.trim() ?? '';
      final cwdError = cwdJailError(cwd);
      if (cwdError != null) return ToolResult.error(cwdError);
      // 危险命令只看模型传入的 command 段：`cd <root> && ` 前缀（含工作区名）
      // 不参与扫描，否则工作区叫 mount-app 会让该工作区所有命令被误杀。
      final danger = checkDangerousCommand(command);
      if (danger != null) {
        return ToolResult.error('危险命令被拒绝：$danger');
      }
      // 本地工作区：内嵌沙箱执行（dev_shell 同款执行器）。
      // 注意 cwd 必须补 `cd ` 并单引号转义 —— 旧版拼成 `'$cwd && $command'`
      // 把目录名当命令执行，带 cwd 的本地测试 100% 失败（可用性评估 P0-8）。
      final wsId = effectiveWorkspaceOf(args);
      final remote = wsId != null && wsId != DevWorkspace.kDefaultId
          ? await _isRemoteWorkspace(wsId)
          : false;
      if (!remote) {
        final root = await devShellRoot(wsId);
        return executeDevShell(buildRunTestsCommand(command: command, cwd: cwd),
            root: root, timeout: const Duration(seconds: 60));
      }
      return sshRunInWorkspace(
        args,
        (root) => buildRunTestsCommand(command: command, cwd: cwd, root: root),
        timeout: const Duration(seconds: 60),
        sshConfigs: sshConfigs,
        dangerText: command,
      );
    },
  );
}

/// 工作区是否存在且为远端后端（本地/默认/不存在 = 非远端）。
Future<bool> _isRemoteWorkspace(String workspaceId) async {
  try {
    final workspaces = await DevStore.resolve().loadWorkspaces();
    final ws = workspaces.where((w) => w.id == workspaceId).firstOrNull;
    return ws?.isRemote ?? false;
  } catch (_) {
    return false;
  }
}
