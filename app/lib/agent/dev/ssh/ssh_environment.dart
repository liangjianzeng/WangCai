/// SSH 开发环境服务（Dev Agent Phase B）—— 全局连接状态机 + 命令执行 + SFTP。
///
/// 仿 DSH-Phone `tunnel_service.dart` 的连接/认证模式（真机验证过）：
/// - 密钥优先（SSHKeyPair.fromPem），密码兜底（onPasswordRequest）；
/// - keep-alive 保活 + 主机密钥 TOFU（首次记录指纹，后续比对，可清除）；
/// - 输出健壮解码（UTF-8 → GBK → 宽松 UTF-8）。
///
/// 安全：仅作为 SSH **客户端**；默认目标 Termux sshd（127.0.0.1:8022），
/// 不暴露任何服务端口。连接层不感知工具/沙箱，工具层负责护栏。
library;

import 'dart:async' show TimeoutException;
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:dartssh2/dartssh2.dart';
import 'package:flutter/foundation.dart' show ChangeNotifier, debugPrint;
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';

import 'secret_store.dart' show resolveSshSecrets;
import 'ssh_credentials.dart';

/// 连接状态。
enum SshStatus { idle, connecting, connected, failed }

/// 单次 SFTP 读取上限（对齐 DSH-Phone 8MB 经验，防移动端 OOM）。
const int kSshMaxReadBytes = 8 * 1024 * 1024;

/// 连接/认证超时。
const Duration kSshConnectTimeout = Duration(seconds: 15);
const Duration kSshAuthTimeout = Duration(seconds: 20);

// ---------------------------------------------------------------------------
// dartssh2 错误收口（2026-10-28 真机定案）
//
// dartssh2 的错误类**没有一个实现 Exception**：`abstract class SSHError {}`、
// `class SftpError { ... }` 都是裸类（见 third_party/dartssh2/lib/src/
// ssh_errors.dart、sftp/sftp_errors.dart）。Dart 的 `on Exception` 只抓实现了
// Exception 的对象，于是**全 app 所有 `on Exception` 兜底对 dartssh2 完全失效**。
// 真机实锤：远端一个文件不存在（SftpStatusError code 2）就能穿过每层 catch，
// 把整条消息发送打死 —— 屏幕底部「发送失败: SftpStatusError: No such file(code 2)」，
// 对话区留下空气泡。用户看到的就是"工作区没建过，发消息直接报错"。
//
// 本文件是通往 dartssh2 的唯一门，所以所有出口在这里统一换成 Dart 认识的异常，
// 并说人话（哪个路径、什么原因、下一步怎么办）。
// ---------------------------------------------------------------------------

/// 本服务对外的唯一错误类型（实现 Exception ⇒ 下游 `on Exception` 真的能抓到）。
class SshServiceException implements Exception {
  final String message;

  /// 原始 dartssh2 错误（排障用；日志里保留，不进用户文案）。
  final Object? cause;
  const SshServiceException(this.message, {this.cause});

  @override
  String toString() => 'SshServiceException: $message';
}

/// SFTP 状态码 → 中文原因（code 2「No such file」是这次真机事故的那一个）。
String _sftpCodeHint(int code) => switch (code) {
      1 => '已到文件尾',
      2 => '远端文件或目录不存在',
      3 => '远端权限不足（该账号无权读写此路径）',
      4 => '远端拒绝该操作（常见：目标已存在 / 磁盘只读）',
      7 => '与远端的连接中断',
      8 => '远端未启用 SFTP 服务（sshd_config 缺 Subsystem sftp）',
      _ => '远端返回错误码 $code',
    };

/// 任意 dartssh2 抛出物 → 带中文原因的 [SshServiceException]。
///
/// [context] 说清"在干什么"（读哪个文件 / 建哪个目录），用户才可能自己修。
SshServiceException sshServiceFailure(Object error, {String? context}) {
  final hint = switch (error) {
    SftpStatusError(:final code) => _sftpCodeHint(code),
    SftpAbortError() => 'SFTP 会话被中断（连接可能已断开）',
    SSHAuthError() => '认证失败',
    SSHSocketError() => '网络不可达或远端服务未启动',
    _ => '远端操作失败',
  };
  // SftpStatusError 的类名对用户毫无意义（真机就是被这串英文吓到的）：
  // 换成 code；其余错误保留 toString 作为排障线索（原始对象也留在 cause 里）。
  final detail =
      error is SftpStatusError ? '（code ${error.code}）' : '（$error）';
  return SshServiceException(
    context == null ? '$hint$detail' : '$context：$hint$detail',
    cause: error,
  );
}


