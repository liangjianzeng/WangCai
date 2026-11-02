/// 联网搜索 provider 与标准化结果（对齐 DSH `ctx.web` 的可插拔搜索能力）。
///
/// 本文件只定义接缝与默认实现（SearXNG）：web_search 工具通过 [WebSearchSeam]
/// 调用、不感知具体搜索源——替换搜索实现只需 [WebSearchSeam.registerProvider]。
///
/// 2026-09 在一台自建 SearXNG 实例上实测修正：
/// - 请求必须自带 `/search` 路径，不能依赖实例把空路径 308 过去；
/// - 必须按字符串收响应再自行 jsonDecode：Dio 只在 Content-Type 是 JSON 时才解码，
///   实例未开 `format=json` 时旧代码会抛类型错、被误报成"不可达"；
/// - 引擎列表决定延迟：实例上不可达的引擎（google cse / duckduckgo / brave /
///   startpage / wikipedia）各自等到超时，实测默认全引擎 21s、只指定可达引擎 2.5s，
///   所以引擎白名单做成了设置项。
library;

import 'dart:convert';
import 'dart:io' show SocketException;

import 'package:dio/dio.dart';

import '../../services/settings_service.dart';
import 'direct_search_provider.dart';
import 'web_search_seam.dart';

/// 搜索 provider 统一接口（对齐 DSH ctx.web 的可插拔搜索能力）。
abstract class WebSearchProvider {
  /// 该 provider 的稳定 id（如 "searxng"）。
  String get id;

  /// 该 provider 的名字（用于诊断/展示）。
  String get name;

  /// 廉价可用性探测：仅本地校验（如 URL 合法性），不联网。
  /// 返回 null 表示可用；返回非空字符串表示不可用及原因。
  String? available();

  /// 执行一次搜索。失败抛 [WebSearchProviderError]。
  ///
  /// [timeout] 为 null 时使用 provider 自身配置的超时——调用方**不要**传自己的
  /// 默认值进来，否则设置项里的超时会静默失效（本文件曾踩此坑）。
  Future<WebSearchResult> search(String query, {Duration? timeout});

  /// 释放资源（如 HttpClient / Dio）。
  void dispose();
}

/// 标准化搜索结果（对齐 DSH WebSearchResult）。
class WebSearchResult {
  final List<WebSearchSource> sources;

  /// 是否因超出 maxResults 丢弃过结果（此前该字段恒为 false）。
  final bool truncated;

  /// 0 结果时的引擎诊断（哪些引擎 timeout/CAPTCHA/静默 0 条），
  /// 供工具层转成可行动的报错——"查询不到"必须能看出是实例挂了。
  final String? diagnostics;
  const WebSearchResult({
    required this.sources,
    this.truncated = false,
    this.diagnostics,
  });
}

/// 标准化搜索结果中的一条来源（对齐 DSH WebSearchSource）。
class WebSearchSource {
  final String url;
  final String? title;
  final String? snippet;
  final String? publishedAt;

  /// 来源引擎（SearXNG `engine`；定位"哪个引擎给的结果"很有用）。
  final String? engine;

  /// 相关性得分（SearXNG `score`，越大越相关；缺失为 null）。
  final double? score;
  const WebSearchSource({
    required this.url,
    this.title,
    this.snippet,
    this.publishedAt,
    this.engine,
    this.score,
  });
}

/// 内部错误码：实例拒绝了 `engines=`（400/422）。仅用于触发"去引擎重试"，
/// 不会外泄给模型（对外仍是 WEB_PROVIDER_ERROR / WEB_ABORTED 两类）。
const String kWebEngineRejected = 'WEB_ENGINE_REJECTED';

/// 结构化搜索错误（对齐 DSH WEB_PROVIDER_ERROR / WEB_ABORTED）。
class WebSearchProviderError {
  /// 'WEB_PROVIDER_ERROR'（不可用/出错）| 'WEB_ABORTED'（超时/取消）
  /// | 'WEB_ENGINE_REJECTED'（实例不接受 engines 参数，触发去引擎重试）。
  final String kind;
  final String message;
  const WebSearchProviderError(this.kind, this.message);
}

/// SearXNG 搜索 provider（对齐 DSH `@deepseek-ai/dsh-web-search-searxng`）。
///
/// 调用自建 SearXNG 实例的 JSON API：`GET {baseURL}/search?q=...&format=json`。
class SearXNGSearchProvider implements WebSearchProvider {
  /// 默认不预置任何实例：搜索服务由用户在「设置 → API 接入 → 联网搜索」填写。
  /// 留空时 [available] 会给出"未配置"的明确诊断（旧默认 127.0.0.1 在手机上
  /// 指向手机自己，只会得到一个误导性的"不可达"）。
  static const String kDefaultBaseUrl = '';

