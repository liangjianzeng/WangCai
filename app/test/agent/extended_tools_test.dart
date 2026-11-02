import 'package:flutter_test/flutter_test.dart';

import 'package:tongyi_lite/agent/agent.dart';

void main() {
  setUp(() {
    resetTodoStore();
    resetNoteStore();
  });

  group('unit_converter 工具', () {
    test('长度换算：cm → inch', () async {
      final result = await createUnitConverterTool().execute({
        'value': 12, 'from': 'cm', 'to': 'inch',
      });
      expect(result.isError, isFalse);
      expect(result.content, contains('cm ='));
      expect(result.content, contains('inch'));
    });

    test('重量换算：kg → lb', () async {
      final result = await createUnitConverterTool().execute({
        'value': 5, 'from': 'kg', 'to': 'lb',
      });
      expect(result.isError, isFalse);
      expect(result.content, contains('kg ='));
    });

    test('温度换算：c → f', () async {
      final result = await createUnitConverterTool().execute({
        'value': 100, 'from': 'c', 'to': 'f',
      });
      expect(result.isError, isFalse);
      expect(result.content, contains('212'));
    });

    test('时间换算：min → s', () async {
      final result = await createUnitConverterTool().execute({
        'value': 2, 'from': 'min', 'to': 's',
      });
      expect(result.isError, isFalse);
      expect(result.content, contains('120'));
    });

    test('未知单位 → 错误', () async {
      final result = await createUnitConverterTool().execute({
        'value': 1, 'from': 'foo', 'to': 'bar',
      });
      expect(result.isError, isTrue);
    });

    test('缺参数 → 错误', () async {
      final result = await createUnitConverterTool().execute({'from': 'cm', 'to': 'inch'});
      expect(result.isError, isTrue);
    });
  });

  group('note 工具', () {
    test('note_take 保存便签，note_list 读取', () async {
      await createNoteTakeTool().execute({'title': '会议', 'content': '明天 10 点评审'});
      final result = await createNoteListTool().execute(const {});
      expect(result.isError, isFalse);
      expect(result.content, contains('会议: 明天 10 点评审'));
    });

    test('空便签时 note_list 提示无', () async {
      final result = await createNoteListTool().execute(const {});
      expect(result.isError, isFalse);
      expect(result.content, contains('没有便签'));
    });

    test('缺 title → 错误', () async {
      final result = await createNoteTakeTool().execute({'content': 'x'});
      expect(result.isError, isTrue);
    });
  });

  group('shell_exec 工具', () {
    test('缺少 command → 错误', () async {
      final result = await createShellExecTool().execute(const {});
      expect(result.isError, isTrue);
      expect(result.content, contains('command'));
    });
  });
}
