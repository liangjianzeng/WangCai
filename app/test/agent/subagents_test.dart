/// Phase 4 子代理测试（DSH Part 11）。
///
/// 覆盖：fork seed（前缀切法）、审批 `never`（自动拒绝升级）、深度上限 ≤ 2、
/// spawn/fork 会话构造与 result → SubagentResult 映射。
library;

import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:tongyi_lite/agent/builtin_tools/builtin_tools.dart';
import 'package:tongyi_lite/agent/llm/adapter.dart';
import 'package:tongyi_lite/agent/sandbox.dart';
import 'package:tongyi_lite/agent/subagents/in_process.dart';
import 'package:tongyi_lite/agent/subagents/provider.dart';
import 'package:tongyi_lite/agent/subagents/subagent_tool.dart';
import 'package:tongyi_lite/agent/session/session.dart';
import 'package:tongyi_lite/agent/tool_registry.dart';

/// 覆写 [LlmAdapter.generate] 的桩：按轮次返回预设 [LlmResult]，并捕获
/// 每次收到的消息历史（验证 fork 前缀/上下文）。
final class _FakeAdapter extends LlmAdapter {
  final List<LlmResult> _outcomes;
  int _calls;
  final List<List<Map<String, dynamic>>> _capturedMessages;

  _FakeAdapter(this._outcomes)
      : _calls = 0,
        _capturedMessages = [];

  @override
  Future<LlmResult> generate(
    GenerateOptions options, {
    StreamController<String>? onToken,
    StreamController<String>? onThinking,
    Completer<void>? cancel,
  }) async {
    _capturedMessages.add(List.of(options.messages));
    final idx = _calls < _outcomes.length ? _calls : _outcomes.length - 1;
    final result = _outcomes[idx];
    _calls++;
    return result;
  }

  int get calls => _calls;
  List<List<Map<String, dynamic>>> get capturedMessages => _capturedMessages;
}

/// 构建带已完成 turn + 进行中 turn 的父会话。
SessionLog buildParentWithCompletedTurn() {
  final log = SessionLog.fromEvents(const []);
  log.append(kEventSystemMessage, {'content': '父系统提示'});
  log.append(kEventUserMessage, {'content': '父用户消息'});
  log.append(kEventTurnStart, {'turn': 1, 'userSeq': 2});
  log.append(kEventAssistantMessage, {'content': '父助手回答'});
  log.append(kEventTurnEnd, {'turn': 1, 'reason': 'completed'});
  // 进行中的第二个 turn（不应被 fork 拖入）。
  log.append(kEventUserMessage, {'content': '进行中用户消息'});
  log.append(kEventTurnStart, {'turn': 2, 'userSeq': 7});
  log.append(kEventAssistantMessage, {'content': '进行中助手回答'});
  return log;
}