final class SshEnvironmentService extends ChangeNotifier {
  SshEnvironmentService._();

  /// 全局单例。
  static final SshEnvironmentService instance = SshEnvironmentService._();

  SshStatus _status = SshStatus.idle;
  SSHClient? _client;
  SshConfig? _activeConfig;
  String? _lastError;
  Map<String, String> _hostKeys = <String, String>{};

  SshStatus get status => _status;

  /// 当前生效配置（用于 UI 展示）。
  SshConfig? get activeConfig => _activeConfig;

  String? get lastError => _lastError;

  /// 是否已认证连接。
  bool get isConnected =>
      _status == SshStatus.connected && _client != null;

  /// 确保连接：未连接 → 连接；配置不同 → 自动切换；配置相同 → 复用。
  /// 返回是否处于已连接状态；失败原因见 [lastError]。
  Future<bool> ensureConnected(SshConfig config) async {
    await connect(config);
    return isConnected;
  }

  /// 建立连接（幂等：已连接且配置相同则跳过；[force] = 强制重新握手）。
  Future<void> connect(SshConfig config, {bool force = false}) async {
    // P2-D3：密钥从安全存储回填（JSON 只留空槽位；内存配置自带密钥则直通）。
    SshConfig cfg = config;
    try {
      cfg = await resolveSshSecrets(config);
    } on Exception catch (_) {}
    if (!cfg.isComplete) {
      _fail('SSH 配置不完整（host/port/username/认证）');
      return;
    }
    if (isConnected && _activeConfig != null) {
      // 配置未变：直接复用现有连接（force = 用户手点「连接」，强制重握手）。
      if (!force && _sameConfig(_activeConfig!, cfg)) return;
      await disconnect();
    }
    _status = SshStatus.connecting;
    _lastError = null;
    // 连接前预载主机指纹（onVerifyHostKey 是同步回调，须用内存缓存）。
    _hostKeys = await _loadHostKeys();
    notifyListeners();
    SSHClient? client;
    try {
      final socket = await SSHSocket.connect(cfg.host, cfg.port,
          timeout: kSshConnectTimeout);

      List<SSHKeyPair>? identities;
      if (cfg.usesKey) {
        try {
          identities = SSHKeyPair.fromPem(cfg.privateKeyPem ?? '',
              (cfg.keyPassphrase ?? '').isEmpty
                  ? null
                  : cfg.keyPassphrase);
        } catch (_) {
          if (!cfg.usesPassword) {
            // 旧版向导曾生成 checkint/公钥格式错误的密钥，永远无法认证。
            throw const FormatException(
                '密钥无法解析——旧版向导生成的坏格式密钥，请重跑「连接 Termux / 远程电脑」向导重新生成并安装');
          }
          // 密钥+密码兜底模式：坏私钥不致命，降级用密码继续认证。
          debugPrint('[SSH] 私钥解析失败，回落密码认证：${cfg.host}');
          identities = null;
        }
      } else {
        identities = null;
      }
      if (identities == null && !cfg.usesPassword) {
        throw const FormatException('没有可用凭据：请填写私钥或登录密码');
      }

      client = SSHClient(
        socket,
        username: cfg.username,
        identities: identities,
        // 密码通道：密码模式必需；密钥+密码兜底模式作 fallback（dartssh2 先试
        // publickey，失败再试 password，见 ssh_client.dart _startAuthentication）。
        onPasswordRequest: cfg.usesPassword
            ? () async => (cfg.password ?? '').isEmpty ? null : cfg.password
            : null,
        keepAliveInterval: const Duration(seconds: 10),
        onVerifyHostKey: (hostkeyType, fingerprint) =>
            _verifyHostKey(cfg, hostkeyType, fingerprint),
        // 注：fork 回调签名 = (typeName: String, fingerprint: Uint8List)。
      );

      // 立即"认领"为当前连接：否则下面 `client != _client` 守卫恒为真，
      // 认证成功后也会被自己判成"已被替换"而关闭 —— 真实表现是
      // 「远程电脑/Termux 永远连不上，报 SSH 连接已被替换」（2026-10-27 修）。
      _client = client;

      // 传输关闭通知。
      client.done.then(
        (_) => _onTransportClosed(client!, failed: false),
        onError: (Object e) {
          debugPrint('[SSH] transport error: $e');
          _onTransportClosed(client!, failed: true);
        },
      );

      await client.authenticated.timeout(kSshAuthTimeout);
      if (client != _client) {
        // 并发断开守卫：期间被 disconnect 替换则放弃。
        client.close();
        throw const SocketException('SSH 连接已被替换，放弃本次');
      }
      _activeConfig = cfg;
      _status = SshStatus.connected;
      notifyListeners();
      debugPrint('[SSH] connected ${config.username}@${config.host}:${config.port}');
    } catch (e) {
      debugPrint('[SSH] connect failed: $e');
      if (client != null) {
        // 失败路径必须自己收尾：本次握手的 client 若仍被认领，要摘掉并关闭，
        // 否则留下半死 socket（status=failed 但 _client 非空 → socket 泄漏）。
        if (_client == client) {
          _client = null;
          _activeConfig = null;
        }
        try {
          client.close();
        } catch (_) {}
      }
      _fail('连接失败：$e');
    }
  }

