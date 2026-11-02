/// 两阶段压缩（Phase 2）—— 对照 DSH Part 10.8。
///
/// 端侧默认**仅阶段 1（确定性裁剪）**：无需模型调用、免费、确定性。
/// 阶段 2（模型摘要）为可选开关，端侧默认关闭（tokens/s 低）。
///
/// 阶段 1 语义（DSH 7.4.4 裁剪）：
///   - 保留尾部 [keepRounds] 轮完整（user/assistant/tool 不动）；
///   - 遮蔽更早区域的旧 tool/result（连同其间旧消息）为一条摘要 user 消息；
///   - [replaceGeneration]++ 作前进性证明 → 允许 overflow retry。
library;

import 'dart:async';

import 'package:flutter/foundation.dart' show debugPrint;

import '../session/event.dart';
import '../session/session.dart';
import '../loop/failure.dart';
import 'token_estimate.dart';

/// 两阶段压缩插件（替代 [NoCompactionPlugin] 的占位）。
///
/// 端侧：`useSummary=false`（默认）→ 只跑确定性裁剪；
/// P1-B：传入 [llmSummarizer] 时旧区摘要交给**便宜模型**生成（按步模型
/// 路由的压缩分支）——模型失败/超时/空回复一律回退确定性 digest，
/// 压缩永不因摘要模型而失败。
final class DeterministicCompaction implements CompactionPlugin {
  /// 尾部保留的 user 轮数（默认 5）。
  final int keepRounds;

  /// 是否启用模型摘要（端侧默认关）。
  final bool useSummary;

  /// LLM 摘要器：入参为摘要提示词（含旧区摘录），返回摘要文本；
  /// 失败返回 null。null = 不用模型（纯确定性裁剪）。
  final Future<String?> Function(String summaryPrompt)? llmSummarizer;

  /// 摘要提示词里的单条工具结果摘录上限（字符）。
  static const int _excerptLen = 400;

  /// 摘要提示词总长上限（字符），超限截尾。
  static const int _promptCap = 12000;

  DeterministicCompaction({
    this.keepRounds = 5,
    this.useSummary = false,
    this.llmSummarizer,
  });

