import 'dart:convert';
import 'dart:io';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:wangcai/agent/dev/dev.dart';
import 'package:wangcai/project/project.dart';
import 'package:wangcai/project/project_store.dart';
import 'package:wangcai/providers/project_provider.dart';

// ---------------------------------------------------------------------------
// v0.0.4 D1 双真源收编（计划书 §5.3）：projects.json 是唯一注册表，
// dev/workspaces 只是它的派生缓存——孤儿迁移、整体重写、变更收敛、幂等。
// ---------------------------------------------------------------------------

void main() {
  late Directory projTmp;
  late Directory devTmp;
  late ProjectStore store;
  late DevStore devStore;
  late ProviderContainer container;

  String wsDir() => '${devTmp.path}/dev/workspaces';
  List<String> cacheFiles() {
    final d = Directory(wsDir());
    if (!d.existsSync()) return const [];
    return d
        .listSync()
        .whereType<File>()
        .map((f) => f.path.split(RegExp(r'[\\/]')).last)
        .toList()
      ..sort();
  }

  void seedWorkspaceFile(DevWorkspace ws) {
    Directory(wsDir()).createSync(recursive: true);
    File('${wsDir()}/${Uri.encodeComponent(ws.id.replaceAll(RegExp(r'[^A-Za-z0-9_\-]'), '-'))}.json')
        .writeAsStringSync(jsonEncode(ws.toJson()));
  }

  setUp(() {
    projTmp = Directory.systemTemp.createTempSync('wc_d1_proj_');
    devTmp = Directory.systemTemp.createTempSync('wc_d1_dev_');
    store = ProjectStore(baseDirOverride: projTmp.path);
    ProjectStore.testDefault = store;
    devStore = DevStore(baseDirOverride: devTmp.path);
    DevStore.testDefault = devStore;
    DevSessionController.testStore = devStore;
    DevSessionController.instance.debugReset();
    container = ProviderContainer();
  });

  tearDown(() async {
    container.dispose();
    ProjectStore.testDefault = null;
    DevStore.testDefault = null;
    DevSessionController.testStore = null;
    DevSessionController.instance.debugReset();
    if (projTmp.existsSync()) projTmp.deleteSync(recursive: true);
    if (devTmp.existsSync()) devTmp.deleteSync(recursive: true);
  });

  Future<void> load() async {
    // 构造期会自发跑一次 _load；不等它收尾就 refresh 会有两个 _load 并发
    // （孤儿迁移/缓存重写互踩，机器忙时真踩出过假败）。
    for (var i = 0; i < 100 && !container.read(projectsProvider).loaded; i++) {
      await Future<void>.delayed(const Duration(milliseconds: 10));
    }
    await container.read(projectsProvider.notifier).refresh();
  }

  test('孤儿工作区一次性收编为项目，孤儿文件从缓存清除', () async {
    // 一条本地孤儿（有镜像）+ 一条远程孤儿（无路径 → 占位 ~/projects/<名>）。
    seedWorkspaceFile(DevWorkspace(
        id: 'ws_legacy1', name: '旧本地区', localMirror: r'E:\old\local'));
    seedWorkspaceFile(DevWorkspace(
        id: '1730000',
        name: '旧远程区',
        backend: WorkspaceBackend.remotePc,
        sshConfigId: 'cfg-1'));

    await load();

    final st = container.read(projectsProvider);
    final legacy1 = st.projects.firstWhere((p) => p.id == 'legacy1');
    expect(legacy1.workspacePath, r'E:\old\local');
    expect(legacy1.isRemote, isFalse);
    final legacy2 = st.projects.firstWhere((p) => p.id == 'p_mig_1730000');
    expect(legacy2.isRemote, isTrue);
    expect(legacy2.sshConfigId, 'cfg-1');
    expect(legacy2.workspacePath, '~/projects/旧远程区');

    // 收编后再发布缓存：只剩项目派生项，孤儿文件已删。
    expect(cacheFiles(),
        containsAll(['ws_legacy1.json', 'ws_p_mig_1730000.json']));
    expect(File('${wsDir()}/1730000.json').existsSync(), isFalse);

    // 幂等重入：再 load 一次不多不少。
    await load();
    expect(container.read(projectsProvider).projects.length,
        st.projects.length);
  });

  test('缓存 = 项目的纯派生投影：create/rename/remove 全收敛', () async {
    await load(); // 建默认项目
    final p = await container.read(projectsProvider.notifier).create(
        name: '博客', workspacePath: r'D:\blog', activate: false);
    expect(File('${wsDir()}/ws_${p.id}.json').existsSync(), isTrue);
    final cached = DevSessionController.instance.workspaces
        .firstWhere((w) => w.id == 'ws_${p.id}');
    expect(cached.localMirror, r'D:\blog');
    expect(cached.backend, WorkspaceBackend.localApp);

    await container.read(projectsProvider.notifier).rename(p.id, '博客二代');
    final renamed = DevSessionController.instance.workspaces
        .firstWhere((w) => w.id == 'ws_${p.id}');
    expect(renamed.name, '博客二代');

    await container.read(projectsProvider.notifier).remove(p.id);
    expect(
        DevSessionController.instance.workspaces.any((w) => w.id == 'ws_${p.id}'),
        isFalse);
    expect(File('${wsDir()}/ws_${p.id}.json').existsSync(), isFalse);
  });

  test('缓存内容漂移被派生重写覆盖；激活项目的工作区跟随切换', () async {
    // 手工埋一份与注册表矛盾的陈旧缓存（名字/路径都是错的）——
    // 派生重写以 projects.json 为准，缓存里的旧值不可能存活。
    seedWorkspaceFile(
        DevWorkspace(id: 'ws_p_default', name: '幽灵名', localMirror: r'D:\wrong'));
    await load();
    final def = DevSessionController.instance.workspaces
        .firstWhere((w) => w.id == 'ws_p_default');
    expect(def.name, Project.kDefaultName);
    expect(def.localMirror, isNot(r'D:\wrong'));

    final p = await container.read(projectsProvider.notifier)
        .create(name: '远程', workspacePath: '/home/u/proj', sshConfigId: 'c1');
    final dev = DevSessionController.instance;
    expect(dev.activeWorkspaceId, 'ws_${p.id}');
    final active = dev.activeWorkspace;
    expect(active.isRemote, isTrue);
    expect(active.remotePath, '/home/u/proj');
    expect(active.sshConfigId, 'c1');
  });

  test('devWorkspaceFor / projectIdOfDevWorkspace 派生纪律', () {
    final local = Project(id: 'p_a', name: 'A', workspacePath: r'D:\a',
        createdAt: DateTime(2026));
    final w1 = devWorkspaceFor(local);
    expect(w1.id, 'ws_p_a');
    expect(w1.localMirror, r'D:\a');
    expect(w1.remotePath, isNull);
    expect(projectIdOfDevWorkspace('ws_p_a'), 'p_a');
    expect(projectIdOfDevWorkspace('default'), isNull);
    expect(projectIdOfDevWorkspace('ws_'), isNull);
    final remote = Project(
        id: 'p_b', name: 'B', workspacePath: '/srv', sshConfigId: 's',
        createdAt: DateTime(2026));
    final w2 = devWorkspaceFor(remote);
    expect(w2.isRemote, isTrue);
    expect(w2.remotePath, '/srv');
    expect(w2.sshConfigId, 's');
  });
}
