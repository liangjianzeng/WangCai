/// 进程内假 adbd —— ADB 协议/客户端/工具三层共用的测试夹具。
///
/// 严格照 2026-10-27 小米13（2211133C）抓到的行为复现：
/// - 所有**入站**帧 `data_check = 0`；
/// - 子进程已退出时**不再 ack 客户端最后一次 WRTE**，直接回 CLSE；
/// - 设备帧把"我们的 stream id"放在 `arg1`（host→device 则相反，arg0 是本地 id）；
/// - sync 回复按 id 变长度（STAT 16B / DENT 20B+名 / OKAY、DONE 8B）。
library;

import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:tongyi_lite/agent/adb/adb_protocol.dart';

/// 假 adbd 对一条 shell 命令的答复（真机口径：stdout/stderr/exit 分帧）。
class FakeReply {
  FakeReply({this.stdout = '', this.stderr = '', this.exit = 0, this.raw});
  final String stdout;
  final String stderr;
  final int exit;

  /// 非空则走 exec/exec-out 的裸字节路径（截图那种二进制安全场景）。
  final List<int>? raw;
}

class FakeAdbd {
  FakeAdbd({
    FakeReplyStub? reply,
    this.deviceFeatures = 'shell_v2,cmd,abb_exec,stat_v2',
    this.requirePubkey = true,
    this.model = '2211133C',
  }) : reply = reply ?? FakeReplyStub();

  /// 命令 → 答复；未命中返回 stdout="OK"。
  final FakeReplyStub reply;
  final String deviceFeatures;

  /// true = 第一次签名不认（模拟首次连接），必须收到 AUTH(RSAPUBLICKEY) 才放行。
  final bool requirePubkey;
  final String model;

  final Uint8List token =
      Uint8List.fromList(List<int>.generate(20, (i) => (i * 13 + 1) & 0xff));

  ServerSocket? _srv;
  Socket? _sock;
  int get port => _srv!.port;

  /// 观测点（断言用）
  final List<String> services = [];
  int shellRuns = 0;
  String? lastShellCmd;
  Uint8List? pushedData;
  String? pushedPath;
  int? pushedMode;
  List<int>? lastPubkeyPayload;
  List<int>? lastSignature;
  bool sawOkayForCloseStdin = false;

  /// sync 侧数据（pull / stat / ls 用）
  final Map<String, Uint8List> files = {};
  int statMode = 0x81a4; // 0o100644
  int statSize = 7;
  int statMtime = 0x6ae0c430;
  List<String> dirEntries = const ['a.txt', 'b.log'];

  Future<void> start() async {
    _srv = await ServerSocket.bind(InternetAddress.loopbackIPv4, 0);
    _srv!.listen((sock) {
      _sock = sock;
      final buf = BytesBuilder(copy: true);
      sock.listen((bytes) {
        buf.add(bytes);
        _drain(sock, buf);
      }, onError: (_) {}, onDone: () {});
    });
  }

  Future<void> stop() async {
    try {
      _sock?.destroy();
    } catch (_) {}
    await _srv?.close();
  }

  void _send(Socket s, AdbMessage m) {
    // 真机 adbd 的入站帧 data_check 恒 0（magic 仍为 ~command）—— 这里必须照抄，
    // 否则就测不到"我方按校验和判等 → 一条帧都收不下"那个坑。
    final bytes = adbEncode(m);
    ByteData.sublistView(bytes).setUint32(16, 0, Endian.little);
    expect(ByteData.sublistView(bytes).getUint32(16, Endian.little), 0,
        reason: '假 adbd 必须像真机一样不发校验和');
    s.add(bytes);
  }

  void _sendSync(Socket s, int localId, int peerId, List<int> payload) {
    _send(s, AdbMessage(AdbCommand.wrte, peerId, localId, Uint8List.fromList(payload)));
  }

  void _drain(Socket sock, BytesBuilder builder) {
    var bytes = builder.toBytes();
    builder.clear();
    while (true) {
      final dec = adbTryDecode(bytes);
      if (dec == null) break;
      bytes = bytes.sublist(dec.consumed);
      _handle(sock, dec.message);
    }
    if (bytes.isNotEmpty) builder.add(bytes);
  }

  void _handle(Socket sock, AdbMessage m) {
    switch (m.command) {
      case AdbCommand.cnxn:
        _send(sock, AdbMessage.create(AdbCommand.auth, AdbAuth.token, 0, token));
        break;
      case AdbCommand.auth:
        if (m.arg0 == AdbAuth.signature) {
          lastSignature = m.payload;
          if (!requirePubkey) {
            _cnxnOk(sock);
          } else {
            // 真机首次连接：签名不认 → 再要一次 token → 客户端上送公钥
            _send(sock, AdbMessage.create(AdbCommand.auth, AdbAuth.token, 0, token));
          }
        } else if (m.arg0 == AdbAuth.rsaPublicKey) {
          lastPubkeyPayload = m.payload;
          _cnxnOk(sock);
        }
        break;
      case AdbCommand.open:
        _serve(sock, m);
        break;
      case AdbCommand.wrte:
        _onHostWrite(sock, m);
        break;
      case AdbCommand.okay:
      case AdbCommand.clse:
        break; // 对端确认，假 adbd 不关心
    }
  }

