import 'dart:math' as math;

import 'package:tongyi_lite/agent/loop/agent.dart';
import 'package:tongyi_lite/agent/loop/config.dart';
import 'package:tongyi_lite/agent/loop/failure.dart';
import 'package:tongyi_lite/agent/llm/adapter.dart';
import 'package:tongyi_lite/agent/context_eng/compaction.dart';
import 'package:tongyi_lite/agent/tool_definition.dart';
import 'package:tongyi_lite/agent/tool_registry.dart';
import 'package:tongyi_lite/agent/tools/guard.dart';
import '../helpers/fake_llm.dart';
import 'package:tongyi_lite/agent/tools/pipeline.dart';
import 'package:tongyi_lite/agent/session/session.dart';
import 'package:flutter_test/flutter_test.dart';

// ---------------------------------------------------------------------------
// 工具桩
// ---------------------------------------------------------------------------

/// 固定结果的通用假工具。
ToolDefinition _tool(String name, String result) {
  return ToolDefinition(
    name: name,
    description: '假工具 $name',
    parameters: {'type': 'object', 'properties': {}, 'required': []},
    execute: (args) => Future.value(ToolResult(content: result)),
  );
}

/// 记录并发数的工具（并行测试）。
ToolDefinition _concurrentTool() {
  final state = <int>[0, 0]; // [inFlight, max]
  return ToolDefinition(
    name: 'concurrent',
    description: '并发工具',
    parameters: {'type': 'object', 'properties': {}, 'required': []},
    execute: (args) async {
      state[0]++;
      state[1] = math.max(state[1], state[0]);
      await Future.delayed(Duration(milliseconds: 20));
      state[0]--;
      return ToolResult(content: 'ok');
    },
  );
}

// ---------------------------------------------------------------------------
// 工具：guard 拦截（危险命令 deny）
// ---------------------------------------------------------------------------