  /// 判断当前会话是否超预算，并尝试压缩。
  /// [reason] 触发原因（`contextWindowExceeded` 时强制裁剪；其余情况也做主动裁剪）。
  Future<CompactionResult> decide({
    required SessionRef ref,
    required int turn,
    required int step,
    required String? reason,
  }) async {
    final log = ref.log;
    final events = log.rawEvents;

    // ---- 统计未遮蔽的 user 消息（surface）----
    final userSeqs = <int>[];
    for (final e in events) {
      if (e.type != kEventUserMessage) continue;
      if (log.isShadowed(e.seq)) continue;
      userSeqs.add(e.seq);
    }
    if (userSeqs.isEmpty) {
      return const CompactionResult(CompactionResultKind.failure);
    }

    // 保留尾部 keepRounds 轮；若 user 轮数 ≤ keepRounds，无旧内容可裁。
    // 返回 failure（而非 success）：DSH 不变量 11 —— 重试必须以
    // replaceGeneration 前进为前提。此处没有遮蔽任何事件，若返回 success
    // 会让失败瀑布无条件 retry 同一超限请求 → 无限循环（turn 永不结束）。
    if (userSeqs.length <= keepRounds) {
      return const CompactionResult(CompactionResultKind.failure);
    }

    // 阈值 = 近期窗口的第一条 user 消息；其之前的 tool/result 均为"旧"。
    final threshold = userSeqs[userSeqs.length - keepRounds];

    // ---- 收集旧 tool/result（seq < threshold）----
    final oldToolResultSeqs = <int>[];
    for (final e in events) {
      if (e.type != kEventToolResult) continue;
      if (log.isShadowed(e.seq)) continue;
      if (e.seq < threshold) {
        oldToolResultSeqs.add(e.seq);
      }
    }
    if (oldToolResultSeqs.isEmpty) {
      // 旧轮无工具结果 → 无 token 大户可裁，无前进 → failure（同上，防死循环）。
      return const CompactionResult(CompactionResultKind.failure);
    }
    final first = oldToolResultSeqs.first;
    final last = oldToolResultSeqs.last;

    // ---- 摘要：对 [first..last] 内未遮蔽的旧 user 消息 + 触达工具做 digest ----
    final digestParts = <String>[];
    final toolNames = <String>{};
    for (final e in events) {
      if (e.seq < first || e.seq > last) continue;
      if (e.type != kEventUserMessage) continue;
      if (log.isShadowed(e.seq)) continue;
      final content = e.data['content'] as String? ?? '';
      // 240 字：120 字经常把任务诉求截掉后半句，模型据此"失忆式续跑"。
      final short = content.length > 240 ? content.substring(0, 240) : content;
      digestParts.add('用户：$short');
    }
    // 附本轮触达过的工具名：模型知道"查过什么"，避免重复调用已做过的工具。
    for (final e in events) {
      if (e.seq < first || e.seq > last) continue;
      if (e.type != kEventToolResult) continue;
      if (log.isShadowed(e.seq)) continue;
      final name = e.data['name'];
      if (name is String && name.isNotEmpty) toolNames.add(name);
    }

    final summary = digestParts.isEmpty
        ? '[较早轮次的工具结果已省略，模型不可见原内容]'
        : '较早轮次摘要（旧工具结果已省略；此前已调用过工具：'
            '${toolNames.isEmpty ? "无" : toolNames.join("、")}）：\n'
            '${digestParts.join('\n')}';

    // ---- P1-B：LLM 摘要（便宜模型）——失败回退确定性 digest ----
    var finalSummary = summary;
    var summaryProvider = 'deterministic-prune';
    var summaryModel = 'none';
    final summarizer = llmSummarizer;
    if (summarizer != null && digestParts.isNotEmpty) {
      try {
        final prompt = _buildSummaryPrompt(
          digestParts: digestParts,
          toolNames: toolNames,
          events: events,
          first: first,
          last: last,
          log: log,
        );
        final modelSummary = await summarizer(prompt)
            .timeout(const Duration(seconds: 20));
        final t = modelSummary?.trim() ?? '';
        if (t.isNotEmpty) {
          finalSummary = '较早轮次摘要（由模型生成）：\n$t';
          summaryProvider = 'llm';
          summaryModel = 'compression';
        }
      } on Exception {
        // 摘要模型失败 → 确定性 digest 兜底（压缩本身不能失败）。
      } on TimeoutException {
        // 超时同上。
      }
    }

    // ---- 遮蔽 [first..last] 为一条摘要 ----
    // 压缩前基线：估算当前投影 token（与预算/呈现同一口径）。
    final beforeTokens =
        estimateContextTokens(log.deriveModelMessages());
    final advance = log.replace(
      startSeq: first,
      endSeq: last,
      newContent: finalSummary,
      summaryProvider: summaryProvider,
      summaryModel: summaryModel,
    );
    if (advance > 0) {
      final afterTokens = estimateContextTokens(log.deriveModelMessages());
      final stats = CompactionStats(
        maskedEvents: last - first + 1,
        beforeTokens: beforeTokens,
        afterTokens: afterTokens,
        provider: summaryProvider,
        summaryChars: finalSummary.length,
      );
      debugPrint('[Compaction] 裁剪（$summaryProvider）：mask [${first}..${last}]，'
          '${stats.beforeTokens}→${stats.afterTokens} tok'
          '（省 ${stats.savedTokens}），summary=${finalSummary.length}chars');
      return CompactionResult(CompactionResultKind.success, stats);
    }
    return const CompactionResult(CompactionResultKind.failure);
  }

  /// 构造 LLM 摘要提示词：任务诉求摘录 + 触达工具 + 旧工具结果摘录
  ///（头 [_excerptLen] 字符），总长截到 [_promptCap]。
  String _buildSummaryPrompt({
    required List<String> digestParts,
    required Set<String> toolNames,
    required List<SessionEvent> events,
    required int first,
    required int last,
    required SessionLog log,
  }) {
    final buf = StringBuffer();
    buf.writeln('以下是智能体较早轮次的执行记录。请生成一份紧凑摘要（≤300 字），'
        '保留：用户的任务目标、已完成的关键步骤与结论、重要数据/文件路径、'
        '未完成的部分。不要逐条罗列，不要评论。');
    buf.writeln();
    for (final p in digestParts) {
      buf.writeln(p);
    }
    if (toolNames.isNotEmpty) {
      buf.writeln('调用过的工具：${toolNames.join('、')}');
    }
    for (final e in events) {
      if (e.seq < first || e.seq > last) continue;
      if (e.type != kEventToolResult) continue;
      if (log.isShadowed(e.seq)) continue;
      final name = e.data['name'] as String? ?? 'tool';
      var content = e.data['content'] as String? ?? '';
      if (content.length > _excerptLen) {
        content = '${content.substring(0, _excerptLen)}…';
      }
      buf.writeln('[$name] $content');
      if (buf.length > _promptCap) {
        buf.writeln('（记录过长，已截断）');
        break;
      }
    }
    return buf.toString();
  }
}
