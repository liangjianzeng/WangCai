import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

import 'package:tongyi_lite/agent/web_search/web_search_provider.dart';

/// 真实 SearXNG 实例的连通性验收（默认 **跳过**，不污染常规测试与 CI）。
///
/// 跑法（自己指定实例，不写入仓库任何默认值）：
/// ```
/// $env:SEARX_LIVE_URL     = 'http://<你的实例>:8080'
/// $env:SEARX_LIVE_ENGINES = 'bing,sogou'   # 可选：只填该实例可达的引擎
/// flutter test test/agent/web_search_live_test.dart
/// ```
/// 验证：URL 拼接后实例真的返回 JSON、结果非空可读；以及不可达地址能在秒级失败
/// 并给出可诊断的错误（而不是挂到几十秒或只回一句"不可达"）。
void main() {
  final liveUrl = (Platform.environment['SEARX_LIVE_URL'] ?? '').trim();
  final engines = (Platform.environment['SEARX_LIVE_ENGINES'] ?? '').trim();
  final skip = liveUrl.isEmpty
      ? '未设置 SEARX_LIVE_URL，跳过真实实例连通性测试'
      : false;

  // flutter_test 的 binding 会把 HttpOverrides 装成"永远回 400"的 mock，本文件要
  // 真实 socket，所以显式关掉它。这个 SDK 的 HttpOverrides 只有 setter 没有 getter，
  // 旧值取不回来，因此只在真的要跑实时用例时动它；本 suite 默认整体跳过，且
  // flutter test 里每个测试文件是独立 isolate，不会影响其它测试。
  // （HttpOverrides.runZoned(createHttpClient: (c) => HttpClient(...)) 那条路不通：
  //  回调里的 HttpClient() 会再次命中同一个 override，直接 Stack Overflow。）
  void enableRealHttp() => HttpOverrides.global = null;

  test('真实实例：搜索可用且返回可读结果', () async {
    enableRealHttp();
    final provider = SearXNGSearchProvider(
      baseURL: liveUrl,
      engines: engines.isEmpty ? null : engines,
      timeout: const Duration(seconds: 40),
    );
    final sw = Stopwatch()..start();
    try {
      final result = await provider.search('llama.cpp 端侧推理');
      sw.stop();
      // 延迟是这台机器/这个实例的关键指标，打出来供优化对比。
      // ignore: avoid_print
      print('[实时] ${result.sources.length} 条，用时 ${sw.elapsedMilliseconds}ms，'
          'truncated=${result.truncated}');
      for (final s in result.sources.take(3)) {
        // ignore: avoid_print
        print('[实时] - ${s.title} | engine=${s.engine} | '
            '摘要 ${s.snippet?.length ?? 0} 字 | ${s.url}');
      }
      expect(result.sources, isNotEmpty);
      expect(result.sources.every((s) => s.url.startsWith('http')), isTrue);
    } on WebSearchProviderError catch (e) {
      // ignore: avoid_print
      print('[实时][失败] ${e.kind}：${e.message}（${sw.elapsedMilliseconds}ms）');
      rethrow;
    }
  }, skip: skip, timeout: const Timeout(Duration(minutes: 2)));

  test('不可达地址：快速失败且错误可诊断', () async {
    enableRealHttp();
    final provider = SearXNGSearchProvider(
      baseURL: 'http://127.0.0.1:59999',
      timeout: const Duration(seconds: 8),
    );
    final sw = Stopwatch()..start();
    try {
      await provider.search('x');
      fail('不可达地址本应抛错');
    } on WebSearchProviderError catch (e) {
      sw.stop();
      // ignore: avoid_print
      print('[实时] 不可达诊断：${e.kind} ${e.message}（${sw.elapsedMilliseconds}ms）');
      expect(e.message, contains('127.0.0.1'));
      // 连不上必须立刻失败，不能把用户挂在那里等。
      expect(sw.elapsedMilliseconds, lessThan(9000));
    }
  }, skip: skip);
}
