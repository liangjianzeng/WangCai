/// data_api 的股票行情 provider —— 通用数据源框架的第一个实例。
///
/// 三源热备（2026-10-25 全部 curl 实测）：
/// - 主源 腾讯 `web.ifzq.gtimg.cn/appstock/app/fqkline/get`：
///   **参数是 6 段** `param=sz000157,day,,,320,qfq`（code,周期,起,止,条数,复权）——
///   5 段形态（条数放第 3 段）返回 `param error`。日/周/月线同形态。
/// - 备源1 东财 `push2his.eastmoney.com/api/qt/stock/kline/get`：
///   `secid=0.000157`（0=SZ/1=SH/116=HK），`klt=101/102/103` 日周月，
///   `fqt=0/1/2` 不复权/前/后；klines 逗号串 = date,open,close,high,low,vol(手)…
///   实时行情 `push2.eastmoney.com/api/qt/stock/get` 一次给全 PE/PB/市值/营收。
/// - 备源2 新浪 `quotes.sina.cn/cn/api/jsonp_v2.php/.../CN_MarketDataService.
///   getKLineData`：仅日线（scale=240），datalen ≤1023，volume 单位=股（其余源=手）；
///   实时 `hq.sinajs.cn` 必须带 `Referer: https://finance.sina.com.cn`，GBK 编码。
///
/// 热备语义（用户定案）：备用源不是纯故障切换——**主源返回条数不足请求量时，
/// 并行拉备用源按周期键合并**（union by day/week/month 键，主源优先），
/// 仍不足则带 meta 返回已有部分；全部源失败才报错。
library;

import 'dart:convert';

import 'package:fast_gbk/fast_gbk.dart' as gbk;

import '../fetch_url_tool.dart' show FetchHttpResponse, kFetchUserAgent;

/// 注入缝：与 fetch_url 同款抽象响应。
typedef StockHttp = Future<FetchHttpResponse> Function(
    Uri url, Map<String, String> headers);

// ---------------------------------------------------------------------------
// 符号归一：'000157' / '000157.SZ' / 'sz000157' / '600519.SH' / 'hk00700' /
// '00700.HK' / 'usAAPL' → 各源形态。
// ---------------------------------------------------------------------------

class _Sym {
  final String market; // cn | hk | us
  final String code; // 裸代码：000157 / 00700 / aapl
  final String tencent; // sz000157 / hk00700 / usAAPL
  final String? eastSecid; // 0.000157 / 116.00700（us 不支持）
  final String? sina; // sz000157（us 用 gb_aapl）
  const _Sym(this.market, this.code, this.tencent, this.eastSecid, this.sina);
}

_Sym? _normalizeSymbol(String raw) {
  final s = raw.trim().toLowerCase();
  if (s.isEmpty) return null;
  // 前缀形态：sz000157 / sh600519。
  var m = RegExp(r'^([shz]{2})(\d{6})$').firstMatch(s);
  if (m != null) return _cn(m.group(2)!, m.group(1)!);
  // 后缀形态：000157.SZ / 600519.SH / 00700.HK。
  m = RegExp(r'^(\d{4,6})[.:](hk|sh|sz|bj)$').firstMatch(s);
  if (m != null) {
    final code = m.group(1)!;
    switch (m.group(2)!) {
      case 'hk':
        final c = code.padLeft(5, '0');
        return _Sym('hk', c, 'hk$c', '116.$c', null);
      case 'sh':
        return _cn(code, 'sh');
      case 'sz':
        return _cn(code, 'sz');
      default:
        return null; // 北交所暂不支持
    }
  }
  // hk00700 / usAAPL 前缀形态。
  m = RegExp(r'^(hk|us)(\w+)$').firstMatch(s);
  if (m != null) {
    if (m.group(1) == 'hk') {
      final c = m.group(2)!.padLeft(5, '0');
      return _Sym('hk', c, 'hk$c', '116.$c', null);
    }
    final code = m.group(2)!;
    return _Sym('us', code, 'us$code', null, 'gb_$code');
  }
  // 纯数字：按首位推市场（6/9/5=SH，0/2/3=SZ；4/8 北交所不支持）。
  if (RegExp(r'^\d{6}$').hasMatch(s)) {
    final mk = '695'.contains(s[0])
        ? 'sh'
        : '023'.contains(s[0]) ? 'sz' : '';
    return mk.isEmpty ? null : _cn(s, mk);
  }
  // 4-5 位数字 → 港股。
  if (RegExp(r'^\d{4,5}$').hasMatch(s)) {
    final c = s.padLeft(5, '0');
    return _Sym('hk', c, 'hk$c', '116.$c', null);
  }
  // 字母代码 → 美股。
  if (RegExp(r'^[a-z]{1,6}$').hasMatch(s)) {
    return _Sym('us', s, 'us$s', null, 'gb_$s');
  }
  return null;
}

