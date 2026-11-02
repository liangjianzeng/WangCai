/// ADB 高层客户端 —— 在 [AdbConnection] 之上提供 shell / 文件 / 安装 / 截图 / 日志。
///
/// 服务名选择全部按 2026-10-27 真机取证（代理抓 `adb 1.0.41` ↔ 小米13 adbd）：
/// - 命令执行优先 **`exec:`**（`abb_exec` 特性，真 adb 的 `exec-out` 走的就是它，
///   直接 fork/exec，**不经过 sh 包装、不做 CRLF 翻译**），设备不支持时才退回
///   `exec-out:`。注意 `exec-out:` 在我们这台机器上实测**不回 OKAY**（卡到超时），
///   所以有 abb_exec 时必须优先 `exec:`。
/// - 交互 shell 用 **`shell,v2,TERM=dumb,raw:`**，配合 shell_v2 子帧拿到
///   stdout/stderr 分离与**真退出码**。
/// - 文件走 **`sync:`** 子协议（SEND/DATA/DONE/OKAY、RECV/DATA/DONE、STAT/LIST）。
/// - 安装优先 **`cmd:package install -r -t -S <size>`** 流式（不落盘、不占 /data 空间），
///   不支持 `cmd` 特性时退回 "push 到 /data/local/tmp + `pm install -r -t`"。
///
/// 铁律（项目记忆）：**绝不调用 `adb uninstall`** —— 会清掉已下载的端侧模型缓存。
library;

import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';

import 'adb_connection.dart';
import 'adb_protocol.dart';
import 'adb_rsa.dart';

/// shell 执行结果。
class AdbShellResult {
  final String stdout;
  final String stderr;
  final int exitCode;

  const AdbShellResult({
    required this.stdout,
    required this.stderr,
    required this.exitCode,
  });

  bool get ok => exitCode == 0;

  /// 给模型看的合并输出（stderr 单独标注，避免模型把报错当正文）。
  String get merged {
    if (stderr.trim().isEmpty) return stdout;
    return stdout.isEmpty ? '[stderr] $stderr' : '$stdout\n[stderr] $stderr';
  }
}

/// sync 侧的文件元信息。
class AdbFileInfo {
  final String path;
  final int mode;
  final int size;
  final int mtime;

  const AdbFileInfo(
      {required this.path, required this.mode, required this.size, required this.mtime});

  bool get isDirectory => (mode & 0x4000) != 0;
  bool get isSymlink => (mode & 0xa000) == 0xa000;

  Map<String, dynamic> toJson() =>
      {'path': path, 'mode': mode, 'size': size, 'mtime': mtime, 'dir': isDirectory};
}

/// 目标机概览（devices 动作的数据源）。
class AdbDeviceIdentity {
  final String host;
  final int port;
  final String model;
  final String device;
  final String productName;
  final List<String> features;
  final Map<String, String> properties;

  const AdbDeviceIdentity({
    required this.host,
    required this.port,
    required this.model,
    required this.device,
    required this.productName,
    required this.features,
    required this.properties,
  });

  String get serial => '$host:$port';

  Map<String, dynamic> toJson() => {
        'serial': serial,
        'model': model,
        'device': device,
        'product': productName,
        'androidVersion': properties['ro.build.version.release'] ?? '',
        'sdk': properties['ro.build.version.sdk'] ?? '',
        'features': features,
      };
}

/// 一台目标机的高层客户端。
class AdbClient {
  final AdbConnection conn;
  final String host;
  final int port;

  AdbClient(this.conn, {required this.host, required this.port});

  String get serial => '$host:$port';

  /// 连接 + 认证（[key] 为我方 RSA 密钥；首次连接需要目标机点「允许调试」）。
  static Future<AdbClient> connect({
    required String host,
    int port = 5555,
    required AdbRsaKeyPair key,
    Duration connectTimeout = const Duration(seconds: 6),
    Duration handshakeTimeout = const Duration(seconds: 15),
  }) async {
    final conn = await AdbConnection.connect(
      host: host,
      port: port,
      key: key,
      connectTimeout: connectTimeout,
      handshakeTimeout: handshakeTimeout,
    );
    return AdbClient(conn, host: host, port: port);
  }

