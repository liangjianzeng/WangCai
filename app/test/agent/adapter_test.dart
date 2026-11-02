import 'dart:async';

import 'package:tongyi_lite/agent/capability.dart';
import 'package:tongyi_lite/agent/llm/adapter.dart';
import 'package:tongyi_lite/agent/llm/base_engine_adapter.dart';
import 'package:tongyi_lite/agent/protocol/prompt_json_protocol.dart';
import 'package:tongyi_lite/agent/protocol/protocol_selector.dart';
import 'package:tongyi_lite/agent/protocol/tool_protocol.dart';
import 'package:tongyi_lite/agent/tool_registry.dart';
import 'package:flutter_test/flutter_test.dart';

/// 覆写 prepareCall 的桩（仿 [BaseEngineAdapter]，注入能力快照）。
class _CapsAdapter extends LlmAdapter {
  final EngineCapabilities? _caps;
  _CapsAdapter(this._caps);

  @override
  Future<LlmResult> generate(
    GenerateOptions options, {
    StreamController<String>? onToken,
    StreamController<String>? onThinking,
    Completer<void>? cancel,
  }) async => const LlmResult(text: 'ok');

  @override
  PreparedLlmCall prepareCall(String model) =>
      PreparedLlmCall(adapter: this, model: model, capabilities: _caps);
}

/// 不覆写 prepareCall 的桩（走 [LlmAdapter] 默认实现：仅 adapter + model）。
class _PlainAdapter extends LlmAdapter {
  @override
  Future<LlmResult> generate(
    GenerateOptions options, {
    StreamController<String>? onToken,
    StreamController<String>? onThinking,
    Completer<void>? cancel,
  }) async => const LlmResult(text: 'ok');
}

void main() {
  convertEngineMessagesTests();
  test('prepareCall：覆写版固化能力快照（adapter + model + capabilities）', () {
    final caps = EngineCapabilities(
      nativeToolCall: false,
      toolTemplate: 'spark-xml',
      maxParallelToolCalls: 4,
    );
    final adapter = _CapsAdapter(caps);
    final call = adapter.prepareCall('qwen3.5-4b');
    expect(call.adapter, adapter);
    expect(call.model, 'qwen3.5-4b');
    expect(call.capabilities, caps);
  });

  test('prepareCall（默认）：不覆写时仅 adapter + model，capabilities=null', () {
    final adapter = _PlainAdapter();
    final call = adapter.prepareCall('m1');
    expect(call.adapter, adapter);
    expect(call.model, 'm1');
    expect(call.capabilities, null);
  });

  test('EngineCapabilities.resolve：probed 事实优先，缺失字段回退 declared', () {
    final declared = EngineCapabilities(
      nativeToolCall: true, // 预期（静态声明）
      structuredOutput: true, // 预期
      toolTemplate: 'spark-xml',
    );
    final probed = EngineCapabilities(
      nativeToolCall: false, // 事实（引擎上报：实际不支持）
      structuredOutput: false, // 事实
      // toolTemplate 缺失 → 回退 declared
    );
    final resolved = EngineCapabilities.resolve(declared: declared, probed: probed);
    expect(resolved.nativeToolCall, false);
    expect(resolved.structuredOutput, false);
    expect(resolved.toolTemplate, 'spark-xml');
  });

  test('EngineCapabilities.resolve：无 probed → 纯 declared', () {
    final declared = const EngineCapabilities(
      nativeToolCall: true,
      toolTemplate: 'openai',
    );
    final resolved = EngineCapabilities.resolve(declared: declared, probed: null);
    expect(resolved.nativeToolCall, true);
    expect(resolved.toolTemplate, 'openai');
  });

  test('selectProtocol：至少一个候选时返回最优先级（此处唯一 prompt-json）', () {
    final protocol = selectProtocol(
      [PromptJsonProtocol()],
      const EngineCapabilities(),
    );
    expect(protocol.id, isNot(null));
    final byNative = selectProtocol(
      [PromptJsonProtocol()],
      const EngineCapabilities(nativeToolCall: true),
    );
    expect(byNative.id, protocol.id);
    expect(byNative.supports(const EngineCapabilities(nativeToolCall: true)), true);
  });

  test('selectProtocol：空候选抛 ArgumentError', () {
    expect(
      () => selectProtocol(<PromptJsonProtocol>[], const EngineCapabilities()),
      throwsArgumentError,
    );
  });

  test('selectProtocol：无协议 supports 时抛 StateError', () {
    final noSupport = _NoSupportProtocol();
    expect(
      () => selectProtocol([noSupport], const EngineCapabilities(nativeToolCall: true)),
      throwsStateError,
    );
  });
}

/// 对任何能力都不支持的协议（验证 StateError 路径）。
class _NoSupportProtocol implements ToolProtocol {
  @override
  String get id => 'no-support';

  @override
  bool supports(EngineCapabilities caps) => false;

  @override
  int priority(EngineCapabilities caps) => 0;

  @override
  String buildToolSection(ToolRegistry registry, {String modelId = ''}) => '';

  @override
  Future<StreamOutcome> parseStream(Stream<String> stream) async =>
      const StreamOutcome(text: '');
}

/// BaseEngineAdapter 具体桩：仅复用 [BaseEngineAdapter.convertEngineMessages]
/// （generate 沿用基类抛 UnimplementedError，本组测试不触发生成）。
class _EngineAdapter extends BaseEngineAdapter {
  _EngineAdapter({required super.protocol, super.capabilities});
}

void convertEngineMessagesTests() {
  final protocol = PromptJsonProtocol();

  List<Map<String, dynamic>> input() => [
        {'role': 'user', 'content': '帮我看下时间'},
        {'role': 'assistant', 'content': '我来查一下'},
        {'role': 'tool', 'content': '2026-10-14 12:00:00'},
      ];

  test('convertEngineMessages：默认（无能力快照）tool→user', () {
    final adapter = _EngineAdapter(protocol: protocol);
    final out = adapter.convertEngineMessages(input());
    expect(out[2]['role'], 'user');
  });

  test('convertEngineMessages：spark-xml 模板 tool→user（模板不识别 tool 角色）',
      () {
    final adapter = _EngineAdapter(
      protocol: protocol,
      capabilities: const EngineCapabilities(toolTemplate: 'spark-xml'),
    );
    final out = adapter.convertEngineMessages(input());
    expect(out[2]['role'], 'user');
  });

  test('convertEngineMessages：bailing-v3（Ling）模板保留 role:tool'
      '（渲染为 OBSERVATION）', () {
    final adapter = _EngineAdapter(
      protocol: protocol,
      capabilities: const EngineCapabilities(toolTemplate: 'bailing-v3'),
    );
    final out = adapter.convertEngineMessages(input());
    expect(out[2]['role'], 'tool');
    expect(out[2]['content'], '2026-10-14 12:00:00');
  });
}
