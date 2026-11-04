/// 桌面本地执行器（Windows 分叉，替代手机端 embedded_tools/embedded_git）。
///
/// - [runLocalShell] / [executeDevShell]：本地命令走系统 shell
///   （Windows `cmd.exe /d /c`，POSIX `sh -c`），在指定工作目录里执行；
/// - [LocalGit]：本地 git 走系统 `git`（Git for Windows 在 PATH）。
///   与旧 JGit 版同名同返回型（LocalGitResult），git_tools 零改动迁移。
/// 凭据（用户名/token）注入 https URL 后执行，不落 remote 配置。
library;

import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/foundation.dart' show visibleForTesting;

import '../../tool_definition.dart';
import '../workspace.dart';
import '../workspace_store.dart';

/// 本地 shell 执行结果（embedded 时代语义保留：exit/stdout/stderr）。
final class DevShellResult {
  final int exit;
  final String stdout;
  final String stderr;
  const DevShellResult(
      {required this.exit, required this.stdout, required this.stderr});
  bool get ok => exit == 0;
}

/// 命令执行器（测试注入点：非 null 时代替真实 Process）。
typedef LocalShellRunner = Future<DevShellResult> Function(
    String executable, List<String> arguments, String? workingDirectory);

LocalShellRunner? _runnerOverride;

@visibleForTesting
set localShellRunnerForTest(LocalShellRunner? r) => _runnerOverride = r;

/// 平台 shell 命令行（纯函数，可测）。
({String exe, List<String> args}) localShellCommandLine(String command) =>
    Platform.isWindows
        ? (exe: 'cmd.exe', args: ['/d', '/c', command])
        : (exe: 'sh', args: ['-c', command]);

/// 在本地目录里执行一条 shell 命令（超时杀进程；输出 systemEncoding 解码，
/// 兼容中文 Windows 控制台 GBK 输出）。
Future<DevShellResult> runLocalShell(
  String command, {
  String? workingDirectory,
  Duration timeout = const Duration(seconds: 10),
  String? stdinInput,
}) async {
  final (:exe, :args) = localShellCommandLine(command);
  if (_runnerOverride != null) {
    return _runnerOverride!(exe, args, workingDirectory);
  }
  try {
    final proc = await Process.start(exe, args,
        workingDirectory: workingDirectory,
        includeParentEnvironment: true);
    // 双通道并拉，避免 stderr 缓冲写满死锁（shell_tool 同款纪律）。
    final out = proc.stdout.transform(systemEncoding.decoder).join();
    final err = proc.stderr.transform(systemEncoding.decoder).join();
    if (stdinInput != null) {
      proc.stdin.write(stdinInput);
    }
    await proc.stdin.close();
    final timer = Timer(timeout, () => proc.kill(ProcessSignal.sigkill));
    final exit = await proc.exitCode;
    timer.cancel();
    return DevShellResult(
        exit: exit, stdout: await out, stderr: await err);
  } on ProcessException catch (e) {
    return DevShellResult(exit: -1, stdout: '', stderr: '${e.message}');
  } catch (e) {
    return DevShellResult(exit: -1, stdout: '', stderr: '$e');
  }
}

/// dev_shell 根目录（embedded 时代同名 API）：null/'default' = 默认工作区，
/// 其余 = 工作区本地镜像（取目录即建目录）。
Future<String> devShellRoot(String? workspaceId, {DevStore? store}) async {
  final s = DevStore.resolve(store);
  if (workspaceId == null || workspaceId == DevWorkspace.kDefaultId) {
    return s.defaultWorkspaceDir();
  }
  return s.workspaceLocalMirror(workspaceId);
}

/// 在 [root] 里执行命令并包成 ToolResult（verify_tool / 旧 dev_shell 同款收口）。
Future<ToolResult> executeDevShell(
  String command, {
  required String root,
  Duration timeout = const Duration(seconds: 60),
  int outputLimit = 4000,
}) async {
  final dir = Directory(root);
  if (!dir.existsSync()) {
    return ToolResult.error('工作区目录不存在：$root');
  }
  final res =
      await runLocalShell(command, workingDirectory: root, timeout: timeout);
  final out = res.stdout.trim();
  final err = res.stderr.trim();
  var text = out;
  if (err.isNotEmpty) text = text.isEmpty ? err : '$out\n[stderr] $err';
  if (text.length > outputLimit) {
    text = '${text.substring(0, outputLimit)}\n…（输出截断）';
  }
  if (!res.ok) {
    return ToolResult.error('命令失败（exit=${res.exit}）：'
        '${text.isEmpty ? '无输出' : text}');
  }
  return ToolResult(content: text.isEmpty ? '（执行成功，无输出）' : text);
}

