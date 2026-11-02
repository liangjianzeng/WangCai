/// 内嵌沙箱 shell 工具（Dev Agent L0/L1）—— 在**本地**工作区根目录执行命令。
///
/// 与 builtin shell_exec 的分工：shell_exec 面向主智能体（app 权限、系统 PATH）；
/// dev_shell 面向 Dev 工作区（cwd 锚定工作区根、PATH 前插 nativeLibraryDir
/// —— jniLibs 的 lib*.so 是 targetSdk 34 下唯一可 exec 的白名单位置，
/// busybox/rg/jq 等内嵌工具落在这里）、带 Dev safety 黑名单。
/// 运行器可注入（测试桩）；解析失败/命令缺失给可读错误（如实报告铁律）。
library;

import 'dart:async';
import 'dart:convert';
import 'dart:io';

import '../../builtin_tools/shell_tool.dart'
    show kShellOutputLimit; // 复用同一截断上限语义
import '../../sandbox.dart' show SandboxMode, effectiveModeOf, withEscalationFields;
import '../../tool_definition.dart';
import '../native_env.dart';
import '../safety.dart';
import '../workspace.dart';
import '../workspace_store.dart';

/// dev_shell 单次超时。
const Duration kDevShellTimeout = Duration(seconds: 30);

/// 进程运行结果（注入桩与真实实现共用）。
final class DevShellResult {
  final int exit;
  final String stdout;
  final String stderr;
  const DevShellResult(
      {required this.exit, required this.stdout, required this.stderr});
}

/// 进程运行器签名（测试注入点）。
typedef DevShellRunner = Future<DevShellResult> Function(
  String executable,
  List<String> args, {
  String? cwd,
  Map<String, String> environment,
  String? stdin,
});

/// 解析 dev_shell 的工作目录（纯逻辑，store 可注入）。
///
/// - null/'default' → 默认工作区根（`documents/workspace`，旧行为）；
/// - 其他工作区（localApp/embedded）→ `documents/workspace/projects/<safe-id>/`。
Future<String> devShellRoot(String? workspaceId, {DevStore? store}) async {
  final s = DevStore.resolve(store);
  if (workspaceId == null || workspaceId == DevWorkspace.kDefaultId) {
    return s.defaultWorkspaceDir();
  }
  return s.workspaceLocalMirror(workspaceId);
}

/// 组装 dev_shell 的 PATH（nativeLibraryDir 前插；info 缺失 = 系统默认）。
String devShellPath(String? nativeLibraryDir) =>
    (nativeLibraryDir == null || nativeLibraryDir.isEmpty)
        ? Platform.environment['PATH'] ?? '/system/bin'
        : '$nativeLibraryDir:${Platform.environment['PATH'] ?? '/system/bin'}';

/// 内嵌沙箱执行核心（dev_shell 与 run_tests 共用）。
///
/// 黑名单检查由调用方负责（dev_shell 按沙箱模式放行批准的满权限，
/// run_tests 恒检查）。输出格式：stdout + [stderr] 段 + 截断 + exit 标注。
Future<ToolResult> executeDevShell(
  String command, {
  required String root,
  Duration timeout = kDevShellTimeout,
  DevShellRunner? runner,
  Future<String?> Function()? nativeLibDir,
}) async {
  final dir = Directory(root);
  if (!await dir.exists()) {
    await dir.create(recursive: true);
  }
  final libDir = await (nativeLibDir ?? _defaultNativeLibDir)();
  final envPath = devShellPath(libDir);
  Future<DevShellResult> runDefault(
    String executable,
    List<String> args, {
    String? cwd,
    Map<String, String> environment = const {},
    String? stdin,
  }) async {
    final env = <String, String>{...Platform.environment, ...environment};
    final proc = await Process.start(executable, args,
        workingDirectory: cwd, environment: env);
    final stdoutFuture = proc.stdout.transform(utf8.decoder).join();
    final stderrFuture = proc.stderr.transform(utf8.decoder).join();
    if (stdin != null && stdin.isNotEmpty) {
      proc.stdin.write(stdin);
    }
    await proc.stdin.flush();
    await proc.stdin.close();
    final timer = Timer(timeout, () {
      proc.kill(ProcessSignal.sigkill);
    });
    final exit = await proc.exitCode;
    timer.cancel();
    return DevShellResult(
        exit: exit, stdout: await stdoutFuture, stderr: await stderrFuture);
  }

  try {
    final result = await (runner ?? runDefault)('sh', ['-c', command],
        cwd: root, environment: {'PATH': envPath});
    var out = result.stdout.trim();
    if (result.stderr.trim().isNotEmpty) {
      out = out.isEmpty
          ? '[stderr] ${result.stderr.trim()}'
          : '$out\n[stderr] ${result.stderr.trim()}';
    }
    final truncated = out.length > kShellOutputLimit
        ? '${out.substring(0, kShellOutputLimit)}\n…（已截断）'
        : out;
    return ToolResult(
        content: truncated.isEmpty ? '（无输出，exit=${result.exit}）' : truncated,
        isError: result.exit != 0);
  } catch (e) {
    return ToolResult.error('命令执行失败：$e');
  }
}

