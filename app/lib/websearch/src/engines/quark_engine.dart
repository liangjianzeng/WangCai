/// 夸克搜索（quark.sm.cn，阿里系/神马索引）适配器。
///
/// 事实要点（对齐 SearXNG quark.py 的端点/结构事实，解析自写）：
/// - 端点 `https://quark.sm.cn/s?q=&layout=html&page=1`，无需特殊 Cookie；
/// - 结果不在 HTML 标签里，而在 `<script type="application/json"
///   id="s-data-..." data-used-by="hydrate">` 的 hydrate JSON 块中，
///   按 `extraData.sc` 分约 20 种卡片类型，字段名随类型变化——因此本解析器
///   **按字段名集合递归收集**（url 类：normal_url/dest_url/url/title_url/
///   sourceProps.dest_url；title 类：title/titleProps.content 等），对类型
///   变化鲁棒；
/// - 阿里 x5sec 风控：短时约 9 次请求触发，`"action": "captcha"` JSON 片段
///   出现即判 blocked——熔断冷却会指数退避兜底（2026-10-02 已放宽至 1min 起、
///   封顶 10min，冷却到期换身份重试）。
library;

import 'dart:convert';

import '../html_text.dart';
import '../search_engine.dart';
import '../search_hit.dart';
import 'common.dart';

class QuarkEngine implements SearchEngine {
  @override
  String get id => 'quark';

  @override
  String get displayName => '夸克';

  final FetchPage fetch;

  QuarkEngine(this.fetch);

  @override
  Future<List<SearchHit>> search(String query, {int limit = 8}) async {
    final n = limit.clamp(1, 20);
    final url = Uri.https('quark.sm.cn', '/s', {
      'q': query,
      'layout': 'html',
      'page': '1',
    });
    final body = await fetchPageOrNetworkError(id, fetch, url);
    return takeLimit(parsePage(body), n);
  }

  static List<SearchHit> parsePage(String body) {
    final lower = body.toLowerCase();
    if (lower.contains('"action":"captcha"') ||
        lower.contains('"action": "captcha"') ||
        lower.contains('x5sec')) {
      throw const SearchEngineException('quark', 'blocked', '夸克触发 x5sec 验证码');
    }
    final blobRe = RegExp(
      r'<script[^>]*type="application/json"[^>]*>(.*?)</script>',
      dotAll: true,
      caseSensitive: false,
    );
    final hits = <SearchHit>[];
    final seen = <String>{};
    for (final m in blobRe.allMatches(body)) {
      final dynamic decoded;
      try {
        decoded = jsonDecode(m.group(1)!);
      } on FormatException {
        continue; // 非 JSON 的 script 块跳过。
      }
      _collect(decoded, hits, seen);
    }
    if (hits.isEmpty) {
      throw const SearchEngineException(
          'quark', 'parse', '夸克页面无 hydrate 结果（结构变化或被拦）');
    }
    return hits;
  }

  /// 递归收集"同时有合法外链 url 和标题"的节点。
  static void _collect(dynamic node, List<SearchHit> out, Set<String> seen) {
    if (node is List) {
      for (final item in node) {
        _collect(item, out, seen);
      }
      return;
    }
    if (node is! Map) return;
    final url = _pickUrl(node);
    final title = _pickTitle(node);
    if (url != null && title != null && title.isNotEmpty) {
      final host = hostOf(url);
      final isSelf = hostMatchesDomain(host, 'quark.sm.cn') ||
          hostMatchesDomain(host, 'sm.cn');
      final key = normalizeUrlKey(url);
      if (!isSelf && key.isNotEmpty && seen.add(key)) {
        out.add(SearchHit(
          title: title,
          url: url,
          snippet: _pickSummary(node),
          engine: 'quark',
        ));
      }
    }
    node.values.forEach((v) => _collect(v, out, seen));
  }

  static String? _pickUrl(Map node) {
    // 先查嵌套的 sourceProps.dest_url（新闻卡片常见），再查平铺字段。
    final sp = node['sourceProps'];
    if (sp is Map) {
      final dest = '${sp['dest_url'] ?? ''}'.trim();
      if (dest.startsWith('http')) return dest;
    }
    for (final key in const ['normal_url', 'url', 'title_url', 'dest_url']) {
      final v = '${node[key] ?? ''}'.trim();
      if (v.startsWith('http')) return v;
    }
    return null;
  }

  static String? _pickTitle(Map node) {
    final t = node['title'];
    if (t is String && t.trim().isNotEmpty) return htmlToText(t);
    final tp = node['titleProps'];
    if (tp is Map) {
      for (final key in const ['content', 'text']) {
        final v = '${tp[key] ?? ''}'.trim();
        if (v.isNotEmpty) return htmlToText(v);
      }
    }
    return null;
  }

  static String? _pickSummary(Map node) {
    final sp = node['summaryProps'];
    if (sp is Map) {
      final v = htmlToText('${sp['content'] ?? sp['text'] ?? ''}');
      if (v.isNotEmpty) return v;
    }
    for (final key in const ['summary', 'desc', 'replyContent']) {
      final v = htmlToText('${node[key] ?? ''}');
      if (v.isNotEmpty) return v;
    }
    return null;
  }

  @override
  void dispose() {}
}

/// 轻量同源去重键（模块内 quark 专用；聚合层还有统一 normalizeUrl）。
String normalizeUrlKey(String raw) {
  final uri = Uri.tryParse(raw.trim());
  if (uri == null || uri.host.isEmpty) return '';
  return '${uri.host.toLowerCase()}${uri.path}';
}
