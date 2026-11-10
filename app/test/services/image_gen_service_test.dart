// ImageGenService 单测（mock dio HttpClientAdapter，web_search/sse_stall 同款
// 惯例；path_provider 经 dayDirOverride 注入临时目录）。
//
// 覆盖：成功落盘+b64 解码 / 错误映射（401→unauthorized、429→serverBusy、
// connectionError→unreachable）/ 响应缺 data→decode / 单飞队列串行 /
// 超时分档表 / notConfigured 门禁 / Windows 默认地址回落 / checkHealth
// 三分支（全绿 / 服务可达但 key 无效 / 服务不可达）/ Bearer 头随请求。
import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data' show Uint8List;

import 'package:dio/dio.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:wangcai/services/image_gen_service.dart';

/// 按请求回调的假适配器（断言请求体/头 + 定制响应）。
class _FakeAdapter implements HttpClientAdapter {
  _FakeAdapter(this.onRequest);

  /// 返回 [ResponseBody]；抛 DioException 模拟网络错误。
  final Future<ResponseBody> Function(RequestOptions options) onRequest;

  @override
  void close({bool force = false}) {}

  @override
  Future<ResponseBody> fetch(RequestOptions options,
      Stream<Uint8List>? requestStream, Future<void>? cancelFuture) async {
    if (cancelFuture != null) {
      // 已取消的请求直接走 cancel 错误（dio 真实行为近似）。
      final cancelled = Completer<void>();
      cancelFuture.then((_) {
        if (!cancelled.isCompleted) cancelled.complete();
      });
      // 不阻塞：真实 dio 会在传输中检查取消；这里简单处理为不取消。
      unawaited(cancelled.future);
    }
    return onRequest(options);
  }
}

ResponseBody _jsonBody(Map<String, dynamic> json) => ResponseBody(
      Stream.value(utf8.encode(jsonEncode(json))),
      200,
      headers: {Headers.contentTypeHeader: [Headers.jsonContentType]},
    );

String _b64Of(List<int> bytes) => base64Encode(bytes);

