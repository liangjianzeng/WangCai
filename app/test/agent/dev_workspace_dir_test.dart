/// 「工作区目录有就用、没有就建」（2026-10-27 用户定案）。
///
/// 旧行为：工作区记录在、远端目录不在（手输路径 / 换机器 / 目录被删 / 建区时没填），
/// 每发一条消息第一个 ssh_* 工具就撞 `cd: No such file or directory` 或
/// `未配置远端路径（remotePath）`。现在这条路径必须自愈。
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

import 'package:tongyi_lite/agent/dev/dev_controller.dart';
import 'package:tongyi_lite/agent/dev/dev_workspace_actions.dart';
import 'package:tongyi_lite/agent/dev/tools/ssh_tools.dart';
import 'package:tongyi_lite/agent/dev/workspace.dart';
import 'package:tongyi_lite/agent/dev/workspace_store.dart';

void main() {
  late Directory tmp;
  late DevStore store;

  setUp(() {
    tmp = Directory.systemTemp.createTempSync('dev_dir_test');
    store = DevStore(baseDirOverride: tmp.path);
    DevStore.testDefault = store; // resolveRemoteRoot 走 DevStore.resolve()
    DevSessionController.testStore = store;
    DevSessionController.instance.debugReset();
    clearEnsuredRemoteDirsCache();
  });

  tearDown(() {
    DevStore.testDefault = null;
    DevSessionController.testStore = null;
    DevSessionController.instance.debugReset();
    if (tmp.existsSync()) tmp.deleteSync(recursive: true);
  });

  group('缺省远端目录', () {
    test('占位路径交给远端 shell 展开 ~（不必先连上问 \$HOME）', () {
      expect(defaultRemoteProjectPathPlaceholder('博客 项目'),
          '~/projects/博客-项目');
      expect(defaultRemoteProjectPathPlaceholder('  '), '~/projects/workspace',
          reason: '名字空也得有个可建目录，不能生成 ~/projects/');
    });

    test('绝对化时去掉家目录尾斜杠，避免 // 双斜杠', () {
      expect(defaultRemoteProjectPath('/home/alice/', 'demo'),
          '/home/alice/projects/demo');
      expect(defaultRemoteProjectPath('/srv/dev', 'my.app'),
          '/srv/dev/projects/my-app', reason: '点号进目录名要安全化');
      expect(defaultRemoteProjectPath('', 'demo'), 'projects/demo');
    });
  });

  group('远端命令前缀（第二道自愈防线）', () {
    test('cd 前缀自带 mkdir -p：目录被删也不会再撞 No such file', () {
      expect(remoteCdPrefix('/home/alice/my proj'),
          "mkdir -p '/home/alice/my proj' && cd '/home/alice/my proj'");
    });

    test('单引号闭合转义（路径里带引号不许逃逸成任意命令）', () {
      expect(remoteCdPrefix("/home/a'b"),
          r"mkdir -p '/home/a'\''b' && cd '/home/a'\''b'");
    });

    test('~ 开头不能加引号（引号里波浪号不展开）', () {
      expect(remoteCdPrefix('~/projects/demo'),
          'mkdir -p ~/projects/demo && cd ~/projects/demo');
    });

    test('父目录：写文件前先建；无目录分隔时返回空串', () {
      expect(remoteParentDir('/home/a/src/main.dart'), '/home/a/src');
      expect(remoteParentDir('/main.dart'), '');
      expect(remoteParentDir('main.dart'), '');
    });
  });

  group('未填远端路径的工作区照样能用（不再一开口就报错）', () {
    test('resolveRemoteRoot 给占位 ~/projects/<安全名>，不抛「未配置远端路径」',
        () async {
      await store.saveWorkspace(const DevWorkspace(
        id: 'ws_nopath',
        name: '新电脑项目',
        backend: WorkspaceBackend.remotePc,
      ));
      final r = await resolveRemoteRoot('ws_nopath');
      expect(r.root, '~/projects/新电脑项目');
      expect(r.workspace.name, '新电脑项目');
    });

    test('本地/默认工作区仍然硬拒（防把远端工具打到手机目录上）', () async {
      await store.saveWorkspace(const DevWorkspace(
          id: 'ws_local', name: '本地', backend: WorkspaceBackend.localApp));
      // resolveRemoteRoot 是异步的：StateError 在 Future 里，必须 expectLater。
      await expectLater(resolveRemoteRoot('ws_local'), throwsStateError);
      await expectLater(
          resolveRemoteRoot(DevWorkspace.kDefaultId), throwsStateError);
      await expectLater(resolveRemoteRoot('ghost'), throwsStateError);
    });

    test('未连接时 ensureWorkspaceRemoteDir 不表态（交给连接层）', () async {
      const ws = DevWorkspace(
          id: 'w', name: 'w', backend: WorkspaceBackend.remotePc);
      final r = await ensureWorkspaceRemoteDir(ws);
      expect(r.root, isNull);
      expect(r.error, isNull);
    });

    test('本地工作区不需要远端目录（直接放行）', () async {
      const ws = DevWorkspace(
          id: 'w2', name: 'w2', backend: WorkspaceBackend.localApp);
      final r = await ensureWorkspaceRemoteDir(ws);
      expect(r.root, isNull);
      expect(r.error, isNull);
    });
  });
}