  AdbDeviceIdentity identity() => AdbDeviceIdentity(
        host: host,
        port: port,
        model: conn.model,
        device: conn.deviceCodename,
        productName: conn.productName,
        features: conn.features,
        properties: conn.properties,
      );

  Future<void> close() => conn.close();

  // -------------------------------------------------------------------------
  // 命令执行
  // -------------------------------------------------------------------------

  /// 执行 shell 命令，拿到分离的 stdout/stderr 与真退出码。
  ///
  /// 优先 shell_v2（`shell,v2,TERM=dumb,raw:`）；老设备（< Android 8）不支持时
  /// 退回 `shell:`（此时 stderr 混在 stdout 里、退出码恒 0，属协议本身限制）。
  Future<AdbShellResult> shell(String command,
      {Duration timeout = const Duration(seconds: 20)}) async {
    if (command.trim().isEmpty) {
      throw const AdbTransportException('命令不能为空');
    }
    if (conn.supportsShellV2) {
      // **只在 OPEN 这一步失败时才允许降级换路**：命令一旦开始执行，
      // 换条路重试就等于把同一条命令跑两遍（`input tap`、`pm install`
      // 这类副作用翻倍，是真机上的事故级问题）。
      AdbStream? stream;
      try {
        stream = await conn.open('shell,v2,TERM=dumb,raw:$command');
      } on AdbTransportException {
        stream = null; // 老 ROM 声明了 shell_v2 却不实现：此时还没发过任何字节，可安全退路
      }
      if (stream != null) return _consumeShellV2(stream, timeout);
    }
    final out = await execOut('sh -c ${_singleQuote(command)}', timeout: timeout);
    return AdbShellResult(
        stdout: utf8.decode(out, allowMalformed: true), stderr: '', exitCode: 0);
  }

  Future<AdbShellResult> _consumeShellV2(AdbStream stream, Duration timeout) async {
    final out = BytesBuilder(copy: true);
    final err = BytesBuilder(copy: true);
    var exit = 0;
    final dec = ShellPacketDecoder();
    try {
      // 发完 stdin 立刻关：adbd 的 shell 进程等 EOF 才收尾（真 adb 同此，取证见协议层注释）
      await stream.write(shellPacketEncode(ShellPacketId.closeStdin));
      await stream.data
          .listen((bytes) {
            for (final p in dec.feed(bytes)) {
              switch (p.id) {
                case ShellPacketId.stdout:
                  out.add(p.payload);
                  break;
                case ShellPacketId.stderr:
                  err.add(p.payload);
                  break;
                case ShellPacketId.exit:
                  exit = p.exitCode ?? 0;
                  break;
                default:
                  break; // STDIN/WINDOW_SIZE 是本端→对端方向，不该出现
              }
            }
          })
          .asFuture<void>()
          .timeout(timeout);
    } on TimeoutException {
      throw AdbTransportException(
          'shell 超时（${timeout.inSeconds}s）：命令可能卡在交互输入或前台运行。'
          '交互/常驻进程请用 `nohup … &`，或改用 logcat/dumpsys 类动作');
    } finally {
      await stream.close();
    }
    return AdbShellResult(
      stdout: utf8.decode(out.toBytes(), allowMalformed: true),
      stderr: utf8.decode(err.toBytes(), allowMalformed: true),
      exitCode: exit,
    );
  }

  /// 二进制安全的命令执行（截图 screencap、cat 图片等），拿原始字节。
  ///
  /// 用 `exec:`（abb_exec）时**不会**发生 legacy shell 的 `\n → \r\n` 翻译，
  /// 这是"截图/PNG 损坏"类问题的根因所在； abb_exec 不可用时退 `exec-out:`。
  Future<Uint8List> execOut(String command,
      {Duration timeout = const Duration(seconds: 30)}) async {
    final service =
        conn.features.contains('abb_exec') ? 'exec:$command' : 'exec-out:$command';
    final stream = await conn.open(service);
    final out = BytesBuilder(copy: true);
    try {
      await stream.data.listen(out.add).asFuture<void>().timeout(timeout);
    } on TimeoutException {
      throw AdbTransportException(
          'exec-out 超时（${timeout.inSeconds}s）：$command');
    } finally {
      await stream.close();
    }
    return out.toBytes();
  }

