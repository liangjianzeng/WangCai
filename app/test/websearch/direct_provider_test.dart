/// 直连 provider 与 Seam 注册逻辑测试。
library;

import 'package:flutter_test/flutter_test.dart';
import 'package:tongyi_lite/services/settings_service.dart';
import 'package:tongyi_lite/agent/web_search/direct_search_provider.dart';
import 'package:tongyi_lite/agent/web_search/web_search_seam.dart';

void main() {
  tearDown(() {
    // 测试间恢复空态，避免污染其它用例的 seam 单例。
    WebSearchSeam.instance.dispose();
  });

  test('SearXNG 未配置 → 注册直连 provider（单例幂等）', () {
    final settings = InferenceSettings();
    applySearXNGProviderFromSettings(settings);
    expect(WebSearchSeam.instance.provider, same(DirectSearchProvider.instance));

    // 重复调用（每轮对话都会调）不替换实例——熔断状态必须跨搜索存活。
    applySearXNGProviderFromSettings(settings);
    expect(WebSearchSeam.instance.provider, same(DirectSearchProvider.instance));
  });

  test('直连 provider available() 恒可用（无需配置）', () {
    expect(DirectSearchProvider.instance.available(), isNull);
  });

  test('端侧直连总开关打开 → 即使配置了 SearXNG 也直连（最高优先级）', () {
    applySearXNGProviderFromSettings(InferenceSettings(
      webSearchSearXngBaseUrl: 'http://192.168.1.20:8080',
      webSearchDirectEnabled: true,
    ));
    expect(WebSearchSeam.instance.provider, same(DirectSearchProvider.instance));
  });

  test('总开关关闭 → SearXNG 模式（未配置则注册诊断型 provider）', () {
    // 关闭 + 未配置地址：available() 给"请填写地址"诊断。
    applySearXNGProviderFromSettings(InferenceSettings(
      webSearchDirectEnabled: false,
    ));
    final p1 = WebSearchSeam.instance.provider;
    expect(p1, isA<SearXNGSearchProvider>());
    expect(p1!.available(), isNotNull);

    // 关闭 + 已配置地址：SearXNG 生效。
    applySearXNGProviderFromSettings(InferenceSettings(
      webSearchDirectEnabled: false,
      webSearchSearXngBaseUrl: 'http://192.168.1.20:8080',
    ));
    final p2 = WebSearchSeam.instance.provider;
    expect(p2, isA<SearXNGSearchProvider>());
    expect(p2!.available(), isNull);

    // 重新打开总开关（默认值）→ 回到直连。
    applySearXNGProviderFromSettings(InferenceSettings(
      webSearchSearXngBaseUrl: 'http://192.168.1.20:8080',
    ));
    expect(WebSearchSeam.instance.provider, same(DirectSearchProvider.instance));
  });

  test('applySettings：全部引擎关闭 → available() 给出可行动诊断', () {
    final provider = DirectSearchProvider.instance;
    provider.applySettings(InferenceSettings(webSearchDirectEngines: []));
    expect(provider.available(), isNotNull);
    expect(provider.available(), contains('至少启用一个引擎'));

    // 恢复默认（全启用）→ 可用。
    provider.applySettings(InferenceSettings());
    expect(provider.available(), isNull);
  });

  test('applySettings：引擎列表过滤到已知 id，乱序/未知 id 不炸', () {
    final provider = DirectSearchProvider.instance;
    provider.applySettings(InferenceSettings(
      webSearchDirectEngines: ['quark', 'bing_cn', 'unknown_x'],
    ));
    expect(provider.available(), isNull);
    provider.applySettings(InferenceSettings());
  });
}
