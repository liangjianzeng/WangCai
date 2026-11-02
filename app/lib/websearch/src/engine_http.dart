/// 引擎 HTTP 会话层：给各引擎注入统一的 FetchPage 实现。
///
/// 约束/坑（实测得出，见 docs/websearch_direct_2026-10-02.md）：
/// - 百度/搜狗首次搜索前先 GET 一次首页拿 Cookie（BAIDUID / SUID 等），
///   能显著降低首发被拦概率；但 Cookie 不是银弹，连发仍会触发风控——
///   真正的防线是聚合器的引擎级熔断冷却。
/// - 搜索引擎的拦截页都是 HTTP 200 小页面，状态码拦不住，blocked 判定在引擎层。
/// - Cookie 按引擎独立存储（各引擎域不同，混存无意义）。
/// - 单请求超时 12s：手机弱网下 PC 页（百度 1.5MB）也很慢，太短会稳定误杀；
///   太长会拖垮 web_search 工具的 30s 总预算。
/// - **一律不跟随重定向**（对齐 SearXNG 引擎经验）：百度被风控时 302 到
///   wappass 验证码页、搜狗 302 到 antispider 页——跟随过去只会拿到壳页，
///   不跟随才能从 Location 精准判 blocked。
library;

import 'dart:math';

import 'dart:io' show SocketException;

import 'package:dio/dio.dart';

import 'search_engine.dart';
import 'search_hit.dart';

/// 把 3xx 响应分类成异常：Location 指向验证码/风控页 → blocked（熔断冷却），
/// 其它 → network。返回 null 表示不是 3xx 或可放行。
SearchEngineException? redirectException(
  int status,
  String? location,
  String engineId,
) {
  if (status < 300 || status >= 400) return null;
  final loc = (location ?? '').trim();
  final lower = loc.toLowerCase();
  final blocked = lower.contains('wappass') ||
      lower.contains('antispider') ||
      lower.contains('captcha') ||
      lower.contains('verify') ||
      lower.contains(' passport.');
  return SearchEngineException(
    engineId,
    blocked ? 'blocked' : 'network',
    blocked ? '被重定向到风控页：$loc' : 'HTTP $status 重定向到 $loc',
  );
}


/// 默认 PC Chrome UA。实测 PC 端点（www.baidu.com/s、so.com/s、sogou.com/web、
/// cn.bing.com/search）在此 UA 下均可正常返回；移动 UA 反而更容易进风控路径。
const String kDefaultEngineUserAgent =
    'Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 '
    '(KHTML, like Gecko) Chrome/124.0.0.0 Safari/537.36';

/// 真实浏览器 UA 池（会话级轮换用：每个引擎会话随机固定一个，被封清
/// Cookie 时连 UA 一起换新身份）。**不要每请求都换 UA**——同一"浏览器"
/// 会话中途换 UA 是比固定 UA 更强的机器特征。
const List<String> kEngineUserAgentPool = [
  // Chrome 124 / Windows
  'Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 '
      '(KHTML, like Gecko) Chrome/124.0.0.0 Safari/537.36',
  // Chrome 123 / Windows
  'Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 '
      '(KHTML, like Gecko) Chrome/123.0.0.0 Safari/537.36',
  // Chrome 124 / macOS
  'Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/537.36 '
      '(KHTML, like Gecko) Chrome/124.0.0.0 Safari/537.36',
  // Edge 124 / Windows
  'Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 '
      '(KHTML, like Gecko) Chrome/124.0.0.0 Safari/537.36 Edg/124.0.0.0',
  // Firefox 125 / Windows
  'Mozilla/5.0 (Windows NT 10.0; Win64; x64; rv:125.0) Gecko/20100101 '
      'Firefox/125.0',
  // Chrome 123 / Linux
  'Mozilla/5.0 (X11; Linux x86_64) AppleWebKit/537.36 '
      '(KHTML, like Gecko) Chrome/123.0.0.0 Safari/537.36',
];

class EngineHttpSession {
  final Dio _dio;
  final String userAgent;

  /// engineId → (cookieName → value)。
  final Map<String, Map<String, String>> _cookies = {};

  /// engineId → 本会话 UA（首次请求时从池中随机固定）。
  final Map<String, String> _engineUas = {};
  final Random _rnd = Random();

  /// 已做过首页 Cookie 预热的引擎。
  final Set<String> _seeded = {};