_Sym _cn(String code, String mk) => _Sym(
    'cn', code, '$mk$code', '${mk == 'sh' ? 1 : 0}.$code', '$mk$code');

// ---------------------------------------------------------------------------
// HTTP 基础
// ---------------------------------------------------------------------------

Future<FetchHttpResponse> _http(StockHttp http, Uri url,
    {Map<String, String> headers = const {}}) async {
  final resp = await http(url, {
    'User-Agent': kFetchUserAgent,
    'Accept': '*/*',
    ...headers,
  });
  if (resp.statusCode < 200 || resp.statusCode >= 300) {
    throw 'HTTP ${resp.statusCode}';
  }
  return resp;
}

String _bodyOf(FetchHttpResponse resp) {
  final ct = (resp.contentType ?? '').toLowerCase();
  final explicit = RegExp(r'charset=([\w-]+)', caseSensitive: false)
      .firstMatch(ct)
      ?.group(1);
  final head = latin1.decode(resp.bytes.take(256).toList(), allowInvalid: true);
  final meta = RegExp(r"""charset=["']?([\w-]+)""", caseSensitive: false)
      .firstMatch(head)
      ?.group(1);
  final cs = (explicit ?? meta ?? '').toLowerCase().replaceAll('-', '');
  final body = (cs == 'gbk' || cs == 'gb2312' || cs == 'gb18030')
      ? gbk.gbk.decode(resp.bytes)
      : utf8.decode(resp.bytes, allowMalformed: true);
  // 新浪 jsonp 系列在正文前塞一行反爬注释（/*<script>…</script>*/），剥掉。
  return body.replaceFirst(RegExp(r'^/\*.*?\*/', dotAll: true), '').trim();
}

double _num(Object? v) =>
    v is num ? v.toDouble() : (double.tryParse('${v ?? ''}') ?? 0);

double? _tryD(String? s) => (s == null || s.isEmpty) ? null : double.tryParse(s);

String _fmt(num n) =>
    n == n.roundToDouble() ? n.toInt().toString() : n.toString();

// ---------------------------------------------------------------------------
// 三源实现（K线）
// ---------------------------------------------------------------------------

class _SourceResult {
  final String id;
  final List<List<String>> bars; // [date,open,close,high,low,vol(手)]
  final Map<String, dynamic>? quote;
  final String? error;
  const _SourceResult(this.id, {this.bars = const [], this.quote, this.error});
  bool get ok => error == null;
}

