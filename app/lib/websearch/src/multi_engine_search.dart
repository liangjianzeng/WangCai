/// 多引擎聚合器：并行查多引擎 → 引擎级熔断冷却 → 跨引擎去重合并 → 链接还原。
///
/// 设计要点（调研+实测沉淀，详见 docs/websearch_direct_2026-10-02.md）：
/// - **熔断按引擎维度**：blocked（反爬）冷却指数退避（1min 起，×2，封顶 10min），
///   parse（页面改版）3min，network 20s，empty 不冷却（是查询相关现象）。
///   手机 IP 频繁漂移（蜂窝/WiFi 切换），分钟级冷却天然适配——冷却到期自动
///   重试，不需要用户干预。
/// - **合并按引擎优先级轮转**（bing → 360 → chinaso → 搜狗 → 百度）：
///   前几条混合各家头部结果，避免单引擎质量差拖垮整体。
/// - **链接还原只对最终返回的结果做**（跳转链还原=每条一次额外请求，
///   能省则省；还原失败保留原跳转链，不影响结果可用性）。
/// - 聚合器本身**不抛异常**：所有引擎都失败时返回空 hits + 各引擎状态，
///   由上层把状态渲染成可行动的诊断文案。
library;

import 'dart:async';

import 'engine_http.dart';
import 'link_resolver.dart';
import 'search_engine.dart';
import 'search_hit.dart';
import 'engines/baidu_engine.dart';
import 'engines/bing_cn_engine.dart';
import 'engines/chinaso_engine.dart';
import 'engines/quark_engine.dart';
import 'engines/so360_engine.dart';
import 'engines/sogou_engine.dart';

/// 各失败类型的冷却时长（指数退避基于此）。
/// 2026-10-02 放宽（端侧直连门控太严）：blocked 2min→1min 起步、封顶 15→10min；
/// parse 5→3min；network 45s→20s。手机 IP 频繁漂移，分钟级冷却已足够防反爬，
/// 过长的冷却反而让整回合搜索体验"卡死"。
const Duration _cooldownBlockedBase = Duration(minutes: 1);
const Duration _cooldownBlockedCap = Duration(minutes: 10);
const Duration _cooldownParse = Duration(minutes: 3);
const Duration _cooldownNetwork = Duration(seconds: 20);

class _EngineState {
  int blockedStreak = 0;
  DateTime coolingUntil = DateTime.fromMillisecondsSinceEpoch(0);
  String? lastStatus;
}

/// 窗口预算状态（固定窗口：首个请求开启，到期重置）。
class _BudgetState {
  int used = 0;
  DateTime windowStart = DateTime.fromMillisecondsSinceEpoch(0);
}

/// 一次聚合搜索的结果。
class MultiSearchOutcome {
  /// 合并去重后的结果（跨引擎，轮转混合，≤maxResults）。
  final List<SearchHit> hits;

  /// 去重后总条数超出 maxResults 时为 true。
  final bool truncated;

  /// engineId → 状态（ok:N / blocked / network:msg / parse:msg / empty /
  /// cooling / disabled），供 0 结果时生成可行动诊断。
  final Map<String, String> engineStatus;

  const MultiSearchOutcome({
    required this.hits,
    required this.truncated,
    required this.engineStatus,
  });

  bool get allFailed => hits.isEmpty;

  /// 0 结果时的诊断文案（写给人/模型看，可行动）。
  String diagnosticsText() {
    if (engineStatus.isEmpty) return '没有可用的搜索引擎';
    final parts = <String>[];
    for (final e in engineStatus.entries) {
      parts.add('${e.key}: ${e.value}');
    }
    return '各引擎状态：${parts.join('；')}。'
        'budget=本轮请求预算已用完（安全管控，窗口到期自动恢复）；'
        'blocked/network=当前网络出口被该引擎风控，稍后自动恢复；'
        '多数为 empty 时说明关键词确实无结果，可更换关键词。';
  }
}

