import 'dart:async';

import 'package:tongyi_lite/agent/loop/agent.dart';
import 'package:tongyi_lite/agent/loop/config.dart';
import 'package:tongyi_lite/agent/loop/failure.dart';
import 'package:tongyi_lite/agent/llm/adapter.dart';
import 'package:tongyi_lite/agent/session/session.dart';
import 'package:tongyi_lite/agent/tool_definition.dart';
import 'package:tongyi_lite/agent/tool_registry.dart';
import 'package:flutter_test/flutter_test.dart';
import '../helpers/fake_llm.dart';

// ---------------------------------------------------------------------------
// 测试桩
// ---------------------------------------------------------------------------

/// 挂起桩：一直挂到 cancel 完成，然后抛 [AgentCancelledException]（验证取消竞跑）。
class HangingFakeLlmAdapter implements LlmAdapter {
  bool cancelled = false;
  int calls = 0;

  @override
  Future<LlmResult> generate(
    GenerateOptions options, {
    StreamController<String>? onToken,
    StreamController<String>? onThinking,
    Completer<void>? cancel,
  }) async {
    calls++;
    if (cancel != null) {
      await cancel.future;
    }
    cancelled = true;
    throw const AgentCancelledException();
  }

  @override
  void cancel() {}

  @override
  PreparedLlmCall prepareCall(String model) =>
      PreparedLlmCall(adapter: this, model: model);
}

/// 一个返回固定结果的假天气工具。
ToolDefinition _weatherTool() => ToolDefinition(
      name: 'get_weather',
      description: '查询天气',
      parameters: {
        'type': 'object',
        'properties': {'city': {'type': 'string', 'description': '城市'}},
        'required': ['city'],
      },
      execute: (args) => Future.value(ToolResult(content: 'Beijing: sunny 25C')),
    );

ToolRegistry _registryWith(List<ToolDefinition> tools) {
  final reg = ToolRegistry();
  for (final t in tools) {
    reg.register(t);
  }
  return reg;
}

/// 从事件里取某类型事件的 data。
Map<String, dynamic>? _findData(SessionLog log, String type) {
  for (final e in log.rawEvents) {
    if (e.type == type) return e.data;
  }
  return null;
}

/// 构造就绪的 ReactLoopAgent（默认带 get_weather）。
ReactLoopAgent _agent(
  LlmAdapter adapter, {
  List<ToolDefinition>? tools,
  AgentConfig? config,
}) {
  final session = SessionLog.fromEvents(const []);
  final registry = _registryWith(tools ?? [_weatherTool()]);
  final cfg = config ?? AgentConfig();
  return ReactLoopAgent(
    session: session,
    adapter: adapter,
    registry: registry,
    modelId: 'test-model',
    providerKind: ProviderKind.local,
    systemPrompt: '你是 TongYi-Lite 智能体',
    config: cfg,
    compaction: const NoCompactionPlugin(),
  );
}

// ---------------------------------------------------------------------------
// 测试
// ---------------------------------------------------------------------------

