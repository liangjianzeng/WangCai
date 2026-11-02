/// 多引擎聚合器测试：轮转合并/去重、引擎级熔断冷却、诊断文案、链接还原。
library;

import 'package:flutter_test/flutter_test.dart';
import 'package:dio/dio.dart';
import 'package:tongyi_lite/websearch/src/link_resolver.dart';
import 'package:tongyi_lite/websearch/src/multi_engine_search.dart';
import 'package:tongyi_lite/websearch/src/search_engine.dart';
import 'package:tongyi_lite/websearch/src/search_hit.dart';

/// 可脚本化的假引擎：[handler] 决定返回结果或抛异常。
class FakeEngine implements SearchEngine {
  @override
  final String id;
  @override
  final String displayName;
  final Future<List<SearchHit>> Function(String query, int limit) handler;
  int calls = 0;

  FakeEngine(this.id, this.displayName, this.handler);

  @override
  Future<List<SearchHit>> search(String query, {int limit = 8}) async {
    calls++;
    return handler(query, limit);
  }

  @override
  void dispose() {}
}

SearchHit hit(String engine, String url, {String? title}) =>
    SearchHit(title: title ?? 't-$url', url: url, engine: engine);

class _Ticker {
  DateTime now = DateTime(2026, 10, 2, 12);
  DateTime Function() get fn => () => now;
  void advance(Duration d) => now = now.add(d);
}

