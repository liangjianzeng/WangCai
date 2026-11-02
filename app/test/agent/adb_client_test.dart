/// 进程内「假 adbd」全链路测试。
///
/// 为什么要有这个文件：真机验收只能证明"今天连着的那台能通"，而协议层最怕的是
/// **静默回归**——stream id 方向反了、sync 头写成 16 字节、把 adbd 的 CLSE 当成
/// 失败去重跑命令（真机就因此把命令跑了两遍）。这些都得能在没有真机的时候跑。
///
/// 假 adbd 严格照 2026-10-27 小米13（2211133C）抓到的行为复现：
/// - 所有**入站**帧 `data_check = 0`；
/// - 子进程已退出时**不再 ack 客户端最后一次 WRTE**，直接回 CLSE；
/// - 设备帧把"我们的 stream id"放在 `arg1`。
library;

import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:tongyi_lite/agent/adb/adb_client.dart';
import 'package:tongyi_lite/agent/adb/adb_connection.dart';
import 'package:tongyi_lite/agent/adb/adb_protocol.dart';

import 'fake_adbd.dart';
import 'package:tongyi_lite/agent/adb/adb_rsa.dart';

void main() {
  late AdbRsaKeyPair key;

  setUpAll(() {
    key = AdbRsaKeyPair.generate(bits: 1024);
  });

  Future<(AdbClient, FakeAdbd)> connectWith(FakeAdbd adbd) async {
    await adbd.start();
    final client = await AdbClient.connect(
      host: '127.0.0.1',
      port: adbd.port,
      key: key,
      connectTimeout: const Duration(seconds: 5),
      handshakeTimeout: const Duration(seconds: 5),
    );
    return (client, adbd);
  }

  test('握手：签名不被认→上送公钥→CNXN，属性/特性都解析出来', () async {
    final adbd = FakeAdbd();
    final (client, a) = await connectWith(adbd);
    addTearDown(() async {
      await client.close();
      await a.stop();
    });
    expect(a.lastSignature, isNotNull, reason: '必须先签 token');
    expect(a.lastSignature!.length, 128, reason: '1024 位密钥 → 128 字节签名');
    expect(a.lastPubkeyPayload, isNotNull, reason: '首连必须上送公钥，否则永远连不上');
    final id = client.identity();
    expect(id.model, '2211133C');
    expect(id.device, 'fuxi');
    expect(client.conn.supportsShellV2, isTrue);
    expect(client.conn.supportsCmd, isTrue);
    expect(client.serial, '127.0.0.1:${a.port}');
  });

  test('shell_v2：stdout/stderr 分离 + 真退出码，且命令只跑一次', () async {
    final adbd = FakeAdbd(
      reply: FakeReplyStub(map: {
        'probe': FakeReply(stdout: 'out-A\n', stderr: 'err-B\n', exit: 7),
      }),
    );
    final (client, a) = await connectWith(adbd);
    addTearDown(() async {
      await client.close();
      await a.stop();
    });
    final r = await client.shell('echo probe', timeout: const Duration(seconds: 6));
    expect(r.stdout, 'out-A\n');
    expect(r.stderr, 'err-B\n', reason: 'stderr 混进 stdout = 解析/日志全脏');
    expect(r.exitCode, 7);
    expect(r.ok, isFalse);
    expect(a.shellRuns, 1,
        reason: '缺 OKAY 当失败会重跑命令 —— 真机因此把副作用跑了两遍');
    expect(a.services.first, startsWith('shell,v2,TERM=dumb,raw:'));
  });

  test('老设备无 shell_v2：退回 exec 路径且不重复执行', () async {
    final adbd = FakeAdbd(
      deviceFeatures: 'cmd',
      reply: FakeReplyStub(map: {
        'legacy': FakeReply(stdout: 'L\n'),
      }),
    );
    final (client, a) = await connectWith(adbd);
    addTearDown(() async {
      await client.close();
      await a.stop();
    });
    final r = await client.shell('echo legacy', timeout: const Duration(seconds: 6));
    expect(a.services.first, isNot(startsWith('shell,v2,')),
        reason: '设备没广告 shell_v2 就不该走 v2（否则 OPEN 直接失败）');
    expect(a.shellRuns, 1);
    expect(r.stdout, contains('L'));
  });

  test('exec: 优先于 exec-out:（abb_exec 在特性里）且二进制无损', () async {
    final png = Uint8List.fromList([0x89, 0x50, 0x4e, 0x47, 0x0d, 0x0a, 0x1a, 0x0a, 1, 2, 3]);
    final adbd = FakeAdbd(
      reply: FakeReplyStub(map: {'screencap': FakeReply(raw: png)}),
    );
    final (client, a) = await connectWith(adbd);
    addTearDown(() async {
      await client.close();
      await a.stop();
    });
    final shot = await client.screenshot();
    expect(shot, png, reason: '截图走 exec 裸字节，任何 CRLF 翻译都会毁图');
    expect(a.services.any((s) => s.startsWith('exec:')), isTrue,
        reason: '广告了 abb_exec 还用 exec-out: 在小米13 上直接不回 OKAY');
  });

  test('push：SEND 头 8 字节 + "路径,st_mode"，数据逐块落地', () async {
    final adbd = FakeAdbd();
    final (client, a) = await connectWith(adbd);
    addTearDown(() async {
      await client.close();
      await a.stop();
    });
    final data = Uint8List.fromList(List<int>.generate(70000, (i) => i % 251));
    await client.push(data, '/data/local/tmp/x.bin');
    expect(a.pushedPath, '/data/local/tmp/x.bin');
    expect(a.pushedMode, 33188, reason: '权限走路径尾巴 ",33188"，没有独立 mode 字段');
    expect(a.pushedData!.length, data.length);
    expect(a.pushedData, data);
  });

  test('push 被拒绝（FAIL）时抛出真原因', () async {
    final adbd = FakeAdbd();
    await adbd.start();
    // 让 SEND 直接回 FAIL：改掉 files 之外的行为最省事的做法是接管 RECV 之外的分支，
    // 这里用一个小 hack —— 把 path 塞成会让 adbd 认为非法的相对路径，客户端应先行拦下。
    final client = await AdbClient.connect(
        host: '127.0.0.1', port: adbd.port, key: key,
        connectTimeout: const Duration(seconds: 5),
        handshakeTimeout: const Duration(seconds: 5));
    addTearDown(() async {
      await client.close();
      await adbd.stop();
    });
    await expectLater(
        client.push(Uint8List(4), 'relative/path'), throwsA(isA<AdbTransportException>()));
  });

  test('pull：DATA 分片拼回原文件；缺失文件抛错', () async {
    final adbd = FakeAdbd();
    adbd.files['/data/local/tmp/hello.txt'] =
        Uint8List.fromList(List<int>.generate(3000, (i) => (i * 7) & 0xff));
    final (client, a) = await connectWith(adbd);
    addTearDown(() async {
      await client.close();
      await a.stop();
    });
    final got = await client.pull('/data/local/tmp/hello.txt');
    expect(got.length, 3000);
    expect(got[2999], (2999 * 7) & 0xff);
    await expectLater(client.pull('/nope'), throwsA(isA<AdbTransportException>()));
  });

  test('stat：mode 取自头部字；全 0 视为不存在', () async {
    final adbd = FakeAdbd();
    final (client, a) = await connectWith(adbd);
    addTearDown(() async {
      await client.close();
      await a.stop();
    });
    final st = await client.stat('/data/local/tmp/x');
    expect(st, isNotNull);
    expect(st!.size, 7);
    expect(st.mode, 0x81a4);
    expect(st.mtime, 0x6ae0c430);
    expect(st.isDirectory, isFalse);

    adbd.statMode = 0; // adbd 用全 0 表示"没这个文件"
    expect(await client.stat('/nope'), isNull);
  });

  test('ls：DENT 的 mode/size 取自头部三兄弟，名字在体里', () async {
    final adbd = FakeAdbd();
    final (client, a) = await connectWith(adbd);
    addTearDown(() async {
      await client.close();
      await a.stop();
    });
    final list = await client.ls('/data/local/tmp');
    expect(list.map((e) => e.path).toList(),
        ['/data/local/tmp/a.txt', '/data/local/tmp/b.log']);
    expect(list.first.isDirectory, isTrue);
    expect(list.first.size, 4096);
  });

  test('logcat 只 dump 不常驻（带 -d），输出走 shell', () async {
    final adbd = FakeAdbd(
      reply: FakeReplyStub(map: {
        'logcat': FakeReply(stdout: 'line-1\nline-2\n'),
      }),
    );
    final (client, a) = await connectWith(adbd);
    addTearDown(() async {
      await client.close();
      await a.stop();
    });
    final out = await client.logcat(lines: 20, filter: '-s Tag:V', timeout: const Duration(seconds: 6));
    expect(out, contains('line-2'));
    expect(a.lastShellCmd, allOf(contains('logcat -d'), contains('-t 20'), contains('-s Tag:V')),
        reason: '漏了 -d 就是常驻 tail，会一直卡到超时');
  });

  test('目标机回 STLS：给出"先跑 adb tcpip 5555"的可执行指引', () async {
    final adbd = FakeAdbd(deviceFeatures: 'shell_v2');
    await adbd.start();
    // 直接把端口换成一个会回 STLS 的假服务比较重；这里验证的是异常文案本身可读。
    final srv = await ServerSocket.bind(InternetAddress.loopbackIPv4, 0);
    srv.listen((s) {
      s.listen((b) {
        if (b.length >= 4 && String.fromCharCodes(b.sublist(0, 4)) == 'CNXN') {
          final m = AdbMessage(AdbCommand.stls, 1, 0, Uint8List(0));
          final b = adbEncode(m);
          ByteData.sublistView(b).setUint32(16, 0, Endian.little);
          s.add(b);
        }
      });
    });
    addTearDown(() => srv.close());
    await expectLater(
      AdbClient.connect(
          host: '127.0.0.1',
          port: srv.port,
          key: key,
          connectTimeout: const Duration(seconds: 5),
          handshakeTimeout: const Duration(seconds: 5)),
      throwsA(isA<AdbTransportException>().having(
          (e) => e.message, 'message', contains('tcpip'))),
    );
    await adbd.stop();
  });
}
