import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';

import 'package:fast_gbk/fast_gbk.dart' as gbk;
import 'package:tongyi_lite/agent/builtin_tools/fetch_url_tool.dart';

FetchHttpResponse _resp(String body,
        {int status = 200, String? contentType = 'text/html; charset=utf-8'}) =>
    FetchHttpResponse(
        statusCode: status, contentType: contentType, bytes: utf8.encode(body));

void main() {
  group('fetch_url', () {
    test('HTML → 结构化文本：剥脚本、保留表格行列', () async {
      final html = '''
<html><head><title>t</title><script>var a=1;</script>
<style>.x{color:red}</style></head><body>
<h1>标题</h1>
<table><tr><th>日期</th><th>营收</th></tr>
<tr><td>2026Q3</td><td>271.35&nbsp;亿</td></tr></table>
<!-- 注释 -->
<p>正文段落</p>
</body></html>''';
      final tool = createFetchUrlTool(httpGet: (url, headers) async {
        expect(headers, contains('User-Agent'));
        return _resp(html);
      });
      final r = await tool.execute({'url': 'https://example.com/a'});
      expect(r.isError, isFalse, reason: r.content);
      expect(r.content, contains('标题'));
      expect(r.content, contains('日期 | 营收'));
      expect(r.content, contains('2026Q3 | 271.35 亿'));
      expect(r.content, contains('正文段落'));
      expect(r.content, isNot(contains('var a=1')));
      expect(r.content, isNot(contains('color:red')));
      expect(r.content, isNot(contains('注释')));
    });

    test('JSON 透传原文', () async {
      final tool = createFetchUrlTool(
          httpGet: (url, headers) async => _resp('{"code":0,"data":[1,2]}',
              contentType: 'application/json'));
      final r = await tool.execute({'url': 'https://example.com/api'});
      expect(r.content, contains('{"code":0,"data":[1,2]}'));
    });

    test('GBK 页面按声明解码', () async {
      // '中联重科' 的 GBK 编码。
      final gbkBytes = gbk.gbk.encode('中联重科 财务数据');
      final tool = createFetchUrlTool(
          httpGet: (url, headers) async => FetchHttpResponse(
              statusCode: 200,
              contentType: 'text/html; charset=gbk',
              bytes: gbkBytes));
      final r = await tool.execute({'url': 'https://example.com/gbk'});
      expect(r.content, contains('中联重科'));
    });

    test('meta charset 嗅探（Content-Type 未声明时）', () async {
      final html = '<html><head><meta charset="gb2312"></head><body>凤凰股份</body></html>';
      final tool = createFetchUrlTool(
          httpGet: (url, headers) async => FetchHttpResponse(
              statusCode: 200,
              contentType: 'text/html',
              bytes: gbk.gbk.encode(html)));
      final r = await tool.execute({'url': 'https://example.com/m'});
      expect(r.content, contains('凤凰股份'));
    });

    test('max_chars 截断', () async {
      final tool = createFetchUrlTool(
          httpGet: (url, headers) async =>
              _resp('x' * 500, contentType: 'text/plain'));
      final r = await tool.execute({'url': 'https://e.com/', 'max_chars': 100});
      expect(r.content, contains('已截断'));
      expect(r.content.length, lessThan(300)); // 100 正文 + 头部/截断说明
    });

    test('HTTP 错误与非法 URL fail-loud', () async {
      final tool = createFetchUrlTool(
          httpGet: (url, headers) async => _resp('', status: 404));
      expect((await tool.execute({'url': 'https://e.com/'})).isError, isTrue);
      expect(
          (await tool.execute({'url': 'not-a-url'})).isError, isTrue);
      expect((await tool.execute({'url': ''})).isError, isTrue);
    });

    test('网络异常 → 可读错误', () async {
      final tool = createFetchUrlTool(
          httpGet: (url, headers) async => throw Exception('timeout'));
      final r = await tool.execute({'url': 'https://e.com/'});
      expect(r.isError, isTrue);
      expect(r.content, contains('抓取失败'));
    });
  });
}
