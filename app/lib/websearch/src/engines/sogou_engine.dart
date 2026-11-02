import '../html_text.dart';
import '../search_engine.dart';
import '../search_hit.dart';
import 'common.dart';

/// 搜狗（www.sogou.com）适配器。
///
/// 约束/坑：
/// - 真实 URL 在块内 `data-url` 属性（实测每条结果都有，挂在 vrwrap 内的
///   r-sech 扩展 div 上，取块内第一个即是本条的真实地址，别取第二个——
///   那是块内子推荐位）；没有就退回 href 并补 https://www.sogou.com 前缀；
/// - 标题 href 是 /link?url=... 跳转形态，直链只能靠 data-url；
/// - 摘要在 `class="fz-mid space-txt ..."` 的 div（space-txt 优先于 fz-mid，
///   后者会命中块内图片说明等杂项元素）；
/// - 无 h3 a 的 vrwrap 块（"大家还在搜"提示框/推荐位）直接跳过。
class SogouEngine implements SearchEngine {
  @override
  String get id => 'sogou';

  @override
  String get displayName => '搜狗';

  final FetchPage fetch;

  SogouEngine(this.fetch);

  @override
  Future<List<SearchHit>> search(String query, {int limit = 8}) async {
    final url = Uri.https('www.sogou.com', '/web', {'query': query});
    final body = await fetchPageOrNetworkError(id, fetch, url);
    return takeLimit(parsePage(body), limit);
  }

  /// 解析结果页。按 `<div class="vrwrap">` 分块。
  ///
  /// - 反爬：antispider 标记 / "验证码" / title 恰为"搜狗搜索"且 body 极小
  ///   （<10KB，风控壳页特征）→ kind=blocked；
  /// - 无 vrwrap → kind=parse；有块但全被过滤 → kind=empty。
  static List<SearchHit> parsePage(String body) {
    final lower = body.toLowerCase();
    final title = _titleText(body);
    if (body.contains('验证码') ||
        lower.contains('antispider') ||
        (title == '搜狗搜索' && body.length < 10 * 1024)) {
      throw const SearchEngineException('sogou', 'blocked', '搜狗触发反爬拦截');
    }
    final blocks =
        splitBlocks(stripHtmlComments(body), RegExp(r'<div class="vrwrap'));
    if (blocks.isEmpty) {
      throw const SearchEngineException('sogou', 'parse', '搜狗页面结构不认识（无 vrwrap）');
    }
    final hits = <SearchHit>[];
    for (final block in blocks) {
      final h3 = firstH3Link(block);
      if (h3 == null) continue; // 推荐位/提示框
      final dataUrl = attrValue(block, 'data-url');
      final href = h3.href;
      final url = dataUrl ??
          (href.startsWith('/') ? 'https://www.sogou.com$href' : href);
      final snippet = firstClassTokenText(block, 'div', ['space-txt']) ??
          firstClassTokenText(block, 'div', ['fz-mid']) ??
          firstClassTokenText(block, 'p', ['space-txt', 'fz-mid']);
      hits.add(SearchHit(
        title: h3.title,
        url: url,
        snippet: snippet,
        engine: 'sogou',
      ));
    }
    if (hits.isEmpty) {
      throw const SearchEngineException('sogou', 'empty', '搜狗 0 条结果（全部为噪声块）');
    }
    return hits;
  }

  static String _titleText(String body) {
    final m = RegExp(r'<title>(.*?)</title>', dotAll: true).firstMatch(body);
    return m == null ? '' : htmlToText(m.group(1)!);
  }

  @override
  void dispose() {}
}
