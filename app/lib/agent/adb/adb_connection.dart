/// ADB 传输层 —— 一条 TCP 连接上的 CNXN/AUTH 握手 + OPEN/OKAY/WRTE/CLSE 流复用。
///
/// 设计要点（都是"连真 adbd 才踩得到"的地方）：
/// - **握手时序**：需要认证的 adbd 是在 **CNXN 之前**就发 AUTH(TOKEN) 的，所以密钥
///   必须在发我方 CNXN 之前就位；"先等 CNXN 再处理 TOKEN" 会直接握手死锁。
/// - **两轮认证**：第一轮只发签名（不打扰用户）；adbd 不认这把钥匙会**再发一次
///   TOKEN**，这时才补发公钥（目标机弹「允许 USB 调试吗？」）。
/// - **STLS 直接给人话诊断**：Android 11+ 的"无线调试"开关走 TLS-PSK + SPAKE2，
///   本实现不做（Dart 无 TLS-PSK 原语）。检测到 STLS 就明确让用户先用有线 adb
///   跑一次 `adb tcpip 5555`，而不是超时到天荒地老。
/// - **写侧停等流控**：每发一个 WRTE 等对端 OKAY 再发下一个。adbd 只保证"未 ack
///   的数据不超过 maxdata"，停等是最省事且绝不会死锁的实现。
/// - **读侧先投递再回 OKAY**：绝不能"处理完再 ack"，否则 adbd 发送窗口被我们卡死，
///   症状是"输出一大就卡住"。
library;

import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'adb_protocol.dart';
import 'adb_rsa.dart';

/// 帧级调试开关：置 true 后把每条进出帧打到 stderr。
///
/// 真机联调时"哪条帧没来 / id 方向回错 / 子帧解歪"只有看线才能定论，
/// 而这类问题在 CI 上永远复现不了（协议层三条真机 bug 全靠这个开关抓的）。
bool adbDebugFrames = false;

/// 按环境变量 `TONGYI_ADB_DEBUG=1` 打开帧调试（由 tool/adb_probe.dart 调用）。
void enableAdbFrameDebugFromEnvironment() {
  adbDebugFrames = Platform.environment['TONGYI_ADB_DEBUG'] == '1';
}

void _traceIn(AdbMessage m) {
  if (!adbDebugFrames) return;
  var extra = '';
  if (m.payload.isNotEmpty && m.payload.length <= 32) {
    extra = ' body=${m.payload.map((b) => b.toRadixString(16).padLeft(2, '0')).join()}';
  }
  stderr.writeln('[adb<<] ${commandName(m.command)} arg0=${m.arg0} arg1=${m.arg1} '
      'len=${m.payload.length}$extra');
}

void _traceOut(Uint8List bytes) {
  if (!adbDebugFrames || bytes.length < 24) return;
  final bd = ByteData.sublistView(bytes, 0, 24);
  stderr.writeln('[adb>>] ${commandName(bd.getUint32(0, Endian.little))} '
      'arg0=${bd.getUint32(4, Endian.little)} arg1=${bd.getUint32(8, Endian.little)} '
      'len=${bd.getUint32(12, Endian.little)}');
}

/// 连接层异常（带人话原因，工具层直接回填给模型）。
class AdbTransportException implements Exception {
  final String message;
  const AdbTransportException(this.message);
  @override
  String toString() => 'AdbTransportException: $message';
}

/// 一条逻辑流（一次 shell / sync / 服务连接）。
class AdbStream {
  final AdbConnection conn;
  final int localId;
  final String service;
  int peerId;

  final _incoming = StreamController<Uint8List>();
  final _writeAcks = <Completer<void>>[];
  Completer<void>? opened;
  bool closed = false;

  AdbStream(this.conn, this.localId, this.service, this.peerId);

  /// 对端数据流（WRTE 载荷，按到达序投递）。
  Stream<Uint8List> get data => _incoming.stream;

  /// 本流是否已经开始收发过字节（决定上层能否安全降级重试）。
  bool get started => _everStarted || _writeAcks.isNotEmpty;
  bool _everStarted = false;

