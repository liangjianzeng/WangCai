/// 施工质量基建测试（P0 遥测 / P0 轨迹 / P2-A 并行安全 / P1-C 环境尾部注入 /
/// P1-D 技能目录冻结）。
import 'dart:convert' show jsonDecode;
import 'dart:io';

import 'package:tongyi_lite/agent/context_eng/compaction.dart';
import 'package:tongyi_lite/agent/loop/agent.dart';
import 'package:tongyi_lite/agent/loop/config.dart';
import 'package:tongyi_lite/agent/loop/failure.dart'
    show CompactionResultKind, NoCompactionPlugin, SessionRef;
import 'package:tongyi_lite/agent/llm/adapter.dart';
import 'package:tongyi_lite/agent/metrics/turn_metrics.dart';
import 'package:tongyi_lite/agent/session/session.dart';
import 'package:tongyi_lite/agent/session/trace_export.dart';
import 'package:tongyi_lite/agent/skills/provider.dart';
import 'package:tongyi_lite/agent/skills/skill.dart';
import 'package:tongyi_lite/agent/tool_definition.dart';
import 'package:tongyi_lite/agent/tool_registry.dart';
import 'package:flutter_test/flutter_test.dart';

import '../helpers/fake_llm.dart';

ToolDefinition _tool(
  String name, {
  bool Function(Map<String, dynamic>)? isConcurrencySafe,
  Duration? delay,
}) =>
    ToolDefinition(
      name: name,
      description: '测试工具 $name',
      parameters: const {
        'type': 'object',
        'properties': {
          'x': {'type': 'string'}
        },
      },
      execute: (args) async {
        if (delay != null) await Future.delayed(delay);
        return ToolResult(content: '$name done');
      },
      isConcurrencySafe: isConcurrencySafe,
    );

ReactLoopAgent _agent(
  LlmAdapter adapter, {
  List<ToolDefinition>? tools,
  AgentConfig? config,
  String Function()? environmentNoteProvider,
}) {
  final registry = ToolRegistry();
  for (final t in tools ?? [_tool('get_weather')]) {
    registry.register(t);
  }
  return ReactLoopAgent(
    session: SessionLog.fromEvents(const []),
    adapter: adapter,
    registry: registry,
    modelId: 'test-model',
    providerKind: ProviderKind.api,
    systemPrompt: '你是 TongYi-Lite 智能体',
    config: config ?? AgentConfig(),
    compaction: const NoCompactionPlugin(),
    environmentNoteProvider: environmentNoteProvider,
  );
}

/// 组装一段有代表性的事件流（指标源）。
SessionLog _metricsLog() {
  final log = SessionLog.fromEvents(const []);
  log.append(kEventSystemMessage, {'content': 'sys'});
  log.append(kEventTurnStart, {'turn': 1, 'userSeq': 2});
  log.append(kEventUserMessage, {'content': '问题'});
  log.append(kEventStepStart, {'turn': 1, 'step': 1});
  log.append(kEventAssistantMessage, {'content': '', 'toolCalls': []});
  log.append(kEventToolCall, {
    'callId': 'c1',
    'name': 'web_search',
    'arguments': {'q': 'a'},
  });
  log.append(kEventToolResult, {'callId': 'c1', 'content': '结果'});
  log.append(kEventStepEnd, {'turn': 1, 'step': 1});
  log.append(kEventStepStart, {'turn': 1, 'step': 2});
  log.append(kEventAssistantMessage, {'content': '', 'toolCalls': []});
  // 重复同签名调用
  log.append(kEventToolCall, {
    'callId': 'c2',
    'name': 'web_search',
    'arguments': {'q': 'a'},
  });
  log.append(kEventToolResult, {
    'callId': 'c2',
    'content': '结果\n[提醒：这是本回合第 3 次调用 web_search…]',
  });
  log.append(kEventStepEnd, {'turn': 1, 'step': 2});
  log.append(kEventAssistantAttempt,
      {'turn': 1, 'step': 3, 'code': 'toolCallTruncated', 'content': 'x'});
  log.append(kEventLlmRetry,
      {'turn': 1, 'step': 3, 'retries': 1, 'code': 'emptyResponse'});
  log.append(kEventCompactionSummary,
      {'content': '摘要', 'surfaceOp': 'replace', 'shadowsEndSeq': 5});
  log.append(kEventStepStart, {'turn': 1, 'step': 3});
  log.append(kEventAssistantMessage, {'content': '最终回答', 'toolCalls': []});
  log.append(kEventStepEnd, {'turn': 1, 'step': 3});
  log.append(kEventTurnEnd, {'turn': 1, 'reason': 'completed'});
  return log;
}

