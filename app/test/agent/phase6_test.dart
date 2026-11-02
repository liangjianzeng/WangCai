/// Phase 6 tests：SessionLog 事件流 + AgentUiState reducer + 内嵌工作流
/// UI 渲染（回合块 / 消息分组 / 工具活动解析）。
library;

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:tongyi_lite/agent/session/event.dart';
import 'package:tongyi_lite/agent/session/log.dart';
import 'package:tongyi_lite/models/chat_message.dart';
import 'package:tongyi_lite/models/turn_trace.dart';
import 'package:tongyi_lite/providers/agent_state_provider.dart';
import 'package:tongyi_lite/widgets/agent_workflow.dart';

void main() {
  /// 测试消息工厂（分组/解析组共用）。
  ChatMessage userMsg(String c) => ChatMessage(
        id: 'u',
        conversationId: 'c',
        role: MessageRole.user,
        content: c,
        timestamp: DateTime.now(),
      );

  ChatMessage asst(String c, {bool streaming = false}) => ChatMessage(
        id: 'a',
        conversationId: 'c',
        role: MessageRole.assistant,
        content: c,
        isStreaming: streaming,
        timestamp: DateTime.now(),
      );

  group('SessionLog.events 广播流', () {
    test('append 实时推送事件', () async {
      final log = SessionLog.fromEvents([]);
      final received = <SessionEvent>[];
      log.events.listen(received.add);
      log.append(kEventTurnStart, {'turn': 1});
      log.append(kEventToolCall, {'callId': 'c1', 'name': 'x'});
      expect(received.length, 2);
      expect(received.first.type, kEventTurnStart);
      expect(received.last.data['callId'], 'c1');
      log.dispose();
    });

    test('多订阅者都能收到（broadcast）', () async {
      final log = SessionLog.fromEvents([]);
      final a = <SessionEvent>[];
      final b = <SessionEvent>[];
      log.events.listen(a.add);
      log.events.listen(b.add);
      log.append(kEventStepStart, {'turn': 1, 'step': 1});
      expect(a.length, 1);
      expect(b.length, 1);
      log.dispose();
    });

    test('dispose 后 append 正常但不再推送', () async {
      final log = SessionLog.fromEvents([]);
      final received = <SessionEvent>[];
      log.events.listen(received.add);
      log.dispose();
      log.append(kEventTurnStart, {'turn': 1}); // 不抛
      expect(received, isEmpty);
    });
  });

  group('AgentUiStateNotifier reducer', () {
    // 多会话并发（槽位）：状态按会话分键，测试统一取 conv-a 的快照。
    const kConv = 'conv-a';
    late SessionLog log;
    late AgentUiStateNotifier n;

    AgentUiState st([String conv = kConv]) =>
        n.state[conv] ?? const AgentUiState();

    setUp(() {
      log = SessionLog.fromEvents([]);
      n = AgentUiStateNotifier();
      n.attach(kConv, log);
    });

    tearDown(() {
      n.detach(kConv);
      log.dispose();
    });

    test('step 边界把流式思考落档为历史块（工作流可回看）', () {
      n.setThinking(kConv, '第一步思考内容');
      log.append(kEventStepStart, {'turn': 1, 'step': 2});
      expect(st().thinkingHistory, ['第一步思考内容']);
      expect(st().thinking, isEmpty);

      n.setThinking(kConv, '第二步思考');
      log.append(kEventTurnEnd, {'reason': 'completed'});
      expect(st().thinkingHistory, ['第一步思考内容', '第二步思考']);
      expect(st().thinking, isEmpty);
      expect(st().running, isFalse);
    });

    test('turn/start → running + turn；step/start → step', () {
      log.append(kEventTurnStart, {'turn': 3});
      expect(st().running, isTrue);
      expect(st().turn, 3);
      log.append(kEventStepStart, {'turn': 3, 'step': 2});
      expect(st().step, 2);
    });

    test('tool/call → 卡片（含参数）；tool/result → done', () {
      log.append(kEventToolCall, {
        'callId': 'c1',
        'name': 'get_time',
        'arguments': {'tz': 'Asia/Shanghai'},
      });
      expect(st().tools.length, 1);
      expect(st().tools.first.status, ToolUiStatus.executing);
      expect(st().tools.first.arguments['tz'], 'Asia/Shanghai');

      log.append(kEventToolResult,
          {'callId': 'c1', 'name': 'get_time', 'content': '12:00', 'isError': false});
      expect(st().tools.first.status, ToolUiStatus.done);
      expect(st().tools.first.result, '12:00');
    });

    test('tool/result isError → failed', () {
      log.append(kEventToolCall, {'callId': 'c2', 'name': 'shell'});
      log.append(kEventToolResult,
          {'callId': 'c2', 'name': 'shell', 'content': 'boom', 'isError': true});
      expect(st().tools.first.status, ToolUiStatus.failed);
      expect(st().tools.first.isError, isTrue);
    });

    test('llm/retry → retryAttempt；turn/end 清零', () {
      log.append(kEventLlmRetry, {'turn': 1, 'step': 1, 'retries': 2});
      expect(st().retryAttempt, 2);
      log.append(kEventTurnEnd, {'turn': 1, 'reason': 'completed'});
      expect(st().running, isFalse);
      expect(st().retryAttempt, 0);
      expect(st().lastError, isNull);
    });

    test('compaction/summary → compacted', () {
      log.append(kEventCompactionSummary, {'content': '摘要'});
      expect(st().compacted, isTrue);
    });

    test('turn/end reason=error（String 形态）→ lastError', () {
      log.append(kEventTurnEnd, {'turn': 1, 'reason': 'error'});
      expect(st().lastError, isNotNull);
    });

    test('turn/end reason=Map 形态（崩溃修复）兼容', () {
      log.append(kEventTurnEnd, {
        'turn': 1,
        'reason': {'kind': 'interrupted'},
      });
      expect(st().running, isFalse);
      expect(st().lastError, isNull);
    });

    test('detach 后事件不再进 state（状态保留）', () {
      log.append(kEventTurnStart, {'turn': 1});
      n.detach(kConv);
      log.append(kEventToolCall, {'callId': 'cX', 'name': 'x'});
      expect(st().tools, isEmpty);
      expect(st().running, isTrue); // 末态保留
    });

    test('attach 新 log 重置状态', () {
      log.append(kEventTurnStart, {'turn': 9});
      final log2 = SessionLog.fromEvents([]);
      n.attach(kConv, log2);
      expect(st().turn, 0);
      expect(st().running, isFalse);
      log2.dispose();
    });

    test('多会话并发：两个会话的事件流互不串台', () {
      const kConvB = 'conv-b';
      final logB = SessionLog.fromEvents([]);
      n.attach(kConvB, logB);
      try {
        log.append(kEventTurnStart, {'turn': 1});
        log.append(kEventToolCall, {'callId': 'a1', 'name': 'web_search'});
        logB.append(kEventTurnStart, {'turn': 5});
        logB.append(kEventToolCall, {'callId': 'b1', 'name': 'get_time'});

        expect(st().turn, 1);
        expect(st().tools.single.name, 'web_search');
        expect(st(kConvB).turn, 5);
        expect(st(kConvB).tools.single.name, 'get_time');

        // 思考流同样分键。
        n.setThinking(kConv, 'A 思考');
        n.setThinking(kConvB, 'B 思考');
        expect(st().thinking, 'A 思考');
        expect(st(kConvB).thinking, 'B 思考');

        // 会话 B 结束不影响会话 A 的 running 态。
        logB.append(kEventTurnEnd, {'reason': 'completed'});
        expect(st(kConvB).running, isFalse);
        expect(st().running, isTrue);
      } finally {
        n.detach(kConvB);
        logB.dispose();
      }
    });
  });

  group('groupMessages 消息重排（内嵌工作流）', () {
    test('turnTrace 信封：历史回合按落库真实交错顺序还原', () {
      ChatMessage tool(String id, String name) => ChatMessage(
            id: id,
            conversationId: 'c',
            role: MessageRole.assistant,
            content: '🔧 $name ✓ok',
            kind: MessageKind.toolActivity,
            toolData: ToolActivityData(phase: 'done', name: name, summary: 'ok'),
          );
      final envelope = ChatMessage(
        id: 'env',
        conversationId: 'c',
        role: MessageRole.assistant,
        content: encodeTurnUiTrace([
          const TurnUiItem.think('先思考'),
          const TurnUiItem.tool('tool1'),
          const TurnUiItem.think('再思考'),
          const TurnUiItem.tool('tool2'),
        ])!,
        kind: MessageKind.notice,
        noticeCode: 'turnTrace',
      );
      // 信封在存储序里位置无关（flush 时扫整回合消息）。
      final units = groupMessages([
        userMsg('Q'),
        envelope,
        asst('最终答案'),
        tool('tool1', 'web_search'),
        tool('tool2', 'get_weather'),
      ]);
      final turn = units.last as TurnUnit;
      expect(turn.trace, isNotNull);
      expect(turn.trace!.map((i) => i.type).toList(),
          ['think', 'tool', 'think', 'tool']);
      expect(turn.trace![0].text, '先思考');
      expect(turn.traceTools['tool1']?.name, 'web_search');
      expect(turn.traceTools['tool2']?.name, 'get_weather');
      expect(turn.traceTools['tool1']?.status, ToolUiStatus.done);
    });

    test('信封引用的工具消息缺失 → 回退散消息重排（trace=null）', () {
      final envelope = ChatMessage(
        id: 'env',
        conversationId: 'c',
        role: MessageRole.assistant,
        content: encodeTurnUiTrace([const TurnUiItem.tool('gone')])!,
        kind: MessageKind.notice,
        noticeCode: 'turnTrace',
      );
      final units = groupMessages([
        userMsg('Q'),
        asst('答案'),
        asst('🔧 A ✓ok'),
        envelope,
      ]);
      final turn = units.last as TurnUnit;
      expect(turn.trace, isNull);
      expect(turn.tools.length, 1);
    });

    test('新存储序 [user, ans, t1, t2] → 块 [t1, t2, ans]', () {
      final units = groupMessages([
        userMsg('Q1'),
        asst('最终答案'),
        asst('🔧 A ✓ok'),
        asst('🔧 B ✓ok2'),
      ]);
      expect(units.length, 2);
      expect(units.first, isA<UserUnit>());
      final turn = units.last as TurnUnit;
      expect(turn.tools.length, 2);
      expect(turn.tools.map((m) => m.content), ['🔧 A ✓ok', '🔧 B ✓ok2']);
      expect(turn.answer?.content, '最终答案');
      expect(turn.answer?.role, MessageRole.assistant);
    });

    test('旧存储序 [user, t1, t2, ans] → 块 [t1, t2, ans]（重排到回答之前）', () {
      final units = groupMessages([
        userMsg('Q1'),
        asst('🔧 A ✓ok'),
        asst('🔧 B ✓ok2'),
        asst('最终答案'),
      ]);
      expect(units.length, 2);
      final turn = units.last as TurnUnit;
      expect(turn.tools.length, 2);
      expect(turn.tools.map((m) => m.content), ['🔧 A ✓ok', '🔧 B ✓ok2']);
      expect(turn.answer?.content, '最终答案');
    });

    test('多回合：user 是分界；末回合也 flush；非 🔧 回答成普通回合块', () {
      final units = groupMessages([
        userMsg('Q1'),
        asst('🔧 X ✓'),
        asst('A1'),
        userMsg('Q2'),
        asst('A2'),
      ]);
      expect(units.length, 4);
      expect(units[0], isA<UserUnit>());
      final t1 = units[1] as TurnUnit;
      expect(t1.tools.length, 1);
      expect(t1.tools.first.content, '🔧 X ✓');
      expect(t1.answer?.content, 'A1');
      expect(units[2], isA<UserUnit>());
      final t2 = units[3] as TurnUnit;
      expect(t2.tools, isEmpty);
      expect(t2.answer?.content, 'A2');
    });

    test('空输入 → 空', () {
      expect(groupMessages([]), isEmpty);
    });

    test('💭 思考存档归入回合 thinking（不入 tools 也不当回答）', () {
      final units = groupMessages([
        userMsg('Q1'),
        asst('💭 第一段思考'),
        asst('🔧 A ✓ok'),
        asst('💭 第二段思考'),
        asst('最终答案'),
      ]);
      expect(units.length, 2);
      final turn = units.last as TurnUnit;
      expect(turn.thinking, ['第一段思考', '第二段思考']);
      expect(turn.tools.length, 1);
      expect(turn.answer?.content, '最终答案');
    });
  });

  group('parseToolActivity 工具活动解析（历史回合步骤回看）', () {
    test('✓ 成功摘要', () {
      final ui = parseToolActivity(asst('🔧 file_write ✓写入 3 行'));
      expect(ui?.name, 'file_write');
      expect(ui?.status, ToolUiStatus.done);
      expect(ui?.result, '写入 3 行');
      expect(ui?.isError, isFalse);
    });

    test('⚠️ 失败（isError + 摘要）', () {
      final ui = parseToolActivity(asst('🔧 shell ⚠️exit code=1'));
      expect(ui?.name, 'shell');
      expect(ui?.status, ToolUiStatus.failed);
      expect(ui?.result, 'exit code=1');
      expect(ui?.isError, isTrue);
    });

    test('执行中（新单工具格式）', () {
      final ui = parseToolActivity(asst('🔧 正在调用 web_search…'));
      expect(ui?.name, 'web_search');
      expect(ui?.status, ToolUiStatus.executing);
      expect(ui?.result, isNull);
    });

    test('执行中（旧多工具冒号格式）也能解析', () {
      final ui = parseToolActivity(asst('🔧 正在调用：web_search、shell…'));
      expect(ui?.name, 'web_search、shell');
      expect(ui?.status, ToolUiStatus.executing);
    });

    test('非 🔧 消息 → null', () {
      expect(parseToolActivity(asst('普通回复')), isNull);
      expect(parseToolActivity(asst('🔧 无状态标记')), isNull);
    });
  });

  group('AgentTurnBlock 内嵌工作流渲染', () {
    ToolActivityUi act({
      required ToolUiStatus status,
      required String name,
      String? result,
      Map<String, dynamic>? args,
    }) => ToolActivityUi(
          callId: 'c1',
          name: name,
          arguments: args ?? const {},
          status: status,
          result: result,
        );

    Future<void> pump(WidgetTester tester, AgentUiState ui,
        {List<ToolActivityUi> steps = const [],
         ChatMessage? answer,
         bool isLive = false,
         List<String> thinking = const []}) async {
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: Center(
              child: AgentTurnBlock(
                isLive: isLive,
                steps: steps,
                answer: answer,
                ui: ui,
                thinking: thinking,
              ),
            ),
          ),
        ),
      );
    }

    testWidgets('空步骤无回答：不渲染内容', (tester) async {
      await pump(tester, const AgentUiState(), isLive: false);
      expect(find.byType(ToolActivityCard), findsNothing);
      expect(find.textContaining('思考中'), findsNothing);
    });

    testWidgets('执行中步骤：卡片 + 执行中标签', (tester) async {
      await pump(
        tester,
        const AgentUiState(running: true),
        steps: [act(status: ToolUiStatus.executing, name: 'get_time', args: {'tz': 'UTC'})],
        isLive: true,
      );
      expect(find.textContaining('🔧 get_time'), findsOneWidget);
      expect(find.textContaining('执行中'), findsOneWidget);
    });

    testWidgets('完成步骤：总折叠区展开后显示结果', (tester) async {
      await pump(
        tester,
        const AgentUiState(running: false),
        steps: [act(status: ToolUiStatus.done, name: 'get_time', result: '12:00', args: {'tz': 'UTC'})],
        isLive: false,
      );
      // 已完成回合：工具卡收进「执行过程」总折叠区，默认收起不可见。
      expect(find.textContaining('执行过程'), findsOneWidget);
      expect(find.textContaining('🔧 get_time'), findsNothing);
      await tester.tap(find.textContaining('执行过程'));
      await tester.pump();
      expect(find.textContaining('🔧 get_time'), findsOneWidget);
      // 折叠态摘要 = 结果首行（2026-10-25 用户定案：收起也要概知输出）。
      expect(find.textContaining('12:00'), findsOneWidget);
      await tester.tap(find.byType(ToolActivityCard));
      await tester.pump();
      // 展开后折叠行摘要 + 结果正文各出现一次。
      expect(find.textContaining('12:00'), findsWidgets);
      expect(find.textContaining('参数'), findsOneWidget);
    });

    testWidgets('失败步骤：⚠️ 标记 + 结果（总折叠区展开可见）', (tester) async {
      await pump(
        tester,
        const AgentUiState(running: false),
        steps: [act(status: ToolUiStatus.failed, name: 'shell', result: 'exit code=1')],
        isLive: false,
      );
      expect(find.textContaining('执行过程'), findsOneWidget);
      await tester.tap(find.textContaining('执行过程'));
      await tester.pump();
      expect(find.textContaining('🔧 shell'), findsOneWidget);
      await tester.tap(find.byType(ToolActivityCard));
      await tester.pump();
      // 失败首行顶进折叠摘要 + 展开体 OUT 段 = 至少各一处（DSH errorSummary
      // 形态：错误不只靠 ⚠️ 后缀传达，折叠行即可读）。
      expect(find.textContaining('exit code=1'), findsWidgets);
    });

    testWidgets('已完成回合：思考存档入总折叠区（展开后可回看）', (tester) async {
      await pump(
        tester,
        const AgentUiState(running: false),
        steps: [act(status: ToolUiStatus.done, name: 'get_time')],
        answer: asst('答案'),
        thinking: const ['思考一', '思考二'],
        isLive: false,
      );
      expect(find.textContaining('1 工具 · 2 思考'), findsOneWidget);
      expect(find.textContaining('思考一'), findsNothing);
      await tester.tap(find.textContaining('执行过程'));
      await tester.pump();
      // 展开后呈现思考存档块（块本身仍是折叠条）：序号已去掉（用户定案
      // 「思考 1/2/3 难看」），折叠头部直接显示思考首行摘要。
      expect(find.textContaining('思考一'), findsOneWidget);
      expect(find.textContaining('思考二'), findsOneWidget);
      await tester.tap(find.textContaining('思考一'));
      await tester.pump();
      expect(find.textContaining('思考一'), findsOneWidget);
      expect(find.textContaining('答案'), findsOneWidget);
    });

    testWidgets('运行中且无答案 → 执行中…', (tester) async {
      await pump(tester, const AgentUiState(running: true), isLive: true);
      expect(find.text('执行中…'), findsOneWidget);
      // 非 live：历史回合不显示执行中行
      await pump(tester, const AgentUiState(running: true), isLive: false);
      expect(find.text('执行中…'), findsNothing);
    });

    testWidgets('live 回合：思考与工具按执行顺序交错渲染', (tester) async {
      // 时间线 [思考0, 工具0, 思考1, 工具1] → 渲染顺序必须与执行次序一致，
      // 而非"思考一律在前、工具一律在后"（用户反馈）。
      final ui = AgentUiState(
        running: true,
        thinkingHistory: ['第一步思考', '第二步思考'],
        thinkingDurations: const [Duration(seconds: 3), Duration(seconds: 2)],
        tools: [
          act(status: ToolUiStatus.done, name: 'web_search', result: '2 条结果'),
          act(status: ToolUiStatus.done, name: 'get_weather', result: '晴'),
        ],
        timeline: const [
          UiTimelineThinking(0),
          UiTimelineTool(0),
          UiTimelineThinking(1),
          UiTimelineTool(1),
        ],
      );
      await pump(tester, ui, isLive: true);
      // 序号已去（用户定案「思考 1/2/3 难看」）：有耗时只显示「思考 - 持续了X」。
      expect(find.textContaining('思考 - 持续了3秒'), findsOneWidget);
      expect(find.textContaining('🔧 web_search'), findsOneWidget);
      expect(find.textContaining('思考 - 持续了2秒'), findsOneWidget);
      expect(find.textContaining('🔧 get_weather'), findsOneWidget);
      // 垂直顺序 = 执行顺序（思考0 → 工具0 → 思考1 → 工具1）。
      final dyThink1 = tester.getTopLeft(find.textContaining('思考 - 持续了3秒')).dy;
      final dyTool1 = tester.getTopLeft(find.textContaining('🔧 web_search')).dy;
      final dyThink2 = tester.getTopLeft(find.textContaining('思考 - 持续了2秒')).dy;
      final dyTool2 = tester.getTopLeft(find.textContaining('🔧 get_weather')).dy;
      expect(dyThink1, lessThan(dyTool1));
      expect(dyTool1, lessThan(dyThink2));
      expect(dyThink2, lessThan(dyTool2));
    });

    testWidgets('思考流式自动展开：流式中内容可见，答案开始/回合结束自动闭合',
        (tester) async {
      // 流式输出中 → 自动展开（否则用户不知道智能体在干什么）。
      // 两行思考：闭合后折叠行仍显示 latestLine 摘要（DSH 形态），
      // 但展开体整段隐藏——用首行消失判定"已闭合"。
      const thinking = '第一行推理\n第二行推理';
      final streaming = AgentUiState(running: true, thinking: thinking);
      await pump(tester, streaming, isLive: true);
      // 展开体是整段 Text（多行），用 contains 判定首行可见。
      expect(find.textContaining('第一行推理'), findsOneWidget);

      // 答案开始 → 自动闭合（展开体隐藏；折叠摘要只剩最后一行）。
      await pump(tester, streaming,
          isLive: true, answer: asst('答案'));
      expect(find.textContaining('第一行推理'), findsNothing);
      expect(find.text('第二行推理'), findsOneWidget);

      // 回合结束（running=false）→ 闭合。
      await pump(tester,
          const AgentUiState(thinking: thinking), isLive: true);
      expect(find.textContaining('第一行推理'), findsNothing);
    });

    testWidgets('思考流式长内容：自动滚动到底部，用户上滑后暂停跟随', (tester) async {
      // 流式内容超过卡片 150px 可见区时，最新输出必须滚进可见区
      //（用户反馈：内容长了之后最新输出跑到可见区外）。
      String lines(int n) =>
          List.generate(n, (i) => '流式思考第$i行内容').join('\n');
      await pump(tester, AgentUiState(running: true, thinking: lines(3)),
          isLive: true);
      await tester.pump(); // 等首帧：didUpdateWidget 的 post-frame 跟随执行
      // 内容变长 → 自动滚到底部。
      await pump(tester,
          AgentUiState(running: true, thinking: lines(60)), isLive: true);
      await tester.pump();

      final scrollable = tester.widget<Scrollable>(find.byType(Scrollable).first);
      final pos = scrollable.controller!.position;
      expect(pos.maxScrollExtent, greaterThan(0)); // 内容确实超出可见区
      expect(pos.pixels, pos.maxScrollExtent); // 已跟随到底部

      // 用户手动上滑（查看早前内容）→ 暂停跟随。
      await tester.drag(find.byType(Scrollable).first, const Offset(0, 120));
      await tester.pump();
      final before = scrollable.controller!.position.pixels;
      expect(before, lessThan(scrollable.controller!.position.maxScrollExtent));

      // 流式继续变长 → 位置保持不动（不抢用户的阅读位置）。
      await pump(tester,
          AgentUiState(running: true, thinking: lines(80)), isLive: true);
      await tester.pump();
      expect(scrollable.controller!.position.pixels, before);
    });

    testWidgets('live 显示重试/压缩横幅，非 live 不显示', (tester) async {
      final liveUi = const AgentUiState(running: true, retryAttempt: 2, compacted: true);
      await pump(tester, liveUi, isLive: true);
      expect(find.textContaining('重试中'), findsOneWidget);
      expect(find.textContaining('上下文已压缩'), findsOneWidget);
      await pump(tester, liveUi, isLive: false);
      expect(find.textContaining('重试中'), findsNothing);
      expect(find.textContaining('上下文已压缩'), findsNothing);
    });

    testWidgets('答案：渲染回答内容（无头像）', (tester) async {
      final answer = asst('答案内容');
      await pump(tester, const AgentUiState(), answer: answer, isLive: false);
      expect(find.text('答案内容'), findsOneWidget);
    });
  });
}
