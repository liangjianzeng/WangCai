/// 搜索引擎统一接口：引擎只做"一次查询 → 一页结果"，HTTP 抓取由外部注入，
/// 保证解析逻辑可离线单测（喂 fixture 字符串）。
library;

import 'search_hit.dart';

/// 抓取一页文本（HTML/XML/RSS）的函数，由上层注入（带 Cookie/UA/重试策略）。
///
/// 非 2xx 或明显被反爬拦截时由注入方抛 [SearchEngineException]；
/// 引擎内部也应对"HTTP 200 但内容是验证码页"做判定并抛 blocked。
typedef FetchPage = Future<String> Function(
  Uri url, {
  Map<String, String>? extraHeaders,
});

/// 单引擎适配器。
abstract class SearchEngine {
  /// 稳定 id（如 "bing_cn"），用于结果标注/熔断状态/设置项。
  String get id;

  /// 展示名（诊断文案用）。
  String get displayName;

  /// 执行一次搜索，返回至多 [limit] 条结果（按引擎自己的相关性排序）。
  ///
  /// 失败抛 [SearchEngineException]；0 条结果抛 kind=empty。
  Future<List<SearchHit>> search(String query, {int limit = 8});

  /// 释放资源（如注入方持有的 Dio）。
  void dispose() {}
}
