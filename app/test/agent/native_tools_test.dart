/// 原生工具调用协议（API 路线）测试 —— 2026-09-28 智能体 API 路线翻盘包。
///
/// 覆盖：
/// - NativeToolProtocol 能力驱动选择（nativeToolCall → 压过 prompt-json）；
/// - deriveModelMessages 的 call_id/id 键名兼容（配对 id 不再恒空串）；
/// - toOpenAiWireMessages（assistant tool_calls 线格式 + role:tool 配对锚点）；
/// - OpenAiNativeStreamAssembler（分片拼装/多调用/坏 JSON/缺 id 兜底）；
/// - 失败分档（4xx → invalidRequest 不重试；空响应 emptyResponse）；
/// - parseAndReturn 空响应 fail-loud；
/// - 压缩死循环修复（无前进 → failure → turn 终态 error 而非无限重试）。
library;

import 'dart:async';
import 'dart:convert';

import 'package:dio/dio.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:tongyi_lite/agent/capability.dart';
import 'package:tongyi_lite/agent/context_eng/compaction.dart';
import 'package:tongyi_lite/agent/llm/adapter.dart';
import 'package:tongyi_lite/agent/llm/base_engine_adapter.dart';
import 'package:tongyi_lite/agent/llm/openai_adapter.dart';
import 'package:tongyi_lite/agent/loop/agent.dart';
import 'package:tongyi_lite/agent/loop/config.dart';
import 'package:tongyi_lite/agent/loop/failure.dart';
import 'package:tongyi_lite/agent/protocol/native_tool_protocol.dart';
import 'package:tongyi_lite/agent/protocol/prompt_json_protocol.dart';
import 'package:tongyi_lite/agent/protocol/protocol_selector.dart';
import 'package:tongyi_lite/agent/session/session.dart';
import 'package:tongyi_lite/agent/tool_definition.dart';
import 'package:tongyi_lite/agent/tool_registry.dart';
import 'package:tongyi_lite/providers/agent_stream_processor.dart';

// ---------------------------------------------------------------------------
// 测试桩
// ---------------------------------------------------------------------------

/// 恒抛上下文溢出的 LLM 桩（验证压缩死循环修复后 turn 能终止）。
class _OverflowAdapter implements LlmAdapter {
  int calls = 0;

  @override
  Future<LlmResult> generate(
    GenerateOptions options, {
    StreamController<String>? onToken,
    StreamController<String>? onThinking,
    Completer<void>? cancel,
  }) async {
    calls++;
    throw const LlmFailure(
      code: LlmFailureCode.contextWindowExceeded,
      message: 'context overflow',
    );
  }

  @override
  void cancel() {}

  @override
  PreparedLlmCall prepareCall(String model) =>
      PreparedLlmCall(adapter: this, model: model);
}

/// 暴露 parseAndReturn 的最小桩。
class _TestAdapter extends BaseEngineAdapter {
  _TestAdapter({required super.protocol});
}

// ---------------------------------------------------------------------------
// 协议选择
// ---------------------------------------------------------------------------