  /// 引擎白名单默认为空 = 由实例决定。实例上存在不可达引擎时，用户自行缩小
  /// 白名单可把搜索从二十秒级降到秒级（实测某实例：21s → 2.5s）。
  static const String kDefaultEngines = '';
  static const int kDefaultMaxResults = 8;

  /// 默认预算 30s：SearXNG 聚合多引擎本身就要十几到二十几秒，15s 会稳定误杀。
  static const Duration kDefaultTimeout = Duration(seconds: 30);

  /// 连接超时：不设时 Dio 不限连接阶段，主机不可达会挂到 OS TCP 超时（几十秒）。
  static const Duration kConnectTimeout = Duration(seconds: 6);

  @override
  final String id = 'searxng';
  @override
  final String name = 'SearXNG';

  final String baseURL;
  final String? apiKey;
  final int maxResults;
  final Duration timeout;
  final String? language;
  final String? categories;

  /// 逗号分隔引擎白名单（SearXNG `engines=` 参数）。
  final String? engines;

  /// 请求 User-Agent（部分实例/反代会拦非常规 UA）。
  final String userAgent;

  final Dio _dio;

  SearXNGSearchProvider({
    this.baseURL = kDefaultBaseUrl,
    this.apiKey,
    this.maxResults = kDefaultMaxResults,
    this.timeout = kDefaultTimeout,
    this.language,
    this.categories,
    this.engines = kDefaultEngines,
    this.userAgent = 'Mozilla/5.0 (Android) TongYiLite/1.0',
    Dio? dio,
  }) : _dio = dio ??
            Dio(BaseOptions(
              // 按字符串收响应、自行 jsonDecode（见文件头实测说明）。
              responseType: ResponseType.plain,
              connectTimeout: kConnectTimeout,
              sendTimeout: const Duration(seconds: 10),
            ));

  /// 从持久化设置构建（对齐 DSH web-search-searxng settings section）。
  factory SearXNGSearchProvider.fromSettings(InferenceSettings settings) {
    return SearXNGSearchProvider(
      baseURL: settings.webSearchSearXngBaseUrl,
      apiKey: settings.webSearchSearXngApiKey,
      maxResults: settings.webSearchSearXngMaxResults,
      timeout: Duration(milliseconds: settings.webSearchSearXngTimeoutMs),
      language: settings.webSearchSearXngLanguage,
      categories: settings.webSearchSearXngCategories,
      engines: settings.webSearchSearXngEngines,
    );
  }

  /// 配置签名：内容相同即同一份配置，供 [WebSearchSeam] 判断是否需要重建。
  /// 没有它，每轮对话都会 new provider 并 dispose 旧 Dio，连接池全废。
  String get configSignature => _signature(
        baseURL,
        apiKey,
        maxResults,
        timeout,
        language,
        categories,
        engines,
      );

  /// 不构造实例也能算签名（避免"比较前先 new 一个带 HttpClient 的对象"）。
  static String signatureFromSettings(InferenceSettings s) => _signature(
        s.webSearchSearXngBaseUrl,
        s.webSearchSearXngApiKey,
        s.webSearchSearXngMaxResults,
        Duration(milliseconds: s.webSearchSearXngTimeoutMs),
        s.webSearchSearXngLanguage,
        s.webSearchSearXngCategories,
        s.webSearchSearXngEngines,
      );

  static String _signature(
    String baseURL,
    String? apiKey,
    int maxResults,
    Duration timeout,
    String? language,
    String? categories,
    String? engines,
  ) =>
      [
        baseURL.trim(),
        apiKey ?? '',
        maxResults,
        timeout.inMilliseconds,
        language ?? '',
        categories ?? '',
        engines ?? '',
      ].join('\u0000');

  /// 廉价可用性探测：校验 baseURL 可解析、协议合法、有 host；不联网。
  @override
  String? available() {
    if (baseURL.trim().isEmpty) {
      return '未配置 SearXNG 地址：请在「设置 → API 接入 → 联网搜索」填写实例地址'
          '（如 http://192.168.1.20:8080），并确认手机能访问该地址';
    }
    try {
      final uri = Uri.parse(baseURL);
      if (uri.scheme.isEmpty) {
        return 'baseURL 缺少协议（应为 http:// 或 https://）：$baseURL';
      }
      if (uri.scheme != 'http' && uri.scheme != 'https') {
        return 'baseURL 协议不支持 "${uri.scheme}"（仅 http/https）：$baseURL';
      }
      if (uri.host.isEmpty) return 'baseURL 未配置或格式错误：$baseURL';
      return null;
    } catch (_) {
      return 'baseURL 格式错误：$baseURL';
    }
  }