  // -------------------------------------------------------------------------
  // sync: 文件协议
  // -------------------------------------------------------------------------

  /// 打开 sync 会话并执行 [body]，结束时补 QUIT。
  Future<T> _withSync<T>(Future<T> Function(AdbStream s, _SyncReader rd) body) async {
    final stream = await conn.open('sync:');
    final rd = _SyncReader(stream);
    try {
      return await body(stream, rd);
    } finally {
      try {
        await stream.write(syncEncodeQuit());
      } catch (_) {}
      await stream.close();
      rd.dispose();
    }
  }

  /// 推一个文件（[mode] 默认 0644；目录需目标机已存在）。
  Future<void> push(Uint8List data, String remotePath,
      {int mode = 0x1a4, Duration timeout = const Duration(seconds: 120)}) async {
    if (remotePath.isEmpty || !remotePath.startsWith('/')) {
      throw AdbTransportException('远端路径必须是绝对路径：$remotePath');
    }
    // adbd 的 SEND **没有独立的 mode 字段**：权限以十进制 st_mode 拼在路径尾部
    // （`/path/file,33188` = 0o100644）。真机取证：抓 `adb 1.0.41 push` 的线上字节
    // `SEND | u32(35) | "/data/local/tmp/x.bin,33188" | DATA | u32(2048) | …`。
    // 曾按「mode<<16 | pathlen」编头 → adbd 把路径前 4 字节当长度 → FAIL "path too long"。
    final withMode = '$remotePath,${0x8000 | mode}'; // 0o100000(S_IFREG) | 权限位
    final pathBytes = utf8.encode(withMode);
    await _withSync((s, rd) async {
      await s.write(syncEncode(SyncMessage.create('SEND', pathBytes.length, pathBytes)));
      const chunk = 64 * 1024;
      for (var off = 0; off < data.length; off += chunk) {
        final end = off + chunk > data.length ? data.length : off + chunk;
        await s.write(
            syncEncode(SyncMessage.create('DATA', end - off, data.sublist(off, end))));
      }
      await s.write(syncEncode(SyncMessage.create(
          'DONE', DateTime.now().millisecondsSinceEpoch ~/ 1000)));
      final reply = await rd.next(timeout);
      if (reply.id == 'FAIL') {
        throw AdbTransportException('push 被拒绝：${reply.text}');
      }
      if (reply.id != 'OKAY') {
        throw AdbTransportException('push 返回意外应答 ${reply.id}');
      }
    });
  }

  /// 拉一个文件为字节。
  Future<Uint8List> pull(String remotePath,
      {Duration timeout = const Duration(seconds: 120)}) async {
    final pathBytes = utf8.encode(remotePath);
    return _withSync((s, rd) async {
      await s.write(syncEncode(SyncMessage.create('RECV', pathBytes.length, pathBytes)));
      final out = BytesBuilder(copy: true);
      while (true) {
        final m = await rd.next(timeout);
        if (m.id == 'DATA') {
          out.add(m.body);
        } else if (m.id == 'DONE') {
          break;
        } else if (m.id == 'FAIL') {
          throw AdbTransportException('pull 失败：${m.text}');
        } else {
          throw AdbTransportException('pull 返回意外应答 ${m.id}');
        }
      }
      return out.toBytes();
    });
  }

  /// 列目录（sync LIST，v1 形态，全版本 adbd 支持）。
  Future<List<AdbFileInfo>> ls(String remotePath,
      {Duration timeout = const Duration(seconds: 20)}) async {
    final pathBytes = utf8.encode(remotePath);
    return _withSync((s, rd) async {
      await s.write(syncEncode(SyncMessage.create('LIST', pathBytes.length, pathBytes)));
      final out = <AdbFileInfo>[];
      while (true) {
        final m = await rd.next(timeout);
        if (m.id == 'DONE') break;
        if (m.id == 'FAIL') {
          throw AdbTransportException('列目录失败：${m.text}');
        }
        if (m.id != 'DIR' && m.id != 'DENT') {
          throw AdbTransportException('列目录返回意外应答 ${m.id}');
        }
        if (m.a0 == 0) continue; // '.' / '..' 与 v1 的裸目录名
        final name = utf8.decode(m.body.sublist(12), allowMalformed: true);
        out.add(AdbFileInfo(
          path: remotePath.endsWith('/') ? '$remotePath$name' : '$remotePath/$name',
          mode: m.mode,
          size: m.size,
          mtime: m.mtime,
        ));
      }
      return out;
    });
  }

