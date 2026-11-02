// 手动压缩（存储级确定性裁剪）纯函数核心单测。
//
// planStorageCompaction：旧信封选取（尾部 keepRounds 用户轮保留）、摘要
// 生成（工具名/摘录/上限）、原位改写 + 删除清单；摘要信封经
// importFromMessages 还原后投影为 user 摘要（模型可见、UI 不渲染）。
import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:tongyi_lite/agent/session/event.dart' show kEventToolResult;
import 'package:tongyi_lite/agent/session/store.dart';
import 'package:tongyi_lite/models/chat_message.dart';

ChatMessage _user(String id, String content, {int ms = 0}) => ChatMessage(
      id: id,
      conversationId: 'c1',
      role: MessageRole.user,
      content: content,
      timestamp: DateTime.fromMillisecondsSinceEpoch(ms),
    );

ChatMessage _assistant(String id, String content, {int ms = 0}) => ChatMessage(
      id: id,
      conversationId: 'c1',
      role: MessageRole.assistant,
      content: content,
      timestamp: DateTime.fromMillisecondsSinceEpoch(ms),
    );

ChatMessage _trace(String id, List<Map<String, dynamic>> events,
        {int ms = 0}) =>
    ChatMessage(
      id: id,
      conversationId: 'c1',
      role: MessageRole.assistant,
      content: kAgentTraceMessagePrefix + jsonEncode({'v': 1, 'events': events}),
      timestamp: DateTime.fromMillisecondsSinceEpoch(ms),
    );

Map<String, dynamic> _toolResult(String callId, String name, String content) =>
    {
      'type': kEventToolResult,
      'data': {'callId': callId, 'name': name, 'content': content},
    };

