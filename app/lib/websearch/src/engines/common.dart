/// 各引擎结果页解析共用的小工具（正则切块 / 属性提取 / 摘要元素抓取）。
///
/// 约束/坑：
/// - 各结果页的摘要元素都是"叶子"（内部不再嵌同名标签），所以抓内容时直接找
///   第一个 `</tag>` 当闭合即可；真正嵌套的容器（如 360 的 res-rich 大块）
///   只出现在兜底路径里，截断一点可接受。
/// - 属性值单双引号都可能出现（360 模板大量用单引号 class），统一按两种引号提取。
library;

import '../html_text.dart';
import '../search_engine.dart';
import '../search_hit.dart';

/// 去掉 HTML 注释。结果块里常见 `<!--s-text-->`、`<!--VR OK-->` 之类的记号，
/// 先剥掉再跑正则，避免注释内容干扰匹配（搜狗标题锚前就有 `<!--awbg1-->`）。
String stripHtmlComments(String html) =>
    html.replaceAll(RegExp(r'<!--.*?-->', dotAll: true), '');

/// 把 body 按 [startPattern] 的每个匹配位置切成块：
/// 块 i = 第 i 个匹配起点 → 第 i+1 个匹配起点，最后一块到结尾。
List<String> splitBlocks(String body, Pattern startPattern) {
  final starts =
      startPattern.allMatches(body).map((m) => m.start).toList(growable: false);
  final blocks = <String>[];
  for (var i = 0; i < starts.length; i++) {
    final end = i + 1 < starts.length ? starts[i + 1] : body.length;
    blocks.add(body.substring(starts[i], end));
  }
  return blocks;
}

/// 提取属性值（要求属性名前是空白/串首，防止 `mu` 误中 `xxmu=` 之类的尾巴），
/// 支持单双引号，已做 HTML 实体解码（百度 mu、360 mdurl 里常带 `&amp;`）。
String? attrValue(String html, String name) {
  final m = RegExp(
          '(?:^|[\\s])' +
              RegExp.escape(name) +
              '\\s*=\\s*(?:"([^"]*)"|\'([^\']*)\')')
      .firstMatch(html);
  if (m == null) return null;
  final v = m.group(1) ?? m.group(2) ?? '';
  return decodeEntities(v).trim();
}

/// 块内第一个 `<[tag]...><a href="...">标题</a>`。
/// 标题锚里常嵌 `<em>` 高亮/嵌套 span，用 [htmlToText] 清洗。
/// 拿不到合法链接或空标题返回 null（调用方按"噪声块"跳过）。
({String href, String title})? firstTitleLink(String chunk,
    {String tag = 'h3'}) {
  final h =
      RegExp('<$tag(?=[\\s>])[^>]*>', caseSensitive: false).firstMatch(chunk);
  if (h == null) return null;
  final rest = chunk.substring(h.end);
  final a =
      RegExp(r'<a(?=[\s>])[^>]*>', caseSensitive: false).firstMatch(rest);
  if (a == null) return null;
  final href = attrValue(a.group(0)!, 'href');
  if (href == null || href.isEmpty) return null;
  final close = rest.indexOf('</a>', a.end);
  if (close < 0) return null;
  final title = htmlToText(rest.substring(a.end, close));
  if (title.isEmpty) return null;
  return (href: href, title: title);
}

/// [firstTitleLink] 的 h3 快捷形式（so360/sogou/baidu 的标题载体）。
({String href, String title})? firstH3Link(String chunk) =>
    firstTitleLink(chunk, tag: 'h3');

/// 找第一个 class 含有以 [prefixes] 之一为前缀的 token 的 [tag] 元素，
/// 返回其清洗后的文本。摘要 class 带哈希后缀（百度 `summary-text_15QGa`）、
/// 或前缀本身带后缀变体（360 `res-desc`/`res-list-summary`），一律按前缀匹配。
String? firstClassTokenText(String chunk, String tag, List<String> prefixes) {
  final openRe = RegExp('<$tag(?=[\\s>])[^>]*>', caseSensitive: false);
  for (final m in openRe.allMatches(chunk)) {
    final cls = attrValue(m.group(0)!, 'class');
    if (cls == null || cls.isEmpty) continue;
    final tokens = cls.split(RegExp(r'\s+'));
    if (!tokens.any((c) => prefixes.any(c.startsWith))) continue;
    final close = chunk.indexOf('</$tag>', m.end);
    if (close < 0) continue;
    final text = htmlToText(chunk.substring(m.end, close));
    if (text.isNotEmpty) return text;
  }
  return null;
}

/// URL 的 host（小写）；解析失败返回空串（跳转链接实体解码后再 parse）。
String hostOf(String url) {
  try {
    return Uri.parse(url).host.toLowerCase();
  } catch (_) {
    return '';
  }
}

/// host 是否等于 [domain] 或其子域（防止 `evilbing.com` 误判为 bing.com）。
bool hostMatchesDomain(String host, String domain) =>
    host == domain || host.endsWith('.$domain');

/// 统一的抓取包装：注入方抛的 [SearchEngineException] 原样上抛，
/// 其它异常（Dio/IO/解析不了的状态码等）一律包装成 network。
Future<String> fetchPageOrNetworkError(
    String engineId,
    FetchPage fetch,
    Uri url, {
    Map<String, String>? extraHeaders,
  }) async {
  try {
    return await fetch(url, extraHeaders: extraHeaders);
  } on SearchEngineException {
    rethrow;
  } catch (e) {
    throw SearchEngineException(engineId, 'network', '抓取失败: $e');
  }
}

/// 解析出 [hits] 后按调用方的 limit 截断（分块解析多产出的部分丢弃）。
List<SearchHit> takeLimit(List<SearchHit> hits, int limit) =>
    hits.length <= limit ? hits : hits.sublist(0, limit);
