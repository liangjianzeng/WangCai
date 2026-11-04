import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

import 'package:wangcai/agent/session/event.dart';
import 'package:wangcai/agent/session/log.dart';
import 'package:wangcai/agent/session/store.dart';
import 'package:wangcai/project/migration.dart';
import 'package:wangcai/project/project.dart';
import 'package:wangcai/project/project_store.dart';
import 'package:wangcai/services/storage_service.dart';

// ---------------------------------------------------------------------------
// v0.0.3 项目层级数据层：ProjectStore / JSONL 项目树 / 一次性迁移 / SQLite v7
// （DB 用 sqflite_common_ffi 真库；文件系统全部走临时目录注入，不碰 %APPDATA%）
// ---------------------------------------------------------------------------

void main() {
  late Directory tmp;
  late Directory legacyBase;
  late ProjectStore store;

  setUpAll(() {
    sqfliteFfiInit();
    databaseFactory = databaseFactoryFfi;
  });

  setUp(() {
    tmp = Directory.systemTemp.createTempSync('wc_proj_');
    legacyBase = Directory.systemTemp.createTempSync('wc_legacy_');
    store = ProjectStore(baseDirOverride: tmp.path);
    ProjectStore.testDefault = store;
    JsonlSessionStore.legacyBaseOverrideForTest = legacyBase.path;
    JsonlSessionStore.projectIdResolver = null;
    // v0.0.4 修复：SQLite 库路径同样隔离——此前直写真实
    // %APPDATA%\WangCai\wangcai.db，留下 mig-old-* 测试垃圾会话。
    StorageService.dbPathOverrideForTest = '${tmp.path}/test.db';
  });

  tearDown(() async {
    ProjectStore.testDefault = null;
    JsonlSessionStore.legacyBaseOverrideForTest = null;
    JsonlSessionStore.projectIdResolver = null;
    StorageService.dbPathOverrideForTest = null;
    await StorageService.closeForTest(); // 释放句柄后再删临时目录
    if (tmp.existsSync()) tmp.deleteSync(recursive: true);
    if (legacyBase.existsSync()) legacyBase.deleteSync(recursive: true);
  });

  SessionLog oneUserEvent(String text) {
    final log = SessionLog.fromEvents([]);
    log.append(kEventUserMessage, {'content': text},
        source: const {'kind': 'user'}, timeMs: 1730000000000);
    return log;
  }

  group('ProjectStore', () {
    test('create/load/激活/默认项目语义与移除保护', () async {
      await store.ensureDefault(r'D:\ws\default');
      await store.ensureDefault(r'D:\ws\default'); // 幂等
      var list = await store.loadProjects();
      expect(list.where((x) => x.id == Project.kDefaultId).length, 1);

      final p1 = await store.create(name: '  博客  ', workspacePath: r'E:\blog');
      expect(p1.name, '博客');
      expect(p1.id, startsWith('p_'));
      expect((await store.projectById(p1.id))!.workspacePath, r'E:\blog');

      await store.setActiveProjectId(p1.id);
      expect(await store.loadActiveProjectId(), p1.id);
      // 激活刷新 lastOpenedAt。
      expect((await store.projectById(p1.id))!.lastOpenedAt, isNotNull);

      // 默认项目不可移除；普通项目可移除且不留激活幽灵。
      expect(await store.remove(Project.kDefaultId), isFalse);
      expect(await store.remove(p1.id), isTrue);
      expect(await store.projectById(p1.id), isNull);
      expect(await store.loadActiveProjectId(), isNot(p1.id));

      list = await store.loadProjects();
      expect(list.map((e) => e.id), contains(Project.kDefaultId));
    });

    test('坏条目/坏注册表 fail-loud 不炸', () async {
      File('${tmp.path}/projects.json').writeAsStringSync(
          '[{"id":"ok","name":"n","workspacePath":"w"}, 42, {"nope":1}]');
      expect((await store.loadProjects()).map((e) => e.id), ['ok']);
      File('${tmp.path}/projects.json').writeAsStringSync('{{{');
      expect(await store.loadProjects(), isEmpty);
    });

    test('新项目 id 形态合规且路径安全', () {
      final ids = <String>{for (var i = 0; i < 200; i++) newProjectId()};
      // 随机尾缀保证快速连发不撞（留 1 个容差防理论撞车）。
      expect(ids.length, greaterThan(198));
      expect(
          ids.every((e) => RegExp(r'^p_[0-9]+_[0-9a-f]{1,8}$').hasMatch(e)),
          isTrue);
      expect(safeProjectDirName(r'a\b/../c*'), 'a_b_.._c_');
    });
  });

  group('JsonlSessionStore 项目树', () {
    test('写入落项目树 + header 带 workspacePath/cwd', () async {
      final prj =
          await store.create(name: '博客', workspacePath: r'E:\work\blog');
      JsonlSessionStore.projectIdResolver = (c) async => prj.id;
      final js = JsonlSessionStore();
      await js.rewrite('c1', oneUserEvent('hi'));

      final file = File('${tmp.path}/projects/${prj.id}/sessions/c1.jsonl');
      expect(file.existsSync(), isTrue);
      final head = jsonDecode(file.readAsLinesSync().first)
          as Map<String, dynamic>;
      expect(head['workspacePath'], r'E:\work\blog');
      expect(head['cwd'], r'E:\work\blog');
    });

    test('未接线 resolver → 落默认项目树', () async {
      final js = JsonlSessionStore();
      await js.rewrite('c10', oneUserEvent('hi'));
      expect(
          File('${tmp.path}/projects/${Project.kDefaultId}/sessions/'
                  'c10.jsonl')
              .existsSync(),
          isTrue);
    });

    test('legacy 双读兜底 + 首触达整体复制 + 删除清两处', () async {
      final prj = await store.create(name: 'B', workspacePath: r'D:\b');
      JsonlSessionStore.projectIdResolver = (c) async => prj.id;
      final js = JsonlSessionStore();

      // 旧平铺文件：header + 一条事件。
      final legacyDir = Directory('${legacyBase.path}/sessions')
        ..createSync();
      final old = File('${legacyDir.path}/c9.jsonl');
      final h = SessionHeader(
          version: kSessionFormatVersion, conversationId: 'c9', createdAtMs: 1);
      final e = SessionEvent(
          type: kEventUserMessage,
          seq: 1,
          timeMs: 2,
          data: const {'content': 'old'},
          source: const {'kind': 'user'});
      old.writeAsStringSync('${h.toJson()}\n${e.toJsonLine()}\n');

      expect(await js.isMigrated('c9'), isTrue);
      expect((await js.load('c9')).rawEvents.map((x) => x.data['content']),
          ['old']);

      // 首触达追加：旧文件整体复制进项目树后再续写（绝不劈成两半）。
      await js.appendEvent(
        'c9',
        SessionEvent(
            type: kEventUserMessage,
            seq: 2,
            timeMs: 3,
            data: const {'content': 'new'},
            source: const {'kind': 'user'}),
      );
      final inTree = File('${tmp.path}/projects/${prj.id}/sessions/c9.jsonl');
      expect(inTree.existsSync(), isTrue);
      expect((await js.load('c9')).rawEvents.map((x) => x.data['content']),
          ['old', 'new']);

      await js.delete('c9');
      expect(inTree.existsSync(), isFalse);
      expect(old.existsSync(), isFalse);
    });
  });

  group('一次性迁移 migrateLegacySessions', () {
    test('备份、搬移、NULL 归户默认项目、幂等重跑', () async {
      final legacyDir = Directory('${legacyBase.path}/sessions')..createSync();
      File('${legacyDir.path}/a.jsonl').writeAsStringSync('{}\n');
      File('${legacyDir.path}/b.jsonl').writeAsStringSync('{}\n');

      final db = StorageService();
      final c1 = await db.createConversation(title: 'mig-old-1');
      await Future.delayed(const Duration(milliseconds: 3));
      final c2 =
          await db.createConversation(title: 'mig-old-2', projectId: 'p_custom');
      final wsDir = Directory('${tmp.path}/ws')..createSync();

      final r1 = await migrateLegacySessions(
          projects: store,
          storage: db,
          defaultWorkspacePath: wsDir.path,
          legacySessionsDir: legacyDir);
      expect(r1.movedFiles, 2);
      expect(r1.backedUp, isTrue);
      expect(Directory('${legacyBase.path}/sessions.backup').existsSync(),
          isTrue);
      expect(
          File('${tmp.path}/projects/${Project.kDefaultId}/sessions/a.jsonl')
              .existsSync(),
          isTrue);
      expect(legacyDir.listSync(), isEmpty);
      expect(await db.projectOfConversation(c1.id), Project.kDefaultId);
      expect(await db.projectOfConversation(c2.id), 'p_custom'); // 已归属不动

      // 幂等：第二次什么都没发生。
      final r2 = await migrateLegacySessions(
          projects: store,
          storage: db,
          defaultWorkspacePath: wsDir.path,
          legacySessionsDir: legacyDir);
      expect(r2.movedFiles, 0);
      expect(r2.assignedConversations, 0);
      expect(r2.didAnything, isFalse);

      await db.deleteConversation(c1.id);
      await db.deleteConversation(c2.id);
    });
  });

  group('SQLite v7 会话过滤语义', () {
    test('NULL 归默认项目、其他项目不串门、全量可查回', () async {
      final db = StorageService();
      final a = await db.createConversation(title: 'pt-a', projectId: 'p_alpha');
      await Future.delayed(const Duration(milliseconds: 3));
      final b = await db.createConversation(title: 'pt-b', projectId: 'p_beta');
      await Future.delayed(const Duration(milliseconds: 3));
      final nul = await db.createConversation(title: 'pt-null');

      final alpha = await db.getAllConversations(projectId: 'p_alpha');
      expect(alpha.map((c) => c.id), contains(a.id));
      expect(alpha.map((c) => c.id), isNot(contains(b.id)));
      expect(alpha.map((c) => c.id), isNot(contains(nul.id)));

      final def = await db.getAllConversations(projectId: Project.kDefaultId);
      expect(def.map((c) => c.id), contains(nul.id)); // NULL = 默认项目可见
      expect(def.map((c) => c.id), isNot(contains(a.id)));

      final all = await db.getAllConversations();
      expect(all.map((c) => c.id), containsAll([a.id, b.id, nul.id]));

      // 归户：NULL 一次性回填后 projectOf 可见。
      expect(await db.assignNullProjectConversations(Project.kDefaultId),
          greaterThanOrEqualTo(1));
      expect(await db.projectOfConversation(nul.id), Project.kDefaultId);
      expect(await db.projectOfConversation('ghost-conv'), isNull);

      for (final id in [a.id, b.id, nul.id]) {
        await db.deleteConversation(id);
      }
    });
  });
}
