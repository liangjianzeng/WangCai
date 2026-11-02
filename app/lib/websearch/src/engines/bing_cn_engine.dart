import '../html_text.dart';
import '../search_engine.dart';
import '../search_hit.dart';
import 'common.dart';

/// 必应（cn.bing.com）适配器。
///
/// 约束/坑：
/// - RSS 接口（format=rss）实测最稳：直链 + 摘要 + 日期齐全，优先走它；
/// - RSS 偶发 0 个 `<item>`（风控软失败，HTTP 仍 200）→ 降级抓同一查询、
///   去掉 format=rss 的 HTML 页（b_algo 块）；
/// - pubDate 是中文月名形态（`周四, 01 10月 2026 21:29:00 GMT`），
///   [DateTime.tryParse] 直接挂，只能手抠"日 月 年"；
/// - 必应的风控页不是验证码形态（文本是"异常流量"提示），按规格判 kind=parse。
class BingCnEngine implements SearchEngine {
  @override
  String get id => 'bing_cn';

  @override
  String get displayName => '必应';

  final FetchPage fetch;

  BingCnEngine(this.fetch);

  @override
  Future<List<SearchHit>> search(String query, {int limit = 8}) async {
    final count = limit.clamp(1, 20);
    final url = Uri.https('cn.bing.com', '/search', {
      'q': query,
      'format': 'rss',
      'mkt': 'zh-CN',
      'count': '$count',
    });
    final body =
        await fetchPageOrNetworkError(id, fetch, url);
    final hits = takeLimit(parseRss(body), limit);
    if (hits.isNotEmpty) return hits;

    // RSS 0 item → 降级 HTML（同一查询，去掉 format 参数）。
    final htmlUrl = url.replace(queryParameters: {
      for (final e in url.queryParameters.entries)
        if (e.key != 'format') e.key: e.value,
    });
    final htmlBody = await fetchPageOrNetworkError(id, fetch, htmlUrl);
    return takeLimit(parseHtml(htmlBody), limit);
  }

  /// 解析 RSS 正文。0 个 `<item>` 返回空列表（search 层负责降级 HTML）。
  ///
  /// 风控判定：body 含"异常流量" → kind=parse。
  static List<SearchHit> parseRss(String body) {
    if (body.contains('异常流量')) {
      throw const SearchEngineException(
          'bing_cn', 'parse', '必应返回异常流量拦截页');
    }
    final hits = <SearchHit>[];
    for (final item in splitBlocks(body, '<item>')) {
      final title = _tagText(item, 'title');
      final link = _tagText(item, 'link');
      if (title == null || title.isEmpty || link == null || link.isEmpty) {
        continue;
      }
      hits.add(SearchHit(
        title: title,
        url: link,
        snippet: _tagText(item, 'description'),
        publishedAt: _formatPubDate(_tagText(item, 'pubDate') ?? ''),
        engine: 'bing_cn',
      ));
    }
    return hits;
  }

  /// 解析 HTML 结果页（RSS 降级路径）：`<li class="b_algo">` 块，
  /// `<h2><a href="直链">` 取标题/链接，块内第一个 `<p class="b_lineclamp...">`
  /// （或任意 `<p>`）取摘要。
  static List<SearchHit> parseHtml(String body) {
    if (body.contains('异常流量')) {
      throw const SearchEngineException(
          'bing_cn', 'parse', '必应返回异常流量拦截页');
    }
    final titleTag =
        RegExp(r'<title>(.*?)</title>', dotAll: true).firstMatch(body);
    final titleText =
        titleTag == null ? '' : htmlToText(titleTag.group(1)!);
    final looksResultPage = titleText.contains('必应') || body.contains('b_algo');
    final blocks =
        splitBlocks(stripHtmlComments(body), RegExp(r'<li class="b_algo'));
    if (blocks.isEmpty) {
      if (!looksResultPage) {
        throw const SearchEngineException(
            'bing_cn', 'parse', '必应返回页面不像结果页（无 b_algo）');
      }
      throw const SearchEngineException('bing_cn', 'empty', '必应 0 条结果');
    }
    final hits = <SearchHit>[];
    for (final block in blocks) {
      final h2 = firstTitleLink(block, tag: 'h2');
      if (h2 == null) continue;
      final snippet = firstClassTokenText(block, 'p', ['b_lineclamp']) ??
          _firstPTagText(block);
      hits.add(SearchHit(
        title: h2.title,
        url: h2.href,
        snippet: snippet,
        engine: 'bing_cn',
      ));
    }
    if (hits.isEmpty) {
      throw const SearchEngineException('bing_cn', 'empty', '必应 0 条结果');
    }
    return hits;
  }

  /// 提取单个 XML 标签的文本（支持 CDATA 包裹），清洗内嵌 HTML 后返回。
  static String? _tagText(String xml, String name) {
    final m =
        RegExp('<$name>(.*?)</$name>', dotAll: true).firstMatch(xml);
    if (m == null) return null;
    var v = m.group(1)!;
    final cdata = RegExp(r'<!\[CDATA\[(.*?)\]\]>', dotAll: true).firstMatch(v);
    if (cdata != null) v = cdata.group(1)!;
    return htmlToText(v);
  }

  /// 块内第一个 `<p>` 的文本（b_lineclamp 前缀匹配不中时的兜底）。
  static String? _firstPTagText(String chunk) {
    final m = RegExp(r'<p(?=[\s>])[^>]*>', caseSensitive: false)
        .firstMatch(chunk);
    if (m == null) return null;
    final close = chunk.indexOf('</p>', m.end);
    if (close < 0) return null;
    final text = htmlToText(chunk.substring(m.end, close));
    return text.isEmpty ? null : text;
  }

  /// `周四, 01 10月 2026 21:29:00 GMT` → `2026-10-01`；
  /// 兼容英文月名（`Thu, 01 Oct 2026 ...`）；解析不出保留原文。
  static String? _formatPubDate(String raw) {
    if (raw.isEmpty) return null;
    final zh =
        RegExp(r'(\d{1,2})\s+(\d{1,2})月\s+(\d{4})').firstMatch(raw);
    if (zh != null) {
      return _ymd(int.parse(zh.group(3)!), int.parse(zh.group(2)!),
          int.parse(zh.group(1)!));
    }
    const en = {
      'jan': 1, 'feb': 2, 'mar': 3, 'apr': 4, 'may': 5, 'jun': 6,
      'jul': 7, 'aug': 8, 'sep': 9, 'oct': 10, 'nov': 11, 'dec': 12,
    };
    final en1 = RegExp(r'(\d{1,2})\s+([A-Za-z]{3,9})\s+(\d{4})').firstMatch(raw);
    if (en1 != null) {
      final mo = en[en1.group(2)!.toLowerCase().substring(0, 3)];
      if (mo != null) {
        return _ymd(int.parse(en1.group(3)!), mo, int.parse(en1.group(1)!));
      }
    }
    return raw;
  }

  static String _ymd(int y, int m, int d) =>
      '$y-${m.toString().padLeft(2, '0')}-${d.toString().padLeft(2, '0')}';

  @override
  void dispose() {}
}