  /// 构造搜索请求 URI：**显式带 `/search` 路径**。
  ///
  /// 容忍 `http://h:8080`、`http://h:8080/`、`http://h:8080/search` 三种写法。
  Uri buildRequestUri(String query, {String? enginesOverride}) {
    var base = baseURL.trim();
    while (base.endsWith('/')) {
      base = base.substring(0, base.length - 1);
    }
    if (!base.toLowerCase().endsWith('/search')) base = '$base/search';
    final uri = Uri.parse(base);
    final params = <String, String>{
      ...uri.queryParameters,
      'q': query,
      'format': 'json',
    };
    if (language != null && language!.isNotEmpty) params['language'] = language!;
    if (categories != null && categories!.isNotEmpty) {
      params['categories'] = categories!;
    }
    final eng = enginesOverride ?? engines;
    if (eng != null && eng.trim().isNotEmpty) params['engines'] = eng.trim();
    return uri.replace(queryParameters: params, fragment: '');
  }

  @override
  Future<WebSearchResult> search(String query, {Duration? timeout}) async {
    final availableErr = available();
    if (availableErr != null) {
      throw WebSearchProviderError('WEB_PROVIDER_ERROR', availableErr);
    }
    final t = timeout ?? this.timeout;

    // 第一击带引擎白名单（实测 21s → 2.5s）。若实例上没有这些引擎会回
    // 400/422，此时去掉 engines 再试一次——换实例不至于直接不可用。
    final useEngines = engines != null && engines!.trim().isNotEmpty;
    try {
      return await _request(query, t, buildRequestUri(query));
    } on WebSearchProviderError catch (e) {
      if (useEngines && e.kind == kWebEngineRejected) {
        return _request(query, t, buildRequestUri(query, enginesOverride: ''));
      }
      rethrow;
    }
  }

  Future<WebSearchResult> _request(String query, Duration t, Uri uri) async {
    final sw = Stopwatch()..start();
    try {
      final resp = await _dio.get<String>(
        uri.toString(),
        options: Options(
          receiveTimeout: t,
          responseType: ResponseType.plain,
          headers: _headers(),
          // 状态码自己判定，才能给出可诊断的错（Dio 默认只放过 2xx）。
          validateStatus: (_) => true,
        ),
      );
      final status = resp.statusCode ?? 0;
      if (status >= 400) {
        throw WebSearchProviderError(
          // 400/422 最常见的原因是 engines= 里有该实例没有的引擎。
          (status == 400 || status == 422)
              ? kWebEngineRejected
              : 'WEB_PROVIDER_ERROR',
          'SearXNG 返回 HTTP $status${_statusHint(status)}'
          '（${uri.host}:${uri.port}，用时 ${sw.elapsedMilliseconds}ms）',
        );
      }
      final body = resp.data ?? '';
      // Content-Type 明确不是 JSON → 实例没开 format=json。
      final ct =
          (resp.headers.value(Headers.contentTypeHeader) ?? '').split(';').first.trim();
      if (ct.isNotEmpty && !_isJsonMime(ct)) {
        throw WebSearchProviderError(
          'WEB_PROVIDER_ERROR',
          'SearXNG 返回 $ct 而非 JSON：需在实例 settings.yml 的 search.formats '
          '里加上 json（用时 ${sw.elapsedMilliseconds}ms）',
        );
      }
      final Map<String, dynamic> data;
      try {
        final decoded = body.isEmpty ? <String, dynamic>{} : jsonDecode(body);
        if (decoded is! Map<String, dynamic>) {
          throw const FormatException('顶层不是 JSON 对象');
        }
        data = decoded;
      } on FormatException catch (e) {
        throw WebSearchProviderError('WEB_PROVIDER_ERROR',
            'SearXNG 响应不是合法 JSON：${e.message}（用时 ${sw.elapsedMilliseconds}ms）');
      }
      final rawCount = (data['results'] as List?)?.length ?? 0;
      final mapped = _mapResults(data);
      return WebSearchResult(
        sources: mapped,
        truncated: rawCount > mapped.length,
        diagnostics:
            mapped.isEmpty ? _describeEmpty(data) : null,
      );
    } on WebSearchProviderError {
      rethrow;
    } on DioException catch (e) {
      throw _describeDioError(e, uri, sw);
    }
  }

