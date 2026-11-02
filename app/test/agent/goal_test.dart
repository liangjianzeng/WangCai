/// P1-A goal 无人值守续跑：存储 / 决策函数 / 工具组 / exit_plan 审批。
import 'dart:io';

import 'package:tongyi_lite/agent/builtin_tools/goal_tools.dart';
import 'package:tongyi_lite/agent/goal/goal_store.dart';
import 'package:tongyi_lite/agent/builtin_tools/goal_tools.dart'
    show createPlanStepUpdateTool;
import 'package:flutter_test/flutter_test.dart';

void main() {
  late Directory dir;
  late GoalStore store;
  const conv = 'conv-1';

  setUp(() async {
    dir = await Directory.systemTemp.createTemp('goal_test');
    store = GoalStore(baseDir: dir.path);
  });

  tearDown(() => dir.deleteSync(recursive: true));

  group('decideGoalAction（纯决策）', () {
    final active = GoalState(
        goal: 'g', rounds: 0, maxRounds: 3, status: GoalStatus.active,
        origin: 'user', createdAtMs: 0);
    test('无目标 → none', () {
      expect(decideGoalAction(null, turnCompleted: true), GoalAction.none);
    });
    test('活跃+完成+未耗尽 → continueTurn', () {
      expect(decideGoalAction(active, turnCompleted: true),
          GoalAction.continueTurn);
    });
    test('活跃+完成+耗尽 → expire', () {
      expect(
          decideGoalAction(active.copyWith(rounds: 3), turnCompleted: true),
          GoalAction.expire);
    });
    test('回合未完成（失败/中断）→ 不续跑', () {
      expect(decideGoalAction(active, turnCompleted: false), GoalAction.none);
    });
    test('已终结 → settle', () {
      expect(
          decideGoalAction(active.copyWith(status: GoalStatus.done),
              turnCompleted: true),
          GoalAction.settle);
    });
  });

  group('GoalStore', () {
    test('setGoal → load 往返；重复 setGoal 更新不重置轮数', () async {
      await store.setGoal(conv,
          goalText: '重构模块', maxRounds: 5, origin: 'user');
      var g = await store.load(conv);
      expect(g, isNotNull);
      expect(g!.goal, '重构模块');
      expect(g.maxRounds, 5);
      expect(g.isActive, isTrue);
      await store.bumpRound(conv);
      await store.setGoal(conv,
          goalText: '重构模块 v2', maxRounds: 5, origin: 'plan');
      g = await store.load(conv);
      expect(g!.goal, '重构模块 v2');
      expect(g.rounds, 1, reason: '更新目标不清零已用轮数');
      expect(g.origin, 'plan');
    });

    test('bumpRound 推进；finish 终结后 load 返回 null', () async {
      await store.setGoal(conv, goalText: 'g', maxRounds: 2, origin: 'user');
      await store.bumpRound(conv);
      final g = await store.load(conv);
      expect(g!.rounds, 1);
      expect(g.exhausted, isFalse);
      await store.bumpRound(conv);
      final g2 = await store.load(conv);
      expect(g2!.exhausted, isTrue);
      final finished = await store.finish(conv, GoalStatus.done);
      expect(finished, isNotNull);
      expect(await store.load(conv), isNull);
    });

    test('不同会话互不干扰', () async {
      await store.setGoal(conv, goalText: 'A', maxRounds: 2, origin: 'user');
      await store.setGoal('conv-2', goalText: 'B', maxRounds: 2, origin: 'user');
      expect((await store.load(conv))!.goal, 'A');
      expect((await store.load('conv-2'))!.goal, 'B');
    });
  });

  group('goal 工具组', () {
    test('goal_set → goal_complete 全流程', () async {
      final tools = createGoalTools(store: store, conversationId: conv, maxRounds: 6);
      final byName = {for (final t in tools) t.name: t};
      final r1 = await byName['goal_set']!.execute({'goal': '完成任务 X'});
      expect(r1.isError, isFalse);
      expect(r1.content, contains('完成任务 X'));
      final g = await store.load(conv);
      expect(g!.maxRounds, 6);
      final r2 = await byName['goal_complete']!.execute({'summary': '做完了'});
      expect(r2.isError, isFalse);
      expect(await store.load(conv), isNull);
    });

    test('goal_set 空 goal 报错；goal_complete 无目标报错', () async {
      final tools = createGoalTools(store: store, conversationId: conv, maxRounds: 6);
      final byName = {for (final t in tools) t.name: t};
      expect((await byName['goal_set']!.execute({'goal': '  '})).isError, isTrue);
      expect(
          (await byName['goal_complete']!.execute({'summary': 'x'})).isError,
          isTrue);
    });

    test('goal_cancel 取消目标', () async {
      final tools = createGoalTools(store: store, conversationId: conv, maxRounds: 6);
      final byName = {for (final t in tools) t.name: t};
      await byName['goal_set']!.execute({'goal': 'g'});
      final r = await byName['goal_cancel']!.execute({'reason': '用户放弃'});
      expect(r.isError, isFalse);
      expect(await store.load(conv), isNull);
    });
  });

  group('exit_plan 审批工具', () {
    test('批准 → 计划落为持久目标（origin=plan）', () async {
      final tool = createExitPlanTool(
        store: store,
        conversationId: conv,
        maxRounds: 4,
        ask: (question, options) async {
          expect(question, contains('执行计划'));
          expect(options, contains('批准执行'));
          return '批准执行';
        },
      );
      final r = await tool.execute({'plan': '1. 做 A\n2. 验证 A'});
      expect(r.isError, isFalse);
      expect(r.content, contains('已获批准'));
      final g = await store.load(conv);
      expect(g, isNotNull);
      expect(g!.origin, 'plan');
      expect(g.goal, contains('1. 做 A'));
    });

    test('拒绝 → 返回意见，不设目标', () async {
      final tool = createExitPlanTool(
        store: store,
        conversationId: conv,
        maxRounds: 4,
        ask: (question, options) async => '不批准（回复修改意见）：先补风险分析',
      );
      final r = await tool.execute({'plan': 'P'});
      expect(r.isError, isFalse);
      expect(r.content, contains('未批准'));
      expect(r.content, contains('先补风险分析'));
      expect(await store.load(conv), isNull);
    });

    test('批准 + steps → 结构化计划落库，plan_step_update 推进进度', () async {
      final tool = createExitPlanTool(
        store: store,
        conversationId: conv,
        maxRounds: 4,
        ask: (question, options) async => '批准执行',
      );
      final cards = <String>[];
      final upd = createPlanStepUpdateTool(
        store: store,
        conversationId: conv,
        onPlanChanged: cards.add,
      );
      final r = await tool.execute({
        'plan': '整体计划文本',
        'title': '重构登录',
        'steps': [
          {'title': '调研', 'detail': '读代码', 'verify': '列出要点'},
          {'title': '改造', 'verify': '测试过'},
          {'title': '回归'},
        ],
      });
      expect(r.isError, isFalse);
      final g = await store.load(conv);
      expect(g, isNotNull);
      expect(g!.title, '重构登录');
      expect(g.steps.length, 3);
      expect(g.steps[0].verify, '列出要点');
      expect(g.currentStepIndex, 0);

      // plan_step_update：完成第 1 步 → 进度 1/3，当前步 = 2
      final r1 = await upd.execute({'step_index': 1, 'status': 'done'});
      expect(r1.isError, isFalse);
      expect(r1.content, contains('进度 1/3'));
      expect(r1.content, contains('2. 改造'));
      final g1 = await store.load(conv);
      expect(g1!.steps[0].status, PlanStepStatus.done);
      expect(g1.currentStepIndex, 1);
      // 回调收到计划卡（固定 id 活卡内容）
      expect(cards, isNotEmpty);
      expect(cards.last, contains('📋 计划：重构登录'));
      expect(cards.last, contains('✓ 1. 调研'));

      // 越界与坏状态
      expect(
          (await upd.execute({'step_index': 9, 'status': 'done'})).isError,
          isTrue);
      expect(
          (await upd.execute({'step_index': 1, 'status': 'bad'})).isError,
          isTrue);
      // 无计划会话报错
      final upd2 = createPlanStepUpdateTool(store: store, conversationId: 'other');
      expect((await upd2.execute({'step_index': 1, 'status': 'done'})).isError,
          isTrue);
      // 全部完成 → currentStepIndex = -1，progressText 提示收尾
      await upd.execute({'step_index': 2, 'status': 'done'});
      await upd.execute({'step_index': 3, 'status': 'done'});
      expect((await store.load(conv))!.currentStepIndex, -1);
    });

    test('旧 JSON 兼容：无 id/title/steps 字段正常解析', () async {
      // 直接写一个旧版 JSON（2026-10-05 前格式）
      final f = File('${dir.path}/goal_conv_old.json');
      await f.writeAsString(
          '{"goal":"旧目标","rounds":2,"maxRounds":5,"status":"active","origin":"user","createdAt":123}');
      final store2 = GoalStore(baseDir: dir.path);
      final g = await store2.load('conv_old');
      expect(g, isNotNull);
      expect(g!.goal, '旧目标');
      expect(g.steps, isEmpty);
      expect(g.rounds, 2);
    });

    test('用户未回应 → 明确报错不设目标', () async {
      final tool = createExitPlanTool(
        store: store,
        conversationId: conv,
        maxRounds: 4,
        ask: (question, options) async => null,
      );
      final r = await tool.execute({'plan': 'P'});
      expect(r.isError, isTrue);
      expect(await store.load(conv), isNull);
    });
  });
}