  void _cnxnOk(Socket sock) {
    final banner = 'device::ro.product.model=$model;ro.product.device=fuxi;'
        'ro.product.name=fuxi;features=$deviceFeatures;';
    _send(sock,
        AdbMessage.create(AdbCommand.cnxn, kAdbVersion, 1024 * 1024, utf8.encode(banner)));
  }

  // 一条 sync / shell 流的状态
  final Map<int, _FakeStream> _streams = {};

  void _serve(Socket sock, AdbMessage open) {
    final hostId = open.arg0;
    final service = open.text;
    final peerId = 400 + hostId;
    services.add(service);
    _send(sock, AdbMessage(AdbCommand.okay, peerId, hostId, Uint8List(0)));

    final st = _FakeStream(hostId, peerId);
    _streams[hostId] = st;
    if (service.startsWith('shell,v2,')) {
      st.kind = 'shell_v2';
      st.cmd = _deNull(service.substring(service.indexOf('raw:') + 4));
      shellRuns++;
      lastShellCmd = st.cmd;
    } else if (service.startsWith('exec:') || service.startsWith('exec-out:')) {
      st.kind = 'exec';
      st.cmd = _deNull(service.substring(service.indexOf(':') + 1));
      shellRuns++;
      lastShellCmd = st.cmd;
    } else if (service.startsWith('sync:')) {
      // 服务名带结尾 NUL（text 不剥），用 == 会比不中 —— sync 全军覆没过一次。
      st.kind = 'sync';
    } else if (service.startsWith('cmd:')) {
      st.kind = 'cmd';
      st.cmd = _deNull(service.substring(4));
      shellRuns++;
      lastShellCmd = st.cmd;
    }
    // exec/exec-out 没有 stdin 语义：OPEN 之后直接答复。
    if (st.kind == 'exec') _replyShell(sock, st);
  }

  void _onHostWrite(Socket sock, AdbMessage m) {
    // 方向定案：**host→device 帧的 arg0 才是我们的 local id**（device→host 反之，
    // 见 AdbConnection._dispatch 用 arg1 查表）。这里搞反就是"永远收不到写入"。
    final st = _streams[m.arg0];
    if (st == null) return;
    st.inbound.add(m.payload);
    switch (st.kind) {
      case 'shell_v2':
      case 'cmd':
        // 真机定案：客户端发 CLOSE_STDIN 时子进程往往已经退出，adbd **不再回 OKAY**，
        // 直接 CLSE。这里照抄，钉死"把缺 OKAY 当失败 → 重跑命令"那个事故。
        final packets = ShellPacketDecoder().feed(st.inbound.toBytes());
        st.inbound.clear();
        if (packets.any((p) => p.id == ShellPacketId.closeStdin)) {
          _replyShell(sock, st);
        }
        break;
      case 'exec':
        // exec 无 stdin 语义，收到任何写入都算"命令已发起"
        break;
      case 'sync':
        // adbd 对 sync 流上的每次 WRTE 都回 OKAY（shell 尾部才不回，见上）。
        // 缺了这一条，客户端 push 的 stop-and-wait 会一直等满 ackTimeout。
        _send(sock, AdbMessage(AdbCommand.okay, st.peerId, st.hostId, Uint8List(0)));
        _onSyncBytes(sock, st);
        break;
    }
  }

  void _replyShell(Socket sock, _FakeStream st) {
    final r = reply.forCommand(st.cmd ?? '');
    if (st.kind == 'exec') {
      final body = Uint8List.fromList(r.raw ?? utf8.encode(r.stdout));
      _send(sock, AdbMessage(AdbCommand.wrte, st.peerId, st.hostId, body));
    } else {
      final out = BytesBuilder(copy: false);
      if ((r.stdout).isNotEmpty) {
        out.add(shellPacketEncode(ShellPacketId.stdout, utf8.encode(r.stdout)));
      }
      if ((r.stderr).isNotEmpty) {
        out.add(shellPacketEncode(ShellPacketId.stderr, utf8.encode(r.stderr)));
      }
      out.add(shellPacketEncode(ShellPacketId.exit, [r.exit & 0xff]));
      _send(sock, AdbMessage(AdbCommand.wrte, st.peerId, st.hostId, out.toBytes()));
    }
    _send(sock, AdbMessage(AdbCommand.clse, st.peerId, st.hostId, Uint8List(0)));
  }

  final BytesBuilder _syncPending = BytesBuilder(copy: true);

