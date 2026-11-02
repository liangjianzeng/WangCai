import 'package:tongyi_lite/agent/session/session.dart';
import 'package:tongyi_lite/models/chat_message.dart';
import 'package:tongyi_lite/widgets/agent_workflow.dart'
    show parseToolActivity;
import 'package:flutter_test/flutter_test.dart';

// ---------------------------------------------------------------------------
// WP1a：工具轮轨迹信封（跨 turn 保住工具上下文）
//
// turn 结束后本轮 assistant(toolCalls)+tool/result 事件序列化为一条
// `🔧TRACE{json}` SQLite 消息；下一轮 importFromMessages 还原为真实事件。
// ---------------------------------------------------------------------------

/// 构造一个带工具轮的会话日志（turn1：调 get_weather → 结果 → 回答）。
SessionLog _toolTurnLog() {
  final log = SessionLog.fromEvents(const []);
  log.append(kEventTurnStart, {'turn': 1, 'userSeq': 0});
  log.append(kEventAssistantMessage, {
    'content': '',
    'toolCalls': [
      {'call_id': 'call_1', 'name': 'get_weather', 'arguments': {'city': '北京'}},
    ],
    'turn': 1,
    'step': 1,
  });
  log.append(kEventToolResult, {
    'callId': 'call_1',
    'name': 'get_weather',
    'turn': 1,
    'step': 1,
    'content': '北京今天晴，25C',
    'isError': false,
  });
  log.append(kEventAssistantMessage, {
    'content': '北京今天晴，25C',
    'toolCalls': <dynamic>[],
    'turn': 1,
    'step': 2,
  });
  return log;
}

ChatMessage _msg(String id, String content, {DateTime? time}) => ChatMessage(
      id: id,
      conversationId: 'c1',
      role: MessageRole.assistant,
      content: content,
      timestamp: time ?? DateTime.now(),
    );

void main() {
  test('编码：有工具轮 → 信封非空且含前缀；纯直答 turn → null', () {
    final encoded = encodeAgentTraceMessage(_toolTurnLog());
    expect(encoded, isNotNull);
    expect(encoded!.startsWith(kAgentTraceMessagePrefix), isTrue);
    expect(encoded.contains('call_1'), isTrue);
    expect(encoded.contains('get_weather'), isTrue);

    // 纯直答：assistant 无 toolCalls、无 tool/result → 不需要信封。
    final plain = SessionLog.fromEvents(const []);
    plain.append(kEventTurnStart, {'turn': 1, 'userSeq': 0});
    plain.append(kEventAssistantMessage, {
      'content': '你好',
      'toolCalls': <dynamic>[],
      'turn': 1,
      'step': 1,
    });
    expect(encodeAgentTraceMessage(plain), isNull);
  });

  test('roundtrip：落库信封 → importFromMessages 还原为可配对的事件', () {
    final encoded = encodeAgentTraceMessage(_toolTurnLog())!;

    // 模拟下一轮导入：user 提问在前、信封在中、最终回答在后。
    final log = JsonlSessionStore().importFromMessages('c1', [
      ChatMessage(
        id: 'u1',
        conversationId: 'c1',
        role: MessageRole.user,
        content: '北京天气？',
        timestamp: DateTime.now(),
      ),
      _msg('t1', encoded),
      _msg('a1', '北京今天晴，25C'),
    ]);

    final msgs = log.deriveModelMessages();
    // 形状：user → assistant(tool_calls) → tool → assistant(回答)。
    expect(msgs.length, 4);
    expect(msgs[0]['role'], 'user');
    expect(msgs[0]['content'], '北京天气？');
    expect(msgs[1]['role'], 'assistant');
    final calls = msgs[1]['tool_calls'] as List<dynamic>;
    expect((calls.first as Map)['id'], 'call_1');
    expect(msgs[2]['role'], 'tool');
    expect(msgs[2]['tool_call_id'], 'call_1');
    expect(msgs[2]['content'], '北京今天晴，25C');
    expect(msgs[3]['role'], 'assistant');
    expect(msgs[3]['content'], '北京今天晴，25C');
    // 信封 JSON 本体绝不能出现在模型可见历史里。
    for (final m in msgs) {
      expect((m['content'] as String).contains('TRACE'), isFalse);
    }
  });

  test('损坏信封：解析失败 → 内容不进模型历史（静默跳过）', () {
    final log = JsonlSessionStore().importFromMessages('c1', [
      _msg('bad1', '$kAgentTraceMessagePrefix{"v":1,"events":') // 撕裂 JSON
      ,
      _msg('bad2', '${kAgentTraceMessagePrefix}不是JSON'),
    ]);
    final msgs = log.deriveModelMessages();
    expect(msgs, isEmpty); // 没有任何 assistant/user 文本被投影
    // imported 标记记录了还原失败（可审计）。
    final imported = log.rawEvents.where((e) => e.type == kEventImported);
    expect(imported.length, 2);
  });

  test('超长工具结果：编码截断（体积兜底）', () {
    final log = SessionLog.fromEvents(const []);
    log.append(kEventTurnStart, {'turn': 1, 'userSeq': 0});
    log.append(kEventAssistantMessage, {
      'content': '',
      'toolCalls': [
        {'call_id': 'c2', 'name': 'read_file', 'arguments': {'path': 'a.txt'}},
      ],
      'turn': 1,
      'step': 1,
    });
    log.append(kEventToolResult, {
      'callId': 'c2',
      'name': 'read_file',
      'turn': 1,
      'step': 1,
      'content': 'x' * 50000,
      'isError': false,
    });
    final encoded = encodeAgentTraceMessage(log)!;
    expect(encoded.length, lessThan(20000));
    final decoded = decodeAgentTraceMessage(encoded)!;
    final toolEntry =
        decoded.firstWhere((e) => e['type'] == kEventToolResult);
    final data = toolEntry['data'] as Map<String, dynamic>;
    expect((data['content'] as String).contains('…[轨迹截断]'), isTrue);
  });

  test('UI 兼容：🔧TRACE 前缀 parseToolActivity 返回 null（历史回看静默跳过）',
      () {
    final encoded = encodeAgentTraceMessage(_toolTurnLog())!;
    // groupMessages 把 🔧 前缀 assistant 归为工具步骤；解析不出卡片 → 跳过，
    // 信封消息绝不渲染成回答或坏卡片。
    expect(parseToolActivity(_msg('t', encoded)), isNull);
  });
}
