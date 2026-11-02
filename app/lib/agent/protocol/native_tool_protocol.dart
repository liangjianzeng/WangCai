/// 原生工具调用协议 —— OpenAI 兼容 API 的 `tools` 请求体 + `tool_calls` 响应。
///
/// 与 prompt-json（文本协议）的本质差异：
/// - 提示侧：工具以 function schema 走请求体 `tools` 字段，**不注入 system
///   文本**（[buildToolSection] 返回空）；
/// - 生成侧：工具调用是结构化 `delta.tool_calls` 分片，由 adapter 在流式
///   阶段直接组装（不走文本解析），根治端侧文本协议的"解析降级/截断/
///   思考内容污染"三件套。
///
/// 模型是否走本协议由 [EngineCapabilities.nativeToolCall] 驱动
/// （`selectProtocol` 按 priority 选择：原生 > 文本兜底）。
library;

import '../capability.dart';
import '../tool_registry.dart';
import 'tool_protocol.dart';

/// 原生工具调用协议（OpenAI function calling）。
class NativeToolProtocol implements ToolProtocol {
  static const String kId = 'native-tools';

  @override
  String get id => kId;

  /// 仅当能力声明原生工具调用时可用（API 路线由静态声明给出；
  /// 本地引擎原生改造后运行时探测上报即自动切换）。
  @override
  bool supports(EngineCapabilities caps) => caps.nativeToolCall;

  /// 最高优先级：原生结构化协议存在时压过一切文本协议。
  @override
  int priority(EngineCapabilities caps) => 100;

  /// 工具走请求体 `tools` 字段，system 不注入工具段。
  @override
  String buildToolSection(ToolRegistry registry, {String modelId = ''}) => '';

  /// 原生路线的工具调用在 adapter 流式阶段按结构化分片组装，
  /// 不从文本解析。本实现仅做文本透传（防御性兜底，正常不应被走到）。
  @override
  Future<StreamOutcome> parseStream(Stream<String> stream) async {
    final buffer = StringBuffer();
    await for (final token in stream) {
      if (token.isNotEmpty) buffer.write(token);
    }
    return StreamOutcome(text: buffer.toString());
  }
}