void main() {
  test('NativeToolProtocol：nativeToolCall 时支持且压过 prompt-json', () {
    final native = NativeToolProtocol();
    final text = PromptJsonProtocol();
    final caps = const EngineCapabilities(nativeToolCall: true);
    expect(native.supports(caps), isTrue);
    expect(native.priority(caps), greaterThan(text.priority(caps)));
    final chosen = selectProtocol([text, native], caps);
    expect(chosen.id, NativeToolProtocol.kId);
    // 工具走请求体，system 不注入工具段。
    expect(native.buildToolSection(ToolRegistry()), isEmpty);
  });

  test('NativeToolProtocol：无原生能力时让位 prompt-json', () {
    final caps = const EngineCapabilities(nativeToolCall: false);
    final chosen =
        selectProtocol([NativeToolProtocol(), PromptJsonProtocol()], caps);
    expect(chosen.id, PromptJsonProtocol.kId);
  });

  // -------------------------------------------------------------------------
  // call_id / id 键名错配修复（配对 id 不再恒空串）
  // -------------------------------------------------------------------------

  test('deriveModelMessages：写入侧 call_id 键可投影出 id（此前恒空串）', () {
    final log = SessionLog.fromEvents([]);
    log.append(kEventAssistantMessage, {
      'content': '',
      'toolCalls': [
        {'call_id': 'c1', 'name': 'web_search', 'arguments': {'query': 'x'}},
      ],
    });
    log.append(kEventToolResult, {'callId': 'c1', 'content': 'result'});
    final msgs = log.deriveModelMessages();
    expect(msgs[0]['tool_calls'][0]['id'], 'c1');
    expect(msgs[1]['tool_call_id'], 'c1'); // 配对锚点一致
  });

  test('deriveModelMessages：历史/导入数据的 id 键继续兼容', () {
    final log = SessionLog.fromEvents([]);
    log.append(kEventAssistantMessage, {
      'content': '',
      'toolCalls': [
        {'id': 'call_9', 'function_name': 'get_time', 'arguments': {}},
      ],
    });
    expect(log.deriveModelMessages()[0]['tool_calls'][0]['id'], 'call_9');
  });

  // -------------------------------------------------------------------------
  // OpenAI 线格式翻译
  // -------------------------------------------------------------------------

  test('toOpenAiWireMessages：assistant tool_calls 翻译 + tool 保留配对', () {
    final wire = toOpenAiWireMessages([
      {'role': 'system', 'content': 'sys'},
      {'role': 'user', 'content': '查天气'},
      {
        'role': 'assistant',
        'content': '',
        'tool_calls': [
          {
            'type': 'tool_call',
            'id': 'call_1',
            'function_name': 'get_weather',
            'arguments': {'location': '武汉'},
          },
        ],
      },
      {'role': 'tool', 'tool_call_id': 'call_1', 'content': '晴 30°C'},
    ]);
    expect(wire.length, 4);
    // assistant：arguments 编码为 JSON 字符串（OpenAI 线格式要求）。
    final asst = wire[2];
    expect(asst['role'], 'assistant');
    final tc = asst['tool_calls'][0];
    expect(tc['id'], 'call_1');
    expect(tc['type'], 'function');
    expect(tc['function']['name'], 'get_weather');
    expect(tc['function']['arguments'], jsonEncode({'location': '武汉'}));
    // tool：携带配对锚点 → 严格服务端不再 400。
    expect(wire[3]['role'], 'tool');
    expect(wire[3]['tool_call_id'], 'call_1');
  });

  test('toOpenAiWireMessages：arguments 已是字符串时原样透传', () {
    final wire = toOpenAiWireMessages([
      {
        'role': 'assistant',
        'content': '',
        'tool_calls': [
          {
            'type': 'tool_call',
            'id': 'c2',
            'function_name': 't',
            'arguments': '{"a":1}',
          },
        ],
      },
    ]);
    expect(wire[0]['tool_calls'][0]['function']['arguments'], '{"a":1}');
  });

  test('buildOpenAiToolsSchema：name/description/parameters 三件套', () {
    final tool = ToolDefinition(
      name: 'get_time',
      description: '取当前时间',
      parameters: {'type': 'object', 'properties': const {}},
      execute: (_) async => const ToolResult(content: ''),
    );
    final schema = buildOpenAiToolsSchema([tool]);
    expect(schema.length, 1);
    expect(schema[0]['type'], 'function');
    expect(schema[0]['function']['name'], 'get_time');
    expect(schema[0]['function']['parameters'], isA<Map>());
  });

  // -------------------------------------------------------------------------
  // 流式分片组装器
  // -------------------------------------------------------------------------

  test('OpenAiNativeStreamAssembler：分片 arguments 拼齐后整体解码', () {
    final a = OpenAiNativeStreamAssembler();
    a.addEvent({'type': 'text', 'text': '我来查一下。'});
    a.addEvent({
      'type': 'tool_call',
      'index': 0,
      'id': 'call_a',
      'name': 'web_search',
    });
    a.addEvent({'type': 'tool_call', 'index': 0, 'argumentsFragment': '{"qu'});
    a.addEvent({
      'type': 'tool_call',
      'index': 0,
      'argumentsFragment': 'ery": "今天天气"}',
    });
    a.addEvent({'type': 'finish', 'reason': 'tool_calls'});
    final r = a.finalize();
    expect(r.text, '我来查一下。');
    expect(r.calls.length, 1);
    expect(r.calls[0].id, 'call_a');
    expect(r.calls[0].name, 'web_search');
    expect(r.calls[0].arguments, {'query': '今天天气'});
  });

  test('OpenAiNativeStreamAssembler：多调用按 index 序，缺 id 兜底', () {
    final a = OpenAiNativeStreamAssembler();
    a.addEvent({'type': 'tool_call', 'index': 1, 'id': 'b', 'name': 't2'});
    a.addEvent({'type': 'tool_call', 'index': 0, 'name': 't1'});
    final r = a.finalize();
    expect(r.calls.length, 2);
    expect(r.calls[0].name, 't1'); // index 0 在前
    expect(r.calls[0].arguments, const {});
    expect(r.calls[0].id, isNotEmpty); // 兜底 id
    expect(r.calls[1].id, 'b');
  });

  test('OpenAiNativeStreamAssembler：坏 JSON arguments → null（交必填校验）', () {
    final a = OpenAiNativeStreamAssembler();
    a.addEvent({'type': 'tool_call', 'index': 0, 'id': 'x', 'name': 't'});
    a.addEvent({'type': 'tool_call', 'index': 0, 'argumentsFragment': '{bad'});
    expect(a.finalize().calls[0].arguments, isNull);
  });

  // -------------------------------------------------------------------------
  // 失败分档（4xx 永久 / 429·5xx 瞬态 / 空响应）
  // -------------------------------------------------------------------------

  test('mapApiStatus：429→限流，5xx→服务端，4xx→invalidRequest', () {
    final adapter = _TestAdapter(protocol: PromptJsonProtocol());
    expect(adapter.mapApiStatus(429), LlmFailureCode.rateLimit);
    expect(adapter.mapApiStatus(500), LlmFailureCode.server);
    expect(adapter.mapApiStatus(400), LlmFailureCode.invalidRequest);
    expect(adapter.mapApiStatus(401), LlmFailureCode.invalidRequest);
    expect(adapter.mapApiStatus(null), LlmFailureCode.transport);
  });

  test('mapApiError：badResponse 按 HTTP 状态分档', () {
    final adapter = _TestAdapter(protocol: PromptJsonProtocol());
    final req = RequestOptions(path: '/');
    final e400 = DioException(
      requestOptions: req,
      type: DioExceptionType.badResponse,
      response: Response(requestOptions: req, statusCode: 400),
    );
    expect(adapter.mapApiError(e400), LlmFailureCode.invalidRequest);
    final eTimeout = DioException(
      requestOptions: req,
      type: DioExceptionType.receiveTimeout,
    );
    expect(adapter.mapApiError(eTimeout), LlmFailureCode.timeout);
  });

  test('mapApiStatus：4xx 文案命中上下文溢出 → contextWindowExceeded', () {
    final adapter = _TestAdapter(protocol: PromptJsonProtocol());
    // OpenAI 官方文案
    expect(
      adapter.mapApiStatus(
        400,
        message: "This model's maximum context length is 65536 tokens. "
            'However, you requested 70000 tokens in the messages.',
      ),
      LlmFailureCode.contextWindowExceeded,
    );
    // DeepSeek 常见措辞 + 响应体前缀（_describeApiError 拼接形态）
    expect(
      adapter.mapApiStatus(
        400,
        message: '服务端返回异常（HTTP 400）：| 响应体: '
            'context_length_exceeded: the last request exceeds the '
            'available context length',
      ),
      LlmFailureCode.contextWindowExceeded,
    );
    // 中文端点文案
    expect(
      adapter.mapApiStatus(400, message: '输入长度超出上下文长度限制'),
      LlmFailureCode.contextWindowExceeded,
    );
    // prompt is too long（Claude 兼容层）
    expect(
      adapter.mapApiStatus(
          400, message: 'Your prompt is too long: 210000 tokens > 200000'),
      LlmFailureCode.contextWindowExceeded,
    );
    // 非溢出 4xx 文案仍是 invalidRequest（宁可窄勿宽）
    expect(
      adapter.mapApiStatus(400, message: 'Invalid parameter: max_tokens'),
      LlmFailureCode.invalidRequest,
    );
    expect(
      adapter.mapApiStatus(401, message: 'Invalid API key'),
      LlmFailureCode.invalidRequest,
    );
    // 溢出码不进 llm-retry（由失败瀑布 compaction 步处理）
    const overflow = LlmFailure(
        code: LlmFailureCode.contextWindowExceeded, message: 'context length');
    expect(
        LlmRetry(maxRetries: 5, retryEmptyResponse: true)
            .isRetryable(overflow),
        isFalse);
  });

  test('LlmRetry：invalidRequest 永不重试；空响应按路线开关', () {
    final local = LlmRetry(maxRetries: 3);
    final api = LlmRetry(maxRetries: 5, retryEmptyResponse: true);
    final bad = const LlmFailure(
        code: LlmFailureCode.invalidRequest, message: 'HTTP 400');
    final empty = const LlmFailure(
        code: LlmFailureCode.emptyResponse, message: '空响应');
    expect(local.isRetryable(bad), isFalse);
    expect(api.isRetryable(bad), isFalse);
    expect(local.isRetryable(empty), isFalse);
    expect(api.isRetryable(empty), isTrue);
  });

  test('parseAndReturn：空响应 fail-loud（不再静默存空白消息）', () async {
    final adapter = _TestAdapter(protocol: PromptJsonProtocol());
    await expectLater(
      adapter.parseAndReturn(StringBuffer('  '), AgentStreamProcessor()),
      throwsA(isA<LlmFailure>()
          .having((f) => f.code, 'code', LlmFailureCode.emptyResponse)),
    );
    // 非空文本正常返回。
    final ok = await adapter.parseAndReturn(
        StringBuffer('你好'), AgentStreamProcessor());
    expect(ok.text, '你好');
  });

  // -------------------------------------------------------------------------
  // 压缩死循环修复：溢出 + 无可裁内容 → turn 终态 error（而非无限重试）
  // -------------------------------------------------------------------------

  test('上下文溢出且压缩无前进 → turn 以 error 终止，不再无限重试', () async {
    final session = SessionLog.fromEvents([]);
    session.append(kEventSystemMessage, {'content': 'sys'},
        source: const {'kind': 'system'});
    session.append(kEventUserMessage, {'content': '早期消息'},
        source: const {'kind': 'user'});
    final adapter = _OverflowAdapter();
    final agent = ReactLoopAgent(
      session: session,
      adapter: adapter,
      registry: ToolRegistry(),
      config: const AgentConfig(maxStepsPerTurn: 3),
      modelId: 'm',
      providerKind: ProviderKind.local,
      systemPrompt: 'sys',
      compaction: DeterministicCompaction(), // 单轮会话：无旧工具结果可裁
    );
    final reason = await agent.kick('再来一条');
    expect(reason.kind, TurnEndReasonKind.error);
    // 修复前：compaction 恒 success → 无限重试（calls 不收敛）。
    expect(adapter.calls, 1);
  });
}