  /// 取文件状态（不存在返回 null）。
  Future<AdbFileInfo?> stat(String remotePath,
      {Duration timeout = const Duration(seconds: 20)}) async {
    final pathBytes = utf8.encode(remotePath);
    return _withSync((s, rd) async {
      await s.write(syncEncode(SyncMessage.create('STAT', pathBytes.length, pathBytes)));
      final m = await rd.next(timeout);
      if (m.id != 'STAT') return null;
      if (m.mode == 0) return null; // adbd 用全 0 表示不存在
      return AdbFileInfo(
          path: remotePath, mode: m.mode, size: m.size, mtime: m.mtime);
    });
  }

  // -------------------------------------------------------------------------
  // 应用安装（铁律：只覆盖安装，永不 uninstall）
  // -------------------------------------------------------------------------

  /// 安装 APK。默认 `-r -t`（覆盖安装 + 允许 test 包），**绝不先卸载**。
  ///
  /// 优先 `cmd:package install -r -t -S <size>` 流式（不占 /data/local/tmp，
  /// 与真 adb 的 `adb install` 同路）；设备无 `cmd` 特性时退回
  /// push 到 /data/local/tmp + `pm install -r -t` + 删除临时文件。
  Future<AdbShellResult> installApk(Uint8List apk,
      {String remoteTmp = '/data/local/tmp/tongyi_lite_install.apk',
      Duration timeout = const Duration(minutes: 5)}) async {
    if (conn.supportsCmd) {
      final stream = await conn.open('cmd:package install -r -t -S ${apk.length}');
      final out = BytesBuilder(copy: true);
      final err = BytesBuilder(copy: true);
      var exit = 0;
      final dec = ShellPacketDecoder();
      try {
        // cmd: 服务用的是 shell_v2 帧封装（stdin 也是子帧），先喂 APK 再关 stdin
        const chunk = 64 * 1024;
        for (var off = 0; off < apk.length; off += chunk) {
          final end = off + chunk > apk.length ? apk.length : off + chunk;
          await stream.write(shellPacketEncode(ShellPacketId.stdin, apk.sublist(off, end)));
        }
        await stream.write(shellPacketEncode(ShellPacketId.closeStdin));
        await stream.data.listen((bytes) {
          for (final p in dec.feed(bytes)) {
            if (p.id == ShellPacketId.stdout) {
              out.add(p.payload);
            } else if (p.id == ShellPacketId.stderr) {
              err.add(p.payload);
            } else if (p.id == ShellPacketId.exit) {
              exit = p.exitCode ?? 0;
            }
          }
        }).asFuture<void>().timeout(timeout);
      } on TimeoutException {
        throw AdbTransportException(
            '安装超时（${timeout.inMinutes}min）。MIUI 可能弹了「是否安装该应用」需要手点确认');
      } finally {
        await stream.close();
      }
      return AdbShellResult(
        stdout: utf8.decode(out.toBytes(), allowMalformed: true),
        stderr: utf8.decode(err.toBytes(), allowMalformed: true),
        exitCode: exit,
      );
    }
    await push(apk, remoteTmp, timeout: timeout);
    final r = await shell('pm install -r -t $remoteTmp', timeout: timeout);
    await shell('rm -f $remoteTmp');
    return r;
  }

  /// 截图（PNG 原始字节）。`screencap -p` 经 exec-out 路径，**无 CRLF 翻译**。
  Future<Uint8List> screenshot({Duration timeout = const Duration(seconds: 30)}) =>
      execOut('screencap -p', timeout: timeout);

  /// logcat 一次性导出（`-d` = dump 后退出，绝不做常驻 tail）。
  Future<String> logcat({String? filter, int? lines, Duration timeout = const Duration(seconds: 25)}) async {
    final sb = StringBuffer('logcat -d');
    if (lines != null && lines > 0) sb.write(' -t $lines');
    if (filter != null && filter.trim().isNotEmpty) sb.write(' ${filter.trim()}');
    return (await shell(sb.toString(), timeout: timeout)).merged;
  }

