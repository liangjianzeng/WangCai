// ============================================================
// 会话数据统计条（2026-10-25）：DSH StatsLine 逐行同构实现。
//
// 对照源：deepseek-harness ui-conversation/src/client/chat/StatsLine.tsx
// + locales.ts（zh 组串）+ StatsLine.module.css。此前的自由发挥
// （steps=工具数 / ≈估算 tok / 上下文% 入行 / 数字加重双色）全部作废。
//
// DSH 真实组态（有数据的组才上屏，整组掉线；全空 → 整条不渲染）：
//   {turns} 轮 · {steps} 步            （steps = assistant 消息数！）
//   LLM {dur} · 工具调用 {dur}          （durations，两项都有才成组）
//   首 token 平均 {dur} · {rate} tok/s  （speeds，同上）
//   输入 {n} tok · 输出 {n} tok         （真 usage；无 billing 不显示）
// 上下文占用不进这条——归输入框占用环（一事实一处，DSH 注释原文）。
//
// 本 app 数据源映射：
//   turns = user 消息数；steps = assistant 回答消息数；
//   LLM dur = Σ inferenceStats.totalMs；工具 dur = Σ toolData.durationMs；
//   首 token 平均 = Σ firstTokenMs / 计数步；tok/s = Σ输出tok / Σ解码ms；
//   输入 = API 真 prompt_tokens（contextUsage.usedTokens），本地回退字符估算；
//   输出 = Σ round(tokPerSec × totalMs/1000)，无统计回退估算。
// ============================================================

import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../agent/observability/turn_meter.dart' show estimateTokens;
import '../models/chat_message.dart';
import '../providers/context_usage_provider.dart' show contextUsageProvider;

/// 会话统计条。键盘弹出时由宿主整体收起；无可显示组时整条不渲染。
class ConversationStatsBar extends ConsumerWidget {
  final String conversationId;
  final List<ChatMessage> messages;

  const ConversationStatsBar({
    super.key,
    required this.conversationId,
    required this.messages,
  });

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final theme = Theme.of(context);

    // ---- 折算（DSH deriveStats 同构）----
    var turns = 0;
    var steps = 0;
    var llmMs = 0;
    var toolMs = 0;
    var ttftMs = 0;
    var ttftSteps = 0;
    var decodeMs = 0;
    var decodeTokens = 0;
    var inputTokens = 0;
    var outputTokens = 0;
    for (final m in messages) {
      if (m.role == MessageRole.user) {
        turns++;
        inputTokens += estimateTokens(m.content);
        continue;
      }
      if (m.kind == MessageKind.toolActivity ||
          (m.kind == MessageKind.text && m.content.startsWith('🔧'))) {
        // 工具结果节点：进工具耗时，不进步数（DSH tool-result 分支）。
        final d = m.toolData?.durationMs;
        if (d != null && d > 0) toolMs += d;
        inputTokens += estimateTokens(m.content);
        continue;
      }
      if (m.kind == MessageKind.thinking ||
          (m.kind == MessageKind.text && m.content.startsWith('💭')) ||
          m.kind == MessageKind.notice ||
          m.kind == MessageKind.error) {
        continue; // 过程痕迹不进统计。
      }
      if (m.role == MessageRole.assistant) {
        // assistant 节点 = 一步（DSH：steps 数 assistant 消息，非工具数）。
        steps++;
        final s = m.inferenceStats;
        if (s != null && s.totalMs > 0) {
          llmMs += s.totalMs;
          if (s.firstTokenMs > 0) {
            ttftMs += s.firstTokenMs;
            ttftSteps++;
          }
          final out = (s.tokPerSec * s.totalMs / 1000).round();
          decodeTokens += out;
          decodeMs += s.totalMs;
          outputTokens += out;
        } else {
          // 无 stats 的回答按已生成文本估算输出。两类来源：
          // ① 流式中（回合结束才写入 stats）——不估算则「输出」整回合
          //    纹丝不动、结束才跳变；② API 路线（尤其智能体）回答从不
          //    带原生 stats——不估算则「输出」恒 0（2026-10-25 真机反馈）。
          outputTokens += estimateTokens(m.content);
        }
        inputTokens += estimateTokens(m.content) ~/ 4; // 上下文携带的粗略回填
      }
    }