/// 默认引擎集（按优先级排序）。[session] 持有 Cookie 会话与连接池。
List<SearchEngine> defaultEngines(EngineHttpSession session) => [
      BingCnEngine(session.forEngine('bing_cn')),
      BaiduEngine(session.forEngine('baidu', seed: true)),
      SogouEngine(session.forEngine('sogou', seed: true)),
      So360Engine(session.forEngine('so360')),
      QuarkEngine(session.forEngine('quark')),
      ChinasoEngine(session.forEngine('chinaso')),
    ];

/// 默认引擎权重（结果合并占比）：必应/百度/搜狗给 2 份，其余 1 份。
const Map<String, int> kDefaultEngineWeights = {
  'bing_cn': 2,
  'baidu': 2,
  'sogou': 2,
  'so360': 1,
  'quark': 1,
  'chinaso': 1,
};

/// 默认每窗口请求预算（安全管控"细水长流"）：
/// - 低风险引擎（bing_cn/so360/chinaso，容忍度高）预算宽松；
/// - 高风险引擎（sogou/baidu/quark，风控激进，短时连发即触发验证码）
///   默认每窗口 2 次——偶尔贡献高质量结果，又不至于被判定机器行为。
/// 预算耗尽 → 该引擎本轮跳过（status=budget），窗口到期自动恢复。
const Map<String, int> kDefaultEngineBudgets = {
  'bing_cn': 8,
  'so360': 6,
  'chinaso': 6,
  'sogou': 2,
  'baidu': 2,
  'quark': 2,
};

/// 预算窗口时长。
const Duration kEngineBudgetWindow = Duration(minutes: 10);

/// 时效类查询特征词：命中则对百科/文库类结果降权（这类查询返回
/// "XX市_百度百科"是必应 RSS 的顽疾，实测复现）。
final RegExp _timeSensitiveQuery =
    RegExp(r'今天|今日|昨日|刚刚|最新|最近|新闻|消息|动态|现在|实时|热点');

/// 降权域名：时效类查询下这些站几乎必然不是用户要的"新消息"。
const List<String> _demotedHosts = [
  'baike.baidu.com',
  'wenku.baidu.com',
  'baike.sogou.com',
  'zhidao.baidu.com',
];

/// 每引擎请求的结果池下限：比输出上限大，给去重/降权留余量。
const int kEnginePoolSize = 10;

class MultiEngineSearch {
  /// 引擎优先级 = 列表顺序。
  final List<SearchEngine> engines;

  final int maxResults;

  /// 跳转链还原（可注入替身）；null = 不还原。
  final LinkResolver? resolver;

  final String userAgent;
  final DateTime Function() _now;

  /// engineId → 合并权重（smooth weighted round-robin，默认全 1）。
  final Map<String, int> engineWeights;

  /// 引擎被判 blocked 时的回调（provider 层用它清 Cookie 会话，
  /// 对齐"搜狗/百度惩罚主要绑 Cookie"的调研结论）。
  final void Function(String engineId)? onEngineBlocked;

  /// engineId → 每 [budgetWindow] 窗口内的最大请求次数（安全管控）。
  /// 缺省某引擎 = 不限（仍受熔断约束）。
  final Map<String, int> engineBudgets;
  final Duration budgetWindow;

  final Map<String, _EngineState> _states = {};
  final Map<String, _BudgetState> _budgets = {};

  MultiEngineSearch({
    required this.engines,
    this.maxResults = 8,
    this.resolver,
    this.userAgent = kDefaultEngineUserAgent,
    this.engineWeights = kDefaultEngineWeights,
    this.engineBudgets = kDefaultEngineBudgets,
    this.budgetWindow = kEngineBudgetWindow,
    this.onEngineBlocked,
    DateTime Function()? now,
  }) : _now = now ?? DateTime.now;

