import 'dart:async';

import 'package:tongyi_lite/agent/llm/adapter.dart';

/// 脚本化 LLM 测试桩（全测试共享，2026-09-30 审查 P0-3：此前 4 份复制且
/// 行为漂移——本类统一）。
///
/// 按 [script] 顺序消费：[LlmResult] 正常返回、[LlmFailure] 抛出；
/// 脚本耗尽后抛 `LlmFailure(timeout)`（fail-loud，不静默兜底）。
/// 记录字段：[calls]/[lastMessages]/[allMessages]/[allOptions]。
class FakeLlmAdapter implements LlmAdapter {
  final List<Object> _script;
  int _index = 0;

  int calls = 0;
  List<Map<String, dynamic>>? lastMessages;
  final List<List<Map<String, dynamic>>> allMessages = [];
  final List<GenerateOptions> allOptions = [];

  FakeLlmAdapter(List<Object> script) : _script = script;

  @override
  Future<LlmResult> generate(
    GenerateOptions options, {
    StreamController<String>? onToken,
    StreamController<String>? onThinking,
    Completer<void>? cancel,
  }) async {
    calls++;
    allOptions.add(options);
    lastMessages = options.messages;
    allMessages.add(options.messages);
    final item = _index < _script.length ? _script[_index++] : null;
    if (item == null) {
      throw LlmFailure(
          code: LlmFailureCode.timeout,
          message: 'script exhausted (call #$calls)');
    }
    if (item is LlmFailure) throw item;
    return item as LlmResult;
  }

  @override
  void cancel() {}

  @override
  PreparedLlmCall prepareCall(String model) =>
      PreparedLlmCall(adapter: this, model: model);
}
