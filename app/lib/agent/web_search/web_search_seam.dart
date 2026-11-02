/// 联网搜索接缝（对齐 DSH `ctx.web` 的可插拔搜索能力）。
///
/// web_search 工具只调接缝、不写死搜索源；具体搜索实现（默认 SearXNG）通过
/// [registerProvider] 注入。切换 provider 时自动释放旧资源，避免泄漏 HttpClient。
library;

import 'web_search_provider.dart';

export 'web_search_provider.dart';

/// 持有当前可插拔搜索 provider 的进程内单例，跨 agent 循环共享同一 provider。
class WebSearchSeam {
  WebSearchSeam._();

  static final WebSearchSeam instance = WebSearchSeam._();

  WebSearchProvider? _provider;

  /// 当前注册（且非空）的搜索 provider。
  WebSearchProvider? get provider => _provider;

  /// 注册/切换当前搜索 provider。
  ///
  /// 用配置签名（而非对象身份）判断是否真的变了：provider 每次由 `fromSettings`
  /// 新建，按身份比较等于每轮对话都 dispose 掉旧 Dio、把连接池作废重建。
  void registerProvider(WebSearchProvider? provider) {
    final current = _provider;
    if (identical(provider, current)) return;
    if (current != null &&
        provider != null &&
        current.id == provider.id &&
        _signatureOf(current) == _signatureOf(provider)) {
      // 内容等价：保留旧实例（连同它的连接池），丢弃新实例。
      provider.dispose();
      return;
    }
    current?.dispose();
    _provider = provider;
  }

  /// provider 的配置签名；非 SearXNG provider 退化为身份比较
  /// （即只有同一对象才算"没变"）。
  static String _signatureOf(WebSearchProvider p) => p is SearXNGSearchProvider
      ? p.configSignature
      : 'identity:${identityHashCode(p)}';

  /// 可用性探测（廉价：仅本地校验，不联网）。
  String? available() => _provider?.available();

  /// 执行一次搜索；provider 不可用时抛出结构化 [WebSearchProviderError]。
  ///
  /// [timeout] 仅在显式传入时覆盖 provider 自身的超时；传 null 用 provider 配置，
  /// 否则设置项里的超时会被这里的默认值静默吃掉（旧实现即如此）。
  Future<WebSearchResult> search(
    String query, {
    Duration? timeout,
  }) async {
    final provider = _provider;
    if (provider == null) {
      throw const WebSearchProviderError(
          'WEB_PROVIDER_ERROR', '联网搜索 provider 未配置');
    }
    final availableErr = provider.available();
    if (availableErr != null) {
      throw WebSearchProviderError('WEB_PROVIDER_ERROR', availableErr);
    }
    return provider.search(query, timeout: timeout);
  }

  /// 清空当前 provider（进程退出/重置时使用）。
  void dispose() {
    _provider?.dispose();
    _provider = null;
  }
}
