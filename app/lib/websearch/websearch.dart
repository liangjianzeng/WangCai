/// 独立联网搜索模块（纯 Dart，可复用）。
///
/// 端侧直连国内搜索引擎（必应CN/360/中国搜索/搜狗/百度），内置引擎级
/// 熔断冷却与跳转链还原，见 docs/websearch_direct_2026-10-02.md。
library;

export 'src/engine_http.dart';
export 'src/engines/baidu_engine.dart';
export 'src/engines/bing_cn_engine.dart';
export 'src/engines/chinaso_engine.dart';
export 'src/engines/quark_engine.dart';
export 'src/engines/so360_engine.dart';
export 'src/engines/sogou_engine.dart';
export 'src/link_resolver.dart';
export 'src/multi_engine_search.dart';
export 'src/search_engine.dart';
export 'src/search_hit.dart';