  static String _singleQuote(String s) => "'${s.replaceAll("'", r"'\''")}'";
}

/// sync 子协议读侧。
///
/// adbd 的 sync 回复是 `union syncmsg`（`file_sync_service.h`），**头长随 id 变**：
/// `OKAY/DONE` 8B（id + 0）、`DATA/FAIL` 8B + 变长体、`STAT` 16B（mode/size/mtime）、
/// `DIR/DENT` 20B（namelen + mode/size/mtime）+ 名字。所以必须按 id 决定还要读多少，
/// 不能一律"8 字节头 + 长度字段"。
class _SyncReader {
  final _buf = BytesBuilder(copy: true);
  StreamSubscription<Uint8List>? _subs;
  final _wakeup = <Completer<void>>[];
  bool _closed = false;

  _SyncReader(AdbStream s) {
    _subs = s.data.listen((b) {
      _buf.add(b);
      _wake();
    }, onError: (Object _) {
      _closed = true;
      _wake();
    }, onDone: () {
      _closed = true;
      _wake();
    });
  }

  void _wake() {
    for (final c in _wakeup) {
      if (!c.isCompleted) c.complete();
    }
    _wakeup.clear();
  }

  void dispose() {
    _subs?.cancel();
    _subs = null;
  }

  /// 取下一条 sync 消息（含其变长体）。
  Future<_SyncMsg> next(Duration timeout) async {
    final head = await _read(8, timeout);
    final id = String.fromCharCodes(head.sublist(0, 4));
    final bd = ByteData.sublistView(head);
    final a0 = bd.getUint32(4, Endian.little);
    switch (id) {
      case 'STAT':
        // 回复是 `{id, mode, size, mtime}` 共 16 字节：**mode 就在头部的 a0**，
        // 尾部只有 size+mtime 8 字节（真机取证 `STAT|f9410000|7c0d0000|30c4e06a`）。
        return _SyncMsg(id, a0, await _read(8, timeout));
      case 'DIR':
      case 'DENT':
        return _SyncMsg(id, a0, await _read(12 + a0, timeout));
      case 'DATA':
      case 'FAIL':
        return _SyncMsg(id, a0, await _read(a0, timeout));
      case 'OKAY':
      case 'DONE':
      case 'QUIT':
        return _SyncMsg(id, a0, Uint8List(0));
      default:
        throw AdbTransportException('未知 sync 应答 "$id"（字节流已跑偏）');
    }
  }

  Future<Uint8List> _read(int n, Duration timeout) async {
    while (true) {
      final buf = _buf.toBytes();
      if (buf.length >= n) {
        _buf.clear();
        if (buf.length > n) _buf.add(buf.sublist(n));
        return Uint8List.fromList(buf.sublist(0, n));
      }
      if (_closed) {
        throw const AdbTransportException('sync 会话被对端关闭（数据不完整）');
      }
      final c = Completer<void>();
      _wakeup.add(c);
      await c.future.timeout(timeout,
          onTimeout: () => throw AdbTransportException('sync 等待 $n 字节超时'));
    }
  }
}

class _SyncMsg {
  final String id;

  /// 头里第二个 u32：DATA=长度、FAIL=文本长度、DIR/DENT=名字长度、STAT=未用。
  final int a0;

  /// 已按 id 语义读完的变长体（STAT 为 12 字节 stat 结构，DIR/DENT 为 stat+名字）。
  final Uint8List body;

  const _SyncMsg(this.id, this.a0, this.body);

  String get text => utf8.decode(body, allowMalformed: true);

  /// 时间戳（字节序位置随 id 变，见 [isDir] 注释）。
  int get mtime => ByteData.sublistView(body).getUint32(
        id == 'STAT' ? 4 : 8, Endian.little);

  int get mode => id == 'STAT' ? a0 : ByteData.sublistView(body).getUint32(0, Endian.little);

  int get size => ByteData.sublistView(body).getUint32(
        id == 'STAT' ? 0 : 4, Endian.little);

  bool get isDir => id == 'DIR' || id == 'DENT';
}