Future<_SourceResult> _tencentKline(
    StockHttp http, _Sym sym, String period, int count, String adjust) async {
  try {
    if (sym.market == 'us') {
      return const _SourceResult('tencent', error: '腾讯 K线暂不支持美股');
    }
    final url = Uri.parse(
        'https://web.ifzq.gtimg.cn/appstock/app/fqkline/get'
        '?param=${sym.tencent},$period,,,$count,$adjust');
    final json =
        jsonDecode(_bodyOf(await _http(http, url))) as Map<String, dynamic>;
    if (json['code'] != 0) {
      return _SourceResult('tencent', error: 'code=${json['code']} ${json['msg']}');
    }
    final data = json['data'] as Map<String, dynamic>?;
    final node = data?[sym.tencent] as Map<String, dynamic>?;
    if (node == null) {
      return _SourceResult('tencent', error: '无 ${sym.tencent} 节点');
    }
    // 键：qfqday/hfqday/day、qfqweek/week、qfqmonth/month。
    for (final k in node.keys) {
      final kl = k.toLowerCase();
      if (kl == period || kl == 'qfq$period' || kl == 'hfq$period') {
        final v = node[k];
        if (v is List && v.isNotEmpty && v.first is List) {
          return _SourceResult(
              'tencent',
              bars: [
                for (final r in v.cast<List<dynamic>>())
                  [
                    for (var i = 0; i < 6 && i < r.length; i++) '${r[i]}'
                  ]
              ]);
        }
      }
    }
    return _SourceResult('tencent', error: '无 $period 键');
  } catch (e) {
    return _SourceResult('tencent', error: '$e');
  }
}

Future<_SourceResult> _eastKline(
    StockHttp http, _Sym sym, String period, int count, String adjust) async {
  try {
    if (sym.eastSecid == null) {
      return const _SourceResult('eastmoney', error: '东财 K线不支持该市场');
    }
    final klt = const {'day': 101, 'week': 102, 'month': 103}[period] ?? 101;
    final fqt = const {'none': 0, 'qfq': 1, 'hfq': 2}[adjust] ?? 1;
    final url = Uri.parse(
        'https://push2his.eastmoney.com/api/qt/stock/kline/get'
        '?secid=${sym.eastSecid}'
        '&fields1=f1,f2,f3,f4,f5,f6'
        '&fields2=f51,f52,f53,f54,f55,f56'
        '&klt=$klt&fqt=$fqt&beg=0&end=20500101&lmt=$count');
    final json =
        jsonDecode(_bodyOf(await _http(http, url))) as Map<String, dynamic>;
    final data = json['data'] as Map<String, dynamic>?;
    final klines = data?['klines'] as List?;
    if (klines == null || klines.isEmpty) {
      return const _SourceResult('eastmoney', error: 'klines 空');
    }
    return _SourceResult('eastmoney',
        bars: [
          for (final line in klines.cast<String>())
            line.split(',').take(6).toList()
        ],
        quote: {'name': data?['name']});
  } catch (e) {
    return _SourceResult('eastmoney', error: '$e');
  }
}

/// 日线聚合为周/月线（新浪兜底用）：组内首开/末收/最高/最低/量求和。
List<List<String>> aggregateBars(List<List<String>> dayBars, String period) {
  final groups = <String, List<List<String>>>{};
  for (final b in dayBars) {
    groups.putIfAbsent(periodKey(b[0], period), () => []).add(b);
  }
  final keys = groups.keys.toList()..sort();
  return [
    for (final k in keys)
      [
        groups[k]!.last[0],
        groups[k]!.first[1],
        groups[k]!.last[2],
        _fmt(groups[k]!.map((b) => _tryD(b[3]) ?? 0).reduce(_maxD)),
        _fmt(groups[k]!.map((b) => _tryD(b[4]) ?? 0).reduce(_minD)),
        _fmt(groups[k]!.map((b) => _tryD(b[5]) ?? 0).reduce((a, b) => a + b)),
      ]
  ];
}

double _maxD(double a, double b) => a > b ? a : b;
double _minD(double a, double b) => a < b ? a : b;

