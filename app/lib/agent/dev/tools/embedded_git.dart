/// 本地 git 服务（Dev Agent L1）—— JGit 经 MethodChannel 进程内执行。
///
/// 通道 `com.dgxspark.tongyilite/devgit`（Kotlin 侧 DevGitPlugin）。
/// 为什么走 MethodChannel 而不是 Dart 绑定：JGit 无维护良好的 Dart FFI 绑定，
/// Kotlin/Java 调用是一等公民；所有操作进程内完成，**零 exec**（W^X 安全）。
///
/// 支持操作：status/diff/log/add/commit/push（https + token）/clone。
/// ssh:// 远端不支持（明确报错；引导切 Termux/远程工作区用系统 git）。
library;

import 'package:flutter/services.dart';

const MethodChannel _kDevGitChannel =
    MethodChannel('com.dgxspark.tongyilite/devgit');

/// 通道调用器签名（测试注入点）。
typedef DevGitInvoker = Future<Object?> Function(
    String method, Map<String, dynamic> args);

/// 本地 git 操作结果。
final class LocalGitResult {
  /// 退出语义：ok=false 时 [output] 为可读错误。
  final bool ok;
  final String output;
  const LocalGitResult({required this.ok, required this.output});
}

/// 本地 git 桥（静态收口；invoker 仅供测试注入）。
class LocalGit {
  LocalGit._();

  /// 测试注入：null = 真实 MethodChannel。
  static DevGitInvoker? invoker;

  static Future<LocalGitResult> _invoke(
      String method, Map<String, dynamic> args) async {
    try {
      final raw = await (invoker ?? _kDevGitChannel.invokeMethod)(method, args);
      final map = raw is Map ? raw.cast<String, dynamic>() : <String, dynamic>{};
      return LocalGitResult(
        ok: map['ok'] == true,
        output: (map['output'] as String?) ?? '',
      );
    } on MissingPluginException {
      return const LocalGitResult(
          ok: false, output: '本地 git 服务不可用（JGit 插件未加载）');
    } on PlatformException catch (e) {
      return LocalGitResult(ok: false, output: e.message ?? e.code);
    } catch (e) {
      return LocalGitResult(ok: false, output: '$e');
    }
  }

  /// 仓库是否有效（.git 存在且 JGit 能打开）。
  static Future<bool> isRepo(String root) async =>
      (await _invoke('status', {'root': root})).ok;

  /// status --short --branch。
  static Future<LocalGitResult> status(String root) =>
      _invoke('status', {'root': root});

  /// diff（staged 可选；file 可选）。
  static Future<LocalGitResult> diff(String root,
      {bool staged = false, String? file}) {
    return _invoke('diff', {
      'root': root,
      'staged': staged,
      if (file != null && file.isNotEmpty) 'file': file,
    });
  }

  /// log --oneline -n。
  static Future<LocalGitResult> log(String root, {int n = 10}) =>
      _invoke('log', {'root': root, 'n': n});

  /// add + commit。
  static Future<LocalGitResult> commit(String root,
      {required List<String> files, required String message}) {
    return _invoke('commit', {'root': root, 'files': files, 'message': message});
  }

  /// push（https + 用户名/token）。ssh:// 明确不支持。
  static Future<LocalGitResult> push(String root,
      {String remote = 'origin',
      String? branch,
      String? username,
      String? password}) {
    return _invoke('push', {
      'root': root,
      'remote': remote,
      if (branch != null && branch.isNotEmpty) 'branch': branch,
      if (username != null && username.isNotEmpty) 'username': username,
      if (password != null && password.isNotEmpty) 'password': password,
    });
  }

  /// clone（https + 用户名/token）到 [target]；[depth] 非空时浅克隆
  /// （只拉最近 N 层提交，JGit setDepth——读代码/分析用，浅克隆不能 push）。
  static Future<LocalGitResult> clone(String url, String target,
      {String? username, String? password, String? branch, int? depth}) {
    return _invoke('clone', {
      'url': url,
      'target': target,
      if (username != null && username.isNotEmpty) 'username': username,
      if (password != null && password.isNotEmpty) 'password': password,
      if (branch != null && branch.isNotEmpty) 'branch': branch,
      if (depth != null && depth > 0) 'depth': depth,
    });
  }
}
