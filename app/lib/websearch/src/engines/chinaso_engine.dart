/// 中国搜索（www.chinaso.com，国搜官方聚合）适配器。
///
/// 官方 JSON 接口，免 key：
/// `GET /v5/general/v1/web/search?q=&pn=1&ps=10`
/// → `{"status":0,"msg":"success","data":{"data":[{title,url,snippet,timestamp}]}}`
///
/// 约束/坑（2026-10-02 实测）：
/// - **必须带随机 `uid` Cookie**（`uid=base64(16 随机字节)`，对齐 SearXNG
///   chinaso.py）——不带会被 `{"status":2,"msg":"ip control"}` 拒绝；
/// - `status:2` / msg 含 "ip control" 判 blocked（IP 维度风控，熔断冷却）；
/// - 结果的 url 是 `chinaso.com/link?url=...` 跳转链（官方设计如此），真实
///   地址靠聚合器的链接还原器 302 解开；title/snippet 内嵌 `<em>` 高亮标签，
///   用 htmlToText 清洗；timestamp 为 Unix 秒字符串。
library;

import 'dart:convert';
import 'dart:math';

import '../html_text.dart';
import '../search_engine.dart';
import '../search_hit.dart';
import 'common.dart';

class ChinasoEngine implements SearchEngine {
  @override
  String get id => 'chinaso';

  @override
  String get displayName => '中国搜索';

  final FetchPage fetch;
  final Random _rnd;

  ChinasoEngine(this.fetch, {Random? random}) : _rnd = random ?? Random.secure();

  /// 每次请求生成随机 uid Cookie（SearXNG 同款做法）。
  String buildUidCookie() =>
      'uid=${base64.encode(List<int>.generate(16, (_) => _rnd.nextInt(256)))}';

  @override
  Future<List<SearchHit>> search(String query, {int limit = 8}) async {
    final n = limit.clamp(1, 20);
    final url = Uri.https('www.chinaso.com', '/v5/general/v1/web/search', {
      'q': query,
      'pn': '1',
      'ps': '$n',
    });
    final body = await fetchPageOrNetworkError(
      id,
      fetch,
      url,
      extraHeaders: {
        'Cookie': buildUidCookie(),
        'Referer': 'https://www.chinaso.com/',
      },
    );
    return takeLimit(parsePage(body), limit);
  }

  static List<SearchHit> parsePage(String body) {
    final dynamic decoded;
    try {
      decoded = jsonDecode(body);
    } on FormatException {
      throw const SearchEngineException('chinaso', 'parse', '响应不是合法 JSON');
    }
    if (decoded is! Map<String, dynamic>) {
      throw const SearchEngineException('chinaso', 'parse', '顶层不是 JSON 对象');
    }
    final status = decoded['status'];
    final msg = '${decoded['msg'] ?? ''}';
    if (status is num && status != 0) {
      final blocked = msg.toLowerCase().contains('ip control') || status == 2;
      throw SearchEngineException(
        'chinaso',
        blocked ? 'blocked' : 'network',
        'chinaso 返回 status=$status msg=$msg',
      );
    }
    final inner = decoded['data'];
    // 空结果时上游返回 'data': {}（SearXNG 同款处理：视为合法空结果）。
    if (inner is! Map) {
      throw const SearchEngineException('chinaso', 'empty', 'chinaso 0 条结果');
    }
    final entries = (inner['data'] as List?) ?? const [];
    final hits = <SearchHit>[];
    for (final e in entries) {
      if (e is! Map) continue;
      final title = htmlToText('${e['title'] ?? ''}');
      final url = '${e['url'] ?? ''}'.trim();
      if (title.isEmpty || url.isEmpty) continue;
      final snippet = htmlToText('${e['snippet'] ?? ''}');
      final ts = int.tryParse('${e['timestamp'] ?? ''}'.trim());
      hits.add(SearchHit(
        title: title,
        url: url,
        snippet: snippet.isEmpty ? null : snippet,
        publishedAt: ts == null || ts <= 0
            ? null
            : DateTime.fromMillisecondsSinceEpoch(ts * 1000)
                .toIso8601String()
                .substring(0, 10),
        engine: 'chinaso',
      ));
    }
    if (hits.isEmpty) {
      throw const SearchEngineException('chinaso', 'empty', 'chinaso 0 条结果');
    }
    return hits;
  }

  @override
  void dispose() {}
}