void main() {
  test('guard 拦截危险命令：model_cache 删除被 deny，不执行', () async {
  // 工具本身会返回 "ran"，但 guard 先拦截。
  final tool = _tool('shell_exec', 'ran');
  final registry = ToolRegistry()..register(tool);
  final session = SessionLog.fromEvents(const []);
  final agent = ReactLoopAgent(
    session: session,
    adapter: FakeLlmAdapter([
      // 调 shell_exec rm model_cache
      LlmResult(
          text: '',
          toolCalls: [ToolCall(id: 'c1', name: 'shell_exec',
              arguments: {'command': 'rm -rf model_cache'})]),
      LlmResult(text: '已拒绝', toolCalls: const []),
    ]),
    registry: registry,
    modelId: 'm',
    providerKind: ProviderKind.local,
    systemPrompt: 'x',
    guards: [modelCacheGuard],
  );

  await agent.kick('删缓存');

  final tr = _findToolResult(session, 'c1')!;
  expect(tr['isError'], true);
  expect(tr['content'], contains('受保护'));
  expect(tr['content'], isNot(contains('ran')));
});

// ---------------------------------------------------------------------------
// 工具：pre-execute / post-execute
// ---------------------------------------------------------------------------

test('pre-execute ask 无 approver → deny；post-execute 替换结果', () async {
  final tool = _tool('p', 'orig');
  final registry = ToolRegistry()..register(tool);
  final session = SessionLog.fromEvents(const []);

  final agent = ReactLoopAgent(
    session: session,
    adapter: FakeLlmAdapter([
      LlmResult(text: '', toolCalls: [ToolCall(id: 'c1', name: 'p',
          arguments: {})]),
      LlmResult(text: 'ok', toolCalls: const []),
    ]),
    registry: registry,
    modelId: 'm',
    providerKind: ProviderKind.local,
    systemPrompt: 'x',
    preListeners: [
      (call, args) => Future.value(ToolPreExecuteDecision.ask),
    ],
    postListeners: [
      (call, result) => ToolResult(content: '[post: ${result.content}]'),
    ],
  );

  await agent.kick('hi');
  final tr = _findToolResult(session, 'c1')!;
  // pre-execute ask 无 approver → 拒绝，结果 isError
  expect(tr['isError'], true);
  expect(tr['content'], contains('审批'));
});

// ---------------------------------------------------------------------------
// 工具：溢出压缩（长会话）
// ---------------------------------------------------------------------------

/// 追加一个"含工具"的 turn（user → assistant(tool) → tool/call → tool/result）。
void _appendToolTurn(SessionLog log, int turn) {
  final callId = 'call_$turn';
  log.append(kEventUserMessage, {
    'content': '问题 $turn',
  },
      source: const {'kind': 'user'});
  log.append(kEventAssistantMessage, {
    'content': '',
    'toolCalls': [
      {'call_id': callId, 'name': 't', 'arguments': {}}
    ],
  },
      source: const {'kind': 'model'});
  log.append(kEventToolCall, {'callId': callId, 'name': 't'});
  log.append(kEventToolResult, {
    'callId': callId,
    'name': 't',
    'content': '工具结果_$turn',
  },
      source: {'kind': 'tool', 'callId': callId});
}

test('压缩：旧轮工具结果被遮蔽，摘要入历史，recent 保留', () async {
  final log = SessionLog.fromEvents(const []);
  log.append(kEventSystemMessage, {'content': 'sys'},
      source: const {'kind': 'system'});
  // 8 轮工具 → 尾部 keepRounds=3 完整，前 5 轮被遮。
  for (var t = 1; t <= 8; t++) _appendToolTurn(log, t);

  final compaction = DeterministicCompaction(keepRounds: 3);
  final result = await compaction
      .decide(ref: SessionRef(log), turn: 0, step: 0, reason: 'overflow');
  expect(result.kind, CompactionResultKind.success);
  expect(log.replaceGeneration, greaterThan(0));

  // 旧轮工具结果（turn 1..5）应被遮蔽；新轮（6..8）不遮。
  // 从 log 找 tool/result 的 seq（遮蔽判断用 isShadowed）。
  final toolResultSeqs =
      log.rawEvents
          .where((e) => e.type == kEventToolResult)
          .map((e) => e.seq)
          .toList();
  // 前 5 个（旧轮）被遮，后 3 个（新轮）不被遮。
  for (var i = 0; i < toolResultSeqs.length; i++) {
    final shadowed = log.isShadowed(toolResultSeqs[i]);
    // 新轮 3 个不被遮（i >= 5），旧轮 5 个被遮。
    final isRecent = i >= 8 - 3;
    expect(shadowed, !isRecent, reason: 'seq=${toolResultSeqs[i]}');
  }

  // 摘要事件存在，且模型视角可见。
  final summaryData = _findToolResult(
      log, null, type: kEventCompactionSummary) ??
      log.rawEvents
          .where((e) => e.type == kEventCompactionSummary)
          .last
          .data;
  expect(summaryData, isNotNull);
  final msgs = log.deriveModelMessages();
  // 被遮的旧 tool/result 不应再出现在模型视角。
  expect(msgs
      .where((m) => m['content'] == '工具结果_1' ||
              m['content'] == '工具结果_5'),
      isEmpty);
  expect(msgs.firstWhere(
        (m) => (m['content'] ?? '').contains('较早轮次摘要'),
      orElse: () => throw StateError('no summary')),
      isNotNull);
});

test('压缩：足够近期无旧工具结果 → failure（无前进不 retry，防死循环）', () async {
  final log = SessionLog.fromEvents(const []);
  log.append(kEventSystemMessage, {'content': 'sys'},
      source: const {'kind': 'system'});
  _appendToolTurn(log, 1);
  _appendToolTurn(log, 2);

  final compaction = DeterministicCompaction(keepRounds: 3);
  final result =
      await compaction.decide(ref: SessionRef(log), turn: 0, step: 0, reason: 'x');
  // 2026-09-28 死循环修复：无可裁内容时不得返回 success——否则失败瀑布会
  // 无条件 retry 同一超限请求（不变量 11：重试必须 replaceGeneration 前进）。
  expect(result.kind, CompactionResultKind.failure);
  expect(log.replaceGeneration, 0); // 未遮蔽
});

// ---------------------------------------------------------------------------
// 工具：溢写（大结果）
// ---------------------------------------------------------------------------

test('溢写：大结果被省略，spill/locate 落 log，可 read_file 回读', () async {
  final big = 'x' * (4096 * 4 + 10); // 远超 maxInlineTokens
  final storeWrites = <String?>[];
  final store = (bytes) async {
    storeWrites.add('locator');
    return 'app/data/spill/abc';
  };
  final tool = _tool('big', big);
  final registry = ToolRegistry()..register(tool);
  final session = SessionLog.fromEvents(const []);

  final agent = ReactLoopAgent(
    session: session,
    adapter: FakeLlmAdapter([
      LlmResult(text: '', toolCalls: [ToolCall(id: 'c1', name: 'big',
          arguments: {})]),
      LlmResult(text: 'done', toolCalls: const []),
    ]),
    registry: registry,
    modelId: 'm',
    providerKind: ProviderKind.local,
    systemPrompt: 'x',
    spillStore: store,
    spillMaxInlineTokens: 4096,
  );

  await agent.kick('hi');
  expect(storeWrites.length, 1);
  final tr = _findToolResult(session, 'c1')!;
  expect(tr['isError'], false);
  expect(tr['content'], isNot(contains(big.substring(0, 100))));
  expect(tr['content'], contains('省略'));
  expect(tr['content'], contains('app/data/spill/abc'));
  expect(_findData(session, kEventSpillLocate), isNotNull);
});

test('溢写：read_file 结果始终内联（防循环）', () async {
  final big = 'x' * (4096 * 4 + 10);
  final registry = ToolRegistry()..register(_tool('read_file', big));
  final session = SessionLog.fromEvents(const []);
  final storeWrites = <String?>[];
  final store = (bytes) async {
    storeWrites.add('called');
    return 'should-not-spill';
  };
  final agent = ReactLoopAgent(
    session: session,
    adapter: FakeLlmAdapter([
      LlmResult(
          text: '',
          toolCalls: [ToolCall(id: 'c1', name: 'read_file',
              arguments: {'path': '/f'})]),
      LlmResult(text: 'ok', toolCalls: const []),
    ]),
    registry: registry,
    modelId: 'm',
    providerKind: ProviderKind.local,
    systemPrompt: 'x',
    spillStore: store,
    spillMaxInlineTokens: 4096,
  );
  await agent.kick('read');
  final tr = _findToolResult(session, 'c1')!;
  expect(tr['content'], isNot(contains('省略')));
  expect(storeWrites.length, 0); // 没被调用（read_file 防循环）
});

// ---------------------------------------------------------------------------
// 工具：并行执行
// ---------------------------------------------------------------------------

test('并行：多工具并发执行，并发上限 = maxParallel，结果按序', () async {
  final tool = _concurrentTool();
  final registry = ToolRegistry()..register(tool);
  final session = SessionLog.fromEvents(const []);
  final calls = [
    for (var i = 0; i < 5; i++)
        ToolCall(id: 'c$i', name: 'concurrent', arguments: {}),
  ];
  final fake = FakeLlmAdapter([
    LlmResult(text: '', toolCalls: calls),
    LlmResult(text: 'all done', toolCalls: const []),
  ]);
  final agent = ReactLoopAgent(
    session: session,
    adapter: fake,
    registry: registry,
    modelId: 'm',
    providerKind: ProviderKind.local,
    systemPrompt: 'x',
    config: AgentConfig(allowParallelTools: true, maxParallel: 2),
  );

  final start = DateTime.now();
  final reason = await agent.kick('go');
  final elapsed = DateTime.now().difference(start).inMilliseconds;
  expect(reason.kind, TurnEndReasonKind.completed);
  expect(fake.calls, 2);

  // 5 个各 20ms：串行 ~100ms，并行(max=2) ~60ms（3 批）。
  expect(elapsed, lessThan(100));

  // 5 个 tool/result 按序落地。
  final trs = logToolResults(session);
  expect(trs.length, 5);
  for (var i = 0; i < 5; i++) {
    expect(trs[i]['callId'], 'c$i');
  }
});

test('串行：allowParallelTools=false 时顺序执行', () async {
  final tool = _tool('s', 'ok');
  final registry = ToolRegistry()..register(tool);
  final session = SessionLog.fromEvents(const []);
  final calls = [
    for (var i = 0; i < 3; i++) ToolCall(id: 'c$i', name: 's', arguments: {}),
  ];
  final fake = FakeLlmAdapter([
    LlmResult(text: '', toolCalls: calls),
    LlmResult(text: 'ok', toolCalls: const []),
  ]);
  final agent = ReactLoopAgent(
    session: session,
    adapter: fake,
    registry: registry,
    modelId: 'm',
    providerKind: ProviderKind.local,
    systemPrompt: 'x',
  );
  final reason = await agent.kick('go');
  expect(reason.kind, TurnEndReasonKind.completed);
  expect(fake.calls, 2);
  final trs = logToolResults(session);
  expect(trs.length, 3);
  for (var i = 0; i < 3; i++) expect(trs[i]['callId'], 'c$i');
});
} // main()

// ---------------------------------------------------------------------------
// helpers
// ---------------------------------------------------------------------------

Map<String, dynamic>? _findData(
    SessionLog log, String type, {String? typeFilter}) {
  final t = typeFilter ?? type;
  for (final e in log.rawEvents) {
    if (e.type == t) return e.data;
  }
  return null;
}

Map<String, dynamic>? _findToolResult(SessionLog log,
    String? callId, {String? type}) {
  final t = type ?? kEventToolResult;
  for (final e in log.rawEvents) {
    if (e.type == t) {
      if (callId == null) return e.data;
      if ((e.data['callId'] ?? e.data['call_id']) == callId) return e.data;
    }
  }
  return null;
}

List<Map<String, dynamic>> logToolResults(SessionLog log) {
  final out = <Map<String, dynamic>>[];
  for (final e in log.rawEvents) {
    if (e.type == kEventToolResult) out.add(e.data);
  }
  return out;
}

// 脚本化 LLM 桩已提取到 test/helpers/fake_llm.dart（2026-09-30 审查 P0-3，
// 原「复制 loop_test」的本地副本删除，全测试共享一份）。

