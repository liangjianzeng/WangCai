/// 夸克引擎解析测试（hydrate JSON 泛收集 + x5sec 判 blocked）。
library;

import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:tongyi_lite/websearch/src/search_hit.dart';
import 'package:tongyi_lite/websearch/src/engines/quark_engine.dart';

String _hydrate(Map<String, dynamic> data) =>
    '<script type="application/json" id="s-data-1" data-used-by="hydrate">'
    '${jsonEncode(data)}</script>';

void main() {
  test('解析 hydrate JSON：平铺字段（title/normal_url/summary）', () {
    final body = _hydrate({
      'extraData': {'sc': 'news_uchq'},
      'list': [
        {
          'title': '华为Mate70系列正式发布',
          'normal_url': 'https://news.example.com/a/1',
          'summary': '10月发布会信息汇总',
        },
        {
          'title': '第二条新闻',
          'normal_url': 'https://news.example.com/a/2',
        },
      ],
    });
    final hits = QuarkEngine.parsePage(body);
    expect(hits, hasLength(2));
    expect(hits.first.url, 'https://news.example.com/a/1');
    expect(hits.first.snippet, '10月发布会信息汇总');
    expect(hits.last.snippet, isNull);
    expect(hits.first.engine, 'quark');
  });

  test('解析嵌套字段（titleProps.content / sourceProps.dest_url / summaryProps）', () {
    final body = _hydrate({
      'cards': [
        {
          'titleProps': {'content': '嵌套标题'},
          'sourceProps': {'dest_url': 'https://www.nbd.com.cn/articles/1'},
          'summaryProps': {'content': '嵌套摘要'},
        },
      ],
    });
    final hits = QuarkEngine.parsePage(body);
    expect(hits, hasLength(1));
    expect(hits.first.title, '嵌套标题');
    expect(hits.first.url, 'https://www.nbd.com.cn/articles/1');
    expect(hits.first.snippet, '嵌套摘要');
  });

  test('过滤站内链接与重复 URL', () {
    final body = _hydrate({
      'list': [
        {
          'title': '站内导航',
          'url': 'https://quark.sm.cn/home?from=nav',
        },
        {
          'title': '外链',
          'url': 'https://real.com/page',
        },
        {
          'title': '重复外链',
          'url': 'https://real.com/page?utm_source=x',
        },
      ],
    });
    final hits = QuarkEngine.parsePage(body);
    expect(hits, hasLength(1));
    expect(hits.first.url, 'https://real.com/page');
  });

  test('x5sec / captcha 片段 → blocked', () {
    for (final body in [
      '{"action": "captcha", "url": "https://check.so.com"}',
      '页面被拦截 x5sec token invalid',
    ]) {
      expect(
        () => QuarkEngine.parsePage(body),
        throwsA(isA<SearchEngineException>()
            .having((e) => e.kind, 'kind', 'blocked')),
      );
    }
  });

  test('无 hydrate 块 → parse', () {
    expect(
      () => QuarkEngine.parsePage('<html><body>nothing</body></html>'),
      throwsA(isA<SearchEngineException>()
          .having((e) => e.kind, 'kind', 'parse')),
    );
  });

  test('search() 请求参数就位（layout=html & page=1）', () async {
    Uri? captured;
    final hits = await QuarkEngine((url, {Map<String, String>? extraHeaders}) async {
      captured = url;
      return _hydrate({
        'list': [
          {'title': 'A', 'url': 'https://a.com/1'},
        ],
      });
    }).search('测试');
    expect(captured!.host, 'quark.sm.cn');
    expect(captured!.queryParameters['layout'], 'html');
    expect(captured!.queryParameters['page'], '1');
    expect(hits, hasLength(1));
  });
}
