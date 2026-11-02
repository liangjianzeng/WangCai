/// 直连多引擎搜索 provider：把 lib/websearch 独立模块适配进 WebSearchSeam。
///
/// SearXNG 未配置时的默认搜索源（SearXNG 实例可用时仍优先 SearXNG——
/// 用户显式配置即显式选择）。注册与配置热更新在
/// [applySearXNGProviderFromSettings] → [DirectSearchProvider.applySettings]。
///
/// provider 为进程级单例：熔断状态/Cookie 会话/预算窗口必须跨搜索存活，且
/// WebSearchSeam 对非 SearXNG provider 按对象身份判"配置未变"。
library;

import '../../services/settings_service.dart';
import '../../websearch/src/engine_http.dart';
import '../../websearch/src/link_resolver.dart';
import '../../websearch/src/multi_engine_search.dart';
import '../../websearch/src/search_engine.dart';
import 'web_search_provider.dart';

/// 低风险引擎（容忍度高，预算宽松）。
const List<String> kLowRiskEngines = ['bing_cn', 'so360', 'chinaso'];

/// 直连多引擎 provider（必应CN/百度/搜狗/360/夸克/中国搜索，聚合+熔断+预算）。
class DirectSearchProvider implements WebSearchProvider {
  DirectSearchProvider._() {
    _rebuild(_enginesFromIds(kDirectEngineIds), kDefaultEngineBudgets);
  }

  static final DirectSearchProvider instance = DirectSearchProvider._();

  final EngineHttpSession _session = EngineHttpSession();
  late MultiEngineSearch _multi;

  /// 当前配置签名（引擎集合 + 预算），变了他才重建聚合器。
  String _signature = '';
  LinkResolver? _resolver;

  @override
  final String id = 'direct';

  @override
  String get name => '直连引擎(必应CN/百度/搜狗/360/夸克/中国搜索)';

  @override
  String? available() {
    // 全部引擎被关掉时给出可行动诊断；其余情况由运行时状态决定。
    if (_multi.engines.isEmpty) {
      return '所有直连搜索引擎都已被关闭：请在「设置 → API 接入 → 联网搜索」'
          '至少启用一个引擎，或填写 SearXNG 实例地址';
    }
    return null;
  }

  /// 按设置（重）配置聚合器：引擎开关 + 风险分档窗口预算。
  ///
  /// 配置未变直接返回（保住熔断状态/预算窗口/Cookie 会话）；变了才重建
  /// 聚合器——会话层（Cookie/UA）保留，只有被 blocked 清掉的会话才换新。
  void applySettings(InferenceSettings settings) {
    final enabled = settings.webSearchDirectEngines
        .where(kDirectEngineIds.contains)
        .toList();
    final budgets = <String, int>{
      for (final id in kLowRiskEngines)
        id: settings.webSearchDirectLowRiskPerWindow,
      for (final id in kHighRiskEngineIds)
        id: settings.webSearchDirectHighRiskPerWindow,
    };
    final signature =
        '${enabled.join(',')}\u0000${budgets.entries.map((e) => '${e.key}=${e.value}').join(',')}';
    if (signature == _signature) return;
    _signature = signature;
    _rebuild(_enginesFromIds(enabled), budgets);
  }

  void _rebuild(List<SearchEngine> engines, Map<String, int> budgets) {
    _resolver ??= LinkResolver();
    _multi = MultiEngineSearch(
      engines: engines,
      resolver: _resolver,
      engineBudgets: budgets,
      // 搜狗/百度的风控惩罚主要绑 Cookie：blocked 即丢会话+换 UA，冷却到期
      // 以全新身份重试（调研结论，见 docs/websearch_direct_2026-10-02.md §5）。
      onEngineBlocked: _session.clearCookies,
    );
  }

  List<SearchEngine> _enginesFromIds(List<String> ids) {
    // 保持默认优先级顺序。
    final engines = defaultEngines(_session);
    return [for (final id in ids) ...engines.where((e) => e.id == id)];
  }

  @override
  Future<WebSearchResult> search(String query, {Duration? timeout}) async {
    final outcome = await _multi.search(query);
    final sources = outcome.hits
        .map((hit) => WebSearchSource(
              url: hit.url,
              title: hit.title,
              snippet: hit.snippet,
              publishedAt: hit.publishedAt,
              engine: hit.engine,
            ))
        .toList();
    return WebSearchResult(
      sources: sources,
      truncated: outcome.truncated,
      diagnostics: outcome.allFailed ? outcome.diagnosticsText() : null,
    );
  }

  @override
  void dispose() {
    // 单例：Seam 切换 provider 时会 dispose 旧实例，直连实例不参与
    // （registerProvider 对 identical 实例直接跳过），这里防御性不关。
    _multi.dispose();
    _session.dispose();
  }
}
