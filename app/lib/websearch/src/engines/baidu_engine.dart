/// 百度（www.baidu.com）适配器。
///
/// 主路径 = `tn=json` 结构化端点（`/s?wd=&rn=&pn=0&tn=json`，对齐 SearXNG
/// baidu.py 的 general 形态），返回 `data.feed.entry[]`（title/url/abs/time），
/// 远比 HTML 稳；响应不是 JSON（改版/风控变体）才降级走 HTML 解析。
/// 被风控时 302 → wappass 验证码页，由 engine_http 的 redirectException 统一判
/// blocked（不跟随重定向）。
///
/// 约束/坑：
/// - 百度是最不稳的引擎，本适配器刻意保持薄：解析不出就抛异常交给聚合器熔断；
/// - HTML 路径真实 URL 在块上 `mu="..."` 属性（提取属性时必须带词边界，否则会
///   误中 `m-name=` 之类的尾巴）；没有则保留 href（baidu.com/link 跳转形态）；
/// - 摘要 class 必须前缀匹配（`summary-text_15QGa` 这种哈希后缀），
///   优先 summary-text span，其次 content-right/c-abstract；
/// - 导航块（image.baidu.com/video.baidu.com/top.baidu.com 或标题含
///   "百度图片"等）与广告块（块 class 以 ec- 开头）一律跳过。
library;

import 'dart:convert';

import '../html_text.dart';
import '../search_engine.dart';
import '../search_hit.dart';
import 'common.dart';

class BaiduEngine implements SearchEngine {
  @override
  String get id => 'baidu';

  @override
  String get displayName => '百度';

  final FetchPage fetch;

  BaiduEngine(this.fetch);

  @override
  Future<List<SearchHit>> search(String query, {int limit = 8}) async {
    final n = limit.clamp(1, 50);
    final url = Uri.https('www.baidu.com', '/s', {
      'wd': query,
      'rn': '$n',
      'pn': '0',
      'tn': 'json',
    });
    final body = await fetchPageOrNetworkError(id, fetch, url);
    if (body.trimLeft().startsWith('{')) {
      return takeLimit(parseJsonPage(body), limit);
    }
    return takeLimit(parsePage(body), limit);
  }

  /// 解析 `tn=json` 响应。结构（实测/SearXNG 对齐）：
  /// `{"data":{"feed":{"entry":[{"title","url","abs","time"},...]}}}`，
  /// time 为 Unix 秒（可能缺）。风控页也可能以 JSON 壳出现（status!=0）。
  static List<SearchHit> parseJsonPage(String body) {
    final dynamic decoded;
    try {
      decoded = jsonDecode(body);
    } on FormatException {
      throw const SearchEngineException('baidu', 'parse', 'tn=json 响应不是合法 JSON');
    }
    if (decoded is! Map<String, dynamic>) {
      throw const SearchEngineException('baidu', 'parse', 'tn=json 顶层不是对象');
    }
    final status = decoded['status'];
    if (status is num && status != 0) {
      throw SearchEngineException(
          'baidu', 'blocked', 'tn=json 返回 status=$status（疑似风控/异常）');
    }
    final feed = (((decoded['data'] as Map?)?['feed']) as Map?) ?? const {};
    final entries = (feed['entry'] as List?) ?? const [];
    final hits = <SearchHit>[];
    for (final e in entries) {
      if (e is! Map) continue;
      final title = htmlToText('${e['title'] ?? ''}');
      final url = '${e['url'] ?? ''}'.trim();
      if (title.isEmpty || url.isEmpty) continue;
      final abs = htmlToText('${e['abs'] ?? ''}');
      final time = int.tryParse('${e['time'] ?? ''}'.trim());
      hits.add(SearchHit(
        title: title,
        url: url,
        snippet: abs.isEmpty ? null : abs,
        publishedAt: time == null || time <= 0
            ? null
            : DateTime.fromMillisecondsSinceEpoch(time * 1000)
                .toIso8601String()
                .substring(0, 10),
        engine: 'baidu',
      ));
    }
    if (hits.isEmpty) {
      throw const SearchEngineException('baidu', 'empty', 'tn=json 0 条结果');
    }
    return hits;
  }

  /// 解析 HTML 结果页（tn=json 降级路径）。按 `<div class="result c-container">` 分块。
  ///
  /// - 反爬：body 含"百度安全验证" → kind=blocked；
  /// - 无结果块 → kind=parse；有块但全被过滤 → kind=empty。
  static List<SearchHit> parsePage(String body) {
    if (body.contains('百度安全验证')) {
      throw const SearchEngineException('baidu', 'blocked', '百度触发安全验证');
    }
    final blocks = splitBlocks(
        stripHtmlComments(body), RegExp(r'<div[^>]*class="result c-container'));
    if (blocks.isEmpty) {
      throw const SearchEngineException('baidu', 'parse', '百度页面结构不认识（无 result c-container）');
    }
    final hits = <SearchHit>[];
    for (final block in blocks) {
      // 广告块：块开标签的 class 里有 ec- 开头的 token。
      final gt = block.indexOf('>');
      final openTag = gt < 0 ? block : block.substring(0, gt + 1);
      final openClass = attrValue(openTag, 'class') ?? '';
      if (openClass.split(RegExp(r'\s+')).any((c) => c.startsWith('ec-'))) {
        continue;
      }
      final h3 = firstH3Link(block);
      if (h3 == null) continue;
      // 导航块：标题链接指向图片/视频/热榜，或标题带"百度图片"等尾巴。
      final href = h3.href;
      if (href.contains('image.baidu.com') ||
          href.contains('video.baidu.com') ||
          href.contains('top.baidu.com')) {
        continue;
      }
      if (h3.title.contains('百度图片') ||
          h3.title.contains('百度视频') ||
          h3.title.contains('百度热榜')) {
        continue;
      }
      final url = attrValue(block, 'mu') ?? href;
      final snippet = firstClassTokenText(block, 'span', ['summary-text']) ??
          firstClassTokenText(block, 'div', ['content-right', 'c-abstract']) ??
          firstClassTokenText(block, 'span', ['content-right', 'c-abstract']);
      hits.add(SearchHit(
        title: h3.title,
        url: url,
        snippet: snippet,
        engine: 'baidu',
      ));
    }
    if (hits.isEmpty) {
      throw const SearchEngineException('baidu', 'empty', '百度 0 条结果（全部为导航/广告块）');
    }
    return hits;
  }

  @override
  void dispose() {}
}