// ---------------------------------------------------------------------------
// 系统 git（旧 JGit 桥的桌面替身；同名 API，git_tools 直接复用）
// ---------------------------------------------------------------------------

/// 本地 git 操作结果（与旧 embedded_git 同形）。
final class LocalGitResult {
  final bool ok;
  final String output;
  const LocalGitResult({required this.ok, required this.output});
}

class LocalGit {
  LocalGit._();

  /// 测试注入：非 null 时代替真实 git 进程。
  @visibleForTesting
  static Future<LocalGitResult> Function(
      List<String> args, String workingDir)? invokerOverride;

  static const _noGitHint =
      '未找到 git：请安装 Git for Windows 并确认 git 在 PATH 中';

  static Future<LocalGitResult> _git(
      List<String> args, String workingDir,
      {Duration timeout = const Duration(seconds: 30)}) async {
    if (invokerOverride != null) return invokerOverride!(args, workingDir);
    try {
      final pr = await Process.run('git', args,
              workingDirectory: workingDir, stdoutEncoding: utf8)
          .timeout(timeout);
      final out = <String>[
        '${pr.stdout ?? ''}'.trim(),
        '${pr.stderr ?? ''}'.trim(),
      ].where((s) => s.isNotEmpty).join('\n');
      return LocalGitResult(ok: pr.exitCode == 0, output: out);
    } on ProcessException {
      return const LocalGitResult(ok: false, output: _noGitHint);
    } catch (e) {
      return LocalGitResult(ok: false, output: '$e');
    }
  }

  static Future<bool> isRepo(String root) async =>
      (await _git(['rev-parse', '--is-inside-work-tree'], root)).ok;

  static Future<LocalGitResult> status(String root) =>
      _git(['status', '--short', '--branch'], root);

  static Future<LocalGitResult> diff(String root,
      {bool staged = false, String? file}) {
    final args = <String>['diff'];
    if (staged) args.add('--staged');
    if (file != null && file.isNotEmpty) args.add(file);
    return _git(args, root);
  }

  static Future<LocalGitResult> log(String root, {int n = 10}) =>
      _git(['log', '--oneline', '-$n'], root);

  static Future<LocalGitResult> commit(String root,
      {required List<String> files, required String message}) async {
    final add = await _git(['add', ...files], root);
    if (!add.ok) return add;
    return _git(['commit', '-m', message], root);
  }

  /// https 凭据注入：`https://host/repo.git` → `https://user:token@host/…`。
  static String? _withCreds(String url, String? username, String? password) {
    if (username == null || username.isEmpty) return null;
    final uri = Uri.tryParse(url);
    if (uri == null || !uri.hasScheme || uri.host.isEmpty) return null;
    final pass = password == null || password.isEmpty
        ? ''
        : ':${Uri.encodeComponent(password)}';
    return uri
        .replace(userInfo: '${Uri.encodeComponent(username)}$pass')
        .toString();
  }

  static Future<LocalGitResult> push(String root,
      {String remote = 'origin',
      String? branch,
      String? username,
      String? password}) async {
    if (username != null && username.isNotEmpty) {
      final urlRes = await _git(['remote', 'get-url', remote], root);
      if (!urlRes.ok) return urlRes;
      final credUrl =
          _withCreds(urlRes.output.trim(), username, password);
      if (credUrl == null) {
        return const LocalGitResult(
            ok: false, output: '远端地址不是 https，无法注入凭据；'
                '请去掉 username/token 重试');
      }
      return _git(
        ['push', credUrl, if (branch != null) branch],
        root,
        timeout: const Duration(seconds: 120),
      );
    }
    return _git(['push', remote, if (branch != null) branch], root,
        timeout: const Duration(seconds: 120));
  }

  static Future<LocalGitResult> clone(String url, String target,
      {String? username,
      String? password,
      String? branch,
      int? depth}) async {
    final effectiveUrl = _withCreds(url, username, password) ?? url;
    final args = <String>['clone'];
    if (depth != null && depth > 0) args.addAll(['--depth', '$depth']);
    if (branch != null && branch.isNotEmpty) args.addAll(['-b', branch]);
    args.addAll([effectiveUrl, target]);
    return _git(args, File(target).parent.path,
        timeout: const Duration(minutes: 5));
  }
}