  void _onSyncBytes(Socket sock, _FakeStream st) {
    // sync 流上的 WRTE 载荷是拼接的字节流，可能半帧 —— 累积后再解。
    final pending = _syncPending.toBytes();
    _syncPending.clear();
    final all = Uint8List.fromList([...pending, ...st.inbound.toBytes()]);
    st.inbound.clear();
    var off = 0;
    while (off + 8 <= all.length) {
      final head = syncTryDecodeReplyHeader(all.sublist(off, off + 8));
      if (head == null) break;
      // 请求侧 a0 的含义随 id 变：SEND/RECV/LIST/STAT = 路径长，DATA = 数据长；
      // DONE(a0=mtime)/OKAY/QUIT 没有体 —— 当成体长就会把数据整段吃掉。
      final bodyLen = const {'SEND', 'RECV', 'LIST', 'STAT', 'DATA'}.contains(head.id)
          ? head.a0
          : 0;
      if (off + 8 + bodyLen > all.length) break;
      final body = all.sublist(off + 8, off + 8 + bodyLen);
      off += 8 + bodyLen;
      _onSyncMsg(sock, st, head.id, head.a0, body);
    }
    if (off < all.length) _syncPending.add(all.sublist(off));
  }

  void _onSyncMsg(Socket sock, _FakeStream st, String id, int a0, List<int> body) {
    switch (id) {
      case 'SEND':
        final spec = utf8.decode(body, allowMalformed: true);
        final comma = spec.lastIndexOf(',');
        pushedPath = comma < 0 ? spec : spec.substring(0, comma);
        pushedMode = comma < 0 ? null : int.tryParse(spec.substring(comma + 1));
        pushedData = Uint8List(0);
        _sendSync(sock, st.hostId, st.peerId, syncEncode(SyncMessage.create('OKAY', 0)));
        break;
      case 'DATA':
        final prev = pushedData ?? Uint8List(0);
        pushedData = Uint8List.fromList([...prev, ...body]);
        _sendSync(sock, st.hostId, st.peerId, syncEncode(SyncMessage.create('OKAY', 0)));
        break;
      case 'DONE':
        _sendSync(sock, st.hostId, st.peerId, syncEncode(SyncMessage.create('OKAY', 0)));
        break;
      case 'RECV':
        final path = utf8.decode(body, allowMalformed: true);
        final data = files[path];
        if (data == null) {
          final msg = utf8.encode('No such file or directory');
          _sendSync(sock, st.hostId, st.peerId,
              syncEncode(SyncMessage.create('FAIL', msg.length, msg)));
        } else {
          for (var off = 0; off < data.length; off += 1024) {
            final end = off + 1024 > data.length ? data.length : off + 1024;
            final chunk = data.sublist(off, end);
            _sendSync(
                sock, st.hostId, st.peerId, syncEncode(SyncMessage.create('DATA', chunk.length, chunk)));
          }
          _sendSync(sock, st.hostId, st.peerId, syncEncode(SyncMessage.create('DONE', 0)));
        }
        break;
      case 'STAT':
        // 真机定案：STAT 回复总长 16 字节 = id|mode|size|mtime，mode 落在头部字 a0。
        _sendSync(sock, st.hostId, st.peerId,
            syncEncode(SyncMessage.create('STAT', statMode, [..._u32(statSize), ..._u32(statMtime)])));
        break;
      case 'LIST':
        // DENT：头部 id + a0(=名字长度)，体 = mode|size|mtime|名字（20B + 名字）。
        for (final name in dirEntries) {
          final nb = utf8.encode(name);
          _sendSync(
              sock,
              st.hostId,
              st.peerId,
              syncEncode(SyncMessage.create('DENT', nb.length, [
                ..._u32(0x4000 | 0x1ff),
                ..._u32(4096),
                ..._u32(statMtime),
                ...nb,
              ])));
        }
        _sendSync(sock, st.hostId, st.peerId, syncEncode(SyncMessage.create('DONE', 0)));
        break;
      case 'QUIT':
        _send(sock, AdbMessage(AdbCommand.clse, st.peerId, st.hostId, Uint8List(0)));
        break;
    }
  }
}

/// 命令 → 答复的桩。
class FakeReplyStub {
  FakeReplyStub({this.map = const {}, FakeReply? def}) : def = def ?? FakeReply(stdout: 'OK\n');
  final Map<String, FakeReply> map;
  final FakeReply def;
  FakeReply forCommand(String cmd) {
    for (final e in map.entries) {
      if (cmd.contains(e.key)) return e.value;
    }
    return def;
  }
}

/// 服务名以 \0 结尾（AdbMessage.text 不剥 NUL），记录时按真机 adbd 的做法剥掉。
String _deNull(String s) {
  var end = s.length;
  while (end > 0 && s.codeUnitAt(end - 1) == 0) {
    end--;
  }
  return s.substring(0, end);
}

List<int> _u32(int v) =>
    (ByteData(4)..setUint32(0, v, Endian.little)).buffer.asUint8List();

class _FakeStream {
  _FakeStream(this.hostId, this.peerId);
  final int hostId;
  final int peerId;
  String kind = '';
  String? cmd;
  final BytesBuilder inbound = BytesBuilder(copy: true);
}

