/// eval 评分库（纯 Dart，无 Flutter 依赖）—— 轨迹 × 任务规格 → 评分报告。
///
/// 工作流（P0-C）：设置开启「回合轨迹落盘」→ 真机跑基线任务 → 从
/// `ApplicationSupport/traces/` 拉 JSONL → `dart run eval/score_traces.dart`
/// 离线评分。评分维度（各占一项，报告过/挂 + 总分）：
/// 期望工具覆盖 / 禁用工具未出现 / 终止原因 / 步数预算 / 重复调用上限 /
/// 回答内容断言。
library;

import 'dart:convert';
import 'dart:io';

/// 一个基线任务的规格（与 eval/tasks.json 对应）。
class EvalTask {
  final String id;
  final String name;

  /// 发给模型的完整 prompt（轨迹匹配依据：首条 user 消息含此内容前 40 字符）。
  final String prompt;

  /// 期望至少调用过一次的工具。
  final List<String> expectTools;

  /// 不允许出现的工具。
  final List<String> forbidTools;

  /// 期望 turn/end 原因（默认 completed）。
  final String expectEndReason;

  /// 步数上限（step/start 计数）。
  final int maxSteps;

  /// 完全同签名调用的最大重复次数。
  final int maxDuplicateToolCalls;

  /// 最终回答必须包含的子串。
  final List<String> answerContains;

  /// 最终回答不允许包含的子串。
  final List<String> answerNotContains;

  const EvalTask({
    required this.id,
    required this.name,
    required this.prompt,
    this.expectTools = const [],
    this.forbidTools = const [],
    this.expectEndReason = 'completed',
    this.maxSteps = 16,
    this.maxDuplicateToolCalls = 2,
    this.answerContains = const [],
    this.answerNotContains = const ['<tool_call', '<|tool_call', '本轮执行失败'],
  });

  factory EvalTask.fromJson(Map<String, dynamic> m) => EvalTask(
        id: m['id'] as String,
        name: m['name'] as String? ?? m['id'] as String,
        prompt: m['prompt'] as String? ?? '',
        expectTools:
            (m['expectTools'] as List<dynamic>?)?.cast<String>() ?? const [],
        forbidTools:
            (m['forbidTools'] as List<dynamic>?)?.cast<String>() ?? const [],
        expectEndReason: m['expectEndReason'] as String? ?? 'completed',
        maxSteps: (m['maxSteps'] as num?)?.toInt() ?? 16,
        maxDuplicateToolCalls:
            (m['maxDuplicateToolCalls'] as num?)?.toInt() ?? 2,
        answerContains:
            (m['answerContains'] as List<dynamic>?)?.cast<String>() ?? const [],
        answerNotContains: (m['answerNotContains'] as List<dynamic>?)
                ?.cast<String>() ??
            const ['<tool_call', '<|tool_call', '本轮执行失败'],
      );

  static List<EvalTask> listFromFile(String path) {
    final m = jsonDecode(File(path).readAsStringSync()) as Map<String, dynamic>;
    return (m['tasks'] as List<dynamic>)
        .map((e) => EvalTask.fromJson((e as Map).cast<String, dynamic>()))
        .toList();
  }
}

/// 单项检查结果。
class CheckResult {
  final String name;
  final bool pass;
  final String detail;
  const CheckResult(this.name, this.pass, this.detail);
}

/// 一个任务的评分报告。
class EvalReport {
  final String taskId;
  final bool matched;
  final List<CheckResult> checks;
  const EvalReport(this.taskId, this.matched, this.checks);

  /// 得分 = 通过项 / 总项（未匹配到轨迹 = 0）。
  double get score =>
      matched && checks.isNotEmpty ? checks.where((c) => c.pass).length / checks.length : 0;
  bool get allPass => matched && checks.every((c) => c.pass);
}

/// 单条轨迹的提取结果。
class TraceSummary {
  final int steps;
  final List<String> toolsCalled;
  final int duplicateToolCalls;
  final String endReason;
  final String lastAssistant;
  const TraceSummary(this.steps, this.toolsCalled, this.duplicateToolCalls,
      this.endReason, this.lastAssistant);
}

/// 从事件序列提取轨迹摘要（纯函数；事件来自 SessionEvent.fromJsonLine）。
TraceSummary summarizeTrace(List<dynamic /*SessionEvent-like*/ > events) {
  // 用鸭子类型访问（SessionEvent 无 Flutter 依赖，直接解构 data）。
  var steps = 0;
  final tools = <String>[];
  final sigs = <String>{};
  var dup = 0;
  var endReason = '';
  var lastAssistant = '';
  for (final e in events) {
    final type = e.type as String;
    final data = e.data as Map<String, dynamic>;
    switch (type) {
      case 'step/start':
        steps++;
        break;
      case 'tool/call':
        final name = data['name'] as String? ?? '';
        if (name.isNotEmpty) tools.add(name);
        var body = '';
        try {
          body = jsonEncode(data['arguments'] ?? const {});
        } catch (_) {}
        if (!sigs.add('$name#$body')) dup++;
        break;
      case 'assistant/message':
        final c = data['content'] as String? ?? '';
        if (c.isNotEmpty) lastAssistant = c;
        break;
      case 'turn/end':
        endReason = data['reason'] as String? ?? '';
        break;
      default:
        break;
    }
  }
  return TraceSummary(steps, tools, dup, endReason, lastAssistant);
}

