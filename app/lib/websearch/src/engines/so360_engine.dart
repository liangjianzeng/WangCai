import '../search_engine.dart';
import '../search_hit.dart';
import 'common.dart';

/// 360 搜索（www.so.com）适配器。
///
/// 约束/坑：
/// - 真实 URL 藏在 `data-mdurl` 属性（标题锚上），href 是 so.com/link 跳转形态；
///   拿不到 mdurl 时退回 href（跳转形态也可接受）；
/// - 摘要载体不固定：`<p class="res-desc">` 与 `<span class="res-list-summary">`
///   两种都出现过（类名有时带哈希后缀），按前缀匹配；
/// - 噪声块必须过滤：`data-mohe-type` 垂直聚合卡（news_ai/short_video 等）、
///   标题链接指向 news.so.com/ns? 的聚合条、mdurl 落在导航域
///   （hao.360.com/360kan.com/bing.com）的条目。
class So360Engine implements SearchEngine {
  @override
  String get id => 'so360';

  @override
  String get displayName => '360搜索';

  final FetchPage fetch;

  So360Engine(this.fetch);

  @override
  Future<List<SearchHit>> search(String query, {int limit = 8}) async {
    final url = Uri.https('www.so.com', '/s', {'q': query, 'pn': '1'});
    final body = await fetchPageOrNetworkError(id, fetch, url);
    return takeLimit(parsePage(body), limit);
  }

  /// 解析结果页。按 `<li class="res-list">` 分块。
  ///
  /// - 反爬：body 含"验证码"/captcha（大小写不敏感）→ kind=blocked；
  /// - 无 res-list 块 → kind=parse（页面结构不认识）；
  /// - 有块但全被过滤 → kind=empty。
  static List<SearchHit> parsePage(String body) {
    final lower = body.toLowerCase();
    if (body.contains('验证码') || lower.contains('captcha')) {
      throw const SearchEngineException('so360', 'blocked', '360搜索触发验证码');
    }
    final blocks =
        splitBlocks(stripHtmlComments(body), RegExp(r'<li class="res-list'));
    if (blocks.isEmpty) {
      throw const SearchEngineException('so360', 'parse', '360页面结构不认识（无 res-list）');
    }
    final hits = <SearchHit>[];
    for (final block in blocks) {
      if (block.contains('data-mohe-type')) continue; // 垂直聚合卡
      final h3 = firstH3Link(block);
      if (h3 == null) continue;
      // 标题链接指向新闻垂直搜索的聚合条 → 噪声。
      if (h3.href.contains('news.so.com/ns?')) continue;
      // 真实 URL：块内第一个 data-mdurl（已实体解码）。
      final url = attrValue(block, 'data-mdurl') ?? h3.href;
      // 导航域（hao.360.com/bing.com/360kan 等）→ 噪声。
      final host = hostOf(url);
      const navDomains = ['hao.360.com', '360kan.com', 'bing.com'];
      if (navDomains.any((d) => hostMatchesDomain(host, d))) continue;
      final snippet = firstClassTokenText(block, 'p', ['res-desc', 'mh-news-desc']) ??
          firstClassTokenText(block, 'span', ['res-list-summary']) ??
          firstClassTokenText(block, 'div', ['res-rich']);
      hits.add(SearchHit(
        title: h3.title,
        url: url,
        snippet: snippet,
        engine: 'so360',
      ));
    }
    if (hits.isEmpty) {
      throw const SearchEngineException('so360', 'empty', '360 0 条结果（全部为噪声块）');
    }
    return hits;
  }

  @override
  void dispose() {}
}