  /// 把 Dio 的异常翻成人能看懂、且方向正确的诊断（旧实现一律报"不可达"）。
  WebSearchProviderError _describeDioError(
    DioException e,
    Uri uri,
    Stopwatch sw,
  ) {
    final ms = sw.elapsedMilliseconds;
    final target = '${uri.host}:${uri.port}';
    switch (e.type) {
      case DioExceptionType.connectionTimeout:
        return WebSearchProviderError('WEB_ABORTED',
            '连接 SearXNG 超时（$target，${ms}ms）：检查实例是否开机、Tailscale 是否在线');
      case DioExceptionType.receiveTimeout:
        return WebSearchProviderError('WEB_ABORTED',
            'SearXNG 响应超时（$target，已等 ${ms}ms）：引擎过多/过慢，'
            '考虑在「联网搜索」里指定引擎（如实例只留本域可达的引擎）');
      case DioExceptionType.sendTimeout:
        return WebSearchProviderError('WEB_ABORTED', 'SearXNG 请求发送超时（$target）');
      case DioExceptionType.badResponse:
        final code = e.response?.statusCode;
        return WebSearchProviderError(
          'WEB_PROVIDER_ERROR',
          'SearXNG 返回 HTTP $code${_statusHint(code)}（$target，${ms}ms）',
        );
      case DioExceptionType.cancel:
        return const WebSearchProviderError('WEB_ABORTED', '搜索已取消');
      case DioExceptionType.connectionError:
        return WebSearchProviderError('WEB_PROVIDER_ERROR',
            '连不上 SearXNG（$target，${ms}ms）：${_underlying(e) ?? '网络不通'}；'
            '检查地址/端口是否正确、实例是否在线、手机与实例是否在同一网络或 Tailscale');
      default:
        return WebSearchProviderError('WEB_PROVIDER_ERROR',
            'SearXNG 请求失败（$target，${ms}ms）：${e.message ?? e.type}'
            '${_underlying(e) == null ? '' : ' / ${_underlying(e)}'}');
    }
  }

  /// Dio 常把真正的 socket 错误塞进 [DioException.error]（type 只报 unknown），
  /// 不挖出来就只剩一句没用的"请求失败"。
  String? _underlying(DioException e) {
    final err = e.error;
    if (err is SocketException) {
      final os = err.osError;
      return os == null ? err.message : '${err.message}(${os.errorCode} ${os.message})';
    }
    return err?.toString();
  }

  String _statusHint(int? status) {
    switch (status) {
      case 401:
        return '（未授权：需要在设置里填 API key）';
      case 403:
        return '（被拒绝：实例可能禁止 JSON API 或对来源限流）';
      case 404:
        return '（找不到 /search：确认 baseURL 是否多写了路径）';
      case 429:
        return '（限流：稍后再试或减少搜索频次）';
      case 400:
      case 422:
        return '（请求不被接受：常见于 engines 指定了实例上没有的引擎）';
      default:
        return status != null && status >= 500 ? '（实例内部错误）' : '';
    }
  }

  /// 0 结果时的实例侧诊断（实测案例：上游引擎全 timeout / CAPTCHA 挂起时
  /// SearXNG 仍返回 HTTP 200 + 空 results——不挖 unresponsive_engines 就
  /// 只会得到一句没用的"查询不到"）。
  String _describeEmpty(Map<String, dynamic> data) {
    final unresponsive = data['unresponsive_engines'];
    final parts = <String>[];
    if (unresponsive is List && unresponsive.isNotEmpty) {
      final items = unresponsive
          .map((e) => e is List && e.length >= 2
              ? '${e[0]}(${e[1]})'
              : e.toString())
          .take(8)
          .join('、');
      parts.add('实例侧引擎状态：$items');
    }
    parts.add('所有启用的引擎都未返回结果——多半是 SearXNG 实例的出口网络'
        '不通（引擎集体 timeout）或引擎被 CAPTCHA 挂起，需在实例所在机器上'
        '检查外网连通性/代理与 settings.yml 的引擎配置');
    return parts.join('；');
  }

  bool _isJsonMime(String ct) {
    final lower = ct.toLowerCase();
    return lower == 'application/json' || lower.endsWith('+json');
  }

  Map<String, String> _headers() {
    final headers = <String, String>{
      'User-Agent': userAgent,
      'Accept': 'application/json',
    };
    if (apiKey != null && apiKey!.isNotEmpty) {
      headers['Authorization'] = 'Bearer $apiKey';
    }
    return headers;
  }

