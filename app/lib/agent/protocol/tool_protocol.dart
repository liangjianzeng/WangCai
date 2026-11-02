/// 工具协议抽象 —— 协议可插拔的边界。
///
/// 协议决定两件事：
/// 1. **提示侧**：工具以什么形式呈现给模型（注入文本 / 原生 tools 字段）；
/// 2. **生成侧**：如何从模型输出解析工具调用。
///
/// 新协议 = 新增 adapter，循环/存储零改动（能力驱动的核心）。
library;

import '../capability.dart';
import '../tool_definition.dart';
import '../tool_registry.dart';

/// 一次模型生成的解析结果：可见文本 + 解析出的工具调用。
class StreamOutcome {
  /// 可见文本（工具调用之外的输出；无工具调用时即最终回答）。
  final String text;

  /// 解析出的工具调用；空表示模型直接回答。
  final List<ToolCall> toolCalls;

  const StreamOutcome({required this.text, this.toolCalls = const []});

  bool get hasToolCalls => toolCalls.isNotEmpty;
}

/// 工具协议抽象。
abstract class ToolProtocol {
  /// 协议唯一标识（如 `prompt-json` / `native-tools`）。
  String get id;

  /// 该协议是否适配给定能力。
  bool supports(EngineCapabilities caps);

  /// 选择优先级（越大越优先）；仅对 supports 为 true 的协议有意义。
  int priority(EngineCapabilities caps);

  /// 提示侧：把某模型可见的工具渲染为该协议要求的呈现。
  /// 返回空字符串表示工具不注入文本（如原生 tools 协议）。
  String buildToolSection(ToolRegistry registry, {String modelId = ''});

  /// 生成侧：消费模型文本增量流，解析出文本与工具调用。
  Future<StreamOutcome> parseStream(Stream<String> stream);
}
