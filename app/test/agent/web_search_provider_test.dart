import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';

import 'package:dio/dio.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:tongyi_lite/agent/builtin_tools/web_search_tool.dart';
import 'package:tongyi_lite/agent/tool_definition.dart';
import 'package:tongyi_lite/agent/tool_registry.dart';
import 'package:tongyi_lite/agent/tools/tool_executor.dart';
import 'package:tongyi_lite/agent/web_search/web_search_seam.dart';
import 'package:tongyi_lite/services/settings_service.dart';

/// 可编程的假 HTTP 适配器：记录每次请求，按脚本返回响应/抛异常。
class _MockAdapter implements HttpClientAdapter {
  _MockAdapter(this.onRequest);

  final ResponseBody Function(RequestOptions options) onRequest;
  final requests = <RequestOptions>[];

  @override
  Future<ResponseBody> fetch(RequestOptions options,
      Stream<Uint8List>? requestStream, Future<void>? cancelFuture) async {
    requests.add(options);
    return onRequest(options);
  }

  @override
  void close({bool force = false}) {}
}

ResponseBody _json(Object body, {int status = 200}) => ResponseBody.fromString(
      jsonEncode(body),
      status,
      headers: {
        'content-type': ['application/json; charset=utf-8'],
      },
    );

ResponseBody _html(String body, {int status = 200}) => ResponseBody.fromString(
      body,
      status,
      headers: {
        'content-type': ['text/html; charset=utf-8'],
      },
    );

SearXNGSearchProvider _providerWith(
  _MockAdapter adapter, {
  String baseURL = 'http://searx.test:8080',
  String? engines,
  int maxResults = 8,
}) {
  final dio = Dio()..httpClientAdapter = adapter;
  return SearXNGSearchProvider(
    baseURL: baseURL,
    engines: engines,
    maxResults: maxResults,
    dio: dio,
  );
}

/// 记录 provider 收到的 timeout 参数，用于验证"设置项超时不被接缝覆盖"。
class _RecordingProvider implements WebSearchProvider {
  Duration? lastTimeout;
  bool disposed = false;

  @override
  String get id => 'recording';
  @override
  String get name => 'Recording';
  @override
  String? available() => null;
  @override
  Future<WebSearchResult> search(String query, {Duration? timeout}) async {
    lastTimeout = timeout;
    return const WebSearchResult(sources: []);
  }

  @override
  void dispose() => disposed = true;
}