void main() {
  late Directory tmp;
  setUpAll(() {
    ImageGenService.docsDirOverride = () async => tmp;
  });
  setUp(() async {
    tmp = await Directory.systemTemp.createTemp('imggen_test');
  });
  tearDown(() async {
    await tmp.delete(recursive: true);
  });

  ImageGenService svcWith(_FakeAdapter adapter) {
    final dio = Dio()..httpClientAdapter = adapter;
    return ImageGenService(dio: dio);
  }

  const enabledCfg = ImageGenConfig(
      enabled: true, baseUrl: 'http://127.0.0.1:9999', apiKey: 'sk-test');

  group('generate 成功路径', () {
    test('b64 解码落盘 + 溯源参数齐备 + Bearer 头', () async {
      final pngBytes = [137, 80, 78, 71, 13, 10, 26, 10, 1, 2, 3];
      RequestOptions? captured;
      final svc = svcWith(_FakeAdapter((opts) async {
        captured = opts;
        return _jsonBody({
          'data': [
            {'b64_json': _b64Of(pngBytes)},
          ],
        });
      }));

      final r = await svc.generate(
          config: enabledCfg, prompt: '一只戴围巾的柴犬', seed: 42);

      expect(r.paths, hasLength(1));
      final f = File(r.paths.first);
      expect(f.existsSync(), isTrue);
      expect(f.readAsBytesSync(), pngBytes);
      expect(f.path, contains('imagegen'));
      expect(f.path, endsWith('.png'));
      expect(r.seed, 42);
      expect(r.size, '1024x1024');
      // 请求契约：端点/尺寸/b64/seed/鉴权头。模型口径（2026-11-10 用户点单）：
      // 空模型 = **省略 model 字段**走服务端缺省，不再回落扫描目录路径。
      expect(captured!.uri.path, contains('/v1/images/generations'));
      final body = captured!.data as Map;
      expect(body.containsKey('model'), isFalse,
          reason: '空模型应省略 model 字段（服务端缺省），不回填路径');
      expect(body['prompt'], '一只戴围巾的柴犬');
      expect(body['size'], '1024x1024');
      expect(body['response_format'], 'b64_json');
      expect(body['seed'], 42);
      expect(captured!.headers['Authorization'], 'Bearer sk-test');
      // 溯源元数据（genMeta 的 JSON 结构）。
      final meta = r.metaJson('一只戴围巾的柴犬', '');
      expect(meta['seed'], 42);
      expect(meta['size'], '1024x1024');
      expect(meta['model'], '');
      expect(meta['prompt'], '一只戴围巾的柴犬');
      expect(meta.containsKey('ms'), isTrue);
    });

    test('显式模型 → 透传 model 字段（下拉选中项进请求体）', () async {
      RequestOptions? captured;
      final svc = svcWith(_FakeAdapter((opts) async {
        captured = opts;
        return _jsonBody({
          'data': [
            {'b64_json': _b64Of([1])},
          ],
        });
      }));
      await svc.generate(
          config: const ImageGenConfig(
              enabled: true,
              baseUrl: 'http://127.0.0.1:9999',
              model: 'flux-schnell',
              apiKey: 'sk-test'),
          prompt: '柴犬');
      expect((captured!.data as Map)['model'], 'flux-schnell');
    });

    test('n=2 生成两张，文件名互不覆盖', () async {
      final svc = svcWith(_FakeAdapter((opts) async {
        return _jsonBody({
          'data': [
            {'b64_json': _b64Of([1])},
            {'b64_json': _b64Of([2])},
          ],
        });
      }));
      final r = await svc.generate(config: enabledCfg, prompt: 'x', n: 2);
      expect(r.paths, hasLength(2));
      expect(r.paths.toSet(), hasLength(2));
      for (final p in r.paths) {
        expect(File(p).existsSync(), isTrue);
      }
    });
  });

  group('错误映射', () {
    test('401 → unauthorized', () async {
      final svc = svcWith(_FakeAdapter((_) async => ResponseBody.fromString(
          '{}', 401,
          headers: {Headers.contentTypeHeader: [Headers.jsonContentType]})));
      await expectLater(
          svc.generate(config: enabledCfg, prompt: 'x'),
          throwsA(isA<ImageGenException>()
              .having((e) => e.kind, 'kind', ImageGenErrorKind.unauthorized)));
    });

    test('429 → serverBusy', () async {
      final svc = svcWith(_FakeAdapter((_) async => ResponseBody.fromString(
          '{}', 429,
          headers: {Headers.contentTypeHeader: [Headers.jsonContentType]})));
      await expectLater(
          svc.generate(config: enabledCfg, prompt: 'x'),
          throwsA(isA<ImageGenException>()
              .having((e) => e.kind, 'kind', ImageGenErrorKind.serverBusy)));
    });

    test('connectionError → unreachable（文案含防火墙指引）', () async {
      final svc = svcWith(_FakeAdapter((_) async {
        throw DioException(
            requestOptions: RequestOptions(path: '/v1/images/generations'),
            type: DioExceptionType.connectionError,
            error: const SocketException('refused'));
      }));
      await expectLater(
          svc.generate(config: enabledCfg, prompt: 'x'),
          throwsA(isA<ImageGenException>().having(
              (e) => e.kind, 'kind', ImageGenErrorKind.unreachable)));
    });

    test('响应缺 data 数组 → decode', () async {
      final svc = svcWith(_FakeAdapter((_) async => _jsonBody({'nope': 1})));
      await expectLater(
          svc.generate(config: enabledCfg, prompt: 'x'),
          throwsA(isA<ImageGenException>()
              .having((e) => e.kind, 'kind', ImageGenErrorKind.decode)));
    });

    test('非法 base64 → decode', () async {
      final svc = svcWith(_FakeAdapter((_) async => _jsonBody({
            'data': [
              {'b64_json': '!!!not-base64!!!'},
            ],
          })));
      await expectLater(
          svc.generate(config: enabledCfg, prompt: 'x'),
          throwsA(isA<ImageGenException>()
              .having((e) => e.kind, 'kind', ImageGenErrorKind.decode)));
    });

    test('未启用 → notConfigured（不发包）', () async {
      var called = false;
      final svc = svcWith(_FakeAdapter((_) async {
        called = true;
        return _jsonBody({'data': []});
      }));
      await expectLater(
          svc.generate(
              config: const ImageGenConfig(enabled: false, baseUrl: 'http://x'),
              prompt: 'x'),
          throwsA(isA<ImageGenException>().having(
              (e) => e.kind, 'kind', ImageGenErrorKind.notConfigured)));
      expect(called, isFalse);
    });
  });

  group('配置口径', () {
    test('Windows 空地址回落本机默认（零配置起步）', () {
      const cfg = ImageGenConfig(enabled: true, baseUrl: '');
      expect(cfg.effectiveBaseUrl, kImageGenDefaultBaseUrl);
      expect(cfg.isConfigured, isTrue);
    });

    test('脏尺寸档回落 1024x1024', () {
      const cfg = ImageGenConfig(
          enabled: true, baseUrl: 'http://x', defaultSize: '77x77');
      expect(cfg.effectiveSize, '1024x1024');
    });

    test('generate 传脏 size 时落回配置默认档', () async {
      RequestOptions? captured;
      final svc = svcWith(_FakeAdapter((opts) async {
        captured = opts;
        return _jsonBody({
          'data': [
            {'b64_json': _b64Of([1])},
          ],
        });
      }));
      await svc.generate(
          config: enabledCfg, prompt: 'x', size: '3x3', seed: 1);
      expect((captured!.data as Map)['size'], '1024x1024');
    });
  });

  group('超时分档表', () {
    test('512/1024/1440 → 120s；2048 → 300s', () {
      expect(ImageGenService.timeoutForSize('512x512'),
          const Duration(seconds: 120));
      expect(ImageGenService.timeoutForSize('1024x1024'),
          const Duration(seconds: 120));
      expect(ImageGenService.timeoutForSize('1440x1440'),
          const Duration(seconds: 120));
      expect(ImageGenService.timeoutForSize('2048x2048'),
          const Duration(seconds: 300));
    });
  });

  group('单飞队列', () {
    test('并发调用串行执行（第二个等第一个完成才发请求）', () async {
      final events = <String>[];
      var inFlight = 0;
      var overlap = false;
      Completer<void>? gate;
      final svc = svcWith(_FakeAdapter((opts) async {
        if (inFlight > 0) overlap = true;
        inFlight++;
        events.add('start');
        // 第一次卡住，验证第二个请求确实排队。
        if (gate == null) {
          gate = Completer<void>();
          await gate!.future;
        }
        events.add('end');
        inFlight--;
        return _jsonBody({
          'data': [
            {'b64_json': _b64Of([1])},
          ],
        });
      }));

      final f1 = svc.generate(config: enabledCfg, prompt: 'a', seed: 1);
      final f2 = svc.generate(config: enabledCfg, prompt: 'b', seed: 2);
      await Future<void>.delayed(const Duration(milliseconds: 50));
      expect(events, ['start'], reason: '第二个请求必须在队列里等');
      gate!.complete();
      await Future.wait([f1, f2]);
      expect(overlap, isFalse, reason: '两请求不得并发在飞');
      expect(events, ['start', 'end', 'start', 'end']);
    });

    test('前一任务失败不断链：后续任务照常执行', () async {
      var calls = 0;
      final svc = svcWith(_FakeAdapter((opts) async {
        calls++;
        if (calls == 1) {
          return ResponseBody.fromString('{}', 401,
              headers: {Headers.contentTypeHeader: [Headers.jsonContentType]});
        }
        return _jsonBody({
          'data': [
            {'b64_json': _b64Of([1])},
          ],
        });
      }));
      await expectLater(svc.generate(config: enabledCfg, prompt: 'a'),
          throwsA(isA<ImageGenException>()));
      final r = await svc.generate(config: enabledCfg, prompt: 'b');
      expect(r.paths, hasLength(1));
      expect(calls, 2);
    });
  });

  group('checkHealth 三分支', () {
    test('health + /v1/models 全过 → ok（含模型数）', () async {
      final svc = svcWith(_FakeAdapter((opts) async {
        if (opts.uri.path.endsWith('/api/health')) {
          return _jsonBody({'status': 'healthy'});
        }
        return _jsonBody({
          'data': [
            {'id': 'E:/Unsloth/models'},
            {'id': 'other'},
          ],
        });
      }));
      final h = await svc.checkHealth(enabledCfg);
      expect(h.ok, isTrue);
      expect(h.modelCount, 2);
    });

    test('服务可达但 key 无效 → reachable 且 !authorized', () async {
      final svc = svcWith(_FakeAdapter((opts) async {
        if (opts.uri.path.endsWith('/api/health')) {
          return _jsonBody({'status': 'healthy'});
        }
        return ResponseBody.fromString('{}', 401,
            headers: {Headers.contentTypeHeader: [Headers.jsonContentType]});
      }));
      final h = await svc.checkHealth(enabledCfg);
      expect(h.reachable, isTrue);
      expect(h.authorized, isFalse);
      expect(h.ok, isFalse);
    });

    test('服务不可达 → reachable=false（不抛）', () async {
      final svc = svcWith(_FakeAdapter((_) async {
        throw DioException(
            requestOptions: RequestOptions(path: '/api/health'),
            type: DioExceptionType.connectionError,
            error: const SocketException('refused'));
      }));
      final h = await svc.checkHealth(enabledCfg);
      expect(h.reachable, isFalse);
      expect(h.ok, isFalse);
      expect(h.message, isNotEmpty);
    });

    test('未启用 → 直接给未配置结论（不发包）', () async {
      var called = false;
      final svc = svcWith(_FakeAdapter((_) async {
        called = true;
        return _jsonBody({'status': 'healthy'});
      }));
      final h = await svc.checkHealth(
          const ImageGenConfig(enabled: false, baseUrl: 'http://x'));
      expect(h.ok, isFalse);
      expect(h.message, contains('未启用'));
      expect(called, isFalse);
    });
  });
}
