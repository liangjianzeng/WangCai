/// 独立联网搜索模块的标准化结果条目。
///
/// 本模块（lib/websearch/）刻意不依赖 Flutter 与上层 agent 代码，方便后续
/// 复用到其它 Dart 工程；上层（lib/agent/web_search/）负责把 [SearchHit]
/// 适配成 WebSearchSource。
library;

/// 一条搜索结果。
class SearchHit {
  final String title;

  /// 尽可能是真实目标 URL（各引擎的内嵌真实地址字段）；
  /// 拿不到真实地址时允许退回引擎的跳转链接。
  final String url;
  final String? snippet;
  final String? publishedAt;

  /// 来源引擎 id（如 "bing_cn"），与 [SearchEngine.id] 一致。
  final String engine;

  const SearchHit({
    required this.title,
    required this.url,
    this.snippet,
    this.publishedAt,
    required this.engine,
  });

  @override
  String toString() => 'SearchHit($engine, $title, $url)';
}

/// 引擎级失败。聚合器按 [kind] 决定熔断时长与诊断文案。
class SearchEngineException implements Exception {
  final String engineId;

  /// blocked=反爬拦截（验证码/安全验证页）；network=网络失败/超时；
  /// empty=抓取与解析都成功但 0 条；parse=页面结构不认识（可能改版）。
  final String kind;
  final String message;
  const SearchEngineException(this.engineId, this.kind, this.message);

  @override
  String toString() => 'SearchEngineException($engineId, $kind, $message)';
}
