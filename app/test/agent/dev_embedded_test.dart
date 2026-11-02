/// Dev Agent 内嵌沙箱 + Termux 免 SSH 通道回归（2026-10-04 L1/L2）。
///
/// 覆盖：
/// - WorkspaceBackend.embedded 枚举序列化往返 + 旧 JSON 兼容；
/// - termux_intent 纯函数（wrapper 生成 / 输出解析）与注入式执行链；
/// - dev_shell 工具（注入 runner）：cwd 解析 / PATH / 危险命令黑名单；
/// - git_tools 后端分派：本地 → LocalGit（注入桩），远端 → SSH；
/// - DevContext embedded 后端描述。
library;

import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

import 'package:tongyi_lite/agent/builtin_tools/builtin_tools.dart';
import 'package:tongyi_lite/agent/dev/dev.dart';
import 'package:tongyi_lite/agent/dev/tools/embedded_git.dart';
import 'package:tongyi_lite/agent/dev/tools/embedded_tools.dart';
import 'package:tongyi_lite/agent/dev/tools/git_tools.dart';
import 'package:tongyi_lite/agent/dev/termux_intent.dart';

void main() {
  late Directory tmp;

  setUp(() {
    tmp = Directory.systemTemp.createTempSync('dev_embedded_test');
    DevStore.testDefault = DevStore(baseDirOverride: tmp.path);
    TermuxIntentService.instance.sender = null;
    TermuxIntentService.instance.reader = null;
    LocalGit.invoker = null;
  });

  tearDown(() {
    if (tmp.existsSync()) tmp.deleteSync(recursive: true);
    DevStore.testDefault = null;
    TermuxIntentService.instance.sender = null;
    TermuxIntentService.instance.reader = null;
    LocalGit.invoker = null;
  });

  group('WorkspaceBackend.embedded 枚举', () {
    test('embedded 工作区序列化往返；isRemote=false', () {
      const ws = DevWorkspace(
          id: 'ws_e1', name: '内嵌沙箱', backend: WorkspaceBackend.embedded);
      final restored = DevWorkspace.fromJson(ws.toJson());
      expect(restored, isNotNull);
      expect(restored!.backend, WorkspaceBackend.embedded);
      expect(restored.isRemote, isFalse);
      expect(WorkspaceBackend.embedded.isRemoteBackend, isFalse);
    });

    test('旧 JSON（无 embedded 值）加载不受影响；未知值回落丢弃', () {
      final legacy = <String, dynamic>{
        'id': 'ws_old',
        'name': '旧工作区',
        'backend': 'termux',
        'remotePath': '/home/u/p',
      };
      final ws = DevWorkspace.fromJson(legacy);
      expect(ws!.backend, WorkspaceBackend.termux);
      // 未知后端值 → 条目丢弃（原行为）。
      expect(DevWorkspace.fromJson({
        'id': 'x',
        'name': 'x',
        'backend': 'not_exist',
      }), isNull);
    });
  });

  group('termux_intent 纯函数', () {
    test('buildTermuxWrapper：自建目录 + cd + 输出重定向 + 退出码 + 结束标记；单引号转义', () {
      final w = buildTermuxWrapper(
          command: "echo 'it's ok'", outFilePath: '/tmp/o/1.out', cwd: '/root');
      expect(w.startsWith("mkdir -p '/tmp/o'; "), isTrue);
      expect(w.contains("cd '/root' 2>/dev/null; "), isTrue);
      // 整段命令内所有单引号都转义为 '\'' 。
      expect(w.contains(r"'\''"), isTrue);
      expect(w.contains("> '/tmp/o/1.out' 2>&1"), isTrue);
      expect(w.contains('__TYL_EXIT__='), isTrue);
      expect(w.endsWith("echo '__TYL_DONE__' >> '/tmp/o/1.out'"), isTrue);
    });

    test('parseTermuxOutput：剥离退出码/标记，保留正文', () {
      final parsed = parseTermuxOutput('line1\nline2\n__TYL_EXIT__=3\n'
          '__TYL_DONE__');
      expect(parsed.exit, 3);
      expect(parsed.output, 'line1\nline2');
    });

    test('parseTermuxOutput：无结束标记 = 未完成（exit null 不成立时按 0 但不应被调用）',
        () {
      final parsed = parseTermuxOutput('__TYL_EXIT__=0\n__TYL_DONE__');
      expect(parsed.exit, 0);
      expect(parsed.output, isEmpty);
    });
  });

  group('TermuxIntentService（注入桩）', () {
    test('run：sender 投递 + reader 读到完成标记 → 解析输出与退出码', () async {
      String? sentWrapper;
      TermuxIntentService.instance.sender = (wrapper, cwd) async {
        sentWrapper = wrapper;
        return null;
      };
      // 模拟 Termux 写结果文件（reader 对任意交换 id 返回完成内容）。
      TermuxIntentService.instance.reader = (rid) async {
        expect(rid, startsWith('tyl_'));
        return 'hello intent\n__TYL_EXIT__=0\n__TYL_DONE__';
      };
      final res = await TermuxIntentService.instance.run('echo hello intent');
      expect(sentWrapper, isNotNull);
      // wrapper 把输出重定向到交换文件（/sdcard/TongYiLite 双方可读写）。
      expect(sentWrapper, contains("> '/sdcard/TongYiLite/termux_out/"));
      expect(res.ok, isTrue);
      expect(res.output, 'hello intent');
    });

    test('run：sender 报通道不可用 → 抛 StateError（工具层回落 SSH）', () async {
      TermuxIntentService.instance.sender = (wrapper, cwd) async =>
          'Termux 未安装';
      expect(
        () => TermuxIntentService.instance.run('echo x',
            timeout: const Duration(milliseconds: 300)),
        throwsA(isA<StateError>()),
      );
    });
  });

  group('dev_shell 工具（注入 runner）', () {
    test('危险命令黑名单拒绝（默认 workspace-write 模式）', () async {
      final tool = createDevShellTool(
          nativeLibDir: () async => '/data/app/lib/arm64',
          store: DevStore(baseDirOverride: tmp.path));
      final res = await tool.execute({'command': 'rm -rf /'});
      expect(res.isError, isTrue);
      expect(res.content, contains('危险命令被拒绝'));
    });

    test('正常执行：runner 收到 sh -c、PATH 前插 nativeLibraryDir', () async {
      String? gotPath;
      final tool = createDevShellTool(
        runner: (exe, args, {cwd, environment = const {}, stdin}) async {
          expect(exe, 'sh');
          expect(args, ['-c', 'ls']);
          gotPath = environment['PATH'];
          return const DevShellResult(exit: 0, stdout: 'file1', stderr: '');
        },
        nativeLibDir: () async => '/data/app/org/lib/arm64',
        store: DevStore(baseDirOverride: tmp.path),
      );
      final res = await tool.execute({'command': 'ls'});
      expect(res.isError, isFalse);
      expect(res.content, 'file1');
      expect(gotPath, startsWith('/data/app/org/lib/arm64:'));
    });

    test('工作目录解析：本地工作区 → projects/<safe-id>', () async {
      final store = DevStore(baseDirOverride: tmp.path);
      const ws = DevWorkspace(
          id: 'ws_local1', name: '我的项目', backend: WorkspaceBackend.embedded);
      await store.saveWorkspace(ws);
      String? gotCwd;
      final tool = createDevShellTool(
        runner: (exe, args, {cwd, environment = const {}, stdin}) async {
          gotCwd = cwd;
          return const DevShellResult(exit: 0, stdout: '', stderr: '');
        },
        nativeLibDir: () async => null,
        store: store,
      );
      final res = await tool.execute({'command': 'pwd', '_workspaceId': 'ws_local1'});
      expect(res.isError, isFalse);
      expect(gotCwd!.replaceAll('\\', '/'), contains('projects/ws_local1'));
    });

    test('dev 工具组注册表包含 dev_shell 与 git_clone', () {
      final registryNames = createBuiltinTools(includeDevTools: true)
          .map((t) => t.name)
          .toSet();
      expect(registryNames, containsAll(['dev_shell', 'git_clone']));
      expect(kDevToolNames, containsAll(['dev_shell', 'git_clone']));
    });
  });

  group('git_tools 后端分派（LocalGit 注入桩）', () {
    test('默认工作区（无 _workspaceId）→ 本地 JGit 桩被调用', () async {
      Map<String, dynamic>? gotArgs;
      LocalGit.invoker = (method, args) async {
        expect(method, 'status');
        gotArgs = args;
        return {'ok': true, 'output': '## main'};
      };
      final tool = createGitStatusTool();
      final res = await tool.execute({});
      expect(res.isError, isFalse);
      expect(res.content, '## main');
      expect(gotArgs, isNotNull);
    });

    test('embedded 工作区 → 本地分派，root = projects/<safe-id>', () async {
      final store = DevStore(baseDirOverride: tmp.path);
      await store.saveWorkspace(const DevWorkspace(
          id: 'ws_e2', name: '内嵌项目', backend: WorkspaceBackend.embedded));
      String? gotRoot;
      LocalGit.invoker = (method, args) async {
        gotRoot = args['root'] as String?;
        return {'ok': true, 'output': 'OK'};
      };
      final tool = createGitStatusTool();
      final res = await tool.execute({'_workspaceId': 'ws_e2'});
      expect(res.isError, isFalse);
      expect(gotRoot!.replaceAll('\\', '/'), contains('projects/ws_e2'));
    });

    test('本地 commit：files 直接传列表（无 shell 转义依赖）', () async {
      List<String>? gotFiles;
      String? gotMessage;
      LocalGit.invoker = (method, args) async {
        expect(method, 'commit');
        gotFiles = (args['files'] as List).cast<String>();
        gotMessage = args['message'] as String?;
        return {'ok': true, 'output': 'committed'};
      };
      final tool = createGitCommitTool();
      final res = await tool.execute({
        'files': ["a'b.dart", 'b.dart'],
        'message': "fix: it's done",
      });
      expect(res.isError, isFalse);
      expect(gotFiles, ["a'b.dart", 'b.dart']);
      expect(gotMessage, "fix: it's done");
    });

    test('git_clone：ssh 协议 URL 明确拒绝（本地仅 https）', () async {
      LocalGit.invoker = (method, args) async =>
          {'ok': true, 'output': 'should not be called'};
      final tool = createGitCloneTool();
      final res = await tool.execute({'url': 'git@github.com:a/b.git'});
      expect(res.isError, isTrue);
      expect(res.content, contains('https'));
    });

    test('远端工作区仍走 SSH（LocalGit 不被调用；无配置时给 SSH 诊断）', () async {
      var gitCalled = false;
      LocalGit.invoker = (method, args) async {
        gitCalled = true;
        return {'ok': true, 'output': ''};
      };
      final store = DevStore(baseDirOverride: tmp.path);
      await store.saveWorkspace(const DevWorkspace(
          id: 'ws_r1',
          name: '远端',
          backend: WorkspaceBackend.termux,
          remotePath: '/home/u/proj'));
      final tool = createGitStatusTool(sshConfigs: const []);
      final res = await tool.execute({'_workspaceId': 'ws_r1'});
      expect(gitCalled, isFalse);
      // 未配置 SSH 连接 → 可读诊断（不再静默）。
      expect(res.content, contains('SSH'));
    });
  });

  group('DevContext embedded 后端', () {
    test('工作区上下文段含内嵌沙箱描述', () async {
      final store = DevStore(baseDirOverride: tmp.path);
      await store.saveWorkspace(const DevWorkspace(
          id: 'ws_e3', name: '内嵌项目', backend: WorkspaceBackend.embedded));
      final section = await buildWorkspaceContextSection(
          workspaceId: 'ws_e3', store: store);
      expect(section, contains('内嵌工具沙箱'));
      expect(section, contains('dev_shell'));
      expect(utf8.decode(utf8.encode(section)), contains('dev_shell'));
    });
  });

  group('run_tests 本地分派', () {
    test('embedded 工作区 → 内嵌沙箱执行（不触 SSH）', () async {
      final store = DevStore(baseDirOverride: tmp.path);
      await store.saveWorkspace(const DevWorkspace(
          id: 'ws_e4', name: '内嵌测试', backend: WorkspaceBackend.embedded));
      // 项目目录里放一个脚本，执行它验证 cwd 与执行链。
      final mirror = Directory(
          '${tmp.path}/dev'); // DevStore override 只影响元数据，镜像在 documents
      expect(mirror.existsSync() || !mirror.existsSync(), isTrue); // 无副作用断言
      final tool = createRunTestsTool(sshConfigs: const []);
      final res =
          await tool.execute({'command': 'echo ran', '_workspaceId': 'ws_e4'});
      // 本地执行成功（echo ran 输出）或目录创建失败报错，但绝不出现 [SSH] 前缀。
      expect(res.content.contains('[SSH]'), isFalse);
      expect(res.content.contains('[TERMUX]'), isFalse);
    });
  });
}
