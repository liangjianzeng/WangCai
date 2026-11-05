/// 回合 UI 过程信封（2026-10-25 对话区重构 P0，turnTrace）。
///
/// turn 结束时把 live 事件流的 **真实交错顺序**（思考/工具/错误/通知）
/// 序列化成一条 notice 消息落库（kind=notice, noticeCode='turnTrace'）。
/// 历史回合渲染解析信封走与 live 完全相同的组件管线——根治"历史回合
/// 丢失执行顺序"（💭 靠 timestamp-3ms 造序、工具/思考分列表拼接的旧法退役）。
///
/// 信封不入模型上下文（与 🔧/💭 同规则）；模型侧的轨迹还原信封
/// （🔧TRACE，encodeAgentTraceMessage）是另一条独立机制，互不影响。
library;

import 'dart:convert';

/// 单个 UI 过程项。
///
/// - `think`：思考存档块，[text] = 全文（不引用消息，历史思考不再单独落库）。
/// - `tool`：工具活动，[toolId] = 对应 🔧 消息 id（渲染时查同回合消息）。
/// - `error`：回合错误行，[text] = 错误文案。
/// - `notice`：系统通知行（steer 注入等），[text] = 文案。
class TurnUiItem {
  final String type; // think | tool | error | notice
  final String? toolId;
  final String? text;

  const TurnUiItem.think(this.text)
      : type = 'think',
        toolId = null;
  const TurnUiItem.tool(this.toolId)
      : type = 'tool',
        text = null;
  const TurnUiItem.error(this.text)
      : type = 'error',
        toolId = null;
  const TurnUiItem.notice(this.text)
      : type = 'notice',
        toolId = null;

  Map<String, dynamic> toMap() => {'type': type, 'toolId': toolId, 'text': text};

  static TurnUiItem? fromMap(Map<String, dynamic> map) {
    final type = map['type'] as String?;
    final toolId = map['toolId'] as String?;
    final text = map['text'] as String?;
    switch (type) {
      case 'think':
        return text == null ? null : TurnUiItem.think(text);
      case 'tool':
        return toolId == null ? null : TurnUiItem.tool(toolId);
      case 'error':
        return text == null ? null : TurnUiItem.error(text);
      case 'notice':
        return text == null ? null : TurnUiItem.notice(text);
    }
    return null;
  }
}

/// 编码信封 content（JSON 字符串）；items 为空返回 null（不落库）。
String? encodeTurnUiTrace(List<TurnUiItem> items) {
  if (items.isEmpty) return null;
  return jsonEncode({'v': 1, 'items': [for (final i in items) i.toMap()]});
}

/// 解析信封 content；非法/空返回 null（调用方回退旧重排路径）。
List<TurnUiItem>? decodeTurnUiTrace(String content) {
  try {
    final decoded = jsonDecode(content);
    if (decoded is! Map<String, dynamic>) return null;
    final raw = decoded['items'];
    if (raw is! List) return null;
    final items = <TurnUiItem>[];
    for (final e in raw) {
      if (e is Map<String, dynamic>) {
        final item = TurnUiItem.fromMap(e);
        if (item != null) items.add(item);
      }
    }
    return items;
  } catch (_) {
    return null;
  }
}
