import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

import 'package:tongyi_lite/agent/dev/dev_context.dart';
import 'package:tongyi_lite/agent/dev/task.dart';
import 'package:tongyi_lite/agent/dev/workspace.dart';
import 'package:tongyi_lite/agent/dev/workspace_store.dart';

void main() {
  late Directory tmp;
  late DevStore store;

  setUp(() {
    tmp = Directory.systemTemp.createTempSync('dev_context_test');
    store = DevStore(baseDirOverride: tmp.path);
  });

  tearDown(() {
    if (tmp.existsSync()) tmp.deleteSync(recursive: true);
  });

  group('buildWorkspaceContextSection', () {
    test('默认工作区（无 IO）：本地沙盒段', () async {
      final text = await buildWorkspaceContextSection();
      expect(text, contains('<workspace:context>'));
      expect(text, contains('本地沙盒'));
      expect(text, contains('「默认工作区」'));
    });

    test('远端工作区：含远端路径与分支', () async {
      await store.saveWorkspace(const DevWorkspace(
        id: 'ws_1',
        name: '博客项目',
        backend: WorkspaceBackend.termux,
        remotePath: '/data/data/com.termux/files/home/blog',
        currentBranch: 'dev',
      ));
      final text = await buildWorkspaceContextSection(
          workspaceId: 'ws_1', store: store);
      expect(text, contains('博客项目'));
      expect(text, contains('Termux'));
      expect(text, contains('/data/data/com.termux/files/home/blog'));
      expect(text, contains('分支 dev'));
    });

    test('工作区不存在 → 空（不崩）', () async {
      final text = await buildWorkspaceContextSection(
          workspaceId: 'ghost', store: store);
      expect(text, isEmpty);
    });
  });

  group('buildPlanSection', () {
    test('无任务 → 空', () async {
      expect(await buildPlanSection(null, store: store), isEmpty);
      expect(await buildPlanSection('ghost', store: store), isEmpty);
    });

    test('有任务无计划 → 空', () async {
      await store.saveTask(DevTask(
        id: 't1',
        title: 'X',
        workspaceId: 'ws_1',
        status: DevTaskStatus.planning,
        createdAt: DateTime.now(),
        updatedAt: DateTime.now(),
      ));
      expect(await buildPlanSection('t1', store: store), isEmpty);
    });

    test('有计划 → 当前步骤 + 完成进度', () async {
      await store.saveTask(DevTask(
        id: 't1',
        title: 'X',
        workspaceId: 'ws_1',
        status: DevTaskStatus.implementing,
        createdAt: DateTime.now(),
        updatedAt: DateTime.now(),
        plan: DevPlan(steps: [
          DevPlanStep(id: 's1', title: 'A', done: true),
          DevPlanStep(id: 's2', title: 'B', verify: '测试通过'),
          DevPlanStep(id: 's3', title: 'C'),
        ], currentStep: 1),
      ));
      final text = await buildPlanSection('t1', store: store);
      expect(text, contains('<current-plan>'));
      expect(text, contains('当前步骤：B'));
      expect(text, contains('完成标准：测试通过'));
      expect(text, contains('已完成 1/3'));
    });

    test('全部完成 → 进入验证/收尾', () async {
      await store.saveTask(DevTask(
        id: 't1',
        title: 'X',
        workspaceId: 'ws_1',
        status: DevTaskStatus.verifying,
        createdAt: DateTime.now(),
        updatedAt: DateTime.now(),
        plan: DevPlan(steps: [
          DevPlanStep(id: 's1', title: 'A', done: true),
          DevPlanStep(id: 's2', title: 'B', done: true),
        ], currentStep: 2),
      ));
      final text = await buildPlanSection('t1', store: store);
      expect(text, contains('计划全部完成'));
    });
  });

  group('buildDevContext 组合', () {
    test('开发循环指引恒注入', () async {
      final text = await buildDevContext(store: store);
      expect(text, contains('[开发工作循环]'));
      expect(text, contains('git_status'));
      expect(text, contains('run_tests'));
    });

    test('默认工作区 + 任务计划组合', () async {
      await store.saveTask(DevTask(
        id: 't1',
        title: '实现 SSH 工具',
        workspaceId: DevWorkspace.kDefaultId,
        status: DevTaskStatus.implementing,
        createdAt: DateTime.now(),
        updatedAt: DateTime.now(),
        plan: DevPlan(steps: [
          DevPlanStep(id: 's1', title: '写代码', verify: '编译通过'),
        ], currentStep: 0),
      ));
      final text = await buildDevContext(
          workspaceId: null, taskId: 't1', store: store);
      expect(text, contains('当前任务：「实现 SSH 工具」'));
      expect(text, contains('当前步骤：写代码'));
      expect(text, contains('[开发工作循环]'));
    });

    test('includeInstruction=false 只注入上下文段', () async {
      final text = await buildDevContext(
          store: store, includeInstruction: false);
      expect(text, isNot(contains('[开发工作循环]')));
    });
  });
}