void main() {
  tearDown(() => WebSearchSeam.instance.dispose());

  group('请求 URL 构造', () {
    test('base 无路径时自动补 /search（不再依赖实例 308 跳转）', () {
      final uri = SearXNGSearchProvider(baseURL: 'http://h:8080')
          .buildRequestUri('北京 天气');
      expect(uri.path, '/search');
      expect(uri.queryParameters['q'], '北京 天气');
      expect(uri.queryParameters['format'], 'json');
      expect(uri.toString(), startsWith('http://h:8080/search?'));
    });

    test('尾斜杠 / 已写 /search 都不会拼出双斜杠或双 search', () {
      for (final base in ['http://h:8080/', 'http://h:8080/search', 'http://h:8080/search/']) {
        final uri = SearXNGSearchProvider(baseURL: base).buildRequestUri('x');
        expect(uri.path, '/search', reason: 'base=$base');
      }
    });

    test('engines 白名单按需带上，留空则完全不带该参数', () {
      final withEngines = SearXNGSearchProvider(
              baseURL: 'http://h:8080', engines: 'bing,sogou')
          .buildRequestUri('x');
      expect(withEngines.queryParameters['engines'], 'bing,sogou');

      final without = SearXNGSearchProvider(baseURL: 'http://h:8080', engines: '')
          .buildRequestUri('x');
      expect(without.queryParameters.containsKey('engines'), isFalse);
    });
  });

  group('错误分类（不再一律报"不可达"）', () {
    test('地址未配置 → 明确提示去设置里填', () async {
      final p = SearXNGSearchProvider(baseURL: '');
      expect(p.available(), contains('未配置'));
      expect(p.available(), contains('设置'));
    });

    test('HTML 响应 → 指出实例未启用 format=json', () async {
      final p = _providerWith(_MockAdapter((_) => _html('<html>ok</html>')));
      await expectLater(
        p.search('x'),
        throwsA(isA<WebSearchProviderError>().having((e) => e.message, 'message',
            contains('format'))),
      );
    });

    test('HTTP 503 → 报状态码，而不是"不可达"', () async {
      final p = _providerWith(_MockAdapter((_) => _html('err', status: 503)));
      await expectLater(
        p.search('x'),
        throwsA(isA<WebSearchProviderError>()
            .having((e) => e.message, 'message', contains('503'))),
      );
    });

    test('响应不是合法 JSON → 报解析失败', () async {
      final p = _providerWith(
          _MockAdapter((_) => ResponseBody.fromString('{不是 json', 200, headers: {
                'content-type': ['application/json']
              })));
      await expectLater(
        p.search('x'),
        throwsA(isA<WebSearchProviderError>()
            .having((e) => e.message, 'message', contains('JSON'))),
      );
    });

    test('接收超时 → WEB_ABORTED', () async {
      final p = _providerWith(_MockAdapter((options) {
        throw DioException(
          requestOptions: options,
          type: DioExceptionType.receiveTimeout,
        );
      }));
      await expectLater(
        p.search('x'),
        throwsA(isA<WebSearchProviderError>()
            .having((e) => e.kind, 'kind', 'WEB_ABORTED')),
      );
    });
  });

  group('引擎白名单被拒时的自愈', () {
    test('400 后自动去掉 engines 重试一次并成功', () async {
      final adapter = _MockAdapter((options) {
        // 第一次带 engines → 实例拒绝；第二次不带 → 正常返回。
        // 注意：Dio 不把 URL 上的查询串解析进 options.queryParameters，得看 uri。
        if (options.uri.queryParameters.containsKey('engines')) {
          return _html('bad engines', status: 400);
        }
        return _json({
          'results': [
            {'url': 'https://a.example/x', 'title': 'A', 'content': 'ok'}
          ]
        });
      });
      final p = _providerWith(adapter, engines: 'nonexistent-engine');
      final result = await p.search('x');
      expect(adapter.requests.length, 2);
      expect(adapter.requests[1].uri.queryParameters.containsKey('engines'), isFalse);
      expect(result.sources.single.url, 'https://a.example/x');
    });
  });

  group('结果映射', () {
    test('utm/fragment/尾斜杠变体算同一条（去重）', () async {
      final p = _providerWith(_MockAdapter((_) => _json({
            'results': [
              {'url': 'https://A.example.com/p/', 'title': '1'},
              {'url': 'https://a.example.com/p/?utm_source=x', 'title': '2'},
              {'url': 'https://a.example.com/p#frag', 'title': '3'},
              {'url': 'https://b.example.com/p', 'title': '4'},
            ]
          })));
      final r = await p.search('x');
      expect(r.sources.length, 2);
    });

    test('有 score 的按相关性优先，并按 maxResults 截断且置位 truncated', () async {
      final p = _providerWith(
        _MockAdapter((_) => _json({
              'results': [
                {'url': 'https://a/1', 'title': 'low', 'score': 0.1},
                {'url': 'https://a/2', 'title': 'high', 'score': 0.9},
                {'url': 'https://a/3', 'title': 'mid', 'score': 0.5},
              ]
            })),
        maxResults: 2,
      );
      final r = await p.search('x');
      expect(r.sources.map((s) => s.title).toList(), ['high', 'mid']);
      expect(r.truncated, isTrue);
    });
  });

  group('回填模型的文本预算', () {
    test('单条摘要按 200 字截断，总量不超过预算', () async {
      final long = '长' * 500;
      final p = _providerWith(_MockAdapter((_) => _json({
            'results': List.generate(
              8,
              (i) => {
                'url': 'https://a/$i',
                'title': '标题 $i',
                'content': long,
              },
            )
          })));
      WebSearchSeam.instance.registerProvider(p);
      final result = await WebSearchSeam.instance.search('x');
      final out = await createWebSearchTool().execute({'query': 'x'});
      expect(out.isError, isFalse);
      expect(out.content.length, lessThan(1800));
      expect(out.content, contains('…'));
      expect(result.sources.length, 8);
    });

    test('空结果给出可操作提示', () async {
      WebSearchSeam.instance
          .registerProvider(_providerWith(_MockAdapter((_) => _json({'results': []}))));
      final out = await createWebSearchTool().execute({'query': 'x'});
      // 新语义：空结果回 error（fail-loud），带当前时间；SearXNG 空结果
      // 必附引擎诊断（unresponsive_engines），模型/用户能看出是实例挂了。
      expect(out.isError, isTrue);
      expect(out.content, contains('当前时间：'));
      expect(out.content, contains('搜索服务异常'));
    });

    test('provider 错误回填给模型的文案里带诊断分类', () async {
      WebSearchSeam.instance.registerProvider(
          SearXNGSearchProvider(baseURL: '')); // 未配置地址
      final out = await createWebSearchTool().execute({'query': 'x'});
      expect(out.isError, isTrue);
      expect(out.content, contains('WEB_PROVIDER_ERROR'));
      expect(out.content, contains('未配置'));
    });
  });

  group('超时预算', () {
    test('接缝不传 timeout 时，provider 用的是自身配置（不被接缝默认值覆盖）', () async {
      final recorder = _RecordingProvider();
      WebSearchSeam.instance.registerProvider(recorder);
      await WebSearchSeam.instance.search('x');
      expect(recorder.lastTimeout, isNull);

      await WebSearchSeam.instance.search('x', timeout: const Duration(seconds: 7));
      expect(recorder.lastTimeout, const Duration(seconds: 7));
    });

    test('工具声明的 timeout 生效：慢于全局但快于自身声明 → 成功', () async {
      final registry = ToolRegistry();
      registry.register(ToolDefinition(
        name: 'slow',
        description: '',
        parameters: const {'type': 'object'},
        timeout: const Duration(milliseconds: 300),
        execute: (_) => Future<ToolResult>.delayed(
            const Duration(milliseconds: 80), () => const ToolResult(content: 'done')),
      ));
      final executor = ToolExecutor(
        registry: registry,
        modelId: 'm',
        timeout: const Duration(milliseconds: 10), // 全局 10ms，应被工具声明覆盖
      );
      final r = await executor.execute(
          const ToolCall(id: '1', name: 'slow', arguments: {}));
      expect(r.isError, isFalse);
      expect(r.content, 'done');
    });

    test('未声明 timeout 的慢工具仍受全局超时约束', () async {
      final registry = ToolRegistry();
      registry.register(ToolDefinition(
        name: 'hang',
        description: '',
        parameters: const {'type': 'object'},
        execute: (_) => Future<ToolResult>.delayed(
            const Duration(milliseconds: 300),
            () => const ToolResult(content: 'late')),
      ));
      final executor = ToolExecutor(
        registry: registry,
        modelId: 'm',
        timeout: const Duration(milliseconds: 20),
      );
      final r = await executor.execute(
          const ToolCall(id: '1', name: 'hang', arguments: {}));
      expect(r.isError, isTrue);
      expect(r.content, contains('超时'));
    });
  });

  group('provider 复用与设置持久化', () {
    InferenceSettings settingsWith({String url = 'http://a:8080', String engines = 'e1'}) =>
        const InferenceSettings().copyWith(
          webSearchSearXngBaseUrl: url,
          webSearchSearXngEngines: engines,
          // 这组测试专测 SearXNG provider 路径，须关掉直连总开关。
          webSearchDirectEnabled: false,
        );

    test('配置未变时复用同一实例（连接池不作废）', () {
      applySearXNGProviderFromSettings(settingsWith());
      final first = WebSearchSeam.instance.provider;
      applySearXNGProviderFromSettings(settingsWith());
      expect(identical(WebSearchSeam.instance.provider, first), isTrue);
    });

    test('地址变了才重建 provider', () {
      applySearXNGProviderFromSettings(settingsWith());
      final first = WebSearchSeam.instance.provider;
      applySearXNGProviderFromSettings(settingsWith(url: 'http://b:8080'));
      expect(identical(WebSearchSeam.instance.provider, first), isFalse);
    });

    test('SearXNG 各项配置随 toJson/fromJson 往返保留', () {
      final s = const InferenceSettings().copyWith(
        webSearchEnabled: true,
        webSearchSearXngBaseUrl: 'http://10.0.0.9:8080',
        webSearchSearXngApiKey: 'secret',
        webSearchSearXngEngines: 'bing,sogou',
        webSearchSearXngMaxResults: 5,
        webSearchSearXngTimeoutMs: 45000,
      );
      final back = InferenceSettings.fromJson(s.toJson());
      expect(back.webSearchSearXngBaseUrl, 'http://10.0.0.9:8080');
      expect(back.webSearchSearXngApiKey, 'secret');
      expect(back.webSearchSearXngEngines, 'bing,sogou');
      expect(back.webSearchSearXngMaxResults, 5);
      expect(back.webSearchSearXngTimeoutMs, 45000);
    });

    test('默认不预置任何实例地址', () {
      expect(InferenceSettings.kDefaultSearXngBaseUrl, isEmpty);
      expect(const InferenceSettings().webSearchSearXngBaseUrl, isEmpty);
    });
  });
}
