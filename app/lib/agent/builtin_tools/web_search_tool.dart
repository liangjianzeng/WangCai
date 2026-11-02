/// 联网搜索工具（默认注册；设置关闭时由接入层移除）。
///
/// 对齐 DSH：工具只调 [WebSearchSeam] 接缝、不写死搜索源。具体搜索实现
///（默认 SearXNG）由接入层通过 [WebSearchSeam.registerProvider] 注入，替换
/// 搜索源无需改本工具。
///
/// 返回相关网页标题 + 摘要 + 来源链接，供模型回答时引用。
///
/// **并发多关键词**（2026-09-29 用户要求）：一次调用可提交最多 4 个关键词
///（query + additional_queries），工具并行搜索、合并结果一次返回——把
/// "一个问题搜几次"压缩成"一次搜多个角度"，减少智能体回合的交互次数。
///
/// **回合级搜索预算**（2026-09-29，对齐 DSH 服务端工具 `web_search_20250305`
/// 的 `max_uses` 语义）：每回合最多调用 [maxSearchesPerTurn] 次。达到上限后
/// 工具**拒绝联网**并返回收敛指令，让模型基于既有结果直接回答——杜绝
/// "反复搜索同一内容 / 用完循环次数没输出"的搜索死循环。同一回合内主查询
/// 归一化后与已搜过的关键词相同 → 直接回缓存结果（不重复联网）。
library;

import '../tool_definition.dart';
import '../web_search/web_search_seam.dart';

/// 回填给模型的文本预算（端侧上下文很贵：n_ctx 常见 8k，工具结果越大、
/// 手机 prefill 越慢）。摘要按条截断、总量按此上限截断。
const int kSnippetMaxChars = 200;
const int kResultMaxChars = 1500;

/// 一次调用最多搜索的关键词数（query + additional_queries）。
const int kMaxQueriesPerCall = 4;

/// 每回合 web_search 最多调用次数（对齐 DSH `max_uses` 默认 5；可经设置调整）。
/// 每次调用消耗 1 次预算（含重复关键词），达到上限即拒绝联网、强制收敛。
const int kMaxSearchesPerTurn = 5;

/// 查询里已含年份数字（20xx）时不再补——避免"2025 发布会 2026"这类冗余。
final RegExp _yearInQuery = RegExp(r'20\d{2}');

/// 归一化查询：小写 + 只留中英文/数字，用于同回合重复搜索判定
///（"华为大会 " / "华为 大会" / "华为大会。" 视为同一关键词）。
String _normalizeQuery(String q) {
  final lower = q.toLowerCase();
  final buf = StringBuffer();
  for (var i = 0; i < lower.length; i++) {
    final c = lower.codeUnitAt(i);
    // 0-9 / a-z / CJK 及更高（含全角标点一并保留，中文句读不影响判定）。
    if ((c >= 0x30 && c <= 0x39) ||
        (c >= 0x61 && c <= 0x7a) ||
        c >= 0x80) {
      buf.writeCharCode(c);
    }
  }
  return buf.toString();
}

/// 每回合搜索会话（DSH `max_uses` 语义）。
class _WebSearchTurnSession {
  final int maxSearches;

  /// 本轮已调用次数（每次调用消耗 1，含重复；对齐服务端 max_uses 计数）。
  int used = 0;

  /// 归一化主查询 → 首次搜索结果（重复调用直接回缓存，不重复联网）。
  final Map<String, ToolResult> cache = {};

  _WebSearchTurnSession(this.maxSearches);
}

