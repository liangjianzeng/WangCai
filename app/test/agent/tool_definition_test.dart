import 'package:flutter_test/flutter_test.dart';

import 'package:tongyi_lite/agent/agent.dart';

void main() {
  group('validateRequiredArguments（对照 DSH validateArgs）', () {
    const shellSchema = {
      'type': 'object',
      'properties': {
        'command': {'type': 'string', 'description': '要执行的 shell 命令'},
        'cwd': {'type': 'string', 'description': '工作目录（可选）'},
      },
      'required': ['command'],
    };

    const todoSchema = {
      'type': 'object',
      'properties': {
        'todos': {'type': 'array', 'description': '任务数组'},
      },
      'required': ['todos'],
    };

    test('必填参数齐全 → 无违规', () {
      final violations = validateRequiredArguments({'command': 'ls -la'}, shellSchema);
      expect(violations, isEmpty);
    });

    test('缺失必填参数 → 明确列出参数名与用途', () {
      final violations = validateRequiredArguments(const {}, shellSchema);
      expect(violations.length, 1);
      expect(violations.first, contains('command'));
      expect(violations.first, contains('要执行的 shell 命令'));
    });

    test('可选参数缺失不算违规', () {
      final violations = validateRequiredArguments({'command': 'pwd'}, shellSchema);
      expect(violations, isEmpty);
    });

    test('必填字符串为空串 → 视为缺失', () {
      final violations = validateRequiredArguments({'command': '   '}, shellSchema);
      expect(violations.length, 1);
      expect(violations.first, contains('不能为空'));
    });

    test('数组必填参数只做存在性检查（空数组由工具自行判错）', () {
      // todos 是数组必填：存在即通过，值域校验（如空数组）交给 todo_write 自身。
      final violations = validateRequiredArguments({'todos': []}, todoSchema);
      expect(violations, isEmpty);
    });

    test('无 required 声明 → 恒通过', () {
      const freeSchema = {'type': 'object', 'properties': {'a': {'type': 'string'}}};
      expect(validateRequiredArguments(const {}, freeSchema), isEmpty);
    });
  });
}
