/// 远程电脑「在哪干活」这条链路的回归（2026-10-27）：
/// 激活工作区必须跨启动记住（A），聊天页/向导共用的工作区动作可预期（B/C/D 的地基）。
///
/// 实锤 bug：`InferenceSettings.devWorkspaceId` 只写不读、`DevSessionController`
/// 激活态只在内存 → 杀 App 重开悄悄回落「本地沙盒」，用户表现为
/// "连上了远程电脑，智能体却不肯在电脑上干活"。
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

import 'package:tongyi_lite/agent/dev/dev_controller.dart';
import 'package:tongyi_lite/agent/dev/dev_workspace_actions.dart';
import 'package:tongyi_lite/agent/dev/ssh/ssh_credentials.dart';
import 'package:tongyi_lite/agent/dev/workspace.dart';
import 'package:tongyi_lite/agent/dev/workspace_store.dart';

const _pc = DevWorkspace(
  id: 'ws_pc',
  name: '电脑上的 TongYi-Lite',
  backend: WorkspaceBackend.remotePc,
  remotePath: '/home/alice/projects/tongyi',
  sshConfigId: 'remote-pc',
);

const _local = DevWorkspace(
  id: 'ws_local',
  name: '本地项目',
  backend: WorkspaceBackend.localApp,
);