  /// 写一段数据（内部按分片 + 停等 OKAY）。
  ///
  /// **停等必须能容忍"没有 OKAY"**：子进程已经退出时，adbd 会用 CLSE 取代最后
  /// 那个 WRTE 的 OKAY（真机 2026-10-27 实测：`WRTE CLOSE_STDIN` 之后直接来
  /// `CLSE`）。这时数据早已交给内核，把它判成失败会让上层重跑命令 ——
  /// 对 `input tap` / `pm install` 这类副作用是重复执行事故。
  Future<void> write(List<int> bytes, {Duration? ackTimeout}) async {
    if (closed) throw const AdbTransportException('流已关闭');
    if (bytes.isEmpty) return;
    _everStarted = true;
    final chunkSize = conn.writeChunkSize;
    for (var off = 0; off < bytes.length; off += chunkSize) {
      final end = off + chunkSize > bytes.length ? bytes.length : off + chunkSize;
      final chunk = bytes is Uint8List
          ? bytes.sublist(off, end)
          : Uint8List.fromList(bytes.sublist(off, end));
      final ack = Completer<void>();
      _writeAcks.add(ack);
      await conn.sendRaw(adbEncode(AdbMessage(AdbCommand.wrte, localId, peerId, chunk)));
      try {
        await ack.future.timeout(ackTimeout ?? const Duration(seconds: 10));
      } on TimeoutException {
        if (!closed) rethrow; // 流还活着却不 ack：真异常，交上层
        return; // 流已被对端关闭：数据已发出，视为完成
      }
    }
  }

  /// 主动关闭本流。
  Future<void> close() async {
    if (closed) return;
    closed = true;
    _releaseAcks();
    if (!_incoming.isClosed) await _incoming.close();
    conn.dropStream(localId);
    try {
      await conn
          .sendRaw(adbEncode(AdbMessage(AdbCommand.clse, localId, peerId, Uint8List(0))));
    } catch (_) {
      // 对端已断开/连接已销毁：清理路径不该再往上抛
    }
  }

  /// 唤醒所有还在等 OKAY 的写协程。
  ///
  /// **一律按"成功"收尾**：能走到这里说明字节流已经交给 socket，对端回不回
  /// OKAY 都不代表写失败（adbd 在进程退出时就用 CLSE 代替 OKAY）。
  /// 曾按 error 结束 → 上层降级重跑命令 → 副作用翻倍，别再改回去。
  void _releaseAcks() {
    for (final ack in _writeAcks) {
      if (!ack.isCompleted) ack.complete();
    }
    _writeAcks.clear();
  }

  /// 收到对端 OKAY：open 未确认 → 这是 OPEN 的应答；否则是 WRTE 的 ack。
  void _onOkay(int remoteId) {
    if (opened != null && !opened!.isCompleted) {
      peerId = remoteId;
      opened!.complete();
      return;
    }
    if (_writeAcks.isNotEmpty) _writeAcks.removeAt(0).complete();
  }

  void _onData(Uint8List payload) {
    if (closed || _incoming.isClosed) return;
    _incoming.add(payload);
  }

  void _failClose(String reason) {
    if (closed) return;
    closed = true;
    _releaseAcks();
    if (!_incoming.isClosed) {
      _incoming.close(); // 正常收尾：读侧靠 done 判定结束，错误走 open 失败
    }
    if (opened != null && !opened!.isCompleted) {
      opened!.completeError(AdbTransportException('服务 "$service" 被拒绝：$reason'));
    }
    conn.dropStream(localId);
  }
}

/// 一条到 adbd 的连接。
class AdbConnection {
  final Socket _socket;
  final Map<int, AdbStream> _streams = {};
  final Map<String, String> _properties = {};
  List<String> _features = const [];

  /// 对端声明的单包上限（CNXN arg1；未收到时按 [kAdbMaxData] 保守取）。
  int peerMaxData = kAdbMaxData;

  /// 写分片大小：夹到 [8KB, 64KB]，太小停等 RTT 吃亏，太大 adbd 侧缓冲压力大。
  int get writeChunkSize => peerMaxData.clamp(8 * 1024, 64 * 1024);

  final _rx = BytesBuilder(copy: true);
  Completer<void>? _ready;
  StreamSubscription<Uint8List>? _sub;
  Object? _fatalError;
  int _nextStreamId = 1; // 客户端侧恒用奇数 id（adbd 用偶数）

  AdbRsaKeyPair? _key;
  int _authStage = 0; // 0=没发过签名 1=发过签名 2=连公钥也发了

  /// CNXN 横幅里的属性（ro.product.model / features 等）。
  Map<String, String> get properties => _properties;
  List<String> get features => _features;

  String get model => _properties['ro.product.model'] ?? '';
  String get deviceCodename => _properties['ro.product.device'] ?? '';
  String get productName => _properties['ro.product.name'] ?? '';

  /// 对端是否支持 shell_v2（拿到 stderr + 真退出码）。
  bool get supportsShellV2 => _features.contains('shell_v2');

  /// 对端是否支持 `cmd:` 服务（`cmd package install` 这类）。
  bool get supportsCmd => _features.contains('cmd');

  AdbConnection._(this._socket);

