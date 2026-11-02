import 'package:tongyi_lite/agent/llm/adapter.dart' show LlmAdapter, LlmFailure, LlmFailureCode, LlmResult, ProviderKind;
import 'package:tongyi_lite/agent/loop/agent.dart';
import 'package:tongyi_lite/agent/loop/config.dart';
import 'package:tongyi_lite/agent/loop/failure.dart';
import 'package:tongyi_lite/agent/session/session.dart';
import 'package:tongyi_lite/agent/tool_definition.dart';
import 'package:tongyi_lite/agent/tool_registry.dart';
import '../helpers/fake_llm.dart';
import 'package:flutter_test/flutter_test.dart';

// ---------------------------------------------------------------------------
// WP1b：重试失败反思注入（assistant/failure-note）
//
// 重试不再原样重发：失败瀑布的 llm-retry 分支追加模型可见的失败原因注记，
// 下次请求投影出 [上次尝试失败: ...] 提示；同一 (turn,step) 只留最新一条。
// ---------------------------------------------------------------------------

// LLM 桩用共享的 FakeLlmAdapter（test/helpers/fake_llm.dart）。

ReactLoopAgent _agent(LlmAdapter adapter) {
  final registry = ToolRegistry();
  registry.register(ToolDefinition(
    name: 'get_time',
    description: '获取当前时间',
    parameters: const {'type': 'object'},
    execute: (_) async => const ToolResult(content: '2026-09-29 12:00'),
  ));
  return ReactLoopAgent(
    session: SessionLog.fromEvents(const []),
    adapter: adapter,
    registry: registry,
    modelId: 'test-model',
    providerKind: ProviderKind.local,
    systemPrompt: '你是 TongYi-Lite 智能体',
    config: const AgentConfig(maxStepsPerTurn: 4),
    compaction: const NoCompactionPlugin(),
  );
}

int _countNoteUserMsgs(List<Map<String, dynamic>> msgs) => msgs
    .where((m) =>
        m['role'] == 'user' &&
        (m['content'] as String).contains('[上次尝试失败:'))
    .length;

void main() {
  test('失败→重试成功：failure-note 落日志，重试请求投影出失败原因提示', () async {
    final fake = FakeLlmAdapter([
      LlmFailure(code: LlmFailureCode.timeout, message: '引擎打盹了'),
      LlmResult(text: 'ok', toolCalls: const []),
    ]);
    final agent = _agent(fake);

    final reason = await agent.kick('hi');

    expect(reason.kind, TurnEndReasonKind.completed);
    expect(fake.calls, 2);
    // 注记落日志（surface，非 log-only）。
    final note = agent.session.rawEvents
        .where((e) => e.type == kEventAssistantFailureNote)
        .toList();
    expect(note.length, 1);
    expect(note.first.data['content'], '引擎打盹了');
    // 重试那次请求（第二次）的 messages 里带失败提示。
    final retryMsgs = fake.allMessages[1];
    final notes =
        retryMsgs.where((m) => '${m['content']}'.contains('[上次尝试失败:'));
    expect(notes, isNotEmpty);
    expect('${notes.first['content']}', contains('timeout'));
    expect('${notes.first['content']}', contains('引擎打盹了'));
  });

  test('同一 step 连续失败：投影只保留最新一条失败注记', () async {
    final fake = FakeLlmAdapter([
      LlmFailure(code: LlmFailureCode.timeout, message: '旧失败原因 t1'),
      LlmFailure(code: LlmFailureCode.timeout, message: '新失败原因 t2'),
      LlmResult(text: 'ok', toolCalls: const []),
    ]);
    final agent = _agent(fake);

    final reason = await agent.kick('hi');

    expect(reason.kind, TurnEndReasonKind.completed);
    // 落日志两条（append-only 审计），但投影只有最新一条。
    expect(
      agent.session.rawEvents
          .where((e) => e.type == kEventAssistantFailureNote)
          .length,
      2,
    );
    final msgs = agent.session.deriveModelMessages();
    expect(_countNoteUserMsgs(msgs), 1);
    final noteMsg = msgs
        .firstWhere((m) => '${m['content']}'.contains('[上次尝试失败:'));
    expect('${noteMsg['content']}', contains('t2'));
    expect('${noteMsg['content']}', isNot(contains('t1')));
  });

  test('投影确定性：deriveModelMessages 重复调用结果一致（G12 纯投影）', () async {
    final fake = FakeLlmAdapter([
      LlmFailure(code: LlmFailureCode.timeout, message: 'x'),
      LlmResult(text: 'ok', toolCalls: const []),
    ]);
    final agent = _agent(fake);
    await agent.kick('hi');

    final a = agent.session.deriveModelMessages();
    final b = agent.session.deriveModelMessages();
    expect(a.length, b.length);
    for (var i = 0; i < a.length; i++) {
      expect(a[i]['role'], b[i]['role']);
      expect(a[i]['content'], b[i]['content']);
    }
  });

  test('超长失败信息：注记内容截断到 200 字', () async {
    final fake = FakeLlmAdapter([
      LlmFailure(code: LlmFailureCode.timeout, message: '长' * 500),
      LlmResult(text: 'ok', toolCalls: const []),
    ]);
    final agent = _agent(fake);
    await agent.kick('hi');

    final note = agent.session.rawEvents
        .firstWhere((e) => e.type == kEventAssistantFailureNote);
    expect((note.data['content'] as String).length, lessThan(210));
  });
}
