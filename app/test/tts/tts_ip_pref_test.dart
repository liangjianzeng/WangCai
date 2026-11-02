import 'dart:convert' show utf8;
import 'dart:io';

import 'package:edge_tts/edge_tts.dart';
import 'package:flutter_test/flutter_test.dart';

/// IPv4 优先连接策略（vendored edge_tts 的本地加固）+ connectionFactory 契约回归。
///
/// 背景 1：手机所在网络的 IPv6 到 speech.platform.bing.com 是半死通道——TCP 连得上、
/// TLS 握手被 RST（实测手机 `curl -6` = 000、`curl -4` = 200）。dart:io 只在 TCP
/// 连接失败时才换下一个地址，TLS 阶段失败**不回退**，于是「PC 正常、手机全哑」。
///
/// 背景 2（本组测试的真正价值）：设了 connectionFactory 之后 dart:io **不再自己做
/// TLS 升级**，且直连时工厂只拿到 `cf(uri, null, null)`、wss 改写后的 `uri.port`
/// 还是 0。这两个坑的现场表现都是「TTS 静默超时」，必须在本地起服务把它们钉住。
void main() {
  InternetAddress ip4(String a) =>
      InternetAddress(a, type: InternetAddressType.IPv4);
  InternetAddress ip6(String a) =>
      InternetAddress(a, type: InternetAddressType.IPv6);

  group('地址族排序', () {
    test('IPv6 在前也重排成 IPv4 优先（组内保持原序）', () {
      final ordered = orderAddressesPreferIPv4([
        ip6('2620:1ec:33::10'),
        ip4('150.171.27.10'),
        ip6('2620:1ec:33:1::10'),
        ip4('150.171.28.10'),
      ]);
      expect(
        ordered.map((a) => a.address),
        ['150.171.27.10', '150.171.28.10', '2620:1ec:33::10', '2620:1ec:33:1::10'],
      );
    });

    test('全 IPv4 / 全 IPv6 / 空表都不改变可用性（IPv6-only 网络仍可连）', () {
      expect(orderAddressesPreferIPv4([ip4('1.1.1.1'), ip4('2.2.2.2')])
          .map((a) => a.address), ['1.1.1.1', '2.2.2.2']);
      expect(orderAddressesPreferIPv4([ip6('::1'), ip6('fe80::1')])
          .map((a) => a.address), ['::1', 'fe80::1']);
      expect(orderAddressesPreferIPv4(const []), isEmpty);
    });
  });

  group('effectivePort（复刻 dart:io 的端口归一化）', () {
    test('wss→https 改写后 port=0 必须补成 443，http 补 80', () {
      expect(effectivePort(Uri.parse('https://speech.platform.bing.com/x')), 443);
      expect(effectivePort(Uri.parse('http://example.com/x')), 80);
    });

    test('显式端口与代理端口优先', () {
      expect(effectivePort(Uri.parse('https://example.com:8443/x')), 8443);
      expect(effectivePort(Uri.parse('https://example.com/x'), proxyPort: 3128), 3128);
    });
  });

  group('connectionFactory 端到端（本地服务，绝不联网）', () {
    late HttpServer server;
    late int port;

    setUp(() async {
      server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
      port = server.port;
      server.listen((req) async {
        if (WebSocketTransformer.isUpgradeRequest(req)) {
          final ws = await WebSocketTransformer.upgrade(req);
          ws.listen((msg) => ws.add('echo:$msg'), onDone: () => ws.close());
        } else {
          req.response
            ..statusCode = 200
            ..headers.contentType = ContentType.json
            ..write('{"ok":true}');
          await req.response.close();
        }
      });
    });

    tearDown(() async => server.close(force: true));

    for (final prefer in [true, false]) {
      test('preferIPv4=$prefer：HTTP GET 与 WebSocket upgrade 都走得通', () async {
        final client = createTtsHttpClient(preferIPv4: prefer);
        try {
          final req = await client.getUrl(Uri.parse('http://127.0.0.1:$port/voices'));
          final resp = await req.close();
          final body = await resp.transform(utf8.decoder).join();
          expect(resp.statusCode, 200);
          expect(body, contains('ok'));

          final ws = await WebSocket.connect('ws://127.0.0.1:$port/edge/v1',
              customClient: client).timeout(const Duration(seconds: 5));
          ws.add('你好');
          expect(await ws.first.timeout(const Duration(seconds: 5)), 'echo:你好');
          await ws.close();
        } finally {
          client.close(force: true);
        }
      });
    }
  });
}