  /// 连接并握手。
  ///
  /// [key] 我方 RSA 密钥。首次连接一台新手机时，目标机会弹「允许 USB 调试」，
  /// 需要有人在屏幕上点一次"允许"（勾"始终允许"后同一把钥匙不再弹）。
  static Future<AdbConnection> connect({
    required String host,
    int port = 5555,
    required AdbRsaKeyPair key,
    Duration connectTimeout = const Duration(seconds: 6),
    Duration handshakeTimeout = const Duration(seconds: 15),
  }) async {
    Socket socket;
    try {
      socket = await Socket.connect(host, port, timeout: connectTimeout);
      socket.setOption(SocketOption.tcpNoDelay, true);
    } on SocketException catch (e) {
      throw AdbTransportException('连不上 $host:$port（${e.osError?.message ?? e.message}）。'
          '排查：① 目标机是否已 `adb tcpip 5555`（重启后失效）；'
          '② 两台手机是否同网段/Tailscale 可达；③ 端口是否被防火墙拦');
    }

    final conn = AdbConnection._(socket).._key = key;
    conn._ready = Completer<void>();
    conn._start();
    try {
      // 我方 CNXN（AUTH TOKEN 可能比对方 CNXN 先到，状态机自己处理）
      await conn.sendRaw(adbEncode(AdbMessage.create(
          AdbCommand.cnxn, kAdbVersion, kAdbMaxData, utf8.encode(kAdbBanner))));
      await conn._ready!.future.timeout(handshakeTimeout, onTimeout: () {
        throw const AdbTransportException(
            '握手超时（15s 没等到 CNXN）。常见原因：目标机弹了「允许 USB 调试」没人点；'
            '或对端是 Android 11+ 的 TLS 无线调试（本工具只支持经典网络 adb，'
            '请先用有线 adb 执行 adb tcpip 5555）');
      });
    } catch (e) {
      await conn.close();
      rethrow;
    }
    return conn;
  }

  void _start() {
    _sub = _socket.listen(_onBytes,
        onError: (Object e) => _failAll('连接异常：$e'),
        onDone: () => _failAll('对端关闭连接'),
        cancelOnError: false);
  }

  void _onBytes(Uint8List bytes) {
    _rx.add(bytes);
    while (true) {
      final buf = _rx.toBytes();
      AdbDecoded? decoded;
      try {
        decoded = adbTryDecode(buf);
      } on AdbProtocolException catch (e) {
        _failAll(e.message);
        return;
      }
      if (decoded == null) {
        _rx.clear();
        _rx.add(buf); // 半包：留着等下一批字节
        return;
      }
      _rx.clear();
      final rest = buf.sublist(decoded.consumed);
      if (rest.isNotEmpty) _rx.add(rest);
      _dispatch(decoded.message);
    }
  }

  void _failAll(String reason) {
    _fatalError ??= reason;
    for (final s in _streams.values.toList()) {
      s._failClose(reason);
    }
    final ready = _ready;
    if (ready != null && !ready.isCompleted) {
      ready.completeError(AdbTransportException(reason));
    }
  }

  /// 出站串行链（**必须**有，否则并发写会把 socket 打炸）。
  ///
  /// dart:io 的 `Socket.flush()` 实现就是 `addStream(空流)`，它会临时把 sink
  /// "绑定到流"；这期间任何 `add()` 直接抛 `Bad state: StreamSink is bound to a
  /// stream`。而我们的 OKAY 是在收包回调里 unawaited 发出去的，push 的 DATA 又在
  /// 主线上连着发 —— 两条 sendRaw 一重叠就中招（假 adbd 的 push 用例复现，真机上
  /// 只是概率问题）。所以所有出站走同一条链，add+flush 之间不许被插队。
  Future<void> _tail = Future<void>.value();

  /// 发一条已编码的原始帧（所有出站的唯一出口）。
  Future<void> sendRaw(Uint8List bytes) {
    _traceOut(bytes);
    final fatal = _fatalError;
    if (fatal != null) return Future.error(AdbTransportException(fatal.toString()));
    if (_destroyed) {
      return Future.error(StateError('连接已关闭后仍被使用；close() 调用点：\n$_closedAt'));
    }
    final next = _tail.then((_) async {
      if (_destroyed) return;
      _socket.add(bytes);
      await _socket.flush();
    });
    // 链本身永不失败（否则一次失败会毒死后续所有帧）；失败只回给本次调用方。
    _tail = next.catchError((_) {});
    return next;
  }