ToolDefinition createWebSearchTool({int maxSearchesPerTurn = kMaxSearchesPerTurn}) {
  // 每次 createWebSearchTool 都新建回合会话：接入层每回合重建注册表
  // （createBuiltinTools 全量新建），状态天然随回合重置。
  final session = _WebSearchTurnSession(maxSearchesPerTurn);
  return ToolDefinition(
    name: 'web_search',
    description:
        '联网搜索，返回相关网页的标题与摘要（含来源链接）。'
        '结果头部会标注当前时间，按它判断信息新旧；查新闻/时效性内容时'
        '关键词带上时间词（今天/昨天/最近）。'
        '一个问题的多个角度可一次提交：把想查的其他关键词放进'
        'additional_queries（最多 3 个），工具会并发搜索并合并结果一次返回，'
        '不必多次调用。'
        '每回合最多搜索 $maxSearchesPerTurn 次（含重复），已有足够结果时'
        '直接回答，不要重复搜索同一关键词；无结果时可尝试更换关键词；'
        '若返回诊断说明引擎不可用，不要反复重试，直接向用户说明即可。',
    parameters: {
      'type': 'object',
      'properties': {
        'query': {'type': 'string', 'description': '主要搜索关键词'},
        'additional_queries': {
          'type': 'array',
          'items': {'type': 'string'},
          'description': '可选：同一问题想覆盖的其他角度/关键词，最多 3 个；'
              '并发搜索后合并返回',
        },
      },
      'required': ['query'],
    },
    // 网络搜索比本地工具慢一个量级（实测某实例 2~21s），需要比全局默认
    // 15s 更宽的预算；[ToolDefinition.timeout] 会被 ToolExecutor 采用。
    // 并发搜索时总耗时 ≈ 最慢单次（并行），30s 预算依旧够。
    timeout: const Duration(seconds: 30),
    execute: (args) async {
      final raw = (args['query'] as String?)?.trim() ?? '';
      final extras = (args['additional_queries'] as List?)
          ?.whereType<String>()
          .map((e) => e.trim())
          .where((e) => e.isNotEmpty)
          .take(kMaxQueriesPerCall - 1)
          .toList() ??
          const <String>[];
      if (raw.isEmpty && extras.isEmpty) {
        return ToolResult.error('缺少 query 参数');
      }

      // ---- 预算闸（DSH max_uses）：每次调用消耗 1，含重复。达到上限拒绝
      // 联网，返回收敛指令让模型基于既有结果直接回答，杜绝搜索死循环。----
      if (session.used >= session.maxSearches) {
        return ToolResult.error(
            '本轮搜索次数已达上限（$maxSearchesPerTurn 次）。'
            '请直接基于以上已有的搜索结果回答，不要再调用 web_search。');
      }

      // ---- 去重：主查询归一化后与已搜过的相同 → 回缓存结果（不联网），
      // 但仍消耗预算——重复搜索本身就是浪费，尽快逼模型收敛。----
      final norm = raw.isNotEmpty ? _normalizeQuery(raw) : '';
      final cached = session.cache[norm];
      if (cached != null) {
        session.used++;
        return ToolResult(
            content: '（此关键词本轮已搜索过，结果同上，未重复联网。'
            '请直接基于已有结果回答，不要重复搜索。）\n${cached.content}');
      }

      session.used++;
      // 时间注入：模型经常不知道今天几号，查"最新/今天"类内容会拿到旧闻。
      // 查询缺年份时补当前年份；结果头部再带完整当前时间兜底。
      final now = DateTime.now();
      final queries = <String>[];
      if (raw.isNotEmpty) queries.add(raw);
      queries.addAll(extras);
      final prepared = queries
          .map((q) => _yearInQuery.hasMatch(q) ? q : '$q ${now.year}')
          .toList();
      try {
        // 并行搜索：总耗时 ≈ 最慢单次，而非串行求和。不传 timeout：用
        // provider（设置项）里配置的超时。传了会覆盖设置值。
        final results = await Future.wait(
          prepared.map((q) => WebSearchSeam.instance.search(q)),
        );
        final result = prepared.length == 1
            ? _formatResult(results.first, now)
            : _formatMultiResult(prepared, results, now);
        // 主查询结果入缓存（含时间标签；同回合重复调用直接回读）。
        if (norm.isNotEmpty && !result.isError) {
          session.cache[norm] = result;
        }
        return result;
      } on WebSearchProviderError catch (e) {
        return ToolResult.error('联网搜索失败（${e.kind}）：${e.message}');
      }
    },
  );
}

