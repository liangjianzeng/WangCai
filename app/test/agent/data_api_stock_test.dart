import 'dart:convert';

import 'package:fast_gbk/fast_gbk.dart' as gbk;
import 'package:flutter_test/flutter_test.dart';

import 'package:tongyi_lite/agent/builtin_tools/data_api/data_api_tool.dart';
import 'package:tongyi_lite/agent/builtin_tools/data_api/stock_source.dart';
import 'package:tongyi_lite/agent/builtin_tools/fetch_url_tool.dart';

/// 按 URL 前缀路由到各源 fixture 的桩。
ApiHttp stubHttp({
  String? tencentKline,
  String? eastKline,
  String? sinaKline,
  String? eastQuote,
  String? tencentQuote,
  String? sinaQuote,
  List<String>? failedPrefixes,
}) {
  return (url, headers) async {
    final s = url.toString();
    final fail = failedPrefixes?.any(s.startsWith) ?? false;
    if (fail) {
      return FetchHttpResponse(statusCode: 503, bytes: const []);
    }
    String? body;
    if (s.startsWith('https://web.ifzq.gtimg.cn/appstock/app/fqkline/')) {
      body = tencentKline;
    } else if (s.startsWith('https://push2his.eastmoney.com/')) {
      body = eastKline;
    } else if (s.startsWith('https://quotes.sina.cn/')) {
      body = sinaKline;
    } else if (s.startsWith('https://push2.eastmoney.com/')) {
      body = eastQuote;
    } else if (s.startsWith('https://qt.gtimg.cn/')) {
      body = tencentQuote;
    } else if (s.startsWith('https://hq.sinajs.cn/')) {
      expect(headers, contains('Referer'), reason: '新浪实时必须带 Referer');
      body = sinaQuote;
    }
    if (body == null) {
      return FetchHttpResponse(statusCode: 404, bytes: const []);
    }
    return FetchHttpResponse(
        statusCode: 200, contentType: 'application/json', bytes: utf8.encode(body));
  };
}

String tencentKlineJson(List<List<String>> rows) => jsonEncode({
      'code': 0,
      'data': {
        'sz000157': {
          'qfqday': [for (final r in rows) r],
        }
      },
    });

String eastKlineJson(List<String> lines, {String name = '中联重科'}) => jsonEncode({
      'data': {'name': name, 'klines': lines},
    });

