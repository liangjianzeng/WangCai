import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

import 'package:tongyi_lite/agent/dev/task.dart';
import 'package:tongyi_lite/agent/dev/tools/plan_tools.dart';
import 'package:tongyi_lite/agent/dev/workspace.dart';
import 'package:tongyi_lite/agent/dev/workspace_store.dart';

void main() {
  late Directory tmp;
  late DevStore store;

  setUp(() {
    tmp = Directory.systemTemp.createTempSync('plan_tools_test');
    store = DevStore(baseDirOverride: tmp.path);
  });

  tearDown(() {
    if (tmp.existsSync()) tmp.deleteSync(recursive: true);
  });

  /// 预置一个任务。
  Future<void> seedTask() async {
    await store.saveTask(DevTask(
      id: 't1',
      title: '实现 SSH 工具',
      workspaceId: 'ws_1',
      status: DevTaskStatus.planning,
      createdAt: DateTime.now(),
      updatedAt: DateTime.now(),
    ));
  }

  group('plan_create', () {
    test('创建计划：3 步 + 验证标准，任务进入 implementing', () async {
      await seedTask();
      final tool = createPlanCreateTool(store: store);
      final result = await tool.execute({
        'task_id': 't1',
        'steps': [
          {'title': '步骤一', 'detail': '写代码', 'verify': '编译通过'},
          {'title': '步骤二', 'verify': '测试通过'},
          {'title': '步骤三'},
        ],
      });
      expect(result.isError, isFalse);
      expect(result.content, contains('计划已建立（3 步）'));
      expect(result.content, contains('步骤一'));
      expect(result.content, contains('完成标准：编译通过'));
      final task = (await store.loadTasks()).first;
      expect(task.status, DevTaskStatus.implementing);
      expect(task.plan!.steps.length, 3);
    });

    test('非法步骤丢弃；全空报错', () async {
      await seedTask();
      final tool = createPlanCreateTool(store: store);
      final result = await tool.execute({
        'task_id': 't1',
        'steps': [
          {'title': ''},
          {'no_title': true},
        ],
      });
      expect(result.isError, isTrue);
      expect(result.content, contains('steps 为空'));
    });

    test('任务不存在 → 自动创建（title 缺省取第一步标题）', () async {
      final tool = createPlanCreateTool(store: store);
      final result = await tool.execute({
        'task_id': 'fix-login',
        'steps': [
          {'title': 'A'},
        ],
      });
      expect(result.isError, isFalse);
      expect(result.content, contains('已自动创建'));
      final task = (await store.loadTasks()).first;
      expect(task.id, 'fix-login');
      expect(task.title, 'A');
      expect(task.workspaceId, isNull); // 无注入工作区 → 无主
    });

    test('任务不存在 + title → 用 title 建任务', () async {
      final tool = createPlanCreateTool(store: store);
      final result = await tool.execute({
        'task_id': 'fix-login',
        'title': '修复登录页',
        'steps': [
          {'title': 'A'},
        ],
      });
      expect(result.isError, isFalse);
      final task = (await store.loadTasks()).first;
      expect(task.title, '修复登录页');
    });

    test('plan_create 自动建任务绑定注入的工作区（_workspaceId）', () async {
      await store.saveWorkspace(const DevWorkspace(
          id: 'ws_1', name: '项目一', backend: WorkspaceBackend.localApp));
      final tool = createPlanCreateTool(store: store);
      final result = await tool.execute({
        '_workspaceId': 'ws_1',
        'task_id': 't9',
        'steps': [
          {'title': 'A'},
        ],
      });
      expect(result.isError, isFalse);
      final task = (await store.loadTasks()).first;
      expect(task.workspaceId, 'ws_1');
    });

    test('plan_create 指定不存在的工作区报错', () async {
      final tool = createPlanCreateTool(store: store);
      final result = await tool.execute({
        'task_id': 't9',
        'workspace_id': 'nope',
        'steps': [
          {'title': 'A'},
        ],
      });
      expect(result.isError, isTrue);
      expect(result.content, contains('工作区不存在'));
    });
  });

  group('task_create / task_list', () {
    test('创建任务绑定省略时用注入工作区；带 steps 一步建计划', () async {
      await store.saveWorkspace(const DevWorkspace(
          id: 'ws_2', name: '项目二', backend: WorkspaceBackend.termux));
      final tool = createTaskCreateTool(store: store);
      final result = await tool.execute({
        '_workspaceId': 'ws_2',
        'title': '重构存储层',
        'steps': [
          {'title': 'S1', 'verify': '编译过'},
          {'title': 'S2'},
        ],
      });
      expect(result.isError, isFalse);
      expect(result.content, contains('工作区 ws_2'));
      expect(result.content, contains('计划 2 步'));
      final task = (await store.loadTasks()).first;
      expect(task.workspaceId, 'ws_2');
      expect(task.status, DevTaskStatus.implementing);
      expect(task.plan!.steps.length, 2);
    });

    test('不带 steps → planning 状态无计划', () async {
      final tool = createTaskCreateTool(store: store);
      final result = await tool.execute({'title': '只建任务'});
      expect(result.isError, isFalse);
      expect(result.content, contains('plan_create'));
      final task = (await store.loadTasks()).first;
      expect(task.status, DevTaskStatus.planning);
      expect(task.plan, isNull);
    });

    test('显式 workspace_id 不存在报错', () async {
      final tool = createTaskCreateTool(store: store);
      final result = await tool.execute(
          {'title': 'x', 'workspace_id': 'ghost'});
      expect(result.isError, isTrue);
      expect(result.content, contains('工作区不存在'));
    });

    test('task_list 按当前工作区过滤（默认收编无主任务）', () async {
      Future<void> seed(String id, String? wsId) async {
        await store.saveTask(DevTask(
          id: id,
          title: '任务$id',
          workspaceId: wsId,
          createdAt: DateTime.now(),
          updatedAt: DateTime.now(),
        ));
      }

      await seed('a', null);
      await seed('b', 'ws_1');
      // 注入默认工作区 → 只见无主任务。
      final r1 = await createTaskListTool(store: store)
          .execute({'_workspaceId': 'default'});
      expect(r1.content, contains('任务a'));
      expect(r1.content, isNot(contains('任务b')));
      // 注入 ws_1 → 只见 ws_1 任务。
      final r2 = await createTaskListTool(store: store)
          .execute({'_workspaceId': 'ws_1'});
      expect(r2.content, contains('任务b'));
      expect(r2.content, isNot(contains('任务a')));
      // 无注入 → 全量（旧行为兼容）。
      final r3 = await createTaskListTool(store: store).execute({});
      expect(r3.content, contains('任务a'));
      expect(r3.content, contains('任务b'));
      // 空列表提示。
      final store2 = DevStore(
          baseDirOverride:
              '${tmp.path}/empty-${DateTime.now().microsecondsSinceEpoch}');
      final r4 = await createTaskListTool(store: store2).execute({});
      expect(r4.content, contains('还没有任务'));
    });

    test('task_list 显示状态与进度', () async {
      await store.saveTask(DevTask(
        id: 't1',
        title: '实现 SSH 工具',
        status: DevTaskStatus.implementing,
        plan: DevPlan(steps: [
          const DevPlanStep(id: 's1', title: 'A', done: true),
          const DevPlanStep(id: 's2', title: 'B'),
        ], currentStep: 1),
        createdAt: DateTime.now(),
        updatedAt: DateTime.now(),
      ));
      final result =
          await createTaskListTool(store: store).execute({});
      expect(result.content, contains('实施中'));
      expect(result.content, contains('进度 1/2'));
    });
  });

  group('plan_update mark_done', () {
    test('标记完成自动推进下一步', () async {
      await seedTask();
      await createPlanCreateTool(store: store).execute({
        'task_id': 't1',
        'steps': [
          {'title': 'A'},
          {'title': 'B'},
        ],
      });
      final tool = createPlanUpdateTool(store: store);
      final result = await tool.execute({
        'task_id': 't1',
        'action': 'mark_done',
        'step_id': 's1',
      });
      expect(result.isError, isFalse);
      expect(result.content, contains('已完成：A'));
      expect(result.content, contains('下一步：B'));
      final task = (await store.loadTasks()).first;
      expect(task.plan!.steps[0].done, isTrue);
      expect(task.plan!.nextPendingIndex, 1);
    });

    test('全部完成 → 进入 verifying', () async {
      await seedTask();
      await createPlanCreateTool(store: store).execute({
        'task_id': 't1',
        'steps': [
          {'title': 'A'},
          {'title': 'B'},
        ],
      });
      final tool = createPlanUpdateTool(store: store);
      await tool.execute({
        'task_id': 't1',
        'action': 'mark_done',
        'step_id': 's1',
      });
      final result = await tool.execute({
        'task_id': 't1',
        'action': 'mark_done',
        'step_id': 's2',
      });
      expect(result.content, contains('全部 2 步已完成'));
      final task = (await store.loadTasks()).first;
      expect(task.status, DevTaskStatus.verifying);
      expect(task.plan!.allDone, isTrue);
    });

    test('取消完成（done=false）', () async {
      await seedTask();
      await createPlanCreateTool(store: store).execute({
        'task_id': 't1',
        'steps': [
          {'title': 'A'},
        ],
      });
      final tool = createPlanUpdateTool(store: store);
      await tool.execute({
        'task_id': 't1',
        'action': 'mark_done',
        'step_id': 's1',
      });
      final result = await tool.execute({
        'task_id': 't1',
        'action': 'mark_done',
        'step_id': 's1',
        'done': false,
      });
      expect(result.content, contains('已取消完成'));
      final task = (await store.loadTasks()).first;
      expect(task.plan!.steps[0].done, isFalse);
    });
  });

  group('plan_update add_step', () {
    test('追加步骤', () async {
      await seedTask();
      await createPlanCreateTool(store: store).execute({
        'task_id': 't1',
        'steps': [
          {'title': 'A'},
        ],
      });
      final tool = createPlanUpdateTool(store: store);
      final result = await tool.execute({
        'task_id': 't1',
        'action': 'add_step',
        'step': {'title': '新步骤', 'verify': '冒烟通过'},
      });
      expect(result.isError, isFalse);
      expect(result.content, contains('现在共 2 步'));
      final task = (await store.loadTasks()).first;
      expect(task.plan!.steps.last.id, 's2');
      expect(task.plan!.steps.last.verify, '冒烟通过');
    });
  });

  group('plan_list', () {
    test('列出步骤与状态', () async {
      await seedTask();
      await createPlanCreateTool(store: store).execute({
        'task_id': 't1',
        'steps': [
          {'title': 'A', 'verify': '编译'},
          {'title': 'B'},
        ],
      });
      await createPlanUpdateTool(store: store).execute({
        'task_id': 't1',
        'action': 'mark_done',
        'step_id': 's1',
      });
      final result = await createPlanListTool(store: store).execute({
        'task_id': 't1',
      });
      expect(result.content, contains('当前进行：B'));
      expect(result.content, contains('✅ s1 A'));
      expect(result.content, contains('▶  s2 B')); // 前缀与 id 前各一空格
    });
  });

  group('DevPlan 模型', () {
    test('fromJson 过滤非法步骤', () {
      final plan = DevPlan.fromJson({
        'steps': [
          {'id': 's1', 'title': 'ok', 'done': true},
          'not-a-map',
          {'no_title': true},
          {'id': 's2', 'title': 'ok2'},
        ],
        'currentStep': 0,
      });
      expect(plan!.steps.length, 2);
      expect(plan!.steps[0].done, isTrue);
    });
  });
}