/// 把标准化结果渲染为模型可读文本（标题 / 摘要 / 来源链接），并做长度预算：
/// 单条摘要截到 [kSnippetMaxChars]，整体截到 [kResultMaxChars]。
ToolResult _formatResult(WebSearchResult result, DateTime now) {
  final two = (int v) => v.toString().padLeft(2, '0');
  final timeTag = '当前时间：'
      '${now.year}-${two(now.month)}-${two(now.day)} '
      '${two(now.hour)}:${two(now.minute)}'
      '（周${'一二三四五六日'[now.weekday - 1]}）';
  if (result.sources.isEmpty) {
    // 0 结果 ≠ "没这信息"：先分清是实例挂了还是真无结果，别让模型拿
    // "查询不到"当答案糊弄用户。
    final diag = result.diagnostics;
    if (diag != null) {
      return ToolResult.error('$timeTag\n搜索服务异常：$diag');
    }
    return ToolResult.error('$timeTag\n未找到相关结果，可尝试更换关键词。');
  }
  final buffer = StringBuffer();
  buffer.writeln(timeTag);
  buffer.writeln();
  for (final s in result.sources.take(8)) {
    _appendSource(buffer, s);
    // 够了就停：手机端上下文和 prefill 都很贵，别把 8 条长摘要全塞进去。
    if (buffer.length >= kResultMaxChars) break;
  }
  var text = buffer.toString().trim();
  if (text.length > kResultMaxChars) {
    text = '${_clip(text, kResultMaxChars)}\n（结果已截断）';
  }
  if (result.truncated) {
    text = '$text\n[另有更多结果未展示，可换更具体的关键词]';
  }
  return ToolResult(content: text);
}

/// 多关键词并发结果的合并渲染：每个关键词一个小节（标注关键词），
/// 各小节均分 [kResultMaxChars] 预算，避免前面的查询吃光全部空间。
ToolResult _formatMultiResult(
  List<String> queries,
  List<WebSearchResult> results,
  DateTime now,
) {
  final two = (int v) => v.toString().padLeft(2, '0');
  final timeTag = '当前时间：'
      '${now.year}-${two(now.month)}-${two(now.day)} '
      '${two(now.hour)}:${two(now.minute)}'
      '（周${'一二三四五六日'[now.weekday - 1]}）';
  final perQueryCap = kResultMaxChars ~/ queries.length;
  final buffer = StringBuffer();
  buffer.writeln(timeTag);
  for (var i = 0; i < queries.length; i++) {
    final result = results[i];
    final section = StringBuffer();
    section.writeln('\n[搜索：${queries[i]}]');
    if (result.sources.isEmpty) {
      final diag = result.diagnostics;
      if (diag != null) {
        section.writeln('（无结果：$diag）');
      } else {
        section.writeln('（无结果，可换关键词）');
      }
    } else {
      for (final s in result.sources.take(8)) {
        _appendSource(section, s);
        if (section.length >= perQueryCap) break;
      }
    }
    buffer.write(_clip(section.toString().trim(), perQueryCap));
    buffer.write('\n');
    if (buffer.length >= kResultMaxChars) break;
  }
  var text = buffer.toString().trim();
  if (text.length > kResultMaxChars) {
    text = '${_clip(text, kResultMaxChars)}\n（结果已截断）';
  }
  return ToolResult(content: text);
}

/// 追加一条结果的标题 / 摘要 / 时间 / 来源（共享格式）。
void _appendSource(StringBuffer buffer, WebSearchSource s) {
  final title = s.title?.trim();
  final snippet = s.snippet?.trim();
  final engineTag = _engineLabel(s.engine);
  if (title != null && title.isNotEmpty) {
    buffer.writeln('标题：$title${engineTag.isEmpty ? '' : '〔$engineTag〕'}');
  }
  if (snippet != null && snippet.isNotEmpty) {
    buffer.writeln('摘要：${_clip(snippet, kSnippetMaxChars)}');
  }
  if (s.publishedAt != null && s.publishedAt!.isNotEmpty) {
    buffer.writeln('时间：${s.publishedAt}');
  }
  if (s.url.isNotEmpty) buffer.writeln('来源：${s.url}');
  buffer.writeln();
}

/// 引擎 id → 短署名（结果标注来源引擎，便于定位"谁给的烂结果"）。
String _engineLabel(String? engine) {
  switch (engine) {
    case 'bing_cn':
      return '必应';
    case 'baidu':
      return '百度';
    case 'sogou':
      return '搜狗';
    case 'so360':
      return '360';
    case 'quark':
      return '夸克';
    case 'chinaso':
      return '国搜';
    default:
      return engine ?? '';
  }
}

String _clip(String s, int maxChars) =>
    s.length <= maxChars ? s : '${s.substring(0, maxChars)}…';
