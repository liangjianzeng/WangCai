/// 引擎解析测试：全部离线，fixture 来自 build/search_recon/ 的真实结果页
/// 精简片段（华为Mate70 关键词），绝不发真实网络请求。
///
/// 铁律：本目录测试禁止访问真实搜索引擎（真实 IP 处于反爬冷却期），
/// FetchPage 一律注入假实现。
library;

import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:tongyi_lite/websearch/src/engines/baidu_engine.dart';
import 'package:tongyi_lite/websearch/src/engines/bing_cn_engine.dart';
import 'package:tongyi_lite/websearch/src/engines/so360_engine.dart';
import 'package:tongyi_lite/websearch/src/engines/sogou_engine.dart';
import 'package:tongyi_lite/websearch/src/search_hit.dart';

String fixture(String name) =>
    File('test/websearch/fixtures/$name').readAsStringSync();

/// 断言抛出指定 kind 的引擎异常。
Matcher engineError(String kind) => throwsA(isA<SearchEngineException>()
    .having((e) => e.kind, 'kind', kind));

void main() {
  group('BingCnEngine.parseRss（真实 RSS fixture）', () {
    final hits = BingCnEngine.parseRss(fixture('bing_rss.xml'));

    test('结果数 > 0 且全部字段合理', () {
      expect(hits.length, greaterThan(0));
      for (final h in hits) {
        expect(h.title, isNotEmpty);
        expect(h.url, startsWith('http'));
        expect(h.engine, 'bing_cn');
      }
    });

    test('首条：直链 + 标题 + 摘要 + 中文月名日期转 ISO', () {
      final first = hits.first;
      expect(first.title, 'HUAWEI Mate 70 - 华为官网');
      expect(first.url, 'https://consumer.huawei.com/cn/phones/mate70/');
      expect(first.engine, 'bing_cn');
      // 周四, 01 10月 2026 → 2026-10-01
      expect(first.publishedAt, '2026-10-01');
      expect(first.snippet, isNotNull);
      expect(first.snippet!, contains('玄武架构'));
      // RSS 链接应为真实目标域，不是 bing 跳转。
      expect(first.url.contains('bing.com'), isFalse);
    });

    test('英文月名 pubDate 也能转 ISO，解析不出保留原文', () {
      const rss = '<rss><channel><item>'
          '<title>t</title><link>https://a.example.com/x</link>'
          '<description>d</description>'
          '<pubDate>Thu, 01 Oct 2026 05:00:00 GMT</pubDate></item>'
          '<item><title>t2</title><link>https://a.example.com/y</link>'
          '<description>d</description><pubDate>刚刚</pubDate></item>'
          '</channel></rss>';
      final hits = BingCnEngine.parseRss(rss);
      expect(hits[0].publishedAt, '2026-10-01');
      expect(hits[1].publishedAt, '刚刚');
    });

    test('异常流量风控页 → parse', () {
      expect(() => BingCnEngine.parseRss('<rss>异常流量，请稍后重试</rss>'),
          engineError('parse'));
    });

    test('HTML 空结果页（像必应页但无 b_algo）→ empty；不像必应页 → parse', () {
      expect(() => BingCnEngine.parseHtml(
          '<html><head><title>必应 - 搜索</title></head><body></body></html>'),
          engineError('empty'));
      expect(() => BingCnEngine.parseHtml('<html><body>hello</body></html>'),
          engineError('parse'));
    });

    test('HTML 路径：b_algo 块解析出直链与 b_lineclamp 摘要', () {
      final hits = BingCnEngine.parseHtml(fixture('bing_cn.html'));
      expect(hits.length, greaterThan(0));
      final first = hits.first;
      expect(first.url, 'https://www.huawei.com.cn/');
      expect(first.title, isNotEmpty);
      expect(first.snippet, isNotNull);
      expect(first.snippet!, isNotEmpty);
      expect(first.engine, 'bing_cn');
    });
  });

  group('So360Engine.parsePage（真实页面 fixture）', () {
    final hits = So360Engine.parsePage(fixture('so360.html'));

    test('mohe 聚合卡被过滤，普通结果保留', () {
      // 样本 7 块：news_ai（mohe）+ 5 条普通 + short_video（mohe）。
      expect(hits.length, 5);
      for (final h in hits) {
        expect(h.engine, 'so360');
        expect(h.title, isNotEmpty);
      }
    });

    test('首条真实 URL 来自 data-mdurl（非 so.com/link 跳转）', () {
      final first = hits.first;
      expect(first.url, 'https://news.mydrivers.com/1/1015/1015946.htm');
      expect(first.url.contains('so.com/link'), isFalse);
      expect(first.title, contains('彩排画面曝光'));
      expect(first.snippet, isNotNull);
      expect(first.snippet!, contains('余承东'));
    });

    test('res-desc 与 res-list-summary 两种摘要载体都能取到', () {
      // 第 4 条（华为官网 mate70）摘要走 res-desc。
      final huawei = hits.where((h) => h.url.contains('huawei.com')).toList();
      expect(huawei, isNotEmpty);
      expect(huawei.first.snippet, isNotNull);
      expect(huawei.first.snippet!, isNotEmpty);
    });

    test('验证码页（大小写不敏感）→ blocked', () {
      expect(() => So360Engine.parsePage('<html><body>请输入验证码</body></html>'),
          engineError('blocked'));
      expect(() => So360Engine.parsePage('<html><body>CAPTCHA required</body></html>'),
          engineError('blocked'));
    });

    test('无 res-list → parse；全噪声块 → empty', () {
      expect(() => So360Engine.parsePage('<html><body><ul><li>ads</li></ul></body></html>'),
          engineError('parse'));
      expect(
          () => So360Engine.parsePage(
              '<html><body><ul><li class="res-list"><div>无标题块</div></li></ul></body></html>'),
          engineError('empty'));
    });
  });

  group('SogouEngine.parsePage（真实页面 fixture）', () {
    final hits = SogouEngine.parsePage(fixture('sogou.html'));

    test('无 h3 的 vrwrap（大家还在搜提示框）被过滤', () {
      // 样本 6 块：块 1 是"大家还在搜"提示框，其余 5 块是结果。
      expect(hits.length, 5);
      for (final h in hits) {
        expect(h.engine, 'sogou');
        expect(h.title, isNotEmpty);
        expect(h.url, isNot(contains('sogou.com/link'))); // data-url 命中
      }
    });

    test('真实 URL 来自块内 data-url，第 2 条为 bilibili 直链', () {
      expect(hits.first.url,
          'https://consumer.huawei.com/cn/press/events/2023/wenjie-m9-and-huawei-winter-all-scenario-launch-event/');
      expect(hits.first.title, contains('华为官网'));
      expect(hits[1].url, contains('bilibili.com'));
      expect(hits[1].url, contains('BV171zGYuEoz'));
    });

    test('摘要取自 space-txt 元素', () {
      expect(hits.first.snippet, isNotNull);
      expect(hits.first.snippet!, contains('MateBook'));
    });

    test('反爬判定 → blocked；无 vrwrap → parse；全噪声 → empty', () {
      expect(() => SogouEngine.parsePage(
          '<html><body>/antispider/ 拦截</body></html>'), engineError('blocked'));
      expect(() => SogouEngine.parsePage('<html><body>验证码</body></html>'),
          engineError('blocked'));
      // 壳页：title 恰为"搜狗搜索"且 body 极小。
      expect(() => SogouEngine.parsePage('<html><head><title>搜狗搜索</title></head><body>x</body></html>'),
          engineError('blocked'));
      expect(() => SogouEngine.parsePage('<html><body>正常页面但没有结果</body></html>'),
          engineError('parse'));
      expect(
          () => SogouEngine.parsePage(
              '<html><body><div class="vrwrap"><p>无标题推荐位</p></div></body></html>'),
          engineError('empty'));
    });

    test('data-url 缺失时回退 href 并补 sogou 前缀', () {
      const page = '<html><body><div class="vrwrap">'
          '<h3 class="vr-title"><a href="/link?url=abc">标题啊</a></h3>'
          '</div></body></html>';
      final hits = SogouEngine.parsePage(page);
      expect(hits.single.url, 'https://www.sogou.com/link?url=abc');
    });
  });

  group('BaiduEngine.parsePage（真实页面 fixture）', () {
    final hits = BaiduEngine.parsePage(fixture('baidu_pc.html'));

    test('结果数 > 0 且 engine 字段正确', () {
      expect(hits.length, greaterThan(0));
      for (final h in hits) {
        expect(h.engine, 'baidu');
        expect(h.title, isNotEmpty);
      }
    });

    test('真实 URL 来自 mu 属性（实体解码后），标题/摘要来自哈希后缀 class', () {
      final first = hits.first;
      expect(first.url,
          'https://baijiahao.baidu.com/s?id=1816770301443867394&wfr=spider&for=pc');
      expect(first.title, contains('售价5499元起'));
      expect(first.snippet, isNotNull);
      expect(first.snippet!, contains('全系价格已公布'));
      // 澎湃那条（summary-text span 载体）。
      final thepaper = hits.firstWhere((h) => h.url.contains('thepaper.cn'));
      expect(thepaper.snippet, isNotNull);
      expect(thepaper.snippet!, isNotEmpty);
    });

    test('百度安全验证页 → blocked；无结果块 → parse；全噪声块 → empty', () {
      expect(() => BaiduEngine.parsePage(
          '<html><body><div>百度安全验证</div></body></html>'), engineError('blocked'));
      expect(() => BaiduEngine.parsePage('<html><body>其它页面</body></html>'),
          engineError('parse'));
      expect(
          () => BaiduEngine.parsePage(
              '<html><body><div class="result c-container" id="9"><p>无标题</p></div></body></html>'),
          engineError('empty'));
    });

    test('导航块（image.baidu.com）与 ec- 广告块被跳过', () {
      const page = '<html><body>'
          '<div class="result c-container" mu="https://x.example.com/1">'
          '<h3><a href="https://image.baidu.com/abc">某图</a></h3></div>'
          '<div class="result c-container ec-ad" mu="https://x.example.com/2">'
          '<h3><a href="https://x.example.com/2">广告位</a></h3></div>'
          '</body></html>';
      expect(() => BaiduEngine.parsePage(page), engineError('empty'));
    });
  });

  group('FetchPage 注入（search 全链路，假 fetch 不发网络）', () {
    test('so360：注入 fixture 返回结果，Uri 拼装正确', () async {
      final urls = <Uri>[];
      final engine = So360Engine((url, {extraHeaders}) async {
        urls.add(url);
        return fixture('so360.html');
      });
      final hits = await engine.search('华为Mate70', limit: 3);
      expect(hits.length, 3);
      expect(hits.first.engine, 'so360');
      expect(urls.single.host, 'www.so.com');
      expect(urls.single.path, '/s');
      expect(urls.single.queryParameters['q'], '华为Mate70');
      expect(urls.single.queryParameters['pn'], '1');
    });

    test('bing：RSS 0 item 自动降级 HTML（第二次请求去掉 format）', () async {
      final urls = <Uri>[];
      final engine = BingCnEngine((url, {extraHeaders}) async {
        urls.add(url);
        if (url.queryParameters['format'] == 'rss') {
          return '<rss version="2.0"><channel><title>必应：x</title></channel></rss>';
        }
        return fixture('bing_cn.html');
      });
      final hits = await engine.search('华为Mate70', limit: 4);
      expect(hits.length, 4);
      expect(urls, hasLength(2));
      expect(urls.first.queryParameters['format'], 'rss');
      expect(urls.first.queryParameters['mkt'], 'zh-CN');
      expect(urls.first.queryParameters.containsKey('format'), isTrue);
      expect(urls.last.queryParameters.containsKey('format'), isFalse);
      expect(urls.last.queryParameters['q'], '华为Mate70');
    });

    test('bing：count 夹紧到 [1,20]', () async {
      Uri? requested;
      final engine = BingCnEngine((url, {extraHeaders}) async {
        requested = url;
        return fixture('bing_rss.xml');
      });
      await engine.search('q', limit: 100);
      expect(requested!.queryParameters['count'], '20');
    });

    test('baidu：注入失败包装为 network 异常', () async {
      final engine = BaiduEngine((url, {extraHeaders}) async {
        throw StateError('boom');
      });
      await expectLater(engine.search('x'), engineError('network'));
    });

    test('注入方抛 SearchEngineException 原样上抛', () async {
      final engine = SogouEngine((url, {extraHeaders}) async {
        throw const SearchEngineException('sogou', 'network', '超时');
      });
      await expectLater(engine.search('x'), engineError('network'));
    });
  });
}