Future<_SourceResult> _sinaKline(
    StockHttp http, _Sym sym, String period, int count) async {
  try {
    if (sym.market != 'cn') {
      return const _SourceResult('sina', error: '新浪 K线仅支持沪深');
    }
    // 周/月需先取日线再聚合；datalen 上限 1023。
    final need = period == 'day'
        ? count
        : (period == 'week' ? count * 5 : count * 23).clamp(1, 1023);
    final url = Uri.parse(
        'https://quotes.sina.cn/cn/api/jsonp_v2.php/var%20_=/'
        'CN_MarketDataService.getKLineData?symbol=${sym.sina}'
        '&scale=240&ma=no&datalen=$need');
    final body = _bodyOf(await _http(http, url));
    final start = body.indexOf('[');
    final end = body.lastIndexOf(']');
    if (start < 0 || end <= start) {
      return const _SourceResult('sina', error: '响应无 JSON 数组');
    }
    final list = jsonDecode(body.substring(start, end + 1)) as List;
    final dayBars = [
      for (final e in list.cast<Map<String, dynamic>>())
        [
          '${e['day'] ?? ''}',
          '${e['open'] ?? ''}',
          '${e['close'] ?? ''}',
          '${e['high'] ?? ''}',
          '${e['low'] ?? ''}',
          // 新浪 volume 单位=股，归一到手（其余两源=手）。
          ((num.tryParse('${e['volume'] ?? 0}') ?? 0) / 100).toStringAsFixed(0),
        ]
    ];
    return _SourceResult('sina',
        bars: period == 'day' ? dayBars : aggregateBars(dayBars, period));
  } catch (e) {
    return _SourceResult('sina', error: '$e');
  }
}

// ---------------------------------------------------------------------------
// 三源实现（实时行情）
// ---------------------------------------------------------------------------

Future<_SourceResult> _eastQuote(StockHttp http, _Sym sym) async {
  try {
    if (sym.eastSecid == null) {
      return const _SourceResult('eastmoney', error: '东财实时不支持该市场');
    }
    final url = Uri.parse(
        'https://push2.eastmoney.com/api/qt/stock/get'
        '?secid=${sym.eastSecid}&fields='
        'f43,f44,f45,f46,f47,f48,f57,f58,f59,f60,f84,f85,f116,f117,'
        'f162,f167,f168,f169,f170,f183,f184,f186,f187');
    final json =
        jsonDecode(_bodyOf(await _http(http, url))) as Map<String, dynamic>;
    final data = json['data'] as Map<String, dynamic>?;
    if (data == null || data['f43'] == null || data['f43'] == '-') {
      return const _SourceResult('eastmoney', error: '无行情数据');
    }
    // 价格类字段按 f59（小数位）缩放回原值；缺省按百分位 /100。
    final digits = _num(data['f59']);
    final scale = digits > 0 ? _pow10(digits.toInt()) : 100.0;
    double? scaled(Object? v) =>
        v is num ? v / scale : double.tryParse('${v ?? ''}');
    return _SourceResult('eastmoney', quote: {
      'name': data['f58'],
      'price': scaled(data['f43']),
      'open': scaled(data['f46']),
      'prev_close': scaled(data['f60']),
      'high': scaled(data['f44']),
      'low': scaled(data['f45']),
      'volume': _num(data['f47']), // 手
      'amount': _num(data['f48']),
      'change': scaled(data['f169']),
      'change_pct': scaled(data['f170']),
      'pe_ttm': scaled(data['f162']),
      'pb': scaled(data['f167']),
      'turnover_pct': scaled(data['f168']),
      'total_shares': _num(data['f84']),
      'float_shares': _num(data['f85']),
      'market_cap': _num(data['f116']),
      'float_cap': _num(data['f117']),
      'revenue': _num(data['f183']),
      'revenue_yoy': scaled(data['f184']),
      'profit': _num(data['f186']),
      'profit_yoy': scaled(data['f187']),
      'source': 'eastmoney',
    });
  } catch (e) {
    return _SourceResult('eastmoney', error: '$e');
  }
}

double _pow10(int n) {
  var v = 1.0;
  for (var i = 0; i < n; i++) {
    v *= 10;
  }
  return v;
}