  /// 跳过冷却中的引擎，并行请求其余引擎，合并去重。
  Future<MultiSearchOutcome> search(String query, {int? limit}) async {
    final cap = limit ?? maxResults;
    final status = <String, String>{};
    final futures = <String, Future<List<SearchHit>>>{};

    for (final engine in engines) {
      final st = _states.putIfAbsent(engine.id, _EngineState.new);
      final now = _now();
      if (now.isBefore(st.coolingUntil)) {
        final left = st.coolingUntil.difference(now).inSeconds;
        status[engine.id] = 'cooling(${left}s)';
        continue;
      }
      if (!_takeBudget(engine.id, now)) {
        status[engine.id] = 'budget';
        continue;
      }
      status[engine.id] = 'pending';
      futures[engine.id] = engine.search(query, limit: cap > kEnginePoolSize ? cap : kEnginePoolSize);
    }

    await Future.wait(futures.values.map((f) => f.then(
        (_) {}, onError: (_) {}))); // 全部落定（异常在下面逐个捕获）。

    final perEngine = <String, List<SearchHit>>{};
    for (final entry in futures.entries) {
      final engineId = entry.key;
      try {
        final hits = await entry.value;
        perEngine[engineId] = hits;
        status[engineId] = 'ok:${hits.length}';
        _markSuccess(engineId);
      } on SearchEngineException catch (e) {
        status[engineId] =
            e.kind == 'network' ? 'network:${e.message}' : '${e.kind}:${e.message}';
        _markFailure(engineId, e.kind);
      } catch (e) {
        status[engineId] = 'network:$e';
        _markFailure(engineId, 'network');
      }
    }

    final merged = _mergeRoundRobin(perEngine, cap);
    var hits = _demoteForTimeQuery(query, merged.hits);
    var truncated = merged.truncated;

    // 只对最终返回的结果做跳转链还原（省请求）。
    final resolver = this.resolver;
    if (resolver != null && hits.isNotEmpty) {
      hits = await _resolveLinks(hits);
    }

    return MultiSearchOutcome(
      hits: hits,
      truncated: truncated,
      engineStatus: status,
    );
  }

  /// 加权轮转合并（smooth weighted round-robin）+ 跨引擎同源去重：
  /// 每轮各引擎累积 [engineWeights] 份配额并连续产出，权重高的引擎在结果里
  /// 占比更高（如必应 2 : 360 1 → 必应每 3 席占 2）。
  ({List<SearchHit> hits, bool truncated}) _mergeRoundRobin(
    Map<String, List<SearchHit>> perEngine,
    int cap,
  ) {
    final queues = <String, List<SearchHit>>{
      for (final e in engines)
        if (perEngine[e.id] != null && perEngine[e.id]!.isNotEmpty) e.id: perEngine[e.id]!,
    };
    final total =
        queues.values.fold<int>(0, (sum, q) => sum + q.length);
    final cursors = <String, int>{for (final id in queues.keys) id: 0};
    final credits = <String, int>{for (final id in queues.keys) id: 0};
    int weightOf(String id) =>
        (engineWeights[id] != null && engineWeights[id]! >= 1)
            ? engineWeights[id]!
            : 1;

    final out = <SearchHit>[];
    final seen = <String>{};
    while (out.length < cap) {
      var progress = false;
      for (final engine in engines) {
        final q = queues[engine.id];
        if (q == null) continue;
        credits[engine.id] = credits[engine.id]! + weightOf(engine.id);
        while (credits[engine.id]! >= 1 &&
            cursors[engine.id]! < q.length &&
            out.length < cap) {
          credits[engine.id] = credits[engine.id]! - 1;
          final hit = q[cursors[engine.id]!];
          cursors[engine.id] = cursors[engine.id]! + 1;
          progress = true;
          if (seen.add(normalizeUrl(hit.url))) out.add(hit);
        }
        if (out.length >= cap) break;
      }
      if (!progress) break; // 所有引擎都耗尽
    }
    return (hits: out, truncated: total > out.length);
  }

  /// 时效类查询把百科/文库类结果稳定地排到尾部（若降权后有富余位，
  /// 它们仍可能保留在结果尾部）。
  List<SearchHit> _demoteForTimeQuery(String query, List<SearchHit> hits) {
    if (!_timeSensitiveQuery.hasMatch(query)) return hits;
    bool demoted(SearchHit h) {
      final host = Uri.tryParse(h.url)?.host.toLowerCase() ?? '';
      return _demotedHosts.any(host.endsWith);
    }

    final keep = hits.where((h) => !demoted(h)).toList();
    final tail = hits.where(demoted).toList();
    return [...keep, ...tail];
  }

