// ConversationStatsBar 组态回归（2026-10-25）：钉死 DSH StatsLine 语义。
// 对照源 StatsLine.tsx：steps=assistant 消息数、组掉线、无估算噪音组、
// 上下文不进这条（归占用环）。

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:tongyi_lite/models/chat_message.dart';
import 'package:tongyi_lite/providers/context_usage_provider.dart';
import 'package:tongyi_lite/widgets/conversation_stats_bar.dart';

ChatMessage _user(String c) => ChatMessage(
      id: 'u${c.hashCode}',
      conversationId: 'c1',
      role: MessageRole.user,
      content: c,
      timestamp: DateTime(2026, 10, 25, 12),
    );

ChatMessage _answer(String c, {InferenceStats? stats}) => ChatMessage(
      id: 'a${c.hashCode}',
      conversationId: 'c1',
      role: MessageRole.assistant,
      content: c,
      timestamp: DateTime(2026, 10, 25, 12, 1),
      inferenceStats: stats,
    );

ChatMessage _tool(String name, {int? ms}) => ChatMessage(
      id: 't$name$ms',
      conversationId: 'c1',
      role: MessageRole.assistant,
      content: '🔧 $name ✓',
      timestamp: DateTime(2026, 10, 25, 12, 0, 30),
      kind: MessageKind.toolActivity,
      toolData: ToolActivityData(
        name: name,
        phase: 'done',
        durationMs: ms,
      ),
    );

Widget _host(List<ChatMessage> messages,
        {Map<String, ContextUsage>? usage}) =>
    ProviderScope(
      overrides: [
        if (usage != null)
          contextUsageProvider.overrideWith((ref) {
            final n = ContextUsageNotifier();
            n.state = usage;
            return n;
          }),
      ],
      child: MaterialApp(
        home: Scaffold(
          body: Column(children: [
            Expanded(child: SizedBox()),
            ConversationStatsBar(conversationId: 'c1', messages: messages),
          ]),
        ),
      ),
    );

void main() {
  testWidgets('纯问答：turns/steps 计 assistant 消息，组态 = 轮步|速度|token',
      (tester) async {
    await tester.pumpWidget(_host([
      _user('hi'),
      _answer('你好！', stats: const InferenceStats(
          firstTokenMs: 300, totalMs: 2000, tokPerSec: 10)),
    ]));
    final rendered = _spanText(tester);
    expect(rendered, contains('1 轮 · 1 步'));
    expect(rendered, contains('LLM 2.0s'));
    expect(rendered, contains('首 token 平均 0.3s'));
    expect(rendered, contains('tok/s'));
    expect(rendered, contains('输入'));
    expect(rendered, contains('输出'));
  });

  testWidgets('无工具步不出现「0 步」；工具耗时进「工具调用」组', (tester) async {
    await tester.pumpWidget(_host([
      _user('q'),
      _tool('web_search', ms: 1500),
      _tool('read_file', ms: 500),
      _answer('done', stats: const InferenceStats(
          firstTokenMs: 0, totalMs: 1000, tokPerSec: 5)),
    ]));
    final rendered = _spanText(tester);
    // DSH 语义：steps 只数 assistant 节点，工具结果只进「工具调用」耗时组。
    expect(rendered, contains('1 轮 · 1 步'));
    expect(rendered, isNot(contains('0 步')));
    expect(rendered, contains('工具调用 2.0s'));
  });

  testWidgets('上下文% 不进统计条（归占用环，一事实一处）', (tester) async {
    await tester.pumpWidget(_host([
      _user('hi'),
      _answer('yo'),
    ], usage: {
      'c1': const ContextUsage(usedTokens: 1200, windowTokens: 4096),
    }));
    final rendered = _spanText(tester);
    expect(rendered, isNot(contains('上下文')));
  });

  testWidgets('空会话整条不渲染', (tester) async {
    await tester.pumpWidget(_host(const []));
    expect(_spanText(tester), isEmpty);
  });
}

/// 拼接 StatsBar 内全部 TextSpan 文本。
String _spanText(WidgetTester tester) {
  final rich = tester.widgetList<Text>(find.byType(Text));
  final buf = StringBuffer();
  for (final t in rich) {
    final span = t.textSpan;
    if (span != null) {
      span.visitChildren((v) {
        if (v is TextSpan) buf.write(v.text);
        return true;
      });
    }
    buf.write(t.data ?? '');
  }
  return buf.toString();
}