void main() {
  group('P0-A 回合指标 TurnMetrics.fromLog', () {
    test('全量统计：steps/工具/重复/提醒/重试/压缩/终止原因', () {
      final m = TurnMetrics.fromLog(_metricsLog(), 1);
      expect(m, isNotNull);
      expect(m!.steps, 3);
      expect(m.toolCalls, 2);
      expect(m.duplicateToolCalls, 1);
      expect(m.repeatReminders, 1);
      expect(m.llmRetries, 1);
      expect(m.failureCodes['toolCallTruncated'], 1);
      expect(m.failureCodes['emptyResponse'], 1);
      expect(m.compactions, 1);
      expect(m.endReason, 'completed');
      expect(m.maxStepsHit, isFalse);
      expect(m.failed, isFalse);
    });

    test('JSON 往返一致', () {
      final m = TurnMetrics.fromLog(_metricsLog(), 1)!;
      final m2 = TurnMetrics.fromJson(m.toJson());
      expect(m2.steps, m.steps);
      expect(m2.toolCalls, m.toolCalls);
      expect(m2.duplicateToolCalls, m.duplicateToolCalls);
      expect(m2.failureCodes, m.failureCodes);
      expect(m2.endReason, m.endReason);
    });

    test('不存在的回合返回 null', () {
      expect(TurnMetrics.fromLog(_metricsLog(), 9), isNull);
    });

    test('TurnMetricsStore：落盘 JSONL + 聚合', () async {
      final dir =
          await Directory.systemTemp.createTemp('metrics_test');
      addTearDown(() => dir.deleteSync(recursive: true));
      final store = TurnMetricsStore(baseDir: dir.path);
      await store.record(TurnMetrics.fromLog(_metricsLog(), 1)!);
      await store.record(
        const TurnMetrics(
          turn: 2,
          startedAtMs: 0,
          endedAtMs: 100,
          endReason: 'maxSteps',
          steps: 12,
          toolCalls: 10,
          duplicateToolCalls: 4,
          repeatReminders: 2,
          llmRetries: 0,
          failureCodes: {},
          compactions: 0,
        ),
      );
      final file = File('${dir.path}/turn_metrics.jsonl');
      expect(file.existsSync(), isTrue);
      final lines = file
          .readAsLinesSync()
          .where((l) => l.trim().isNotEmpty)
          .toList();
      expect(lines.length, 2);
      // 逐行可反解
      expect(store.fromJsonMapLine(lines[1]).maxStepsHit, isTrue);
      final agg = store.aggregate();
      expect(agg['turns'], 2);
      expect(agg['toolCalls'], 12);
      expect((agg['endReasons'] as Map)['completed'], 1);
      expect((agg['endReasons'] as Map)['maxSteps'], 1);
      expect(agg['duplicateToolCalls'], 5);
    });
  });

  group('P0-B 轨迹导出', () {
    test('整份导出：header + 全事件，逐行可反解 round-trip', () {
      final log = _metricsLog();
      final text = exportTraceJsonl(log, conversationId: 'conv-1');
      final lines = text.trim().split('\n');
      expect(lines.length, log.eventsCount + 1);
      final header = lines.first;
      expect(header.contains('"conversationId":"conv-1"'), isTrue);
      // 逐行 round-trip
      for (final line in lines.skip(1)) {
        final e = SessionEvent.fromJsonLine(line);
        expect(e, isNotNull);
      }
    });

    test('单回合导出：只含该回合区间；不存在的回合为空', () {
      final log = _metricsLog();
      final turn1 = exportTurnJsonl(log, 1);
      expect(turn1.contains('"type":"turn/start"'), isTrue);
      expect(turn1.contains('"type":"turn/end"'), isTrue);
      expect(turn1.contains('最终回答'), isTrue);
      expect(exportTurnJsonl(log, 5), isEmpty);
    });

    test('writeTraceFile：目录自动创建、文件名安全', () async {
      final dir =
          await Directory.systemTemp.createTemp('trace_test');
      addTearDown(() => dir.deleteSync(recursive: true));
      final f = await writeTraceFile(_metricsLog(),
          baseDir: dir.path, conversationId: 'a/b c');
      expect(f.existsSync(), isTrue);
      expect(f.path.contains(r'trace_a_b_c_'), isTrue);
      expect(f.readAsLinesSync().length, _metricsLog().eventsCount + 1);
    });
  });

  group('P2-A 并行工具安全', () {
    test('isConcurrencySafe=false 的调用不与兄弟调用并发（独占执行）', () async {
      // 模型一次要 3 个调用：A(安全) B(不安全) C(安全)。B 的执行区间必须
      // 不与 A/C 重叠（独占一批；安全调用凑批的先后不影响安全性）。
      final spans = <String, List<DateTime>>{};
      ToolDefinition def(String name, bool safe) => ToolDefinition(
            name: name,
            description: name,
            parameters: const {
              'type': 'object',
              'properties': {
                'x': {'type': 'string'}
              },
            },
            execute: (args) async {
              spans.putIfAbsent(name, () => []).add(DateTime.now());
              await Future.delayed(const Duration(milliseconds: 30));
              spans[name]!.add(DateTime.now());
              return ToolResult(content: name);
            },
            isConcurrencySafe: (_) => safe,
          );
      final calls = [
        const ToolCall(id: '1', name: 'a', arguments: {'x': '1'}),
        const ToolCall(id: '2', name: 'b', arguments: {'x': '1'}),
        const ToolCall(id: '3', name: 'c', arguments: {'x': '1'}),
      ];
      final fake = FakeLlmAdapter([
        LlmResult(text: '', toolCalls: calls),
        LlmResult(text: 'done', toolCalls: const []),
      ]);
      final agent = _agent(
        fake,
        tools: [def('a', true), def('b', false), def('c', true)],
        config: const AgentConfig(
            allowParallelTools: true, maxParallel: 4, maxStepsPerTurn: 4),
      );
      await agent.kick('跑');
      bool overlaps(String x, String y) {
        final a = spans[x]!, b = spans[y]!;
        return a.first.isBefore(b.last) && b.first.isBefore(a.last);
      }

      expect(overlaps('b', 'a'), isFalse, reason: '不安全调用 b 不与 a 并发');
      expect(overlaps('b', 'c'), isFalse, reason: '不安全调用 b 不与 c 并发');
    });

    test('回合中断：未执行调用合成占位结果（每个 tool/call 有配对 result）',
        () async {
      final calls = [
        const ToolCall(id: '1', name: 't1', arguments: {'x': '1'}),
        const ToolCall(id: '2', name: 't2', arguments: {'x': '1'}),
      ];
      final fake = FakeLlmAdapter([
        LlmResult(text: '', toolCalls: calls),
        LlmResult(text: 'ok', toolCalls: const []),
      ]);
      final agent = _agent(
        fake,
        tools: [_tool('t1', delay: const Duration(milliseconds: 40)), _tool('t2')],
        config: const AgentConfig(
            allowParallelTools: true, maxParallel: 2, maxStepsPerTurn: 4),
      );
      // 启动后在工具执行期取消 → t2 的执行被跳过合成占位。
      final kickFuture = agent.kick('跑');
      await Future.delayed(const Duration(milliseconds: 10));
      await agent.cancel();
      await kickFuture;
      final results = agent.session.rawEvents
          .where((e) => e.type == kEventToolResult)
          .toList();
      expect(results.length, 2);
      final contents = results.map((e) => e.data['content'] as String).toList();
      expect(
          contents.any((c) => c.contains('因回合被用户中断')), isTrue);
    });
  });

  group('P1-C 环境快照尾部注入', () {
    test('provider 内容不变 → 只注入一次；变化 → 追加尾部 user 消息', () async {
      var note = 'T1';
      final fake = FakeLlmAdapter([
        LlmResult(text: '', toolCalls: const []),
        LlmResult(text: '第一轮', toolCalls: const []),
      ]);
      final agent = _agent(fake, environmentNoteProvider: () => note);
      await agent.kick('问1');
      var envNotes = agent.session.rawEvents
          .where((e) => e.type == kEventUserMessage &&
              (e.data['content'] as String).startsWith('【环境】'))
          .toList();
      expect(envNotes.length, 1);
      expect(envNotes.first.data['content'], '【环境】T1');
      // 系统提示不含环境段（逐字节稳定）
      final sys = agent.session.rawEvents
          .firstWhere((e) => e.type == kEventSystemMessage)
          .data['content'] as String;
      expect(sys.contains('【环境】'), isFalse);
      // 第二回合内容变化 → 追加一条；不变 → 不追加
      note = 'T2';
      await agent.kick('问2');
      envNotes = agent.session.rawEvents
          .where((e) => e.type == kEventUserMessage &&
              (e.data['content'] as String).startsWith('【环境】'))
          .toList();
      expect(envNotes.length, 2);
      await agent.kick('问3');
      envNotes = agent.session.rawEvents
          .where((e) => e.type == kEventUserMessage &&
              (e.data['content'] as String).startsWith('【环境】'))
          .toList();
      expect(envNotes.length, 2);
    });

    test('回合内环境快照不变 → 不重复注入（尾部保持 tool result，前缀不破）',
        () async {
      final call = const ToolCall(id: 'c1', name: 'get_weather', arguments: {});
      final fake = FakeLlmAdapter([
        LlmResult(text: '', toolCalls: [call]),
        LlmResult(text: '答', toolCalls: const []),
      ]);
      final agent = _agent(fake, environmentNoteProvider: () => 'T1');
      await agent.kick('问');
      // 同回合内快照未变 → step 2 前不再注入；最后一条消息仍是工具结果。
      final last = fake.allMessages[1].last;
      expect(last['role'], 'tool');
      // 环境消息全回合只有一条（step 1 前注入的那条）。
      final envCount = fake.allMessages[1]
          .where((m) => (m['content'] as String?)?.startsWith('【环境】') == true)
          .length;
      expect(envCount, 1);
    });
  });

  group('P1-B LLM 摘要压缩', () {
    /// 构造 >keepRounds 轮、旧轮含工具结果的日志。
    SessionLog _oldRoundsLog() {
      final log = SessionLog.fromEvents(const []);
      log.append(kEventSystemMessage, {'content': 'sys'});
      for (var i = 1; i <= 7; i++) {
        log.append(kEventTurnStart, {'turn': i, 'userSeq': 0});
        log.append(kEventUserMessage, {'content': '用户任务诉求 $i'});
        log.append(kEventStepStart, {'turn': i, 'step': 1});
        log.append(kEventToolCall, {
          'callId': 'c$i',
          'name': 'web_search',
          'arguments': {'q': '查询$i'},
        });
        log.append(kEventToolResult, {
          'callId': 'c$i',
          'name': 'web_search',
          'content': '搜索结果内容$i' * 20,
        });
        log.append(kEventStepEnd, {'turn': i, 'step': 1});
        log.append(kEventTurnEnd, {'turn': i, 'reason': 'completed'});
      }
      return log;
    }

    test('LLM 摘要成功 → 摘要用模型文本，provider=llm', () async {
      final log = _oldRoundsLog();
      final result = await DeterministicCompaction(
        llmSummarizer: (prompt) async {
          expect(prompt.contains('用户任务诉求'), isTrue);
          expect(prompt.contains('[web_search]'), isTrue);
          return '这是模型生成的紧凑摘要。';
        },
      ).decide(ref: SessionRef(log), turn: 7, step: 1, reason: 'proactive');
      expect(result.kind, CompactionResultKind.success);
      final summary = log.rawEvents
          .lastWhere((e) => e.type == kEventCompactionSummary);
      expect(summary.data['content'], contains('这是模型生成的紧凑摘要'));
      expect(summary.data['provider'], 'llm');
    });

    test('LLM 摘要抛异常 → 回退确定性摘要（压缩不失败）', () async {
      final log = _oldRoundsLog();
      final result = await DeterministicCompaction(
        llmSummarizer: (prompt) async => throw Exception('模型挂了'),
      ).decide(ref: SessionRef(log), turn: 7, step: 1, reason: 'proactive');
      expect(result.kind, CompactionResultKind.success);
      final summary = log.rawEvents
          .lastWhere((e) => e.type == kEventCompactionSummary);
      expect(summary.data['content'], contains('较早轮次摘要'));
      expect(summary.data['provider'], 'deterministic-prune');
    });

    test('LLM 摘要返回空串 → 回退确定性摘要', () async {
      final log = _oldRoundsLog();
      final result = await DeterministicCompaction(
        llmSummarizer: (prompt) async => '   ',
      ).decide(ref: SessionRef(log), turn: 7, step: 1, reason: 'proactive');
      expect(result.kind, CompactionResultKind.success);
      final summary = log.rawEvents
          .lastWhere((e) => e.type == kEventCompactionSummary);
      expect(summary.data['provider'], 'deterministic-prune');
    });

    test('无 summarizer → 纯确定性（原行为）', () async {
      final log = _oldRoundsLog();
      final result = await DeterministicCompaction()
          .decide(ref: SessionRef(log), turn: 7, step: 1, reason: 'proactive');
      expect(result.kind, CompactionResultKind.success);
      final summary = log.rawEvents
          .lastWhere((e) => e.type == kEventCompactionSummary);
      expect(summary.data['provider'], 'deterministic-prune');
    });
  });

  group('P1-D 技能目录冻结', () {
    test('frozenDirectoryText 非空时 availableSkillsText 恒返回冻结文本', () {
      final p = SkillProvider(skills: [
        Skill.parse(
            'description: a\nwhenToUse: b\n---\n正文', name: 'alpha'),
      ]);
      p.frozenDirectoryText = '<available_skills>FROZEN</available_skills>';
      expect(p.availableSkillsText(loadSkillAvailable: true),
          '<available_skills>FROZEN</available_skills>');
      // 解冻恢复实时生成
      p.frozenDirectoryText = null;
      expect(p.availableSkillsText(loadSkillAvailable: true),
          contains('alpha'));
    });

    test('registerUser 后冻结文本不变、byName 可拉取', () {
      final p = SkillProvider();
      p.frozenDirectoryText = 'FROZEN-DIR';
      p.registerUser(Skill.parse('description: 新技能\nwhenToUse: 测试\n---\nB',
          name: 'newone'));
      expect(p.availableSkillsText(loadSkillAvailable: true), 'FROZEN-DIR');
      expect(p.byName('newone'), isNotNull);
    });
  });
}

extension on TurnMetricsStore {
  TurnMetrics fromJsonMapLine(String line) =>
      TurnMetrics.fromJson((jsonDecode(line) as Map).cast<String, dynamic>());
}