  /// 映射 SearXNG `results[]`：URL 规范化去重 → 按 score 降序 → 截 maxResults。
  List<WebSearchSource> _mapResults(Map<String, dynamic> data) {
    final seen = <String>{};
    final sources = <WebSearchSource>[];
    final results = data['results'] as List? ?? const [];
    for (final item in results) {
      if (item is! Map) continue;
      final url = item['url'];
      if (url is! String || url.isEmpty) continue;
      // 规范化后再去重：utm 参数 / fragment / 尾斜杠 / host 大小写不同即同一篇。
      final key = normalizeSourceUrl(url);
      if (!seen.add(key)) continue;
      sources.add(WebSearchSource(
        url: url,
        title: item['title'] as String?,
        snippet: item['content'] as String?,
        publishedAt: item['publishedDate'] as String?,
        engine: item['engine'] as String?,
        score: (item['score'] as num?)?.toDouble(),
      ));
    }
    // 有 score 的按相关性优先（缺失的保持原有顺序）。
    sources.sort((a, b) {
      final sa = a.score, sb = b.score;
      if (sa == null && sb == null) return 0;
      if (sa == null) return 1;
      if (sb == null) return -1;
      return sb.compareTo(sa);
    });
    return sources.take(maxResults).toList();
  }

  @override
  void dispose() {
    _dio.close(force: true);
  }
}

/// 去掉跟踪参数/fragment/尾斜杠并小写 host，用于跨引擎的同源去重。
String normalizeSourceUrl(String raw) {
  final uri = Uri.tryParse(raw.trim());
  if (uri == null || uri.host.isEmpty) return raw.trim();
  final params = uri.queryParameters.entries
      .where((e) => !e.key.toLowerCase().startsWith('utm_'))
      .where((e) => e.key.toLowerCase() != 'from')
      .toList()
    ..sort((a, b) => a.key.compareTo(b.key));
  var path = uri.path;
  if (path.length > 1 && path.endsWith('/')) {
    path = path.substring(0, path.length - 1);
  }
  final query = params.map((e) => '${e.key}=${e.value}').join('&');
  final normalized = Uri(
    scheme: uri.scheme.toLowerCase(),
    host: uri.host.toLowerCase(),
    port: uri.hasPort ? uri.port : null,
    path: path.isEmpty ? '/' : path,
    query: query.isEmpty ? null : query,
  );
  return normalized.toString();
}

/// 用持久化设置（重新）构建并注册当前搜索 provider 到 [WebSearchSeam]。
///
/// 在设置变更时调用即可热切换搜索源，无需重启应用。
///
/// **搜索源选择（优先级）**：
/// - 端侧直连总开关开（`webSearchDirectEnabled`，默认开）→
///   [DirectSearchProvider.instance]，**优先级最高**：即使配置了 SearXNG
///   地址也用端侧直连；
/// - 总开关关 → SearXNG 模式：地址已配置用 SearXNG，未配置则注册
///   "未配置"诊断的 SearXNG provider（web_search 给出可行动提示）。
///
/// **配置未变时直接复用现有实例**：每轮对话都 new 一个 provider 会 dispose 掉旧
/// Dio（连接池作废 → 每次搜索重新 DNS+TCP+TLS，移动网络额外几百 ms 与射频唤醒），
/// 还会打断上一轮在飞的请求。这里先比签名，不匹配才构造新实例。
void applySearXNGProviderFromSettings(InferenceSettings settings) {
  final seam = WebSearchSeam.instance;
  if (settings.webSearchDirectEnabled) {
    // 直连 provider 是单例（熔断状态/Cookie 会话/预算窗口跨搜索存活），
    // registerProvider 对 identical 实例直接跳过，重复注册无副作用。
    // 引擎开关/风险预算经 applySettings 热更新（配置未变则内部直接返回）。
    DirectSearchProvider.instance.applySettings(settings);
    if (seam.provider is! DirectSearchProvider) {
      seam.registerProvider(DirectSearchProvider.instance);
    }
    return;
  }
  // 端侧直连关闭：SearXNG 模式（地址未配置时保留诊断型 provider，
  // web_search 返回"请填写地址"而不是莫名的"provider 未配置"）。
  final current = seam.provider;
  final candidate = SearXNGSearchProvider.fromSettings(settings);
  if (current is SearXNGSearchProvider &&
      current.configSignature == candidate.configSignature) {
    candidate.dispose();
    return; // 配置没变：连 provider 带连接池一起留着。
  }
  seam.registerProvider(candidate);
}