  Future<List<SearchHit>> _resolveLinks(List<SearchHit> hits) async {
    final resolver = this.resolver!;
    final results = await Future.wait(hits.map((hit) async {
      if (!isRedirectLink(hit.url)) return hit;
      final real = await resolver.resolve(hit.url, userAgent: userAgent);
      return real == null ? hit : _copyWithUrl(hit, real);
    }));
    return results;
  }

  SearchHit _copyWithUrl(SearchHit hit, String url) => SearchHit(
        title: hit.title,
        url: url,
        snippet: hit.snippet,
        publishedAt: hit.publishedAt,
        engine: hit.engine,
      );

  void _markSuccess(String engineId) {
    final st = _states[engineId];
    if (st == null) return;
    st.blockedStreak = 0;
    st.coolingUntil = DateTime.fromMillisecondsSinceEpoch(0);
    st.lastStatus = 'ok';
  }

  void _markFailure(String engineId, String kind) {
    final st = _states.putIfAbsent(engineId, _EngineState.new);
    st.lastStatus = kind;
    switch (kind) {
      case 'blocked':
        st.blockedStreak++;
        onEngineBlocked?.call(engineId);
        final seconds = _cooldownBlockedBase.inSeconds * (1 << (st.blockedStreak - 1));
        final capped = seconds > _cooldownBlockedCap.inSeconds
            ? _cooldownBlockedCap.inSeconds
            : seconds;
        st.coolingUntil = _now().add(Duration(seconds: capped));
      case 'parse':
        st.coolingUntil = _now().add(_cooldownParse);
      case 'network':
        st.coolingUntil = _now().add(_cooldownNetwork);
      default: // empty 等查询相关现象：不冷却。
        break;
    }
  }

  /// 预算闸：窗口内请求次数 +1；耗尽返回 false（本轮跳过该引擎）。
  bool _takeBudget(String engineId, DateTime now) {
    final budget = engineBudgets[engineId];
    if (budget == null || budget <= 0) return true; // 未配置 = 不限
    final st = _budgets.putIfAbsent(engineId, _BudgetState.new);
    if (now.isAfter(st.windowStart.add(budgetWindow))) {
      st.used = 0;
      st.windowStart = now;
    }
    if (st.used >= budget) return false;
    st.used++;
    return true;
  }

  /// 引擎当前是否在冷却中（诊断用）。
  bool isCooling(String engineId) =>
      _now().isBefore(_states[engineId]?.coolingUntil ?? DateTime.fromMillisecondsSinceEpoch(0));

  void dispose() {
    for (final e in engines) {
      e.dispose();
    }
  }
}

/// 跨引擎同源去重：去 fragment/尾斜杠、小写 host、丢常见跟踪参数。
String normalizeUrl(String raw) {
  final uri = Uri.tryParse(raw.trim());
  if (uri == null || uri.host.isEmpty) return raw.trim();
  final params = uri.queryParameters.entries
      .where((e) =>
          !e.key.toLowerCase().startsWith('utm_') &&
          e.key.toLowerCase() != 'from' &&
          e.key.toLowerCase() != 'ie' &&
          e.key.toLowerCase() != 'tn')
      .toList()
    ..sort((a, b) => a.key.compareTo(b.key));
  var path = uri.path;
  if (path.length > 1 && path.endsWith('/')) {
    path = path.substring(0, path.length - 1);
  }
  final query = params.map((e) => '${e.key}=${e.value}').join('&');
  return Uri(
    scheme: uri.scheme.toLowerCase(),
    host: uri.host.toLowerCase(),
    port: uri.hasPort ? uri.port : null,
    path: path.isEmpty ? '/' : path,
    query: query.isEmpty ? null : query,
  ).toString();
}
