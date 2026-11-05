// 阶段 1（数据类型化）钉子测试：MessageKind 推断 / ToolActivityData 往返 /
// turnTrace 信封往返 / 旧前缀行读取推断。
import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:wangcai/models/chat_message.dart';
import 'package:wangcai/models/turn_trace.dart';

void main() {
  group('MessageKind 类型化（2026-10-25 对话区重构 P0）', () {
    test('新消息：kind/toolData 序列化往返', () {
      final m = ChatMessage(
        id: 'm1',
        conversationId: 'c1',
        role: MessageRole.assistant,
        content: '🔧 file_write ✓已写入',
        kind: MessageKind.toolActivity,
        toolData: const ToolActivityData(
          phase: 'done',
          name: 'file_write',
          summary: '已写入',
          argsJson: '{"path":"/a.txt"}',
          resultText: 'ok',
          durationMs: 120,
        ),
      );
      final back = ChatMessage.fromMap(m.toMap());
      expect(back.kind, MessageKind.toolActivity);
      expect(back.toolData?.name, 'file_write');
      expect(back.toolData?.phase, 'done');
      expect(back.toolData?.durationMs, 120);
      expect(back.toolData?.isError, isFalse);
    });

    test('旧 DB 行：kind 列缺失 → 按前缀推断（🔧/💭/🔧TRACE）', () {
      final raw = {
        'id': 'm2',
        'conversationId': 'c1',
        'role': 'assistant',
        'content': '💭 一些思考',
        'timestamp': 0,
      };
      expect(ChatMessage.fromMap(raw).kind, MessageKind.thinking);

      final raw2 = Map<String, dynamic>.from(raw)
        ..['content'] = '🔧 web_search ✓结果…';
      expect(ChatMessage.fromMap(raw2).kind, MessageKind.toolActivity);

      final raw3 = Map<String, dynamic>.from(raw)
        ..['content'] = '🔧TRACE{"v":1}';
      expect(ChatMessage.fromMap(raw3).kind, MessageKind.notice);

      final raw4 = Map<String, dynamic>.from(raw)
        ..['content'] = '普通回答文本';
      expect(ChatMessage.fromMap(raw4).kind, MessageKind.text);
    });

    test('toolData 存在但 kind 缺省 → toolActivity（resolveKind 规则）', () {
      expect(
        ChatMessage.resolveKind(
            stored: null, toolData: const ToolActivityData(phase: 'done', name: 'x'), content: ''),
        MessageKind.toolActivity,
      );
      expect(
        ChatMessage.resolveKind(
            stored: MessageKind.notice, toolData: null, content: ''),
        MessageKind.notice,
      );
    });

    test('用户消息以 🔧 开头不受前缀推断影响（kind 显式 text）', () {
      final m = ChatMessage(
        id: 'm3',
        conversationId: 'c1',
        role: MessageRole.user,
        content: '🔧 是什么意思？',
        kind: MessageKind.text,
      );
      expect(m.kind, MessageKind.text);
      final back = ChatMessage.fromMap(m.toMap());
      // kind 列已写 'text' → 不走前缀推断。
      expect(back.kind, MessageKind.text);
    });
  });

  group('turnTrace UI 信封', () {
    test('encode/decode 往返保持顺序与类型', () {
      final items = [
        const TurnUiItem.think('先想一下'),
        const TurnUiItem.tool('agent_tool_1'),
        const TurnUiItem.think('再想一下'),
        const TurnUiItem.tool('agent_tool_2'),
        TurnUiItem.error('本轮执行失败'),
      ];
      final encoded = encodeTurnUiTrace(items);
      expect(encoded, isNotNull);
      final decoded = decodeTurnUiTrace(encoded!);
      expect(decoded, isNotNull);
      expect(decoded!.length, 5);
      expect(decoded[0].type, 'think');
      expect(decoded[0].text, '先想一下');
      expect(decoded[1].type, 'tool');
      expect(decoded[1].toolId, 'agent_tool_1');
      expect(decoded[4].type, 'error');
    });

    test('空 items 不落库；非法 JSON 回退 null', () {
      expect(encodeTurnUiTrace(const []), isNull);
      expect(decodeTurnUiTrace('not json'), isNull);
      expect(decodeTurnUiTrace('{"v":1,"items":"bad"}'), isNull);
    });
  });
}