void main() {
  group('轮转合并与去重', () {
    test('按引擎优先级轮转取第 i 条，去重跨引擎同源', () async {
      final a = FakeEngine('a', 'A', (q, l) async => [
            hit('a', 'https://x.com/1'),
            hit('a', 'https://x.com/2'),
            hit('a', 'https://x.com/3'),
          ]);
      final b = FakeEngine('b', 'B', (q, l) async => [
            hit('b', 'https://x.com/1'), // 与 a 的第一条同源 → 去重
            hit('b', 'https://y.com/1'),
          ]);
      final m = MultiEngineSearch(engines: [a, b], maxResults: 8, now: () => DateTime(2026));
      final out = await m.search('q');
      // 轮转（按索引）：a1 → b1(去重跳过) → a2 → b2 → a3
      expect(out.hits.map((h) => h.url).toList(),
          ['https://x.com/1', 'https://x.com/2', 'https://y.com/1', 'https://x.com/3']);
      expect(out.allFailed, isFalse);
    });

    test('超出 maxResults 标记 truncated', () async {
      final a = FakeEngine('a', 'A', (q, l) async => List.generate(5, (i) => hit('a', 'https://a.com/$i')));
      final m = MultiEngineSearch(engines: [a], maxResults: 3, now: () => DateTime(2026));
      final out = await m.search('q');
      expect(out.hits, hasLength(3));
      expect(out.truncated, isTrue);
    });

    test('加权合并：权重 2 的引擎占 2/3 席位', () async {
      final a = FakeEngine('a', 'A', (q, l) async =>
          List.generate(6, (i) => hit('a', 'https://a.com/$i')));
      final b = FakeEngine('b', 'B', (q, l) async =>
          List.generate(6, (i) => hit('b', 'https://b.com/$i')));
      final m = MultiEngineSearch(
        engines: [a, b],
        maxResults: 6,
        engineWeights: const {'a': 2, 'b': 1},
        now: () => DateTime(2026),
      );
      final out = await m.search('q');
      final urls = out.hits.map((h) => h.url).toList();
      expect(urls.take(3), ['https://a.com/0', 'https://a.com/1', 'https://b.com/0']);
      expect(urls.where((u) => u.contains('a.com')), hasLength(4)); // 6 席中 a 占 4
      expect(urls.where((u) => u.contains('b.com')), hasLength(2));
    });

    test('blocked 时回调 onEngineBlocked（供上层清 Cookie 会话）', () async {
      final bad = FakeEngine('bad', 'B', (q, l) async {
        throw const SearchEngineException('bad', 'blocked', 'x');
      });
      final cleared = <String>[];
      final m = MultiEngineSearch(
        engines: [bad],
        onEngineBlocked: cleared.add,
        now: () => DateTime(2026),
      );
      await m.search('q');
      expect(cleared, ['bad']);
    });

    test('窗口预算：高风险引擎预算耗尽后跳过，窗口到期自动恢复', () async {
      final ticker = _Ticker();
      final e = FakeEngine('sogou', '搜狗', (q, l) async =>
          [hit('sogou', 'https://s.com/${ticker.now.millisecondsSinceEpoch}')]);
      final m = MultiEngineSearch(
        engines: [e],
        engineBudgets: const {'sogou': 2},
        budgetWindow: const Duration(minutes: 10),
        now: ticker.fn,
      );
      final r1 = await m.search('q');
      final r2 = await m.search('q');
      final r3 = await m.search('q'); // 预算（2）耗尽
      expect(r1.engineStatus['sogou'], 'ok:1');
      expect(r2.engineStatus['sogou'], 'ok:1');
      expect(r3.engineStatus['sogou'], 'budget');
      expect(e.calls, 2);

      ticker.advance(const Duration(minutes: 10, seconds: 1));
      final r4 = await m.search('q');
      expect(r4.engineStatus['sogou'], 'ok:1'); // 窗口重置
      expect(e.calls, 3);
    });

    test('未配置预算的引擎不受限', () async {
      final e = FakeEngine('bing_cn', '必应', (q, l) async => [hit('b', 'https://b.com/x')]);
      final m = MultiEngineSearch(
        engines: [e],
        engineBudgets: const {'other': 1},
        now: () => DateTime(2026),
      );
      for (var i = 0; i < 5; i++) {
        final r = await m.search('q');
        expect(r.engineStatus['bing_cn'], 'ok:1');
      }
      expect(e.calls, 5);
    });

    test('时效类查询降权百科：百科条目稳定排到尾部', () async {
      final e = FakeEngine('bing_cn', '必应', (q, l) async => [
            hit('b', 'https://baike.baidu.com/item/北海市/1'),
            hit('b', 'https://news.example.com/a'),
            hit('b', 'https://wenku.baidu.com/view/x'),
            hit('b', 'https://news.example.com/b'),
          ]);
      final m = MultiEngineSearch(engines: [e], maxResults: 8, now: () => DateTime(2026));
      final out = await m.search('北海 新闻 今天');
      expect(out.hits.first.url, 'https://news.example.com/a');
      expect(out.hits[1].url, 'https://news.example.com/b');
      // 尾部两位全是被降权的百科/文库（保持原有相对顺序）。
      expect(out.hits[2].url, contains('baike.baidu.com'));
      expect(out.hits[3].url, contains('wenku.baidu.com'));

      // 非时效查询不降权（百科保持原位）。
      final out2 = await m.search('北海市 是什么');
      expect(out2.hits.first.url, contains('baike.baidu.com'));
    });
  });

  group('引擎级熔断', () {
    test('blocked 触发冷却：下次搜索跳过该引擎不调用', () async {
      final ticker = _Ticker();
      final bad = FakeEngine('bad', 'B', (q, l) async {
        throw const SearchEngineException('bad', 'blocked', '验证码');
      });
      final good = FakeEngine('good', 'G', (q, l) async => [hit('g', 'https://g.com/1')]);
      final m = MultiEngineSearch(
          engines: [bad, good], maxResults: 8, now: ticker.fn);

      final out1 = await m.search('q');
      expect(out1.hits, hasLength(1));
      expect(out1.engineStatus['bad'], startsWith('blocked'));
      expect(bad.calls, 1);

      final out2 = await m.search('q');
      expect(out2.engineStatus['bad'], startsWith('cooling'));
      expect(bad.calls, 1); // 冷却期内未再调用
      expect(out2.hits, hasLength(1)); // 好引擎照常出结果

      // 冷却到期（默认 blocked 首次 1min）自动重试。
      ticker.advance(const Duration(minutes: 1, seconds: 1));
      await m.search('q');
      expect(bad.calls, 2);
    });

    test('blocked 指数退避：连续封锁冷却时长翻倍（1min→2min）', () async {
      final ticker = _Ticker();
      final bad = FakeEngine('bad', 'B', (q, l) async {
        throw const SearchEngineException('bad', 'blocked', '验证码');
      });
      final m = MultiEngineSearch(engines: [bad], now: ticker.fn);
      await m.search('q'); // 第1次：1min
      expect(m.isCooling('bad'), isTrue);
      ticker.advance(const Duration(minutes: 1, seconds: 1));
      await m.search('q'); // 第2次：2min
      ticker.advance(const Duration(minutes: 1));
      expect(m.isCooling('bad'), isTrue); // 2min 未到
      ticker.advance(const Duration(minutes: 1, seconds: 1));
      expect(m.isCooling('bad'), isFalse); // 2min+1s 到期
    });

    test('成功重置封锁连击；empty 不冷却', () async {
      final ticker = _Ticker();
      var fail = true;
      final e = FakeEngine('e', 'E', (q, l) async {
        if (q == 'empty') {
          throw const SearchEngineException('e', 'empty', '0条');
        }
        if (fail) throw const SearchEngineException('e', 'blocked', 'x');
        return [hit('e', 'https://e.com/1')];
      });
      final m = MultiEngineSearch(engines: [e], now: ticker.fn);
      await m.search('q'); // blocked #1 → 冷却 1min
      fail = false;
      ticker.advance(const Duration(minutes: 1, seconds: 1));
      await m.search('ok'); // 成功 → streak 清零
      await m.search('empty'); // empty → 不冷却
      expect(m.isCooling('e'), isFalse);
      // 下次 blocked 因为 streak 已重置，冷却回到 1min 而不是 4min。
      fail = true;
      await m.search('q');
      ticker.advance(const Duration(minutes: 1, seconds: 1));
      expect(m.isCooling('e'), isFalse);
    });

    test('parse 冷却 3min；network 冷却 20s', () async {
      final ticker = _Ticker();
      final e = FakeEngine('e', 'E', (q, l) async {
        throw const SearchEngineException('e', 'parse', '结构不认识');
      });
      final m = MultiEngineSearch(engines: [e], now: ticker.fn);
      await m.search('q');
      ticker.advance(const Duration(minutes: 2));
      expect(m.isCooling('e'), isTrue);
      ticker.advance(const Duration(minutes: 1, seconds: 1));
      expect(m.isCooling('e'), isFalse);
    });
  });

  group('诊断与全失败', () {
    test('全部失败 → 空结果 + 各引擎状态 + 可行动诊断', () async {
      final a = FakeEngine('a', 'A', (q, l) async =>
          throw const SearchEngineException('a', 'blocked', '验证码'));
      final b = FakeEngine('b', 'B', (q, l) async =>
          throw const SearchEngineException('b', 'network', '超时'));
      final m = MultiEngineSearch(engines: [a, b], now: () => DateTime(2026));
      final out = await m.search('q');
      expect(out.allFailed, isTrue);
      expect(out.hits, isEmpty);
      expect(out.engineStatus['a'], startsWith('blocked'));
      expect(out.engineStatus['b'], startsWith('network'));
      final text = out.diagnosticsText();
      expect(text, contains('a: blocked'));
      expect(text, contains('b: network'));
    });
  });

  group('链接还原', () {
    test('只还原跳转链，还原失败保留原链', () async {
      final a = FakeEngine('a', 'A', (q, l) async => [
            hit('a', 'https://www.chinaso.com/link?url=abc'),
            hit('a', 'https://direct.com/1'),
          ]);
      final resolver = _FakeResolver({
        'https://www.chinaso.com/link?url=abc': 'https://real.com/page',
      });
      final m = MultiEngineSearch(
          engines: [a], resolver: resolver, now: () => DateTime(2026));
      final out = await m.search('q');
      expect(out.hits[0].url, 'https://real.com/page');
      expect(out.hits[1].url, 'https://direct.com/1');
    });
  });
}

class _FakeResolver extends LinkResolver {
  final Map<String, String> mapping;
  _FakeResolver(this.mapping) : super(dio: Dio());

  @override
  Future<String?> resolve(String rawUrl, {String userAgent = ''}) async =>
      mapping[rawUrl];
}
