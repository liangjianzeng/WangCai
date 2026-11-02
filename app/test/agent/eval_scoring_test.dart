/// eval 评分库测试（P0-C）。
import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

import '../../eval/scoring.dart';

Map<String, dynamic> _ev(String type, Map<String, dynamic> data) =>
    {'type': type, 'seq': 0, 'time': 0, 'data': data};

String _traceText(List<Map<String, dynamic>> events) {
  final buf = StringBuffer();
  buf.writeln(jsonEncode({
    'version': 1,
    'conversationId': 'c1',
    'exportedAt': 0,
    'events': events.length,
  }));
  for (final e in events) {
    buf.writeln(jsonEncode(e));
  }
  return buf.toString();
}

void main() {
  final task = const EvalTask(
    id: 't1',
    name: '搜索汇总',
    prompt: '搜索一下 X 并总结',
    expectTools: ['web_search'],
    forbidTools: ['shell_exec'],
    maxSteps: 10,
    maxDuplicateToolCalls: 1,
    answerContains: ['结论'],
  );

  test('好轨迹：全过', () {
    final parsed = parseTraceText(_traceText([
      _ev('user/message', {'content': '搜索一下 X 并总结'}),
      _ev('step/start', {'turn': 1, 'step': 1}),
      _ev('tool/call', {
        'callId': 'c1',
        'name': 'web_search',
        'arguments': {'q': 'X'}
      }),
      _ev('tool/result', {'callId': 'c1', 'content': '结果'}),
      _ev('step/end', {'turn': 1, 'step': 1}),
      _ev('assistant/message', {'content': '结论：X 很好'}),
      _ev('turn/end', {'turn': 1, 'reason': 'completed'}),
    ]));
    final report = scoreTrace(task, summarizeTrace(parsed.events));
    expect(report.allPass, isTrue);
    expect(report.score, 1.0);
  });

  test('坏轨迹：重复调用超限 + 终止原因错 + 答案泄漏 → 各项挂', () {
    final parsed = parseTraceText(_traceText([
      _ev('user/message', {'content': '搜索一下 X 并总结'}),
      _ev('tool/call', {
        'name': 'web_search',
        'arguments': {'q': 'X'}
      }),
      _ev('tool/call', {
        'name': 'web_search',
        'arguments': {'q': 'X'}
      }),
      _ev('tool/call', {
        'name': 'web_search',
        'arguments': {'q': 'X'}
      }),
      _ev('assistant/message', {'content': '<tool_call><get_time</tool_call>'}),
      _ev('turn/end', {'turn': 1, 'reason': 'maxSteps'}),
    ]));
    final report = scoreTrace(task, summarizeTrace(parsed.events));
    expect(report.allPass, isFalse);
    expect(report.checks.firstWhere((c) => c.name.contains('重复调用')).pass,
        isFalse);
    expect(report.checks.firstWhere((c) => c.name.contains('终止原因')).pass,
        isFalse);
    expect(
        report.checks
            .firstWhere((c) => c.name.contains('不含「<tool_call」'))
            .pass,
        isFalse);
  });

  test('任务集加载：tasks.json 全部可解析且字段合法', () {
    final tasks = EvalTask.listFromFile('eval/tasks.json');
    expect(tasks.length, greaterThanOrEqualTo(12));
    final ids = tasks.map((t) => t.id).toSet();
    expect(ids.length, tasks.length, reason: 'id 不重复');
    for (final t in tasks) {
      expect(t.prompt, isNotEmpty);
    }
  });

  test('scoreTracesDir：目录评分 + 匹配规则', () async {
    final dir = await Directory.systemTemp.createTemp('eval_test');
    addTearDown(() => dir.deleteSync(recursive: true));
    File('${dir.path}/trace_c1_1.jsonl').writeAsStringSync(_traceText([
      _ev('user/message', {'content': '搜索一下 X 并总结'}),
      _ev('tool/call', {
        'name': 'web_search',
        'arguments': {'q': 'X'}
      }),
      _ev('assistant/message', {'content': '结论：好'}),
      _ev('turn/end', {'turn': 1, 'reason': 'completed'}),
    ]));
    final code = scoreTracesDir('eval/tasks.json', dir.path);
    // 12 个任务只有 1 个匹配 → 退出码 2（有未匹配）。
    expect(code, 2);
  });
}