/// 评分一条轨迹是否满足任务规格。
EvalReport scoreTrace(EvalTask task, TraceSummary t) {
  final checks = <CheckResult>[];
  final called = t.toolsCalled.join('、');
  for (final tool in task.expectTools) {
    checks.add(CheckResult(
        '调用过 $tool', t.toolsCalled.contains(tool), '实际调用：$called'));
  }
  for (final tool in task.forbidTools) {
    checks.add(CheckResult('未调用 $tool（禁用）', !t.toolsCalled.contains(tool),
        '实际调用：$called'));
  }
  checks.add(CheckResult(
      '终止原因=${task.expectEndReason}', t.endReason == task.expectEndReason,
      '实际：${t.endReason.isEmpty ? '（未闭合）' : t.endReason}'));
  checks.add(CheckResult('步数 ≤ ${task.maxSteps}', t.steps <= task.maxSteps,
      '实际：${t.steps}'));
  checks.add(CheckResult(
      '重复调用 ≤ ${task.maxDuplicateToolCalls}',
      t.duplicateToolCalls <= task.maxDuplicateToolCalls,
      '实际：${t.duplicateToolCalls}'));
  for (final s in task.answerContains) {
    checks.add(CheckResult('回答含「$s」', t.lastAssistant.contains(s),
        '回答长度 ${t.lastAssistant.length}'));
  }
  for (final s in task.answerNotContains) {
    checks.add(CheckResult('回答不含「$s」', !t.lastAssistant.contains(s),
        t.lastAssistant.contains(s) ? '命中泄漏' : ''));
  }
  return EvalReport(task.id, true, checks);
}

/// 从 JSONL 文本（header + 事件行）解析事件并返回任务匹配键（首条 user 消息）。
({List<dynamic> events, String firstUser}) parseTraceText(String text) {
  String? firstUser;
  final events = <dynamic>[];
  for (final line in text.split('\n')) {
    final t = line.trim();
    if (t.isEmpty || !t.startsWith('{')) continue;
    final m = jsonDecode(t) as Map<String, dynamic>;
    if (m.containsKey('conversationId')) continue; // header
    if (m['type'] == 'user/message' && firstUser == null) {
      firstUser = ((m['data'] as Map<String, dynamic>)['content'] as String? ?? '');
    }
    events.add(_LazyEvent(m));
  }
  return (events: events, firstUser: firstUser ?? '');
}

/// 轻量事件视图（延迟解构 JSON，避免 eval 依赖 session 库的类型）。
class _LazyEvent {
  final Map<String, dynamic> _m;
  _LazyEvent(this._m);
  String get type => _m['type'] as String;
  Map<String, dynamic> get data =>
      (_m['data'] as Map<String, dynamic>?) ?? const {};
}

/// 主评分入口：tasksFile + 轨迹目录（trace_*.jsonl）→ 控制台报告。
/// 返回进程退出码（0 = 全部匹配任务 allPass，1 = 有挂项，2 = 有任务没匹配到轨迹）。
int scoreTracesDir(String tasksFile, String traceDir) {
  final tasks = EvalTask.listFromFile(tasksFile);
  final reports = <EvalReport>[];
  final matched = <String>{};
  final dir = Directory(traceDir);
  final files = dir.existsSync()
      ? dir
          .listSync()
          .whereType<File>()
          .where((f) => f.path.endsWith('.jsonl'))
          .toList()
      : <File>[];
  for (final task in tasks) {
    final key = task.prompt.length > 40
        ? task.prompt.substring(0, 40)
        : task.prompt;
    EvalReport? report;
    for (final f in files) {
      try {
        final parsed = parseTraceText(f.readAsStringSync());
        if (!parsed.firstUser.contains(key)) continue;
        final summary = summarizeTrace(parsed.events);
        report = scoreTrace(task, summary);
        break;
      } on FormatException {
        continue;
      }
    }
    if (report == null) {
      reports.add(EvalReport(task.id, false, const []));
    } else {
      matched.add(task.id);
      reports.add(report);
    }
  }

  var hasFail = false, hasMissing = false;
  for (final r in reports) {
    final task = tasks.firstWhere((t) => t.id == r.taskId);
    if (!r.matched) {
      hasMissing = true;
      stdout.writeln('○ ${task.id} ${task.name}：未找到匹配轨迹（先跑任务再拉轨迹）');
      continue;
    }
    final icon = r.allPass ? '✓' : '✗';
    if (!r.allPass) hasFail = true;
    stdout.writeln(
        '$icon ${task.id} ${task.name}：score=${(r.score * 100).toStringAsFixed(0)}%'
        '${r.allPass ? '' : ''}');
    for (final c in r.checks.where((c) => !c.pass)) {
      stdout.writeln('    ✗ ${c.name} ${c.detail.isEmpty ? '' : '（${c.detail}）'}');
    }
  }
  stdout.writeln('---');
  stdout.writeln(
      '任务 ${tasks.length}：匹配 ${matched.length}，全过 ${reports.where((r) => r.allPass).length}');
  if (hasMissing) return 2;
  return hasFail ? 1 : 0;
}