  /// 断开连接（幂等）。
  Future<void> disconnect() async {
    final client = _client;
    _client = null;
    _activeConfig = null;
    if (client != null) {
      try {
        client.close();
      } catch (_) {}
    }
    if (_status != SshStatus.idle) {
      _status = SshStatus.idle;
      notifyListeners();
    }
  }

  /// 连接探测：已连接时执行 `echo ok` 验证存活；失败自动标记断开。
  Future<bool> probe() async {
    if (!isConnected) return false;
    try {
      final out = await run('echo ok', timeout: const Duration(seconds: 5));
      return out?.trim() == 'ok';
    } catch (_) {
      _onTransportClosed(_client!, failed: true);
      return false;
    }
  }

  /// 远程执行一条命令，返回合并 stdout+stderr 的文本；失败抛异常。
  ///
  /// 注意（DSH-Phone 教训）：`client.run` 本身就是经远程 bash 执行，
  /// 不要再包一层 `sh -c '...'`（单引号嵌套冲突）。
  ///
  /// 超时处理（真机教训）：`client.run` 等待 stdout+stderr 双流 EOF，
  /// 命令 fork 后台进程等会让 stderr 不关 → future 永久挂起；超时后必须
  /// 断开连接（触发底层流关闭，释放泄漏的 session 通道），并把状态标记
  /// 断开，提示接入层"已断开可重连"。
  Future<String?> run(String command,
      {Duration timeout = const Duration(seconds: 15)}) async {
    final client = _client;
    if (client == null) throw const SocketException('SSH 未连接');
    try {
      final bytes = await client.run(command).timeout(timeout);
      return _decode(bytes);
    } on TimeoutException {
      debugPrint('[SSH] run timeout: $command');
      _onTransportClosed(client, failed: true);
      throw const SocketException(
          'SSH 命令执行超时，连接已断开（可重新连接后重试）');
    } catch (e) {
      // SSHError 不是 Exception：不在这里收口，它会一路撞到聊天发送的兜底。
      throw sshServiceFailure(e, context: '远端命令执行失败');
    }
  }

  /// P2-D4：打开 SFTP 会话（workspace_sync 递归同步用）；未连接抛 [SshServiceException]。
  Future<SftpClient> openSftp() async {
    final client = _client;
    if (client == null) throw const SocketException('SSH 未连接');
    try {
      return await client.sftp();
    } catch (e) {
      throw sshServiceFailure(e, context: '打不开远端 SFTP 会话');
    }
  }

  /// 远程读取文件（SFTP），上限 [kSshMaxReadBytes]；失败抛 [SshServiceException]。
  Future<Uint8List> readFileBytes(String path,
      {int? maxBytes}) async {
    final client = _client;
    if (client == null) throw const SocketException('SSH 未连接');
    try {
      final sftp = await client.sftp();
      try {
        final f = await sftp.open(path, mode: SftpFileOpenMode.read);
        try {
          final limit =
              (maxBytes ?? kSshMaxReadBytes).clamp(1, kSshMaxReadBytes);
          return await f.readBytes(length: limit);
        } finally {
          await f.close();
        }
      } finally {
        sftp.close();
      }
    } on SshServiceException {
      rethrow;
    } catch (e) {
      throw sshServiceFailure(e, context: '读不到远端文件 $path');
    }
  }

  /// 远程写入文件（SFTP，覆盖截断）；失败抛 [SshServiceException]。
  ///
  /// 注意：SFTP `open(create)` **不会创建父目录**，父目录不存在时远端回 code 2；
  /// 调用方（ssh_write_file）负责先 `mkdir -p`。
  Future<void> writeFileBytes(String path, List<int> bytes) async {
    final client = _client;
    if (client == null) throw const SocketException('SSH 未连接');
    if (bytes.length > kSshMaxReadBytes) {
      throw ArgumentError('写入过大（>${kSshMaxReadBytes ~/ 1024 / 1024}MB）');
    }
    try {
      final sftp = await client.sftp();
      try {
        final f = await sftp.open(path,
            mode: SftpFileOpenMode.write |
                SftpFileOpenMode.create |
                SftpFileOpenMode.truncate);
        try {
          await f.writeBytes(Uint8List.fromList(bytes));
        } finally {
          await f.close();
        }
      } finally {
        sftp.close();
      }
    } on SshServiceException {
      rethrow;
    } catch (e) {
      throw sshServiceFailure(e, context: '写远端文件失败 $path（目录可能不存在或不可写）');
    }
  }