Future<_SourceResult> _tencentQuote(StockHttp http, _Sym sym) async {
  try {
    final body = _bodyOf(
        await _http(http, Uri.parse('https://qt.gtimg.cn/q=${sym.tencent}')));
    final m = RegExp(r'"([^"]*)"').firstMatch(body);
    if (m == null) return const _SourceResult('tencent', error: '响应无引号串');
    final f = m.group(1)!.split('~');
    String? at(int i) => i < f.length && f[i].isNotEmpty ? f[i] : null;
    return _SourceResult('tencent', quote: {
      'name': at(1),
      'price': _tryD(at(3)),
      'prev_close': _tryD(at(4)),
      'open': _tryD(at(5)),
      'volume': _tryD(at(6)), // 手
      'change': _tryD(at(31)),
      'change_pct': _tryD(at(32)),
      'high': _tryD(at(33)),
      'low': _tryD(at(34)),
      'turnover_pct': _tryD(at(38)),
      'pe_ttm': _tryD(at(39)),
      'float_cap': _tryD(at(44)) == null
          ? null
          : (_tryD(at(44)) ?? 0) * 1e8, // 亿 → 元
      'market_cap': _tryD(at(45)) == null
          ? null
          : (_tryD(at(45)) ?? 0) * 1e8,
      'pb': _tryD(at(46)),
      'time': at(30),
      'source': 'tencent',
    });
  } catch (e) {
    return _SourceResult('tencent', error: '$e');
  }
}

Future<_SourceResult> _sinaQuote(StockHttp http, _Sym sym) async {
  try {
    if (sym.market != 'cn') {
      return const _SourceResult('sina', error: '新浪实时仅支持沪深');
    }
    final body = _bodyOf(await _http(
        http, Uri.parse('https://hq.sinajs.cn/list=${sym.sina}'),
        headers: {'Referer': 'https://finance.sina.com.cn'}));
    final m = RegExp(r'"([^"]*)"').firstMatch(body);
    if (m == null) return const _SourceResult('sina', error: '响应无引号串');
    final f = m.group(1)!.split(',');
    String? at(int i) => i < f.length && f[i].isNotEmpty ? f[i] : null;
    return _SourceResult('sina', quote: {
      'name': at(0),
      'open': _tryD(at(1)),
      'prev_close': _tryD(at(2)),
      'price': _tryD(at(3)),
      'high': _tryD(at(4)),
      'low': _tryD(at(5)),
      'volume': _tryD(at(8)), // 股（唯一源时换算不到手，注明单位）
      'amount': _tryD(at(9)),
      'time': '${at(30)} ${at(31)}',
      'source': 'sina',
    });
  } catch (e) {
    return _SourceResult('sina', error: '$e');
  }
}

// ---------------------------------------------------------------------------
// 合并
// ---------------------------------------------------------------------------

/// 周期键：day=日期本身；week=ISO 周；month=YYYY-MM。
/// 跨源合并用周期键去重——不同源的周/月线"末端日期"可能差一天，
/// 直接按日期合并会出近重复 K 线。
String periodKey(String date, String period) {
  if (period == 'day' || date.length < 10) return date;
  if (period == 'month') return date.substring(0, 7);
  final d = DateTime.parse(date);
  final thursday = d.add(Duration(days: 3 - ((d.weekday + 6) % 7)));
  final weekNum = (thursday
              .difference(DateTime(thursday.year, 1, 1))
              .inDays /
          7)
      .floor() +
      1;
  return '${thursday.year}-W${weekNum.toString().padLeft(2, '0')}';
}

/// 热备合并：主源在先占位，后源只补周期键缺口（保留主源价格口径，
/// 避免复权基准混写）；输出按日期升序。
(List<List<String>>, Map<String, int>) mergeBars(
    Map<String, List<List<String>>> bySource, String period) {
  final out = <String, List<String>>{};
  final perSource = <String, int>{};
  for (final entry in bySource.entries) {
    var used = 0;
    for (final bar in entry.value) {
      if (bar.length < 6 || bar[0].isEmpty) continue;
      final key = periodKey(bar[0], period);
      if (!out.containsKey(key)) {
        out[key] = bar;
        used++;
      }
    }
    perSource[entry.key] = used;
  }
  final bars = out.values.toList()..sort((a, b) => a[0].compareTo(b[0]));
  return (bars, perSource);
}

