/// ADB 协议层单测 —— **全部用真机抓到的字节当向量**（小米13 / adbd，2026-10-27）。
///
/// 这些向量的价值在于"不许再靠猜"：协议层三条 bug（入站校验和、stream id 方向、
/// shell_v2 子帧 id）都是靠真机取证才定案的，回归必须钉死在同一批字节上。
library;

import 'dart:convert';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:tongyi_lite/agent/adb/adb_protocol.dart';

/// 真机抓到的 AUTH 帧头（adbd 的 data_check 恒 0，见 adbTryDecode 注释）。
const String kRealAuthHeader =
    '41555448' '01000000' '00000000' '14000000' '00000000' 'beaaabb7';

/// 真机 shell_v2 三合一 WRTE 载荷：STDOUT"out-A\n" + STDERR"err-B\n" + EXIT 7。
const String kRealShellTriple = '0106000000' '6f75742d410a' //
    '0206000000' '6572722d420a' //
    '0301000000' '07';

/// 真机 `adb push` 抓到的 SEND + DATA 前缀。
const String kRealSendFrame =
    '53454e44' '23000000' '2f646174612f6c6f63616c2f746d702f6d69746d5f707573682e62696e2c3333313838';

Uint8List _hex(String s) => Uint8List.fromList(
    RegExp(r'..').allMatches(s).map((m) => int.parse(m.group(0)!, radix: 16)).toList());