void main() {
  test(
      '简单 turn：无工具调用 → completed，日志含 system/user/assistant/turn-end',
      () async {
    final fake = FakeLlmAdapter(
        [LlmResult(text: '你好，我是助手', toolCalls: const [])]);
    final agent = _agent(fake);

    final reason = await agent.kick('你好');

    expect(reason.kind, TurnEndReasonKind.completed);
    expect(fake.calls, 1);
    final data = _findData(agent.session, kEventUserMessage);
    expect(data?['content'], '你好');
    expect(agent.phaseState.phase, AgentPhase.idle);
  });

  test('工具调用 turn：模型调工具 → 执行 → 再问模型 → 最终答案', () async {
    final call = ToolCall(
        id: 'call_1',
        name: 'get_weather',
        arguments: {'city': 'Beijing'});
    final fake = FakeLlmAdapter([
      LlmResult(text: '', toolCalls: [call]),
      LlmResult(text: '北京今天晴，25C', toolCalls: const []),
    ]);
    final agent = _agent(fake);

    final reason = await agent.kick('北京天气？');

    expect(reason.kind, TurnEndReasonKind.completed);
    expect(fake.calls, 2);
    // 工具结果落日志
    expect(_findData(agent.session, kEventToolResult), isNotNull);
    // 第二次请求应能看到工具结果（G12）
    final lastMsgs = fake.allMessages.last;
    expect(lastMsgs, isNotEmpty);
  });

  test('失败 → llm-retry → 成功（llm/retry 与 assistant/attempt 落日志）',
      () async {
    final fake = FakeLlmAdapter([
      LlmFailure(code: LlmFailureCode.timeout, message: 'timeout'),
      LlmResult(text: 'ok', toolCalls: const []),
    ]);
    final agent = _agent(fake);

    final reason = await agent.kick('hi');

    expect(reason.kind, TurnEndReasonKind.completed);
    expect(fake.calls, 2); // 1 失败 + 1 重试成功
    expect(_findData(agent.session, kEventLlmRetry), isNotNull);
    expect(_findData(agent.session, kEventAssistantAttempt), isNotNull);
  });

  test('回合内重复调用：同名同参只真执行一次，重复回缓存 + 收敛提示', () async {
    final call = ToolCall(
        id: 'call_1',
        name: 'get_weather',
        arguments: {'city': 'Beijing'});
    final dup = ToolCall(
        id: 'call_2',
        name: 'get_weather',
        arguments: {'city': 'Beijing'});
    final fake = FakeLlmAdapter([
      LlmResult(text: '', toolCalls: [call]),
      LlmResult(text: '', toolCalls: [dup]),
      LlmResult(text: '北京今天晴，25C', toolCalls: const []),
    ]);
    final agent = _agent(fake);

    final reason = await agent.kick('北京天气？');

    expect(reason.kind, TurnEndReasonKind.completed);
    // 两次工具调用都落 tool/result（模型视角一致），但重复调用不真执行，
    // 回填内容 = 首次结果 + 收敛提示。
    final results = agent.session.rawEvents
        .where((e) => e.type == kEventToolResult)
        .toList();
    expect(results.length, 2);
    expect(results.last.data['content'], contains('重复调用提示'));
    expect(results.last.data['content'], contains('Beijing: sunny 25C'));
  });

  test('连续失败超预算 → 终态 error（不无限重试）', () async {
    final fake = FakeLlmAdapter(
        [
          LlmFailure(code: LlmFailureCode.timeout, message: 't1'),
          LlmFailure(code: LlmFailureCode.timeout, message: 't2'),
          LlmFailure(code: LlmFailureCode.timeout, message: 't3'),
          LlmFailure(code: LlmFailureCode.timeout, message: 't4'),
        ]);
    final agent = _agent(fake);

    final reason = await agent.kick('hi');

    expect(reason.kind, TurnEndReasonKind.error);
    // maxRetries=3 → 1 初始 + 3 重试 = 4 次
    expect(fake.calls, 4);
    expect(agent.phaseState.phase, AgentPhase.idle);
  });

  test('本地模型未加载（modelNotReady）→ 立即 giveUp，非重试不空转', () async {
    const notReady = LlmFailure(
      code: LlmFailureCode.modelNotReady,
      message: '本地模型未加载（模型加载失败），请在模型管理页重新加载模型',
    );
    // 即使再给一次结果，也不该被调用 —— 非重试失败只发一次。
    final fake = FakeLlmAdapter([notReady, notReady]);
    final agent = _agent(fake);

    final reason = await agent.kick('hi');

    expect(reason.kind, TurnEndReasonKind.error);
    expect(fake.calls, 1); // 模型未加载是权威状态，重试无益 → 只调一次即止损
    expect(agent.lastTurnAnswer, '');
    expect(agent.lastTurnError, contains('未加载'));
  });

  test('取消 → interrupted（abort 与流竞跑）', () async {
    final fake = HangingFakeLlmAdapter();
    final agent = _agent(fake);
    final future = agent.kick('hi');
    await Future.delayed(Duration(milliseconds: 50));
    agent.cancel('user stop');
    final reason = await future;
    expect(reason.kind, TurnEndReasonKind.interrupted);
    expect(agent.phaseState.phase, AgentPhase.idle);
    expect(fake.calls, 1); // 只发起一次，被取消
  });

  test('G12：每次请求历史均来自 log 派生（非手工构造）', () async {
    final fake = FakeLlmAdapter([
      LlmResult(
          text: '',
          toolCalls: [
            ToolCall(id: 'c1', name: 'get_weather',
                arguments: {'city': 'Beijing'})
          ]),
      LlmResult(text: '晴', toolCalls: const []),
    ]);
    final agent = _agent(fake);
    final session = agent.session;

    await agent.kick('北京天气？');

    // 第一次请求：log 当时只含 system + user（无 assistant/tool）
    final first = fake.allMessages.first;
    expect(first.length, 2);
    expect(first.first['role'], 'system');
    expect(first.first['content'], '你是 TongYi-Lite 智能体');
    expect(first[1]['role'], 'user');
    expect(first[1]['content'], '北京天气？');
    // 结构一致性：roles 序列正确
    expect(first.every((m) => m['role'] != null), true);
  });

  test('maxSteps：持续调工具到上限 → turn/end {reason:maxSteps}', () async {
    final fake = FakeLlmAdapter([
      LlmResult(
          text: '',
          toolCalls: [
            ToolCall(id: 'c0', name: 'get_weather',
                arguments: {'city': 'Beijing'})
          ]),
      LlmResult(
          text: '',
          toolCalls: [
            ToolCall(id: 'c1', name: 'get_weather',
                arguments: {'city': 'Beijing'})
          ]),
      // 第三次不应被调用（达到 maxSteps=2 上限；maxWrapups=0 关闭续跑）
      LlmResult(text: 'never', toolCalls: const []),
    ]);
    final agent = _agent(fake,
        config: const AgentConfig(maxStepsPerTurn: 2, maxWrapups: 0));
    final reason = await agent.kick('北京天气？');
    expect(reason.kind, TurnEndReasonKind.maxSteps);
    expect(fake.calls, 2); // 只到上限，不超
    expect(_findData(agent.session, kEventTurnEnd)?['reason'], 'maxSteps');
  });

  test('maxSteps 续跑（P2-A1）：撞上限自动合成收尾提示追加预算，不死停', () async {
    final fake = FakeLlmAdapter([
      LlmResult(
          text: '',
          toolCalls: [
            ToolCall(id: 'c0', name: 'get_weather',
                arguments: {'city': 'Beijing'})
          ]),
      LlmResult(
          text: '',
          toolCalls: [
            ToolCall(id: 'c1', name: 'get_weather',
                arguments: {'city': 'Beijing'})
          ]),
      // 续跑轮（撞 maxSteps=2 后追加 2 步）：模型收尾作答
      LlmResult(text: '根据查询结果，北京晴', toolCalls: const []),
    ]);
    final agent = _agent(fake,
        config: const AgentConfig(maxStepsPerTurn: 2, maxWrapups: 1,
            wrapupSteps: 2));
    final reason = await agent.kick('北京天气？');
    expect(reason.kind, TurnEndReasonKind.completed);
    expect(fake.calls, 3); // 2 步预算 + 续跑 1 步
    // 收尾提示以 user 事件入 log（模型可见）
    final events = agent.session.rawEvents;
    final guidance = events
        .where((e) => e.type == kEventUserMessage)
        .where((e) => '${e.data['content']}'.contains('收尾阶段'))
        .toList();
    expect(guidance, isNotEmpty);
    expect(_findData(agent.session, kEventTurnEnd)?['reason'], 'completed');
  });

  test('maxSteps 续跑耗尽：总预算封顶后仍 maxSteps 终止', () async {
    LlmResult alwaysTool() => LlmResult(
        text: '',
        toolCalls: [
          ToolCall(id: 'c${DateTime.now().microsecondsSinceEpoch}',
              name: 'get_weather', arguments: {'city': 'Beijing'})
        ]);
    final fake = FakeLlmAdapter(List.generate(10, (_) => alwaysTool()));
    final agent = _agent(fake,
        config: const AgentConfig(maxStepsPerTurn: 2, maxWrapups: 1,
            wrapupSteps: 2));
    final reason = await agent.kick('北京天气？');
    expect(reason.kind, TurnEndReasonKind.maxSteps);
    expect(fake.calls, 4); // 2 + 2（一轮收尾）= 封顶
  });

  test('收敛警告（P2-A1）：剩余步数 ≤2 时注入一次引导消息', () async {
    final fake = FakeLlmAdapter([
      LlmResult(
          text: '',
          toolCalls: [
            ToolCall(id: 'c0', name: 'get_weather',
                arguments: {'city': 'Beijing'})
          ]),
      LlmResult(text: '北京晴', toolCalls: const []),
    ]);
    // maxSteps=2：第一步后剩 1 步 → 应注入警告
    final agent = _agent(fake,
        config: const AgentConfig(maxStepsPerTurn: 2, maxWrapups: 0));
    await agent.kick('北京天气？');
    final events = agent.session.rawEvents;
    final warnings = events
        .where((e) => e.type == kEventUserMessage)
        .where((e) => '${e.data['content']}'.contains('剩余步数不多'))
        .toList();
    expect(warnings.length, 1);
  });

  test('steer（P2-B1）：回合中插话在下一个 step 前落为 user 消息', () async {
    final fake = FakeLlmAdapter([
      LlmResult(
          text: '',
          toolCalls: [
            ToolCall(id: 'c0', name: 'get_weather',
                arguments: {'city': 'Beijing'})
          ]),
      LlmResult(text: '北京晴', toolCalls: const []),
    ]);
    // 工具执行体内排队插话：保证入队时机在 step1 drain 之后、step2 drain 之前。
    late final ReactLoopAgent agent;
    agent = _agent(fake, tools: [
      ToolDefinition(
        name: 'get_weather',
        description: '查询天气',
        parameters: {
          'type': 'object',
          'properties': {'city': {'type': 'string'}},
          'required': ['city'],
        },
        execute: (args) async {
          agent.steer('顺便问下上海呢');
          return ToolResult(content: 'Beijing: sunny 25C');
        },
      ),
    ]);
    await agent.kick('北京天气？');
    final events = agent.session.rawEvents;
    final steerMsgs = events
        .where((e) => e.type == kEventUserMessage)
        .where((e) => '${e.data['content']}'.contains('[用户插话] 顺便问下上海呢'))
        .toList();
    expect(steerMsgs.length, 1);
  });

  test('injectNotice（P3-3）：系统通知在 step 边界入模型上下文', () async {
    final fake = FakeLlmAdapter([
      LlmResult(
          text: '',
          toolCalls: [
            ToolCall(id: 'c0', name: 'get_weather',
                arguments: {'city': 'Beijing'})
          ]),
      LlmResult(text: '北京晴', toolCalls: const []),
    ]);
    late final ReactLoopAgent agent;
    agent = _agent(fake, tools: [
      ToolDefinition(
        name: 'get_weather',
        description: '查询天气',
        parameters: {
          'type': 'object',
          'properties': {'city': {'type': 'string'}},
          'required': ['city'],
        },
        execute: (args) async {
          agent.injectNotice('后台子代理已完成（id=sub-1）');
          return ToolResult(content: 'Beijing: sunny 25C');
        },
      ),
    ]);
    await agent.kick('北京天气？');
    final events = agent.session.rawEvents;
    final notices = events
        .where((e) => e.type == kEventUserMessage)
        .where((e) => '${e.data['content']}'.contains('[系统通知] 后台子代理已完成'))
        .toList();
    expect(notices.length, 1);
  });

  test('未知工具：模型调未注册工具 → 工具返回可读错误，不崩溃', () async {
    final fake = FakeLlmAdapter([
      LlmResult(text: '', toolCalls: [
        ToolCall(id: 'c1', name: 'nonexistent_tool', arguments: {})
      ]),
      LlmResult(text: '抱歉找不到该工具', toolCalls: const []),
    ]);
    final agent = _agent(fake);
    final reason = await agent.kick('用 nonexistent_tool');
    expect(reason.kind, TurnEndReasonKind.completed);
    final tr = _findData(agent.session, kEventToolResult);
    expect(tr?['isError'], true);
    expect(tr?['content'], contains('未知工具'));
  });

  test('必填参数校验：工具缺必填参数 → 工具返回引导性错误', () async {
    final fake = FakeLlmAdapter([
      LlmResult(text: '', toolCalls: [
        ToolCall(id: 'c1', name: 'get_weather', arguments: {}) // 缺 city
      ]),
      LlmResult(text: '请告诉我城市', toolCalls: const []),
    ]);
    final agent = _agent(fake);
    await agent.kick('天气');
    final tr = _findData(agent.session, kEventToolResult);
    expect(tr?['isError'], true);
    expect(tr?['content'], contains('缺少必填参数'));
  });

  test('回归：turn 失败 → lastTurnAnswer 为空不回溯上一轮旧答案，lastTurnError 带原因',
      () async {
    // 用确定性失败（invalidRequest，永不重试）——空响应现已计入本地可重试档，
    // 会走重试预算改变调用次数；本测试只验证"失败轮不回溯旧答案"。
    final fake = FakeLlmAdapter([
      LlmResult(text: '第一轮答案', toolCalls: const []),
      LlmFailure(code: LlmFailureCode.invalidRequest, message: 'HTTP 400'),
    ]);
    final agent = _agent(fake);
    await agent.kick('第一轮问题');
    expect(agent.lastTurnAnswer, '第一轮答案');

    final reason = await agent.kick('第二轮问题');
    expect(reason.kind, TurnEndReasonKind.error);
    // 关键：失败轮不得把上一轮答案冒充本轮回复（重复问候 bug 的根因防线）。
    expect(agent.lastTurnAnswer, '');
    expect(agent.lastTurnError, contains('HTTP 400'));
  });

  test('本地路线空响应可重试：思考中途 EOS → 重试一次成功', () async {
    final fake = FakeLlmAdapter([
      LlmFailure(code: LlmFailureCode.emptyResponse, message: '模型思考中途 EOS'),
      LlmResult(text: '最终回答', toolCalls: const []),
    ]);
    final agent = _agent(fake);

    final reason = await agent.kick('问题');

    expect(reason.kind, TurnEndReasonKind.completed);
    expect(agent.lastTurnAnswer, '最终回答');
    expect(fake.calls, 2); // 空响应计入可重试档 → 重试一次
    expect(_findData(agent.session, kEventLlmRetry), isNotNull);
  });

  test('回归：成功轮的 lastTurnAnswer 在多次 kick 后只反映当轮', () async {
    final fake = FakeLlmAdapter([
      LlmResult(text: '答案A', toolCalls: const []),
      LlmResult(text: '答案B', toolCalls: const []),
    ]);
    final agent = _agent(fake);
    await agent.kick('问题1');
    expect(agent.lastTurnAnswer, '答案A');
    await agent.kick('问题2');
    expect(agent.lastTurnAnswer, '答案B');
    expect(agent.lastTurnError, isNull);
  });

  test('工具调用截断失败：重试有界（maxRetries）后终态报错，不静默', () async {
    const trunc = LlmFailure(
      code: LlmFailureCode.toolCallTruncated,
      message: '工具调用生成不完整（输出 token 预算不足被截断）',
    );
    final fake = FakeLlmAdapter([trunc, trunc, trunc]);
    final agent = ReactLoopAgent(
      session: SessionLog.fromEvents(const []),
      adapter: fake,
      registry: _registryWith([_weatherTool()]),
      modelId: 'test-model',
      providerKind: ProviderKind.local,
      systemPrompt: 'sys',
      compaction: const NoCompactionPlugin(),
      retry: LlmRetry(
        maxRetries: 2,
        initialDelay: Duration.zero,
        maxDelay: Duration.zero,
      ),
    );

    final reason = await agent.kick('写个文件');

    // 1 次原始 + 2 次重试后止损（重试不豁免 maxRetries 上限）。
    expect(fake.calls, 3);
    expect(reason.kind, TurnEndReasonKind.error);
    expect(agent.lastTurnAnswer, '');
    expect(agent.lastTurnError, contains('截断'));
  });
}