// ---------------------------------------------------------------------------
// 入口：action = kline / quote / both
// ---------------------------------------------------------------------------

/// 行情入口。抛异常（String）= 全源失败；正常返回可直接 jsonEncode 的 Map。
Future<Map<String, dynamic>> fetchStockData(
  StockHttp http, {
  required String symbol,
  String action = 'kline',
  String period = 'day',
  int count = 320,
  String adjust = 'qfq',
}) async {
  final sym = _normalizeSymbol(symbol);
  if (sym == null) {
    throw '无法识别的代码「$symbol」：支持 000157 / 000157.SZ / sz000157 / '
        '600519.SH / hk00700 / 00700.HK / usAAPL（北交所暂不支持）';
  }
  final p = const {'day', 'week', 'month'}.contains(period) ? period : 'day';
  final a = const {'qfq', 'hfq', 'none'}.contains(adjust) ? adjust : 'qfq';
  final c = count.clamp(1, 800).toInt();

  final klineFut = action != 'quote'
      ? _fetchKlines(http, sym, period: p, count: c, adjust: a)
      : Future.value(null);
  final quoteFut =
      action != 'kline' ? _fetchQuote(http, sym) : Future.value(null);
  final klines = await klineFut;
  final quote = await quoteFut;

  return {
    'symbol': sym.tencent,
    if (klines != null) ...klines,
    if (quote != null) ...quote,
    'name': quote?['name'] ?? klines?['name'],
  };
}

Future<Map<String, dynamic>?> _fetchKlines(
    StockHttp http, _Sym sym,
    {required String period, required int count, required String adjust}) async {
  // 主源：腾讯。热备语义：不足请求量或失败 → 并行拉备用源按周期键合并。
  final primary =
      await _tencentKline(http, sym, period, count, adjust);
  final bySource = <String, List<List<String>>>{};
  String? name;
  if (primary.ok) {
    bySource['tencent'] = primary.bars;
  }

  final enough = primary.ok && primary.bars.length >= count;
  List<List<String>> bars;
  Map<String, int> perSource;
  if (enough) {
    bars = primary.bars;
    perSource = {'tencent': primary.bars.length};
  } else {
    final backups = await Future.wait([
      _eastKline(http, sym, period, count, adjust),
      _sinaKline(http, sym, period, count),
    ]);
    for (final b in backups) {
      if (b.ok && b.bars.isNotEmpty) bySource[b.id] = b.bars;
      if (b.quote?['name'] is String) name = b.quote!['name'] as String;
    }
    if (bySource.isEmpty) {
      final errs = [
        'tencent: ${primary.error}',
        for (final b in backups) '${b.id}: ${b.error}',
      ].join('；');
      throw '三源均未取得 K 线（$errs）';
    }
    (bars, perSource) = mergeBars(bySource, period);
  }

  return {
    'action': 'kline',
    'period': period,
    'adjust': adjust,
    'requested': count,
    'returned': bars.length,
    'merged': perSource.length > 1,
    'sources': perSource,
    'unit': {'volume': '手'},
    if (bars.length < count)
      'note': '全部来源仅 ${bars.length} 根（< $count），可能为次新股或数据上限',
    'bars': bars,
    if (name != null) 'name': name,
  };
}

Future<Map<String, dynamic>?> _fetchQuote(StockHttp http, _Sym sym) async {
  // 实时行情为单快照，三源并行、取第一成功者（东财字段最全）。
  final results = await Future.wait([
    _eastQuote(http, sym),
    _tencentQuote(http, sym),
    _sinaQuote(http, sym),
  ]);
  for (final r in results) {
    if (r.ok && r.quote?['price'] != null) {
      final q = Map<String, dynamic>.from(r.quote!);
      q['action'] = 'quote';
      q['symbol'] = sym.tencent;
      return q;
    }
  }
  final errs = [for (final r in results) '${r.id}: ${r.error}'].join('；');
  throw '实时行情三源均失败（$errs）';
}