void main() {
  group('帧编解码', () {
    test('fourcc / commandName / 校验和', () {
      expect(fourcc('CNXN'), 0x4e584e43); // 小端：'C' 在最低位
      expect(commandName(AdbCommand.okay), 'OKAY');
      expect(adbChecksum(Uint8List(0)), 0);
      // 定义就是逐字节累加 mod 2^32：'OKAY' = 79+75+65+89
      expect(adbChecksum(utf8.encode('OKAY')), 308);
    });

    test('adbEncode 的 magic = ~command，且可被 adbTryDecode 收回', () {
      final bytes = adbEncode(
          AdbMessage.create(AdbCommand.open, 8, 0, utf8.encode('shell:\x00')));
      final dec = adbTryDecode(bytes, requireChecksum: true);
      expect(dec, isNotNull);
      final back = dec!.message;
      expect(back.command, AdbCommand.open);
      expect(back.arg0, 8);
      // magic 恒为 ~command（AdbMessage 不存它，编码时算）——改从线上验：
      expect(ByteData.sublistView(bytes).getUint32(20, Endian.little),
          0xffffffff & ~AdbCommand.open);
      expect(back.text, 'shell:\x00', reason: 'text 不剥 NUL，服务名字符串原样可见');
      expect(dec.consumed, bytes.length);
    });

    test('真机 AUTH 帧：data_check=0 必须能解（入站不校校验和）', () {
      final header = _hex(kRealAuthHeader);
      final full = Uint8List.fromList([...header, ...List.filled(20, 0x11)]);
      final dec = adbTryDecode(full);
      expect(dec, isNotNull, reason: 'adbd 的 data_check 恒 0，若按校验和判等会全线连不上');
      final m = dec!.message;
      expect(m.command, AdbCommand.auth);
      expect(m.arg0, AdbAuth.token);
      expect(m.payload.length, 20);
      expect(dec.consumed, full.length);
      // check==0 一律视为"未提供"，所以连 requireChecksum=true 也必须放行 ——
      // 这条就是"入站永不校验和"的实现落点。
      expect(adbTryDecode(full, requireChecksum: true), isNotNull);
      // 反向：带**非零错误**校验和的帧必须被抓出来（我方出站帧的自我一致性检查靠它）。
      final bad = Uint8List.fromList(full);
      ByteData.sublistView(bad).setUint32(16, 0xdeadbeef, Endian.little);
      expect(() => adbTryDecode(bad, requireChecksum: true),
          throwsA(isA<AdbProtocolException>()));
    });

    test('magic 不符 / 长度超限 = 抛（流已跑偏）；不足一帧 = null（继续等）', () {
      final good = adbEncode(AdbMessage.create(AdbCommand.cnxn, 1, 2, utf8.encode('hi')));
      final broken = Uint8List.fromList(adbEncode(AdbMessage.create(AdbCommand.cnxn, 1, 2, utf8.encode('hi'))))..[20] ^= 0xff; // 改 magic
      expect(() => adbTryDecode(broken), throwsA(isA<AdbProtocolException>()),
          reason: 'magic 不匹配说明字节流跑偏，必须炸给上层重连，不能当"还没收够"');
      final short = Uint8List.fromList(good.sublist(0, 23));
      expect(adbTryDecode(short), isNull);
      final huge = Uint8List.fromList(
          adbEncode(AdbMessage(AdbCommand.wrte, 1, 2, Uint8List(0))));
      ByteData.sublistView(huge).setUint32(12, 8 * 1024 * 1024, Endian.little);
      expect(() => adbTryDecode(huge), throwsA(isA<AdbProtocolException>()),
          reason: '超限必须拒绝，防被脏长度拖爆内存');
    });

    test('payload 不是合法 UTF-8 时 .text 不抛（截图类二进制绝不能用 .text）', () {
      final m = AdbMessage(AdbCommand.wrte, 1, 2, Uint8List.fromList([0xff, 0xfe, 0x00]));
      expect(() => m.text, returnsNormally);
    });
  });

  group('shell_v2 子帧', () {
    test('子帧 id 按真机取证（stdin=0 stdout=1 stderr=2 exit=3 closeStdin=4）', () {
      expect(ShellPacketId.stdin, 0);
      expect(ShellPacketId.stdout, 1);
      expect(ShellPacketId.stderr, 2);
      expect(ShellPacketId.exit, 3);
      expect(ShellPacketId.closeStdin, 4);
      expect(kShellPacketHeaderSize, 5);
    });

    test('真机三合一载荷解出 stdout/stderr/exit', () {
      final ps = ShellPacketDecoder().feed(_hex(kRealShellTriple));
      expect(ps.length, 3);
      expect(ps[0].id, ShellPacketId.stdout);
      expect(utf8.decode(ps[0].payload), 'out-A\n');
      expect(ps[1].id, ShellPacketId.stderr);
      expect(utf8.decode(ps[1].payload), 'err-B\n');
      expect(ps[2].id, ShellPacketId.exit);
      expect(ps[2].exitCode, 7, reason: '退出码丢了 = 上层无法判断命令成败（真机踩过）');
    });

    test('跨 TCP 分片累积（半帧不许丢也不许提前解）', () {
      final all = _hex(kRealShellTriple);
      final dec = ShellPacketDecoder();
      expect(dec.feed(all.sublist(0, 3)), isEmpty);
      expect(dec.feed(all.sublist(3, 11)).map((p) => p.id).toList(), [1]);
      expect(dec.feed(all.sublist(11)).length, 2);
      expect(dec.feed(Uint8List(0)), isEmpty);
    });

    test('closeStdin 编码 = 04 00000000（真机抓到的正是这 5 字节）', () {
      expect(
          shellPacketEncode(ShellPacketId.closeStdin)
              .map((b) => b.toRadixString(16).padLeft(2, '0'))
              .join(),
          '0400000000');
    });

    test('子帧长度超上限抛协议异常（脏长度不许当长度用）', () {
      final bad = Uint8List(6)..[0] = ShellPacketId.stdout;
      ByteData.sublistView(bad).setUint32(1, 0x7fffffff, Endian.little);
      expect(() => ShellPacketDecoder().feed(bad),
          throwsA(isA<AdbProtocolException>()));
    });
  });

  group('sync 子协议', () {
    test('SEND 是 8 字节头 + "路径,st_mode"（真机取证，不是 16 字节头）', () {
      final enc = syncEncode(SyncMessage.create(
          'SEND', 35, utf8.encode('/data/local/tmp/mitm_push.bin,33188')));
      expect(
          enc.map((b) => b.toRadixString(16).padLeft(2, '0')).join(), kRealSendFrame);
      expect(enc.length, 8 + 35);
    });

    test('QUIT = 8 字节（真机 adb 发的是 51554954 + 4 个 0）', () {
      final q = syncEncodeQuit();
      expect(q.length, 8);
      expect(utf8.decode(q.sublist(0, 4)), 'QUIT');
    });

    test('DATA 头带长度，体紧随其后', () {
      final d = syncEncode(SyncMessage.create('DATA', 3, [1, 2, 3]));
      expect(utf8.decode(d.sublist(0, 4)), 'DATA');
      expect(ByteData.sublistView(d).getUint32(4, Endian.little), 3);
      expect(d.sublist(8), [1, 2, 3]);
    });

    test('回复头解析（8 字节：id + u32）', () {
      final h = syncTryDecodeReplyHeader(_hex('53544154f9410000'))!;
      expect(h.id, 'STAT');
      expect(h.a0, 0x41f9, reason: 'STAT 的 mode 就落在头部 a0');
      expect(syncTryDecodeReplyHeader([1, 2, 3]), isNull);
    });

    test('权限常量：0644 push 后拼出的 st_mode = 33188（与真机 adb 一致）', () {
      expect(kSyncModeFile, 0x1a4);
      expect(0x8000 | kSyncModeFile, 33188);
    });
  });

  group('横幅解析', () {
    test('host::features= 与 device:: 前缀都要剥掉', () {
      final device = adbParseBanner(
          'device::ro.product.name=fuxi;ro.product.model=2211133C;ro.product.device=fuxi;');
      expect(device['ro.product.model'], '2211133C');
      expect(device['ro.product.device'], 'fuxi');
      // 早期只剥 host:: → properties 全 null（真机踩过：型号一律显示不出来）
      expect(device.containsKey('device::ro.product.name'), isFalse);

      final host = adbParseBanner('host::features=shell_v2,cmd,stat_v2');
      expect(host['features'], 'shell_v2,cmd,stat_v2');
      expect(adbParseBanner('ro.build.version.sdk=33')['ro.build.version.sdk'], '33');
    });

    test('kAdbBanner 只广告真实现的能力', () {
      // 广告 stat_v2/ls_v2 会让 adbd 用 v2 结构回话，v1 解包直接错位（真机踩过）。
      expect(kAdbBanner, isNot(contains('stat_v2')));
      expect(kAdbBanner, isNot(contains('ls_v2')));
      expect(kAdbBanner, contains('shell_v2'));
    });
  });
}