void main() {
  group('planStorageCompaction 手动压缩计划', () {
    test('信封不足 2 条 → null（无可压缩）', () {
      final messages = [
        _user('u1', '你好', ms: 1),
        _assistant('a1', '你好！'),
      ];
      expect(planStorageCompaction(messages), isNull);
      // 单条信封也压不了（最后一条保留）。
      final one = [
        _user('u1', '你好', ms: 1),
        _trace('t1', [_toolResult('c1', 'web_search', '结果')], ms: 2),
        _assistant('a1', '回答'),
      ];
      expect(planStorageCompaction(one), isNull);
    });

    test('短对话（用户轮数少）也能压缩：只保留最后一条信封', () {
      // 真机实测教训：旧规则按「尾部保留 5 个用户轮」门槛，短对话里全部
      // 信封都被保护 → 永远返回 (0,0)。新规则只保留最后一条信封。
      final messages = [
        _user('u1', 'q1', ms: 1),
        _trace('t1', [_toolResult('c1', 'web_search', '旧结果')], ms: 2),
        _assistant('a1', 'r1', ms: 3),
        _user('u2', 'q2', ms: 4),
        _trace('t2', [_toolResult('c2', 'get_time', '12:00')], ms: 5),
        _assistant('a2', 'r2', ms: 6),
      ];
      final plan = planStorageCompaction(messages);
      expect(plan, isNotNull);
      expect(plan!.firstId, 't1');
      expect(plan.deleteIds, isEmpty);
      expect(plan.toolNames, contains('web_search'));
      expect(plan.summaryEnvelope, contains('（手动压缩）'));
      expect(plan.summaryEnvelope, contains('旧结果'));
    });

    test('多条信封：首条原位改写，其余进删除清单，最后一条保留；摘录截断生效', () {
      final long = 'x' * 500;
      final messages = [
        _user('u0', 'q0', ms: 1),
        _trace('t1', [_toolResult('c1', 'read_file', long)], ms: 2),
        _trace('t2', [_toolResult('c2', 'web_search', '短结果')], ms: 3),
        _trace('t3', [_toolResult('c3', 'get_time', '13:00')], ms: 4),
        for (var i = 1; i <= 5; i++) ...[
          _user('u$i', 'q$i', ms: 10 + i),
          _assistant('a$i', 'r$i', ms: 20 + i),
        ],
      ];
      final plan = planStorageCompaction(messages);
      expect(plan, isNotNull);
      expect(plan!.firstId, 't1');
      expect(plan.deleteIds, ['t2']);
      // 单条摘录 300 字 + 省略号。
      expect(plan.summaryEnvelope, contains('x' * 300));
      expect(plan.summaryEnvelope, isNot(contains('x' * 400)));
      expect(plan.summaryChars, lessThan(1000));
    });

    test('摘要信封 roundtrip：decode 还原 user/message → 投影为 user 摘要', () {
      final messages = [
        _user('u0', 'q0', ms: 1),
        _trace('t1', [_toolResult('c1', 'get_time', '12:00')], ms: 2),
        _trace('t9', [_toolResult('c9', 'web_search', '保留的最近信封')], ms: 3),
        for (var i = 1; i <= 5; i++) ...[
          _user('u$i', 'q$i', ms: 10 + i),
          _assistant('a$i', 'r$i', ms: 20 + i),
        ],
      ];
      final plan = planStorageCompaction(messages)!;
      // 模拟 manualCompact 落库后的下一轮导入：首条信封被替换，其余删除。
      final after = <ChatMessage>[
        for (final m in messages)
          if (m.id == plan.firstId)
            ChatMessage(
              id: m.id,
              conversationId: m.conversationId,
              role: m.role,
              content: plan.summaryEnvelope,
              timestamp: m.timestamp,
            )
          else if (!plan.deleteIds.contains(m.id))
            m,
      ];
      // 模拟 chat_provider 真实历史过滤：其余 🔧 活动消息排除，TRACE 信封放行。
      final history = after
          .where((m) =>
              m.content.isNotEmpty &&
              (!m.content.startsWith('🔧') ||
                  m.content.startsWith(kAgentTraceMessagePrefix)))
          .toList();
      final log = JsonlSessionStore().importFromMessages('c1', history);
      final projected = log.deriveModelMessages();
      // 摘要作为 user 消息可见（与回合内压缩投影语义一致）。
      final summaryMsgs = projected
          .where((m) =>
              m['role'] == 'user' &&
              (m['content'] as String).contains('（手动压缩）'))
          .toList();
      expect(summaryMsgs, hasLength(1));
      expect((summaryMsgs.first['content'] as String), contains('get_time'));
      // 被压缩信封的工具结果不可见；保留的最后一条信封仍投出 tool 消息。
      final toolMsgs =
          projected.where((m) => m['role'] == 'tool').toList();
      expect(toolMsgs, hasLength(1));
      expect(toolMsgs.first['content'], contains('保留的最近信封'));
      // 尾部 5 轮对话原样保留。
      expect(
        projected.any((m) =>
            m['role'] == 'user' && (m['content'] as String) == 'q5'),
        isTrue,
      );
      // UI 视图：🔧TRACE 信封不渲染为可见气泡（前缀过滤交给 UI 层），
      // 摘要信封同样以 🔧 开头。
      expect(plan.summaryEnvelope.startsWith(kAgentTraceMessagePrefix), isTrue);
    });

    test('损坏信封：decode 失败仍参与删除/改写，摘要不包含其内容', () {
      final messages = [
        _user('u0', 'q0', ms: 1),
        ChatMessage(
          id: 't1',
          conversationId: 'c1',
          role: MessageRole.assistant,
          content: '$kAgentTraceMessagePrefix{broken json',
          timestamp: DateTime.fromMillisecondsSinceEpoch(2),
        ),
        _trace('t9', [_toolResult('c9', 'web_search', '保留')], ms: 3),
        for (var i = 1; i <= 5; i++) ...[
          _user('u$i', 'q$i', ms: 10 + i),
          _assistant('a$i', 'r$i', ms: 20 + i),
        ],
      ];
      final plan = planStorageCompaction(messages);
      expect(plan, isNotNull);
      expect(plan!.firstId, 't1');
      expect(plan.toolNames, isEmpty);
      expect(plan.summaryEnvelope, contains('已调用过工具：无'));
    });
  });
}
