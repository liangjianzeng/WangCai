import 'package:tongyi_lite/providers/agent_stream_processor.dart';
import 'package:flutter_test/flutter_test.dart';

// ---------------------------------------------------------------------------
// WP5：工具调用参数生成期进度（toolGen* getters）
// ---------------------------------------------------------------------------

void main() {
  test('JSON 试探期：toolGenActive + 字符数 + 预览', () {
    final p = AgentStreamProcessor();
    expect(p.toolGenActive, isFalse);
    p.add('我把报告写进文件 {"tool_call": {"name": "write_file", ');
    expect(p.toolGenActive, isTrue);
    expect(p.toolGenChars, greaterThan(0));
    expect(p.toolGenPreview, isNotEmpty);
    final before = p.toolGenChars;
    p.add('"arguments": {"path": "report.html", "content": "......."');
    expect(p.toolGenChars, greaterThan(before));
  });

  test('XML 工具块期：toolGenActive + 字符数增长', () {
    final p = AgentStreamProcessor();
    p.add('<tool_call>write_file<arg_key>path<arg_value>report.html');
    expect(p.toolGenActive, isTrue);
    expect(p.toolGenChars, greaterThan(10));
    // 闭合后退出生成态
    p.add('</arg_value></tool_call>');
    expect(p.toolGenActive, isFalse);
  });

  test('普通文本：不触发 toolGen（无花括号即无试探）', () {
    final p = AgentStreamProcessor();
    p.add('这是普通回答，不含花括号，不进试探态。');
    expect(p.toolGenActive, isFalse);
  });

  test('MiniCPM5 特殊标记：可见流不漏标记，clean 归一化为 <tool_call>', () {
    final p = AgentStreamProcessor();
    p.add('好的，我来查时间。<|tool_call_start|>get_time<|tool_call_end|>');
    expect(p.visibleText, contains('好的，我来查时间'));
    expect(p.visibleText, isNot(contains('tool_call')));
    expect(p.cleanText, contains('<tool_call>get_time</tool_call>'));
    expect(p.toolXmlBlocks.single, '<tool_call>get_time</tool_call>');
  });

  test('MiniCPM5 特殊标记内嵌 JSON：clean 归一化后收块完整', () {
    final p = AgentStreamProcessor();
    p.add('<|tool_call_start|>{"name": "get_weather", '
        '"arguments": {"city": "南宁"}}<|tool_call_end|>');
    expect(p.visibleText, isNot(contains('tool_call')));
    expect(p.cleanText, contains('<tool_call>{"name"'));
    expect(p.toolXmlBlocks.single, contains('</tool_call>'));
  });
}