void main() {
  group('data_api / stock：符号归一 + 三源热备', () {
    test('主源足量：不触发备用源', () async {
      var sinaHit = 0, eastHit = 0;
      final r = await stockProvider(http: (url, headers) {
        if (url.toString().startsWith('https://quotes.sina.cn/')) sinaHit++;
        if (url.toString().startsWith('https://push2his.eastmoney.com/')) {
          eastHit++;
        }
        return stubHttp(
          tencentKline: tencentKlineJson([
            ['2026-10-21', '5.80', '5.84', '5.90', '5.79', '100'],
            ['2026-10-22', '5.84', '5.89', '5.91', '5.76', '200'],
          ]),
        )(url, headers);
      }).execute({'symbol': '000157', 'action': 'kline', 'count': 2});
      expect(r.isError, isFalse, reason: r.content);
      expect(r.content, contains('2026-10-21,5.80,5.84,5.90,5.79,100'));
      expect(r.content, contains('"returned":2'));
      expect(r.content, contains('"merged":false'));
      expect(sinaHit, 0, reason: '足量时不应触碰新浪');
      expect(eastHit, 0, reason: '足量时不应触碰东财');
    });

    test('热备：主源不足 → 并行拉备用源按日期合并（主源优先）', () async {
      final r = await stockProvider(http: stubHttp(
        // 腾讯只有 1 根（不足请求的 2 根）。
        tencentKline: tencentKlineJson([
          ['2026-10-22', '5.84', '5.89', '5.91', '5.76', '200'],
        ]),
        // 东财补出 10-21 与重复的 10-22（重复段应被主源占位）。
        eastKline: eastKlineJson([
          '2026-10-21,5.80,5.84,5.90,5.79,100',
          '2026-10-22,9.99,9.99,9.99,9.99,999',
        ]),
        // 新浪（日线，volume 股→手）补更早的 10-20。
        sinaKline:
            '[{"day":"2026-10-20","open":"5.70","high":"5.80","low":"5.69","close":"5.78","volume":"1200000"}]',
      )).execute({'symbol': 'sz000157', 'action': 'kline', 'count': 5});
      expect(r.isError, isFalse, reason: r.content);
      expect(r.content, contains('2026-10-20,5.70,5.78,5.80,5.69,12000'),
          reason: '新浪 volume 股→手');
      expect(r.content, contains('2026-10-21,5.80,5.84,5.90,5.79,100'),
          reason: '东财补缺');
      // 10-22 重复段：主源占位，东财的 9.99 不得混入。
      expect(r.content, contains('2026-10-22,5.84,5.89,5.91,5.76,200'));
      expect(r.content, isNot(contains('9.99')));
      expect(r.content, contains('"merged":true'));
      expect(r.content, contains('"eastmoney":1'));
    });

    test('主源失败：备用源顶上', () async {
      final r = await stockProvider(http: stubHttp(
        failedPrefixes: ['https://web.ifzq.gtimg.cn/'],
        eastKline: eastKlineJson([
          '2026-10-21,5.80,5.84,5.90,5.79,100',
          '2026-10-22,5.84,5.89,5.91,5.76,200',
        ]),
      )).execute({'symbol': '000157', 'action': 'kline', 'count': 2});
      expect(r.isError, isFalse, reason: r.content);
      expect(r.content, contains('"sources":{"eastmoney":2}'),
          reason: '失败源不进 sources 计数');
    });

    test('三源全挂：报错并列各源原因', () async {
      final r = await stockProvider(http: stubHttp(
        failedPrefixes: [
          'https://web.ifzq.gtimg.cn/',
          'https://push2his.eastmoney.com/',
          'https://quotes.sina.cn/',
        ],
      )).execute({'symbol': '000157', 'action': 'kline'});
      expect(r.isError, isTrue);
      expect(r.content, contains('三源均未取得'));
      expect(r.content, contains('tencent'));
      expect(r.content, contains('eastmoney'));
      expect(r.content, contains('sina'));
    });

    test('实时快照：东财优先，f43 按 f59 缩放', () async {
      final r = await stockProvider(http: stubHttp(
        eastQuote: jsonEncode({
          'data': {
            'f43': 589, 'f44': 591, 'f45': 576, 'f46': 580, 'f59': 2,
            'f47': 530504, 'f48': 310657195.28, 'f57': '000157',
            'f58': '中联重科', 'f60': 584, 'f84': 8648535236, 'f85': 7070417363,
            'f116': 50939872540.04, 'f117': 41644758268.07,
            'f162': 1212, 'f167': 88, 'f168': 75, 'f169': 5, 'f170': 86,
            'f183': 27135030851.85, 'f184': 917, 'f186': 2050000000,
            'f187': 787,
          }
        }),
      )).execute({'symbol': '000157', 'action': 'quote'});
      expect(r.isError, isFalse, reason: r.content);
      expect(r.content, contains('"price":5.89'));
      expect(r.content, contains('"pe_ttm":12.12'));
      expect(r.content, contains('"pb":0.88'));
      expect(r.content, contains('"change_pct":0.86'));
      expect(r.content, contains('中联重科'));
    });

    test('东财实时挂 → 腾讯快照顶上（GBK 解码）', () async {
      // 真实抓包串（qt.gtimg.cn/q=sz000157，GBK）。
      final gbkBody = gbk.gbk.encode(
          'v_sz000157="51~中联重科~000157~5.89~5.84~5.80~530504~291509~238994~'
          '5.89~3717~5.88~5656~5.87~2419~5.86~1522~5.85~1651~5.90~673~'
          '5.91~8698~5.92~5399~5.93~2104~5.94~3063~~20261023161500~0.05~0.86~'
          '5.91~5.76~5.89/530504/310657195~530504~31066~0.75~12.14~~5.91~5.76~'
          '2.57~416.45~509.40~0.88~6.42~5.26"');
      final r = await stockProvider(http: stubHttp(
        failedPrefixes: ['https://push2.eastmoney.com/'],
        tencentQuote: null,
        sinaQuote: null,
      )).execute({'symbol': '000157', 'action': 'quote'});
      // 上面的 stub 不含腾讯实时路径，这里单独用定向桩。
      expect(r.isError, isTrue); // 本桩未配腾讯实时 → 应失败而非静默
      // 定向桩验证腾讯快照解析。
      final r2 = await stockProvider(http: (url, headers) {
        final s = url.toString();
        if (s.startsWith('https://push2.eastmoney.com/')) {
          return Future.value(FetchHttpResponse(statusCode: 503));
        }
        if (s.startsWith('https://qt.gtimg.cn/')) {
          return Future.value(FetchHttpResponse(
              statusCode: 200,
              contentType: 'text/html; charset=gbk',
              bytes: gbkBody));
        }
        return Future.value(FetchHttpResponse(statusCode: 503));
      }).execute({'symbol': '000157', 'action': 'quote'});
      expect(r2.isError, isFalse, reason: r2.content);
      expect(r2.content, contains('中联重科'));
      expect(r2.content, contains('"price":5.89'));
      expect(r2.content, contains('"market_cap":50940000000.0'));
    });

    test('周期键合并：周线跨源按 ISO 周去重', () async {
      final r = await stockProvider(http: stubHttp(
        tencentKline: jsonEncode({
          'code': 0,
          'data': {
            'sz000157': {
              'qfqweek': [
                ['2026-10-23', '5.80', '5.89', '5.91', '5.76', '1000'],
              ]
            }
          },
        }),
        eastKline: eastKlineJson([
          '2026-10-24,5.79,5.90,5.92,5.75,1100', // 同一周（键 2026-W43）
        ]),
      )).execute({'symbol': '000157', 'action': 'kline', 'count': 5, 'period': 'week'});
      expect(r.isError, isFalse, reason: r.content);
      expect(r.content, contains('"returned":1'), reason: '同一 ISO 周只保留主源');
    });

    test('非法代码与北交所拒绝', () async {
      final p = stockProvider(http: stubHttp());
      expect((await p.execute({'symbol': '831010'})).isError, isTrue);
      expect((await p.execute({'symbol': '!!'})).isError, isTrue);
      expect((await p.execute({})).isError, isTrue);
    });

    test('未知 source 与缺 source 报可用清单', () async {
      final tool = createDataApiTool();
      final r1 = await tool.execute({'source': 'nope'});
      expect(r1.isError, isTrue);
      expect(r1.content, contains('stock'));
      final r2 = await tool.execute({});
      expect(r2.isError, isTrue);
      expect(r2.content, contains('stock'));
    });
  });

  group('K 线聚合与周期键（纯函数）', () {
    test('日线聚合为月线：首开/末收/最高/最低/量和', () {
      final bars = aggregateBars([
        ['2026-09-01', '5.0', '5.1', '5.2', '4.9', '100'],
        ['2026-09-15', '5.1', '5.3', '5.5', '5.0', '150'],
        ['2026-10-08', '5.3', '5.4', '5.6', '5.2', '200'],
      ], 'month');
      expect(bars.length, 2);
      expect(bars[0], ['2026-09-15', '5.0', '5.3', '5.5', '4.9', '250']);
      expect(bars[1][0], '2026-10-08');
    });

    test('periodKey：日=日期 / 月=YYYY-MM / 周=ISO 周', () {
      expect(periodKey('2026-10-25', 'day'), '2026-10-25');
      expect(periodKey('2026-10-25', 'month'), '2026-10');
      // 2026-10-25 是周日，ISO 周 = 2026-W43（周一 10-19 起）。
      expect(periodKey('2026-10-25', 'week'), '2026-W43');
      expect(periodKey('2026-10-23', 'week'), '2026-W43');
      expect(periodKey('2026-10-19', 'week'), '2026-W43');
    });

    test('mergeBars：按周期键 union、主源优先、按日期升序', () {
      final (bars, perSource) = mergeBars({
        'a': [
          ['2026-10-22', '5.8', '5.9', '5.9', '5.7', '1'],
        ],
        'b': [
          ['2026-10-21', '5.7', '5.8', '5.8', '5.6', '1'],
          ['2026-10-22', '9', '9', '9', '9', '9'],
        ],
      }, 'day');
      expect(bars.map((b) => b[0]).toList(), ['2026-10-21', '2026-10-22']);
      expect(bars[1][1], '5.8', reason: '主源优先');
      expect(perSource, {'a': 1, 'b': 1});
    });
  });
}