void main() {
  // ---------------------------------------------------------------------------
  // 1. fork seed：前缀切法
  // ---------------------------------------------------------------------------
  test('completedTurnPrefix：只含到最后一个 turn/end 的前缀，不含进行中 turn',
      () {
    final parent = buildParentWithCompletedTurn();
    final prefix = completedTurnPrefix(parent);
    // turn 1 的 5 条（system/user/turnStart/assistant/turnEnd），seq 1-5。
    expect(prefix.length, 5);
    expect(prefix[0].type, kEventSystemMessage);
    expect(prefix.last.type, kEventTurnEnd);
    expect(prefix.last.seq, 5);
    // 进行中的 seq 6-8 不应出现。
    expect(prefix.any((e) => e.seq >= 6), false);
  });

  test('completedTurnPrefix：无 turn/end 时返回空（fork 等价 spawn）', () {
    final log = SessionLog.fromEvents(const []);
    log.append(kEventUserMessage, {'content': '只有用户消息'});
    expect(completedTurnPrefix(log), isEmpty);
  });

  // ---------------------------------------------------------------------------
  // 2. 审批 `never`
  // ---------------------------------------------------------------------------
  test('neverApprover：对任何升级请求恒返回 false', () async {
    final escalation = SandboxEscalation(
      requestedMode: SandboxMode.dangerFullAccess,
      justification: '测试升级请求',
    );
    final granted = await neverApprover(escalation, 'shell_exec');
    expect(granted, false);
  });

  // ---------------------------------------------------------------------------
  // 3. 深度上限
  // ---------------------------------------------------------------------------
  test('深度达到 maxDepth 时拒绝（抛 SubagentMaxDepthExceeded）', () {
    final parent = SessionLog.fromEvents(const []);
    final (provider, _) = buildProvider(
      adapter: _FakeAdapter([const LlmResult(text: '不该到这里')]),
      parentSession: parent,
    );

    // 模拟已嵌套到上限（顶层 depth 0 + 两层子代理 = 2）。
    final original = kSubagentDepth.depth;
    kSubagentDepth.depth = kSubagentMaxDepth;
    try {
      expect(
        () => provider.start(
            SubagentStartRequest(task: 'deep', mode: 'spawn')),
        throwsA(isA<SubagentMaxDepthExceeded>()),
      );
    } finally {
      kSubagentDepth.depth = original;
    }
  });

  // ---------------------------------------------------------------------------
  // 4. spawn：空白会话 + result 映射
  // ---------------------------------------------------------------------------
  test('spawn：子代理空白会话回答，stopReason=completed、isError=false', () async {
    final (provider, registry) = buildProvider(
      adapter: _FakeAdapter([
        const LlmResult(text: '子代理最终答案'),
      ]),
      parentSession: SessionLog.fromEvents(const []),
    );
    registry.register(createSubagentTool(provider));

    final run = await provider.start(
        SubagentStartRequest(task: '完成一个简单任务', mode: 'spawn'));
    final result = await run.result;

    expect(result.output, '子代理最终答案');
    expect(result.isError, false);
    expect(result.stopReason, 'completed');
    // 子代理 session 非空（append 了事件）。
    expect(run.session.eventsCount, greaterThan(0));
  });

  // ---------------------------------------------------------------------------
  // 5. fork：子代理继承前缀，模型能看到父上下文
  // ---------------------------------------------------------------------------
  test('fork：子代理 session 含父前缀，模型消息历史含父内容、不含进行中 turn',
      () async {
    final parent = buildParentWithCompletedTurn();
    final adapter = _FakeAdapter([
      const LlmResult(text: 'fork 子代理答案'),
    ]);
    final (provider, _) = buildProvider(
      adapter: adapter,
      parentSession: parent,
    );

    final run = await provider.start(
        SubagentStartRequest(task: '基于上下文继续', mode: 'fork'));
    final result = await run.result;
    expect(result.output, 'fork 子代理答案');
    expect(result.isError, false);

    // 子代理 session 应含父前缀的事件 + 自己的事件。
    expect(run.session.eventsCount, greaterThan(10));
    // 子代理 session 含父 system 内容。
    expect(
      run.session.rawEvents.any(
          (e) =>
              e.type == kEventSystemMessage && e.data['content'] == '父系统提示'),
      true,
    );

    // 模型看到的消息历史：含父前缀内容，不含进行中 turn 内容。
    expect(adapter.capturedMessages.isNotEmpty, true);
    final joined = adapter.capturedMessages.first
        .map((m) => '${m['role']}: ${m['content']}')
        .join('\n');
    expect(joined, contains('父系统提示'));
    expect(joined, contains('父用户消息'));
    expect(joined, contains('父助手回答'));
    expect(joined, isNot(contains('进行中用户消息')));
    expect(joined, isNot(contains('进行中助手回答')));
  });

  // ---------------------------------------------------------------------------
  // 6. result 映射：失败 → isError=true
  // ---------------------------------------------------------------------------
  test('子代理失败（LlmFailure）→ SubagentResult.isError=true', () async {
    final (provider, _) = buildProvider(
      adapter: _FailingAdapter(),
      parentSession: SessionLog.fromEvents(const []),
    );
    final run = await provider.start(
        SubagentStartRequest(task: '会失败的任务', mode: 'spawn'));
    final result = await run.result;
    expect(result.isError, true);
    expect(result.stopReason, 'error');
  });
}

/// 每次 generate 都抛 LlmFailure（验证失败 → isError=true 映射）。
final class _FailingAdapter extends LlmAdapter {
  @override
  Future<LlmResult> generate(
    GenerateOptions options, {
    StreamController<String>? onToken,
    StreamController<String>? onThinking,
    Completer<void>? cancel,
  }) async {
    // 抛出无法恢复的 server 错误 → 瀑布给 Up 为 error。
    throw const LlmFailure(
        code: LlmFailureCode.server, message: '测试服务端错误', status: 500);
  }
}

/// 构建 provider + registry（注册内置工具；subagent 工具在需要时另行 register）。
(InProcessSubagentProvider, ToolRegistry) buildProvider({
  required LlmAdapter adapter,
  required SessionLog parentSession,
}) {
  final registry = ToolRegistry();
  for (final tool in createBuiltinTools()) {
    registry.register(tool);
  }
  final provider = InProcessSubagentProvider(
    adapter: adapter,
    registry: registry,
    modelId: 'test-model',
    providerKind: ProviderKind.local,
    systemPrompt: '系统提示：可调用工具。',
    parentSession: parentSession,
  );
  return (provider, registry);
}
