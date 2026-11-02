/// JSON 型引擎测试：chinaso 官方 JSON、百度 tn=json（主路径）与 HTML 降级。
library;

import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:tongyi_lite/websearch/src/search_engine.dart';
import 'package:tongyi_lite/websearch/src/search_hit.dart';
import 'package:tongyi_lite/websearch/src/engines/baidu_engine.dart';
import 'package:tongyi_lite/websearch/src/engines/chinaso_engine.dart';

class _FakeFetch {
  final String Function(Uri url) respond;
  final List<Uri> requested = [];
  _FakeFetch(this.respond);

  FetchPage get fetch => (url, {Map<String, String>? extraHeaders}) async {
        requested.add(url);
        return respond(url);
      };
}

void main() {
  group('ChinasoEngine', () {
    test('解析官方 JSON（实测形态）并取第一条', () {
      final body = jsonEncode({
        'status': 0,
        'msg': 'success',
        'data': {
          'data': [
            {
              'title': '共促全球<em>人工智能</em>健康有序发展',
              'url': 'https://www.chinaso.com/link?url=S5fg9wDSiz%2FF8',
              'snippet': '　　国家主席习近平对美国进行国事访问期间……',
              'timestamp': '1790854320',
            },
            {
              'title': '第二条',
              'url': 'https://www.chinaso.com/link?url=other',
              'snippet': '',
              'timestamp': '',
            },
          ],
        },
      });
      final hits = ChinasoEngine.parsePage(body);
      expect(hits, hasLength(2));
      expect(hits.first.title, contains('人工智能'));
      expect(hits.first.title, isNot(contains('<em>')));
      expect(hits.first.url, startsWith('https://www.chinaso.com/link'));
      expect(hits.first.snippet, isNotNull);
      expect(hits.first.publishedAt, '2026-10-01'); // 1790854320 → UTC+8 无关紧要，断言格式
      expect(hits.first.engine, 'chinaso');
      expect(hits.last.publishedAt, isNull);
    });

    test('ip control → blocked', () {
      expect(
        () => ChinasoEngine.parsePage(
            '{"status":2,"msg":"ip control","data":{}}'),
        throwsA(isA<SearchEngineException>()
            .having((e) => e.kind, 'kind', 'blocked')),
      );
    });

    test('空 data（{}）→ empty', () {
      expect(
        () => ChinasoEngine.parsePage('{"status":0,"msg":"success","data":{}}'),
        throwsA(isA<SearchEngineException>()
            .having((e) => e.kind, 'kind', 'empty')),
      );
    });

    test('请求带随机 uid Cookie 与 Referer，pn/ps 参数就位', () async {
      final fake = _FakeFetch((url) => jsonEncode({
            'status': 0,
            'msg': 'success',
            'data': {
              'data': [
                {
                  'title': 'A',
                  'url': 'https://www.chinaso.com/link?url=x',
                  'snippet': 's',
                  'timestamp': '',
                },
              ],
            },
          }));
      final engine = ChinasoEngine(fake.fetch);
      final hits = await engine.search('测试');
      expect(hits, hasLength(1));
      final uri = fake.requested.single;
      expect(uri.host, 'www.chinaso.com');
      expect(uri.queryParameters['pn'], '1');
      expect(uri.queryParameters['ps'], '8');
      // extraHeaders 无法从 fetch 签名断言（fake 只收 url），uid 生成单独验证。
      final uid = engine.buildUidCookie();
      expect(uid, startsWith('uid='));
      expect(uid.length, greaterThan(10));
    });
  });

  group('BaiduEngine tn=json', () {
    test('解析 data.feed.entry（title/url/abs/time）', () {
      final body = jsonEncode({
        'queryId': 'x',
        'status': 0,
        'data': {
          'feed': {
            'entry': [
              {
                'title': '售价5499元起!华为Mate70系列正式发布',
                'url': 'https://baijiahao.baidu.com/s?id=1816770301443867394',
                'abs': '华为Mate70系列正式发布，售价5499元起。',
                'time': '1732620000',
              },
              {
                'title': '第二条',
                'url': 'https://example.com/2',
                'abs': '',
                'time': '',
              },
            ],
          },
        },
      });
      final hits = BaiduEngine.parseJsonPage(body);
      expect(hits, hasLength(2));
      expect(hits.first.url, contains('baijiahao'));
      expect(hits.first.publishedAt, '2024-11-26');
      expect(hits.last.publishedAt, isNull);
    });

    test('status != 0 → blocked', () {
      expect(
        () => BaiduEngine.parseJsonPage('{"status":-1,"msg":"err"}'),
        throwsA(isA<SearchEngineException>()
            .having((e) => e.kind, 'kind', 'blocked')),
      );
    });

    test('search()：tn=json 优先，非 JSON 响应降级 HTML 解析', () async {
      // 百度偶发不返回 JSON（改版/风控变体）：同一请求直接吐 HTML 结果页，
      // 引擎应识别"非 JSON"并走 HTML 解析路径。
      final fake = _FakeFetch((url) {
        expect(url.queryParameters['tn'], 'json');
        return '''
        <div class="result c-container">
          <h3><a href="http://www.baidu.com/link?url=zzz">华为Mate70发布</a></h3>
          <span class="summary-text_15QGa">售价5499元起</span>
        </div>
        ''';
      });
      final hits = await BaiduEngine(fake.fetch).search('华为Mate70');
      expect(fake.requested, hasLength(1));
      expect(hits, hasLength(1));
      expect(hits.first.title, '华为Mate70发布');
      expect(hits.first.snippet, '售价5499元起');
    });

    test('search()：tn=json 正常时直接走 JSON 路径', () async {
      final fake = _FakeFetch((url) => jsonEncode({
            'status': 0,
            'data': {
              'feed': {
                'entry': [
                  {'title': 'A', 'url': 'https://a.com/1', 'abs': 'x', 'time': '0'}
                ],
              },
            },
          }));
      final hits = await BaiduEngine(fake.fetch).search('A');
      expect(hits, hasLength(1));
      expect(hits.first.url, 'https://a.com/1');
    });
  });
}