  /// 网络错误后的单次重试等待（移动网抖动实测一retry能救回大部分偶发失败）。
  static const Duration _retryDelay = Duration(milliseconds: 400);
  static const Duration _receiveTimeout = Duration(seconds: 12);

  EngineHttpSession({this.userAgent = kDefaultEngineUserAgent, Dio? dio})
      : _dio = dio ??
            Dio(BaseOptions(
              // 拦截页也是 200，一律按字符串收、引擎层自行判定内容。
              responseType: ResponseType.plain,
              connectTimeout: const Duration(seconds: 8),
              sendTimeout: const Duration(seconds: 10),
              validateStatus: (_) => true,
              // 不跟随重定向：风控 302 的 Location 是最可靠的 blocked 信号。
              followRedirects: false,
              maxRedirects: 0,
            ));

  /// 为 [engineId] 构造 FetchPage。[seed] 为 true 时首次调用先 GET 同 host
  /// 首页预热 Cookie（百度/搜狗需要）。
  FetchPage forEngine(String engineId, {bool seed = false}) {
    return (url, {Map<String, String>? extraHeaders}) async {
      if (seed && !_seeded.contains(engineId)) {
        _seeded.add(engineId);
        try {
          final home = Uri(scheme: url.scheme, host: url.host, path: '/');
          await _get(engineId, home);
        } catch (_) {
          // 预热失败不阻塞搜索本身（可能只是首页偶发不通）。
        }
      }
      try {
        return await _get(engineId, url, extraHeaders: extraHeaders);
      } on SearchEngineException {
        rethrow;
      } on DioException catch (e) {
        if (e.type == DioExceptionType.cancel) rethrow;
        // 移动网络抖动单次重试。
        await Future<void>.delayed(_retryDelay);
        return _get(engineId, url, extraHeaders: extraHeaders);
      } on SocketException {
        await Future<void>.delayed(_retryDelay);
        return _get(engineId, url, extraHeaders: extraHeaders);
      }
    };
  }

  Future<String> _get(
    String engineId,
    Uri url, {
    Map<String, String>? extraHeaders,
  }) async {
    final resp = await _dio.get<String>(
      url.toString(),
      options: Options(
        responseType: ResponseType.plain,
        receiveTimeout: _receiveTimeout,
        headers: {
          'User-Agent': _uaFor(engineId),
          'Accept':
              'text/html,application/xhtml+xml,application/xml;q=0.9,*/*;q=0.8',
          'Accept-Language': 'zh-CN,zh;q=0.9',
          if (_cookies[engineId]?.isNotEmpty ?? false)
            'Cookie': _cookieHeader(engineId),
          ...?extraHeaders,
        },
      ),
    );
    _absorbCookies(engineId, resp);
    final status = resp.statusCode ?? 0;
    final redirect = redirectException(status, resp.headers.value('location'), engineId);
    if (redirect != null) throw redirect;
    if (status >= 400) {
      throw SearchEngineException(
          engineId, 'network', 'HTTP $status（${url.host}）');
    }
    return resp.data ?? '';
  }

  void _absorbCookies(String engineId, Response<String> resp) {
    final setCookies = resp.headers['set-cookie'];
    if (setCookies == null || setCookies.isEmpty) return;
    final jar = _cookies.putIfAbsent(engineId, () => {});
    for (final sc in setCookies) {
      final pair = sc.split(';').first.trim();
      final eq = pair.indexOf('=');
      if (eq <= 0) continue;
      jar[pair.substring(0, eq).trim()] = pair.substring(eq + 1).trim();
    }
  }

  String _cookieHeader(String engineId) => _cookies[engineId]!
      .entries
      .map((e) => '${e.key}=${e.value}')
      .join('; ');

  /// 引擎会话 UA：首次从池中随机固定（同一会话保持一致，像真实浏览器）。
  String _uaFor(String engineId) =>
      _engineUas.putIfAbsent(engineId,
          () => kEngineUserAgentPool[_rnd.nextInt(kEngineUserAgentPool.length)]);

  /// 丢弃某引擎的 Cookie 会话并换新 UA 身份：搜狗/百度的风控惩罚主要绑
  /// Cookie（调研结论，清 Cookie 常可直接恢复），blocked 后由聚合器回调
  /// 这里，冷却到期即以全新 Cookie+UA 身份重试。
  void clearCookies(String engineId) {
    _cookies.remove(engineId);
    _seeded.remove(engineId);
    _engineUas.remove(engineId);
  }

  void dispose() {
    _dio.close(force: true);
  }
}
