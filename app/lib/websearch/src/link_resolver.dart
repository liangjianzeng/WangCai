/// 跳转链接还原器：把搜索引擎的跳转链解成真实目标 URL。
///
/// 各家形态（2026-10-02 实测，详见 docs/websearch_direct_2026-10-02.md §1.1）：
/// - `baidu.com/link?url=` / `chinaso.com/link?url=`：**302 Location** 直给真链；
/// - `sogou.com/link?url=` / `so.com/link?m=`：HTTP 200，页内 `URL='...'`
///   （meta refresh / JS 跳转）藏真链；
/// - href 值来自 HTML 属性，**必须先实体解码**（`&amp;`→`&`），否则 302
///   Location 会是乱码（实测踩过）。
///
/// 还原是尽力而为：任何一步失败都返回 null，调用方保留原跳转链。
library;

import 'package:dio/dio.dart';

/// 判断一个 URL 是否是"需要还原"的跳转链。
bool isRedirectLink(String url) {
  return url.contains('/link?') &&
      (url.contains('baidu.com/link') ||
          url.contains('sogou.com/link') ||
          url.contains('so.com/link') ||
          url.contains('chinaso.com/link'));
}

class LinkResolver {
  final Dio _dio;

  /// 单次还原预算：跳转链解析不该拖慢整次搜索。
  static const Duration _timeout = Duration(seconds: 6);

  LinkResolver({Dio? dio})
      : _dio = dio ??
            Dio(BaseOptions(
              responseType: ResponseType.plain,
              connectTimeout: const Duration(seconds: 4),
              receiveTimeout: _timeout,
              validateStatus: (_) => true,
              followRedirects: false,
              maxRedirects: 0,
            ));

  /// 尝试还原真实 URL；失败返回 null。最多跟随 2 跳。
  Future<String?> resolve(String rawUrl, {String userAgent = ''}) async {
    var url = rawUrl;
    for (var hop = 0; hop < 2; hop++) {
      String? next;
      try {
        next = await _probe(url, userAgent);
      } catch (_) {
        return null;
      }
      if (next == null) return null;
      if (!isRedirectLink(next)) return next;
      url = next; // 还是跳转链（嵌套跳转），再走一跳。
    }
    return null;
  }

  /// 一次探测：返回下一跳 URL；拿不到返回 null。
  Future<String?> _probe(String url, String userAgent) async {
    final resp = await _dio.get<String>(
      url,
      options: Options(headers: {
        'User-Agent': userAgent.isEmpty ? 'Mozilla/5.0' : userAgent,
        'Accept-Language': 'zh-CN,zh;q=0.9',
      }),
    );
    final status = resp.statusCode ?? 0;
    if (status >= 300 && status < 400) {
      final loc = (resp.headers.value('location') ?? '').trim();
      if (loc.isEmpty) return null;
      return _absolute(loc, url);
    }
    final body = resp.data ?? '';
    if (body.isEmpty) return null;
    // meta refresh / JS 跳转（sogou、360 形态）。
    final m = RegExp(r'''URL\s*=\s*'?([^'">]+)''', caseSensitive: false)
            .firstMatch(body) ??
        RegExp(r'''location(?:\.href)?\s*[=.]\s*["']([^"']+)["']''',
                caseSensitive: false)
            .firstMatch(body) ??
        RegExp(r'''http-equiv=["']?refresh["']?[^>]*url=([^"'>]+)''',
                caseSensitive: false)
            .firstMatch(body);
    if (m == null) return null;
    return _absolute(m.group(1)!.trim(), url);
  }

  String? _absolute(String next, String base) {
    try {
      return Uri.parse(base).resolve(next).toString();
    } on FormatException {
      return null;
    }
  }

  void dispose() {
    _dio.close(force: true);
  }
}