  void _dispatch(AdbMessage m) {
    _traceIn(m);
    final cmd = m.command;
    if (cmd == AdbCommand.cnxn) {
      _properties
        ..clear()
        ..addAll(adbParseBanner(m.text));
      final f = _properties['features'];
      _features =
          f == null ? const [] : f.split(',').where((e) => e.isNotEmpty).toList();
      if (m.arg1 > 0) peerMaxData = m.arg1;
      final ready = _ready;
      if (ready != null && !ready.isCompleted) ready.complete();
      return;
    }
    if (cmd == AdbCommand.auth) {
      if (m.arg0 == AdbAuth.token) unawaited(_handleToken(m.payload));
      return;
    }
    if (cmd == AdbCommand.stls) {
      _failAll('对端要求 TLS（STLS）—— 这是 Android 11+「无线调试」的 TLS-PSK 模式，'
          '本工具只支持经典网络 adb。请先在目标机上用有线 adb 执行一次 '
          '`adb tcpip 5555`（重启失效），再用 ip:5555 连接');
      return;
    }
    if (cmd == AdbCommand.open) {
      // 没声明 reversed 特性，对端不该反向 OPEN
      _failAll('对端尝试反向 OPEN（本端不支持 reversed）');
      return;
    }
    // **对端发来的帧：arg0 是它自己的 id，arg1 才是我们的流 id**
    // （真机抓包：我们 `OPEN a0=8 a1=0` → 对端 `OKAY a0=406 a1=8`）。
    // 拿 arg0 查流会永远查不到，症状是"OPEN 后 8s 超时"——这条最容易想当然。
    final stream = _streams[m.arg1];
    if (stream == null) return; // 已关闭流的迟到帧：忽略
    if (cmd == AdbCommand.okay) {
      stream._onOkay(m.arg0); // arg0 = 对端 id
    } else if (cmd == AdbCommand.wrte) {
      stream._onData(m.payload);
      // 先投递再 ack（见文件头注释）；ack 不 await，避免读侧被写侧卡住。
      // 回程 OKAY 的 arg0/arg1 要反过来：我方 id 在前。
      unawaited(sendRaw(
              adbEncode(AdbMessage(AdbCommand.okay, stream.localId, m.arg0, Uint8List(0))))
          .catchError((_) {}));
    } else if (cmd == AdbCommand.clse) {
      stream._failClose('对端关闭流');
    }
  }

  Future<void> _handleToken(Uint8List token) async {
    final key = _key;
    if (key == null) return;
    if (_authStage == 0) {
      _authStage = 1;
      await sendRaw(adbEncode(
          AdbMessage(AdbCommand.auth, AdbAuth.signature, 0, key.signToken(token))));
      return;
    }
    if (_authStage == 1) {
      // adbd 又发 TOKEN = 不认这把钥匙 → 交公钥，目标机弹「允许 USB 调试」
      _authStage = 2;
      final blob = utf8.encode(key.publicKeyBase64());
      await sendRaw(adbEncode(AdbMessage(
          AdbCommand.auth, AdbAuth.rsaPublicKey, 0, Uint8List.fromList([...blob, 0]))));
      return;
    }
    _failAll('认证被拒绝：目标手机没有授权本机公钥。请在目标机上点「允许 USB 调试」，'
        '或在设置里导入它已信任的 adbkey 私钥');
  }

  /// 打开一路服务（`shell:` / `exec-out:` / `sync:` / `cmd:` …）。
  /// 打开一路服务。
  ///
  /// 只有在**还没收发过任何字节**时失败，上层才允许换另一条服务名重试
  /// （[AdbStream.started]）——半途失败重试等于把命令跑两遍。
  Future<AdbStream> open(String service) async {
    final id = _nextStreamId;
    _nextStreamId += 2;
    final s = AdbStream(this, id, service, 0)..opened = Completer<void>();
    _streams[id] = s;
    try {
      await sendRaw(adbEncode(AdbMessage(
          AdbCommand.open, id, 0, Uint8List.fromList([...utf8.encode(service), 0]))));
      await s.opened!.future.timeout(const Duration(seconds: 8));
    } on TimeoutException {
      dropStream(id);
      throw AdbTransportException('打开服务 "$service" 超时（对端 8s 内没回 OKAY）');
    } on AdbTransportException {
      dropStream(id);
      rethrow;
    }
    return s;
  }

  void dropStream(int id) => _streams.remove(id);

  bool _destroyed = false;
  StackTrace? _closedAt;

  Future<void> close() async {
    _closedAt = StackTrace.current; // 临时埋点：定位谁提前关了连接
    for (final s in _streams.values.toList()) {
      try {
        await s.close();
      } catch (_) {}
    }
    _streams.clear();
    await _sub?.cancel();
    _destroyed = true;
    try {
      _socket.destroy();
    } catch (_) {}
  }
}
