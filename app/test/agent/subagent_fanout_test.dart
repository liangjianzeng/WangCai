/// P2-C 子代理 fan-out 测试：tasks 数组一次派发多个后台子代理。
import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:tongyi_lite/agent/builtin_tools/builtin_tools.dart';
import 'package:tongyi_lite/agent/llm/adapter.dart';
import 'package:tongyi_lite/agent/subagents/in_process.dart';
import 'package:tongyi_lite/agent/subagents/subagent_tool.dart';
import 'package:tongyi_lite/agent/session/session.dart';
import 'package:tongyi_lite/agent/tool_registry.dart';

final class _FakeAdapter extends LlmAdapter {
  int _calls = 0;
  @override
  Future<LlmResult> generate(
    GenerateOptions options, {
    StreamController<String>? onToken,
    StreamController<String>? onThinking,
    Completer<void>? cancel,
  }) async {
    _calls++;
    return LlmResult(text: '子任务结果 #$_calls');
  }

  @override
  void cancel() {}

  @override
  PreparedLlmCall prepareCall(String model) =>
      PreparedLlmCall(adapter: this, model: model);
}

(InProcessSubagentProvider, ToolRegistry) _build() {
  final registry = ToolRegistry();
  for (final tool in createBuiltinTools()) {
    registry.register(tool);
  }
  final provider = InProcessSubagentProvider(
    adapter: _FakeAdapter(),
    registry: registry,
    modelId: 'test-model',
    providerKind: ProviderKind.local,
    systemPrompt: '系统提示',
    parentSession: SessionLog.fromEvents(const []),
  );
  return (provider, registry);
}

void main() {
  test('fan-out：2~4 个任务全部后台启动，返回 id 列表，完成逐个通知',
      () async {
    final (provider, _) = _build();
    final notices = <String>[];
    final tool = createSubagentTool(provider,
        onBackgroundDone: notices.add);

    final r = await tool.execute({
      'tasks': ['任务 A：调研 X', '任务 B：调研 Y', '任务 C：调研 Z'],
    });
    expect(r.isError, isFalse);
    expect(r.content, contains('3 个后台子代理'));
    expect(r.content, contains('任务 A'));
    // 每个任务一个完成通知（等待后台完成）。
    await Future.delayed(const Duration(milliseconds: 50));
    expect(notices.length, 3);
    for (final n in notices) {
      expect(n, contains('后台子代理已完成'));
      expect(n, contains('子任务结果'));
    }
  });

  test('fan-out：单任务/超 4 个 → 明确报错', () async {
    final (provider, _) = _build();
    final tool = createSubagentTool(provider);
    final r1 = await tool.execute({
      'tasks': ['只有一个'],
    });
    expect(r1.isError, isTrue);
    expect(r1.content, contains('至少 2 个'));
    final r2 = await tool.execute({
      'tasks': ['1', '2', '3', '4', '5'],
    });
    expect(r2.isError, isTrue);
    expect(r2.content, contains('最多 4 个'));
  });

  test('单 task 路径不受影响（回归）', () async {
    final (provider, _) = _build();
    final tool = createSubagentTool(provider);
    final r = await tool.execute({
      'task': '单任务',
      'run_in_background': true,
    });
    expect(r.isError, isFalse);
    expect(r.content, contains('已在后台启动子代理'));
  });
}