  // ---------------------------------------------------------------------------
  // 主机密钥 TOFU
  // ---------------------------------------------------------------------------

  Future<File> _hostKeysFile() async {
    final base = await getApplicationSupportDirectory();
    final dir = Directory(p.join(base.path, 'dev', 'ssh'));
    if (!dir.existsSync()) dir.createSync(recursive: true);
    return File(p.join(dir.path, 'hostkeys.json'));
  }

  Future<Map<String, String>> _loadHostKeys() async {
    try {
      final f = await _hostKeysFile();
      if (!f.existsSync()) return <String, String>{};
      final decoded = jsonDecode(f.readAsStringSync());
      if (decoded is Map<String, dynamic>) {
        return decoded.map((k, v) => MapEntry(k, v.toString()));
      }
    } catch (_) {}
    return <String, String>{};
  }

  Future<void> _persistHostKeys() async {
    final f = await _hostKeysFile();
    final tmp = File('${f.path}.tmp');
    await tmp.writeAsString(jsonEncode(_hostKeys), flush: true);
    await tmp.rename(f.path);
  }

  /// TOFU 校验（同步回调，用内存缓存）：key = `host:port`。
  /// - 首次 → 记录指纹接受（fire-and-forget 落盘）；
  /// - 后续一致 → 接受；不一致 → 拒绝（设置页可清除重试）。
  ///
  /// 回调形参：typeName（如 "ssh-ed25519"）+ fingerprint（原始字节）。
  bool _verifyHostKey(SshConfig config, String typeName, Uint8List fingerprint) {
    final hex = fingerprint.map((b) =>
        b.toRadixString(16).padLeft(2, '0')).join(':');
    final key = '${config.host}:${config.port}';
    final saved = _hostKeys[key];
    if (saved == null) {
      _hostKeys[key] = hex;
      _persistHostKeys().catchError((_) {});
      return true;
    }
    if (saved == hex) return true;
    _lastError = '主机密钥指纹与上次不一致（$typeName），已拒绝连接。'
        '若服务端更换密钥，请清除保存的指纹后重试';
    return false;
  }

  /// 清除全部已保存主机指纹（设置页入口）。
  Future<void> clearHostKeyFingerprints() async {
    _hostKeys = <String, String>{};
    final f = await _hostKeysFile();
    if (f.existsSync()) f.deleteSync();
  }

  // ---------------------------------------------------------------------------
  // 内部
  // ---------------------------------------------------------------------------

  bool _sameConfig(SshConfig a, SshConfig b) =>
      a.host == b.host &&
      a.port == b.port &&
      a.username == b.username &&
      a.authType == b.authType &&
      // 凭据也纳入比较：改了密码/换了私钥必须重新握手，
      // 否则"编辑后再点连接"会复用旧凭据的陈旧连接（表现 = 改了没生效）。
      (a.privateKeyPem ?? '') == (b.privateKeyPem ?? '') &&
      (a.keyPassphrase ?? '') == (b.keyPassphrase ?? '') &&
      (a.password ?? '') == (b.password ?? '');

  void _onTransportClosed(SSHClient client, {required bool failed}) {
    if (_client != client) return; // 已被替换/断开
    _client = null;
    _activeConfig = null;
    _status = failed ? SshStatus.failed : SshStatus.idle;
    _lastError = failed ? 'SSH 连接异常断开' : null;
    // 真机教训（超时泄漏）：光把 _client 置 null 不 close，底层 socket 与
    // 挂死的 `client.run` future 永不释放（一条慢命令即拖垮整个连接池）。
    try {
      client.close();
    } catch (_) {}
    notifyListeners();
  }

  void _fail(String message) {
    _lastError = message;
    _status = SshStatus.failed;
    notifyListeners();
  }

  /// 健壮解码：UTF-8 → GBK/GB2312 → 宽松 UTF-8（对齐 DSH-Phone 经验）。
  String _decode(Uint8List bytes) {
    try {
      return utf8.decode(bytes);
    } catch (_) {
      try {
        return latin1.decode(bytes);
      } catch (_) {
        return utf8.decode(bytes, allowMalformed: true);
      }
    }
  }
}