void main() {
  late Directory tmp;
  late DevStore store;

  setUp(() {
    tmp = Directory.systemTemp.createTempSync('dev_active_test');
    store = DevStore(baseDirOverride: tmp.path);
    DevSessionController.testStore = store;
    DevSessionController.instance.debugReset();
  });

  tearDown(() {
    DevSessionController.testStore = null;
    DevSessionController.instance.debugReset();
    if (tmp.existsSync()) tmp.deleteSync(recursive: true);
  });

  group('激活工作区持久化（A）', () {
    test('无落盘 → null；落盘后可读回；clear 后回 null', () async {
      expect(await store.loadActiveWorkspaceId(), isNull);
      await store.saveActiveWorkspaceId('ws_pc');
      expect(await store.loadActiveWorkspaceId(), 'ws_pc');
      await store.clearActiveWorkspaceId();
      expect(await store.loadActiveWorkspaceId(), isNull);
    });

    test('激活文件损坏 → null（回落默认，绝不因坏文件起不来）', () async {
      await store.saveActiveWorkspaceId('ws_pc');
      final f = File('${tmp.path}/dev/active_workspace.json');
      expect(f.existsSync(), isTrue, reason: '应落在 dev/ 下');
      f.writeAsStringSync('{ 这不是 JSON');
      expect(await store.loadActiveWorkspaceId(), isNull);
    });

    test('init 恢复落盘的激活 id —— 杀 App 重开不再回落本地沙盒', () async {
      await store.saveWorkspace(_pc);
      await store.saveActiveWorkspaceId('ws_pc');
      final dev = DevSessionController.instance;
      await dev.init();
      expect(dev.activeWorkspaceId, 'ws_pc');
      expect(dev.activeWorkspace.backend, WorkspaceBackend.remotePc);
      expect(dev.activeWorkspace.remotePath, '/home/alice/projects/tongyi');
    });

    test('init 兜底用设置里的 devWorkspaceId（老用户配置不丢）', () async {
      await store.saveWorkspace(_pc);
      final dev = DevSessionController.instance;
      await dev.init(preferredActiveId: 'ws_pc');
      expect(dev.activeWorkspaceId, 'ws_pc');
    });

    test('恢复优先级：DevStore 落盘值 > 设置种子', () async {
      await store.saveWorkspace(_pc);
      await store.saveWorkspace(_local);
      await store.saveActiveWorkspaceId('ws_local');
      final dev = DevSessionController.instance;
      await dev.init(preferredActiveId: 'ws_pc');
      expect(dev.activeWorkspaceId, 'ws_local');
    });

    test('悬空 id（工作区已删）→ 回落默认，不崩', () async {
      final dev = DevSessionController.instance;
      await dev.init(preferredActiveId: '不存在的区');
      expect(dev.activeWorkspaceId, DevWorkspace.kDefaultId);
    });

    test('switchWorkspace 必须落盘（模拟重开：debugReset + init 仍在那个工作区）',
        () async {
      final dev = DevSessionController.instance;
      await dev.upsertWorkspace(_pc);
      await dev.switchWorkspace('ws_pc');
      expect(dev.activeWorkspaceId, 'ws_pc');
      expect(await store.loadActiveWorkspaceId(), 'ws_pc');

      dev.debugReset();
      await dev.init();
      expect(dev.activeWorkspaceId, 'ws_pc', reason: '这才是"重开还在"的证据');
    });

    test('切到不存在的工作区被忽略，且不动落盘值', () async {
      final dev = DevSessionController.instance;
      await dev.init();
      await dev.switchWorkspace('ghost');
      expect(dev.activeWorkspaceId, DevWorkspace.kDefaultId);
      expect(await store.loadActiveWorkspaceId(), isNull);
    });

    test('删掉激活中的工作区 → 回落默认并清掉激活标记', () async {
      final dev = DevSessionController.instance;
      await dev.upsertWorkspace(_pc);
      await dev.switchWorkspace('ws_pc');
      await dev.deleteWorkspace('ws_pc');
      expect(dev.activeWorkspaceId, DevWorkspace.kDefaultId);
      expect(await store.loadActiveWorkspaceId(), isNull,
          reason: '留着幽灵 id，下次启动会把设置种子又捡回来');
    });
  });

  group('工作区动作库（B/C/D 共用）', () {
    test('pickSshConfigForWorkspace：绑定 id 命中优先于"第一份完整配置"', () {
      const incomplete = SshConfig(id: 'a', host: 'h', username: 'u');
      const bound = SshConfig(
          id: 'remote-pc', host: 'pc', username: 'alice', password: 'pw');
      final picked = pickSshConfigForWorkspace(_pc, const [incomplete, bound]);
      expect(picked?.id, 'remote-pc');
    });

    test('pickSshConfigForWorkspace：未绑定 → 第一份配置完整的；全不完整 → null',
        () {
      const bad = SshConfig(id: 'a', host: '', username: 'u');
      const good = SshConfig(
          id: 'b',
          host: 'pc',
          username: 'alice',
          authType: SshAuthType.password,
          password: 'pw');
      const unbound = DevWorkspace(
          id: 'w', name: 'w', backend: WorkspaceBackend.remotePc);
      expect(pickSshConfigForWorkspace(unbound, const [bad, good])?.id, 'b');
      expect(pickSshConfigForWorkspace(unbound, const [bad]), isNull);
    });

    test('createAndActivateWorkspace：建完即激活、落盘、清掉空路径', () async {
      final ws = await createAndActivateWorkspace(
        name: '  博客项目  ',
        backend: WorkspaceBackend.termux,
        remotePath: '  ',
        sshConfigId: 'termux',
      );
      expect(ws.name, '博客项目');
      expect(ws.remotePath, isNull, reason: '空白路径不落库（否则工具层拿到空目录）');
      expect(ws.sshConfigId, 'termux');
      expect(ws.isRemote, isTrue);
      expect(DevSessionController.instance.activeWorkspaceId, ws.id);

      // 重开仍在（真机痛点）。
      DevSessionController.instance.debugReset();
      await DevSessionController.instance.init();
      expect(DevSessionController.instance.activeWorkspaceId, ws.id);
      expect(
          DevSessionController.instance.activeWorkspace.backend,
          WorkspaceBackend.termux);
    });

    test('未连接时"在当前电脑上开工"给出可执行的下一步，而不是空失败', () async {
      final r = await createWorkspaceOnActiveConnection('随便');
      expect(r.ws, isNull);
      expect(r.dir, contains('连接'));
      expect(DevSessionController.instance.activeWorkspaceId,
          DevWorkspace.kDefaultId, reason: '失败不许留下半个激活工作区');
    });

    test('空名字直接拒绝，不碰连接', () async {
      final r = await createWorkspaceOnActiveConnection('   ');
      expect(r.ws, isNull);
      expect(r.dir, contains('名称'));
    });

    test('后端文案四种都给（聊天页与设置页共用一套说法）', () {
      expect(workspaceBackendLabel(WorkspaceBackend.remotePc), '远程电脑');
      expect(workspaceBackendLabel(WorkspaceBackend.termux), contains('Termux'));
      expect(workspaceBackendLabel(WorkspaceBackend.localApp), '本地沙盒');
      expect(workspaceBackendLabel(WorkspaceBackend.embedded), contains('沙箱'));
    });
  });
}
