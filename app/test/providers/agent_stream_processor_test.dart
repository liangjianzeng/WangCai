import 'package:flutter_test/flutter_test.dart';

import 'package:tongyi_lite/providers/agent_stream_processor.dart';

void main() {
  group('AgentStreamProcessor', () {
    test('普通文本全部可见', () {
      final p = AgentStreamProcessor();
      p.add('你好');
      p.add('，世界！');
      expect(p.visibleText, '你好，世界！');
      expect(p.hasToolCalls, isFalse);
    });

    test('thinking 块被丢弃', () {
      final p = AgentStreamProcessor();
      p.add('先思考<think');
      p.add('ing>这是推理过程</thinking>');
      p.add('然后回答');
      expect(p.visibleText, '先思考然后回答');
      expect(p.visibleText.contains('推理过程'), isFalse);
    });

    test('跨 token 的 thinking 标签正确组装', () {
      final p = AgentStreamProcessor();
      p.add('前缀<');
      p.add('thinking');
      p.add('>');
      p.add('推理');
      p.add('</');
      p.add('thinking>');
      p.add('答案');
      expect(p.visibleText, '前缀答案');
    });

    test('Qwen 风格 thinking... response 块被丢弃', () {
      final p = AgentStreamProcessor();
      p.add('先思考 thinking');
      p.add('\n\n推理过程');
      p.add(' response');
      p.add('\n\n然后回答');
      expect(p.visibleText, '先思考\n\n然后回答');
      expect(p.visibleText.contains('推理过程'), isFalse);
    });

    test('Qwen 风格跨 token 组装', () {
      final p = AgentStreamProcessor();
      p.add('前 think');
      p.add('ing');
      p.add('推理');
      p.add(' resp');
      p.add('onse');
      p.add('答案');
      expect(p.visibleText, '前答案');
    });

    test('thinkingActive 状态暴露', () {
      final p = AgentStreamProcessor();
      p.add('<thinking>');
      expect(p.thinkingActive, isTrue);
      p.add('推理中</thinking>');
      expect(p.thinkingActive, isFalse);
    });

    test('HTML 变体 thinking（不带 ing）块被丢弃（Qwen3.5 实际输出）', () {
      final p = AgentStreamProcessor();
      p.add('前缀 think');
      p.add('\n\n推理内容');
      p.add(' response');
      p.add('\n\n回答');
      expect(p.visibleText, '前缀\n\n回答');
      expect(p.visibleText.contains('推理内容'), isFalse);
    });

    test('空 thinking 块（think + response）被丢弃', () {
      final p = AgentStreamProcessor();
      p.add('前缀 think');
      p.add(' response');
      p.add('\n\n直接回答');
      expect(p.visibleText, '前缀\n\n直接回答');
      expect(p.visibleText.contains('think'), isFalse);
    });

    test('孤立 response 闭合记号（无前置 think）→ 隐式 opener，续写丢弃', () {
      final p = AgentStreamProcessor();
      p.add('先思考 think');
      p.add('\n\n推理一');
      p.add(' response');
      p.add('\n\n回答一');
      // 模型再输出一个无前置 opener 的 ` response`——提前闭合的思考续写。
      // 当作隐式 opener 重新进入思考态，续写一并丢弃（不渗进可见回答）。
      p.add(' response');
      p.add('这段泄漏的续写会一直持续');
      expect(p.visibleText, '先思考\n\n回答一');
      expect(p.thinkingActive, isTrue);
      p.finish(); // EOS：未闭合思考块整体丢弃
      expect(p.visibleText, '先思考\n\n回答一');
    });

    test('英文词 response（如 API response）不误吞', () {
      final p = AgentStreamProcessor();
      p.add('服务返回的 API response 是 200');
      expect(p.visibleText, '服务返回的 API response 是 200');
      expect(p.thinkingActive, isFalse);
    });

    test('XML tool_call 块隐藏并记录', () {
      final p = AgentStreamProcessor();
      p.add('前缀<tool_call>web_search');
      p.add('<arg_key>q<arg_value>今天天气</tool_call>');
      p.add('后缀');
      expect(p.visibleText, '前缀后缀');
      expect(p.hasToolCalls, isTrue);
      expect(p.toolXmlBlocks, hasLength(1));
      expect(p.toolXmlBlocks.single, contains('web_search'));
    });

    test('XML 工具块跨 token 组装', () {
      final p = AgentStreamProcessor();
      p.add('<tool_');
      p.add('call>get_time</tool_call>');
      expect(p.hasToolCalls, isTrue);
      expect(p.visibleText, isEmpty);
    });

    test('XML 未闭合 → finish 后按普通文本显示', () {
      final p = AgentStreamProcessor();
      p.add('<tool_call>get_time');
      expect(p.hasToolCalls, isFalse);
      p.finish();
      expect(p.visibleText, '<tool_call>get_time');
    });

    test('完整工具 JSON 被隐藏并解析', () {
      final p = AgentStreamProcessor();
      p.add('{"tool_call": {"name": "get_time", "arguments": {}}}');
      expect(p.visibleText, isEmpty);
      expect(p.hasToolCalls, isTrue);
      expect(p.toolJsonBlocks.single['tool_call'], isA<Map>());
    });

    test('跨 token 的工具 JSON 正确组装', () {
      final p = AgentStreamProcessor();
      p.add('{"tool_');
      p.add('call": {"name": "calculator", "arguments": {"expression": "1+1"}}}');
      expect(p.hasToolCalls, isTrue);
      final call = p.toolJsonBlocks.single['tool_call'] as Map;
      expect(call['name'], 'calculator');
    });

    test('非工具 JSON 按普通文本显示', () {
      final p = AgentStreamProcessor();
      p.add('结果是 {"count": 3} 个');
      expect(p.visibleText, '结果是 {"count": 3} 个');
      expect(p.hasToolCalls, isFalse);
    });

    test('非法 JSON（字符串内花括号）不误判', () {
      final p = AgentStreamProcessor();
      // '}' 出现在字符串内导致解析失败 → 按普通文本显示。
      p.add('{"msg": "a}b"}');
      expect(p.visibleText, '{"msg": "a}b"}');
      expect(p.hasToolCalls, isFalse);
    });

    test('工具 JSON 前后文本保留', () {
      final p = AgentStreamProcessor();
      p.add('让我查一下\n');
      p.add('{"tool_call": {"name": "get_time", "arguments": {}}}');
      expect(p.visibleText, '让我查一下\n');
      expect(p.hasToolCalls, isTrue);
    });

    test('试探过长放弃（按普通文本显示）', () {
      final p = AgentStreamProcessor();
      p.add('{');
      p.add('这是很长的普通文本' * 300); // 超过 probeMaxLen
      expect(p.visibleText, startsWith('{'));
      expect(p.hasToolCalls, isFalse);
    });

    test('thinking 内出现 JSON 不影响（整体丢弃）', () {
      final p = AgentStreamProcessor();
      p.add('<thinking>{"tool_call": {"name": "x", "arguments": {}}}</thinking>');
      p.add('回答');
      expect(p.visibleText, '回答');
      expect(p.hasToolCalls, isFalse);
    });
  });
}