    // ---- 组装（DSH StatsLine 主体逐行同构）----
    final groups = <List<String>>[];
    if (steps > 0) {
      groups.add(['$turns 轮 · $steps 步']);
      final durations = <String>[
        if (llmMs > 0) 'LLM ${_formatDuration(llmMs)}',
        if (toolMs > 0) '工具调用 ${_formatDuration(toolMs)}',
      ];
      if (durations.isNotEmpty) groups.add(durations);
      final speeds = <String>[
        if (ttftSteps > 0) '首 token 平均 ${_formatDuration(ttftMs ~/ ttftSteps)}',
        if (decodeMs > 0)
          '${_scaled(decodeTokens / (decodeMs / 1000))} tok/s',
      ];
      if (speeds.isNotEmpty) groups.add(speeds);
    }
    // 有 token 活动（出过字/有输入）才显示；全失败会话不出零值组（DSH 同门槛）。
    // 输入优先取 API 真 prompt_tokens，无则用字符估算累计。
    final usage = ref.watch(contextUsageProvider)[conversationId];
    final apiInput = usage?.usedTokens;
    final input = apiInput ?? inputTokens;
    if (steps > 0 && (input > 0 || outputTokens > 0)) {
      groups.add([
        '输入 ${_formatTokens(input)} tok · 输出 ${_formatTokens(outputTokens)} tok',
      ]);
    }

    if (groups.isEmpty) return const SizedBox.shrink();

    // DSH StatsLine 三级灰、居中、组间「|」、超长省略号。字号 10 + 行高
    // 1.3 + 底部避让降到 max(nav, 8)（2026-10-25 用户二连定案：读数是
    // 次级信息，尽量矮——消息输入框得以贴近屏幕底）。
    final style = TextStyle(
        fontSize: 10,
        height: 1.3,
        color: theme.colorScheme.onSurfaceVariant.withValues(alpha: 0.75));
    final sepStyle = TextStyle(
        fontSize: 10,
        height: 1.3,
        color: theme.colorScheme.outlineVariant);

    return Padding(
      // 手势条避让收口：只保系统 inset（含 8px 保底），不再额外垫 16px。
      padding: EdgeInsets.fromLTRB(
          16, 2, 16, math.max(MediaQuery.of(context).padding.bottom, 8)),
      child: Row(
        children: [
          Expanded(
            child: Text.rich(
              TextSpan(
                children: [
                  for (var i = 0; i < groups.length; i++) ...[
                    if (i > 0)
                      TextSpan(
                          text: '  |  ',
                          style: sepStyle.copyWith(
                              letterSpacing: 0)), // DSH sep margin 10px
                    for (var j = 0; j < groups[i].length; j++) ...[
                      if (j > 0) const TextSpan(text: ' · '),
                      TextSpan(text: groups[i][j], style: style),
                    ],
                  ],
                ],
              ),
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              textAlign: TextAlign.center,
            ),
          ),
        ],
      ),
    );
  }

  /// DSH 口径：1 分钟内 45.2s，之后 2m42s。
  static String _formatDuration(int ms) {
    final s = ms / 1000;
    if (s < 60) return '${(s * 10).round() / 10}s';
    final whole = s.round();
    return '${whole ~/ 60}m${whole % 60}s';
  }

  /// DSH 口径：517 / 12.2K / 517K / 1.2M（三位以下一位小数）。
  static String _scaled(double v) {
    if (v >= 100) return v.round().toString();
    final r = (v * 10).round() / 10;
    return r == r.roundToDouble() ? r.round().toString() : r.toStringAsFixed(1);
  }

  static String _formatTokens(int n) {
    if (n < 1000) return '$n';
    if (n < 1000000) return '${_scaled(n / 1000)}K';
    return '${_scaled(n / 1000000)}M';
  }
}
