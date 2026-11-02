import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

import 'package:tongyi_lite/agent/dev/workspace.dart';
import 'package:tongyi_lite/agent/dev/workspace_store.dart';

void main() {
  late Directory tmp;
  late DevStore store;

  setUp(() {
    tmp = Directory.systemTemp.createTempSync('dev_workspace_test');
    store = DevStore(baseDirOverride: tmp.path);
  });

  tearDown(() {
    if (tmp.existsSync()) tmp.deleteSync(recursive: true);
  });

  group('DevWorkspace 模型', () {
    test('默认工作区常量：id=default、后端 localApp、不落盘', () {
      expect(DevWorkspace.defaultWorkspace.id, DevWorkspace.kDefaultId);
      expect(DevWorkspace.defaultWorkspace.backend, WorkspaceBackend.localApp);
      expect(DevWorkspace.defaultWorkspace.isRemote, isFalse);
      expect(DevWorkspace.defaultWorkspace.isDefault, isTrue);
    });

    test('toJson → fromJson 往返一致（远端工作区）', () {
      const ws = DevWorkspace(
        id: 'ws_1',
        name: 'TongYi-Lite',
        backend: WorkspaceBackend.termux,
        remotePath: '/data/data/com.termux/files/home/proj',
        gitManaged: true,
        repoUrl: 'https://example.com/r.git',
        currentBranch: 'main',
        sshConfigId: 'termux',
      );
      final restored = DevWorkspace.fromJson(ws.toJson());
      expect(restored, isNotNull);
      expect(restored!.id, 'ws_1');
      expect(restored.name, 'TongYi-Lite');
      expect(restored.backend, WorkspaceBackend.termux);
      expect(restored.remotePath, '/data/data/com.termux/files/home/proj');
      expect(restored.gitManaged, isTrue);
      expect(restored.currentBranch, 'main');
      expect(restored.sshConfigId, 'termux');
    });

    test('sshConfigId 空/缺失 → 不落盘、回落 null（向后兼容）', () {
      const ws = DevWorkspace(
        id: 'ws_2',
        name: '本地',
        backend: WorkspaceBackend.localApp,
      );
      final restored = DevWorkspace.fromJson(ws.toJson());
      expect(restored!.sshConfigId, isNull);
      expect(ws.toJson().containsKey('sshConfigId'), isFalse);
      // 旧 JSON 无该键 → fromJson 不崩。
      final legacy = DevWorkspace.fromJson({
        'id': 'ws_3', 'name': '旧', 'backend': 'termux',
        'remotePath': '/home/x',
      });
      expect(legacy!.sshConfigId, isNull);
    });

    test('copyWith 只改指定字段（含 sshConfigId 清除）', () {
      const ws = DevWorkspace(
        id: 'ws_1',
        name: 'A',
        backend: WorkspaceBackend.localApp,
        sshConfigId: 'termux',
      );
      final updated = ws.copyWith(name: 'B', currentBranch: 'dev');
      expect(updated.name, 'B');
      expect(updated.id, 'ws_1');
      expect(updated.backend, WorkspaceBackend.localApp);
      expect(updated.currentBranch, 'dev');
      expect(updated.sshConfigId, 'termux');
      expect(ws.copyWith(clearSshConfigId: true).sshConfigId, isNull);
    });
  });

  group('sanitizeWorkspaceDirName', () {
    test('非法字符替换为 -', () {
      expect(sanitizeWorkspaceDirName('a/b'), 'a-b');
      expect(sanitizeWorkspaceDirName('a b'), 'a-b');
      expect(sanitizeWorkspaceDirName('中文'), '中文');
    });
  });

  group('effectiveWorkspaceOf（工具内部键解析）', () {
    test('无键 → null（= 默认工作区语义，文件工具回落 docs/workspace）', () {
      expect(effectiveWorkspaceOf(const {}), isNull);
      expect(effectiveWorkspaceOf(const {'a': 1}), isNull);
    });

    test('显式键 → 返回该工作区', () {
      expect(
        effectiveWorkspaceOf(const {
          kWorkspaceIdArgKey: 'ws_x',
        }),
        'ws_x',
      );
    });

    test('默认值显式传入 → 默认工作区', () {
      expect(
        effectiveWorkspaceOf(const {
          kWorkspaceIdArgKey: DevWorkspace.kDefaultId,
        }),
        DevWorkspace.kDefaultId,
      );
    });
  });

  group('DevStore 持久化', () {
    test('saveWorkspace → loadWorkspaces 往返（默认不落盘）', () async {
      const ws = DevWorkspace(
        id: 'ws_1',
        name: '测试项目',
        backend: WorkspaceBackend.remotePc,
        remotePath: '/home/dev/proj',
      );
      await store.saveWorkspace(ws);
      await store.saveWorkspace(DevWorkspace.defaultWorkspace); // 默认跳过
      final loaded = await store.loadWorkspaces();
      expect(loaded.length, 1);
      expect(loaded.first.id, 'ws_1');
      expect(loaded.first.name, '测试项目');
      expect(loaded.first.remotePath, '/home/dev/proj');
    });

    test('deleteWorkspace 删除', () async {
      const ws = DevWorkspace(
        id: 'ws_2',
        name: 'B',
        backend: WorkspaceBackend.localApp,
      );
      await store.saveWorkspace(ws);
      await store.deleteWorkspace('ws_2');
      expect(await store.loadWorkspaces(), isEmpty);
    });

    test('损坏条目丢弃不崩', () async {
      final dir = Directory('${tmp.path}/dev/workspaces');
      dir.createSync(recursive: true);
      File('${dir.path}/bad.json').writeAsStringSync('{broken json');
      await store.saveWorkspace(const DevWorkspace(
        id: 'ws_ok',
        name: 'OK',
        backend: WorkspaceBackend.localApp,
      ));
      final loaded = await store.loadWorkspaces();
      expect(loaded.length, 1);
      expect(loaded.first.id, 'ws_ok');
    });
  });
}
