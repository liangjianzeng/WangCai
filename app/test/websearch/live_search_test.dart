/// live 集成测试（默认跳过）：直连多引擎真实联网搜索。
///
/// 运行（会发真实网络请求，注意别高频反复跑——反爬惩罚由熔断兜底但仍要克制）：
/// ```
/// TONGYILITE_LIVE_SEARCH=1 flutter test test/websearch/live_search_test.dart
/// ```
library;

import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:tongyi_lite/websearch/src/engine_http.dart';
import 'package:tongyi_lite/websearch/src/link_resolver.dart';
import 'package:tongyi_lite/websearch/src/multi_engine_search.dart';

const _live = bool.fromEnvironment('LIVE_SEARCH');
const _liveEnv = 'TONGYILITE_LIVE_SEARCH';

void main() {
  final enabled =
      _live || Platform.environment[_liveEnv] == '1';

  test('live: 直连多引擎真实搜索', () async {
    final session = EngineHttpSession();
    final multi = MultiEngineSearch(
      engines: defaultEngines(session),
      resolver: LinkResolver(),
    );
    const query = '华为Mate70 发布会';
    final sw = Stopwatch()..start();
    final out = await multi.search(query);
    sw.stop();
    // ignore: avoid_print
    print('耗时 ${sw.elapsedMilliseconds}ms');
    // ignore: avoid_print
    print('引擎状态: ${out.engineStatus}');
    // ignore: avoid_print
    print('结果 ${out.hits.length} 条 (truncated=${out.truncated}):');
    for (final h in out.hits.take(10)) {
      // ignore: avoid_print
      print('- [${h.engine}] ${h.title}\n  ${h.url}\n  ${(h.snippet ?? '')..trim()}');
    }
    expect(out.hits, isNotEmpty,
        reason: '至少一家引擎应返回结果；状态=${out.engineStatus}');
    multi.dispose();
  }, skip: !enabled ? '设置 $_liveEnv=1 启用（会发真实网络请求）' : false);

  test('live: 第二次搜索（验证熔断状态与 Cookie 会话复用）', () async {
    final session = EngineHttpSession();
    final multi = MultiEngineSearch(
      engines: defaultEngines(session),
      resolver: LinkResolver(),
    );
    await multi.search('武汉 天气');
    final out = await multi.search('武汉 天气 预报');
    // ignore: avoid_print
    print('第二次搜索引擎状态: ${out.engineStatus}');
    // ignore: avoid_print
    print('结果 ${out.hits.length} 条');
    for (final h in out.hits.take(5)) {
      // ignore: avoid_print
      print('- [${h.engine}] ${h.title} | ${h.url}');
    }
    expect(out.hits, isNotEmpty, reason: '状态=${out.engineStatus}');
    multi.dispose();
  }, skip: !enabled ? '设置 $_liveEnv=1 启用（会发真实网络请求）' : false);
}
