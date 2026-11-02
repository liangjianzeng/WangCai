import 'package:flutter_test/flutter_test.dart';

import 'package:tongyi_lite/agent/agent.dart';

void main() {
  group('get_time tool', () {
    test('返回当前时间（含日期与星期）', () async {
      final tool = createGetTimeTool();
      final result = await tool.execute(const {});

      expect(result.isError, isFalse);
      // 内容形如 "当前时间：2026-09-02 09:00:00（星期三）"。
      expect(result.content, startsWith('当前时间：'));
      expect(result.content, contains('（星期'));
      expect(result.content, contains('：'));
    });
  });

  group('calculator tool', () {
    test('四则运算求值', () async {
      final tool = createCalculatorTool();
      final result = await tool.execute({'expression': '12*7+3'});
      expect(result.isError, isFalse);
      expect(result.content, '12*7+3 = 87');
    });

    test('括号与小数', () async {
      final tool = createCalculatorTool();
      final result = await tool.execute({'expression': '3.5*(2-1)'});
      expect(result.isError, isFalse);
      expect(result.content, '3.5*(2-1) = 3.5');
    });

    test('一元负号', () async {
      final tool = createCalculatorTool();
      final result = await tool.execute({'expression': '-5+3'});
      expect(result.isError, isFalse);
      expect(result.content, '-5+3 = -2');
    });

    test('非法字符被拒绝（无注入风险）', () async {
      final tool = createCalculatorTool();
      final result = await tool.execute({'expression': '1; rm -rf /'});
      expect(result.isError, isTrue);
      expect(result.content, contains('非法字符'));
    });

    test('除以零被拒绝', () async {
      final tool = createCalculatorTool();
      final result = await tool.execute({'expression': '1/0'});
      expect(result.isError, isTrue);
      expect(result.content, contains('除以零'));
    });

    test('缺少参数 → 错误', () async {
      final tool = createCalculatorTool();
      final result = await tool.execute(const {});
      expect(result.isError, isTrue);
      expect(result.content, contains('expression'));
    });

    test('空表达式 → 错误', () async {
      final tool = createCalculatorTool();
      final result = await tool.execute({'expression': '   '});
      expect(result.isError, isTrue);
      expect(result.content, contains('空表达式'));
    });

    test('括号不匹配 → 错误', () async {
      final tool = createCalculatorTool();
      final result = await tool.execute({'expression': '(1+2'});
      expect(result.isError, isTrue);
      expect(result.content, contains('括号不匹配'));
    });
  });

  group('沙箱升级字段声明（对照 DSH 升级通道）', () {
    test('read_file 声明 sandbox_permissions 与 justification', () {
      final props = createReadFileTool().parameters['properties'] as Map;
      expect(props['sandbox_permissions'], isNotNull);
      expect(props['justification'], isNotNull);
    });

    test('shell_exec 声明升级字段且必填 command', () {
      final tool = createShellExecTool();
      final props = tool.parameters['properties'] as Map;
      expect(props['sandbox_permissions'], isNotNull);
      expect(props['justification'], isNotNull);
      expect(tool.parameters['required'], contains('command'));
    });

    test('python_exec 声明升级字段且必填 script', () {
      final tool = createPythonExecTool();
      final props = tool.parameters['properties'] as Map;
      expect(props['sandbox_permissions'], isNotNull);
      expect(props['justification'], isNotNull);
      expect(tool.parameters['required'], contains('script'));
    });

    test('get_time 不声明升级字段', () {
      final props = createGetTimeTool().parameters['properties'] as Map;
      expect(props['sandbox_permissions'], isNull);
    });
  });
}