/// dev_shell：本地开发沙箱命令执行。
ToolDefinition createDevShellTool({
  DevShellRunner? runner,
  Future<String?> Function()? nativeLibDir,
  DevStore? store,
}) {
  return ToolDefinition(
    name: 'dev_shell',
    // 副作用工具：可写任意工作区文件（P2-A 独占执行 / 计划模式禁用）。
    // 此前漏标（默认按只读安全）导致 /plan 只读门控被 shell 绕过——
    // 计划回合里模型用 dev_shell 下载/改文件，"只读规划"形同虚设（真机实锤）。
    isConcurrencySafe: (_) => false,
    description:
        '在当前开发工作区内执行 shell 命令（本地沙箱，cwd=工作区根）。'
        '系统自带 mksh + toybox（ls/cp/grep/sed/awk/find/tar/diff 等齐全），'
        '并带内嵌工具（存在时）：busybox/ripgrep(rg)/jq。'
        '没有 git/包管理器——git 用 git_status/git_diff/git_commit/git_push/git_clone 工具，'
        '装软件请切 Termux 工作区用 pkg。'
        '输出截断到 ${kShellOutputLimit} 字符，超时 ${kDevShellTimeout.inSeconds}s。'
        '危险命令（rm -rf /、dd 直写设备、git push --force 等）会被拒绝；'
        '需要越出工作区访问时带 sandbox_permissions 请求用户批准。',
    parameters: withEscalationFields({
      'type': 'object',
      'properties': {
        'command': {'type': 'string', 'description': '要执行的 shell 命令'},
        'stdin': {
          'type': 'string',
          'description': '喂给命令 stdin 的输入（一次性批次，喂完即关）'
        },
      },
      'required': ['command'],
    }),
    timeout: kDevShellTimeout,
    execute: (args) async {
      final command = (args['command'] as String?)?.trim() ?? '';
      if (command.isEmpty) return ToolResult.error('缺少 command 参数');
      // 危险命令黑名单（Dev safety 全通道覆盖；用户显式批准满权限时放行）。
      final mode = effectiveModeOf(args);
      if (mode != SandboxMode.dangerFullAccess) {
        final danger = checkDangerousCommand(command);
        if (danger != null) {
          return ToolResult.error('危险命令被拒绝：$danger。'
              '请改用安全的等价操作，或带 sandbox_permissions + justification '
              '请求用户批准');
        }
      }
      String root;
      try {
        root = await devShellRoot(effectiveWorkspaceOf(args), store: store);
      } catch (e) {
        return ToolResult.error('工作目录解析失败：$e');
      }
      return executeDevShell(command,
          root: root, runner: runner, nativeLibDir: nativeLibDir);
    },
  );
}

Future<String?> _defaultNativeLibDir() async =>
    (await DevNativeEnv.nativeInfo())?.nativeLibraryDir;
