/// 协议选择器 —— 按引擎能力自动选择最合适的工具协议。
///
/// 选择规则（参照 DSH 设计思路）：
/// ```
/// protocol_selector.select(caps):
///   1. caps.nativeToolCall         → native-tools 协议（API 天然可用；本地原生改造后自动切换）
///   2. caps.structuredOutput       → grammar/结构化约束 JSON 协议（预留）
///   3. 默认                         → prompt-JSON 文本协议（当前本地引擎的兜底）
/// ```
/// 实现为：过滤 supports(caps) 为真的协议，按 priority 降序取第一个。
/// 因此协议的 priority 声明即"原生 > 结构化 > JSON 文本"的顺序来源。
library;

import '../capability.dart';
import 'tool_protocol.dart';

/// 从候选协议中为给定能力选择最合适的一个。
///
/// [protocols] 空时抛异常（调用方应至少注册一个兜底协议如 prompt-json）。
ToolProtocol selectProtocol(
  List<ToolProtocol> protocols,
  EngineCapabilities caps,
) {
  if (protocols.isEmpty) {
    throw ArgumentError('selectProtocol: no protocols registered');
  }
  final candidates = protocols.where((p) => p.supports(caps)).toList()
    ..sort((a, b) => b.priority(caps).compareTo(a.priority(caps)));
  if (candidates.isEmpty) {
    throw StateError(
        'selectProtocol: no protocol supports capabilities $caps');
  }
  return candidates.first;
}
