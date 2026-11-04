// v0.0.4 数据家统一（计划书 Phase 1）：旧家 → %APPDATA%\WangCai 搬迁语义。
// 覆盖：子目录整体搬迁/幂等/冲突备份/.migrating 自愈、todo 归拢、AGENTS.md
// 单文件、SQLite 旧库 copy 迁移、JSONL 只读兜底指向旧家。
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;
import 'package:wangcai/platform/wangcai_paths.dart';
import 'package:wangcai/services/storage_service.dart';

void main() {
  late Directory legacyHome;
  late Directory dataHome;

  setUp(() {
    final tmp = Directory.systemTemp.createTempSync('wangcai_data_home_');
    legacyHome = Directory(p.join(tmp.path, 'legacy'))..createSync();
    dataHome = Directory(p.join(tmp.path, 'data'))..createSync();
    WangCaiPaths.legacyHomeOverrideForTest = () => legacyHome;
    WangCaiPaths.dataRootOverrideForTest = () => dataHome;
  });

  tearDown(() {
    WangCaiPaths.legacyHomeOverrideForTest = null;
    WangCaiPaths.dataRootOverrideForTest = null;
    StorageService.legacyDbCandidatesForTest = null;
    legacyHome.parent.deleteSync(recursive: true);
  });

  File wf(String path, String content) {
    final f = File(path);
    f.parent.createSync(recursive: true);
    f.writeAsStringSync(content);
    return f;
  }

  test('子目录整体搬迁到 dataRoot 同名位，二次运行幂等', () {
    wf(p.join(legacyHome.path, 'goals', 'p1.json'), '{"plan":1}');
    wf(p.join(legacyHome.path, 'dev', 'workspaces', 'w.json'), '{}');
    wf(p.join(legacyHome.path, 'skills', 'demo', 'SKILL.md'), '# s');

    WangCaiPaths.migrateLegacyHome();
    expect(File(p.join(dataHome.path, 'goals', 'p1.json')).existsSync(), isTrue);
    expect(
        File(p.join(dataHome.path, 'dev', 'workspaces', 'w.json'))
            .readAsStringSync(),
        '{}');
    expect(
        File(p.join(dataHome.path, 'skills', 'demo', 'SKILL.md')).existsSync(),
        isTrue);
    // 旧位已摘牌（目录不在原位）。
    expect(Directory(p.join(legacyHome.path, 'goals')).existsSync(), isFalse);

    // 二次运行：no-op 不炸、不动新家内容。
    WangCaiPaths.migrateLegacyHome();
    expect(File(p.join(dataHome.path, 'goals', 'p1.json')).readAsStringSync(),
        '{"plan":1}');
  });

  test('新家已有同名目录：旧数据改名 .migrated 备份，不动新家', () {
    wf(p.join(legacyHome.path, 'skills', 'old', 'SKILL.md'), 'old');
    wf(p.join(dataHome.path, 'skills', 'new', 'SKILL.md'), 'new');

    WangCaiPaths.migrateLegacyHome();
    expect(
        File(p.join(dataHome.path, 'skills', 'new', 'SKILL.md'))
            .readAsStringSync(),
        'new');
    expect(
        File(p.join(legacyHome.path, 'skills.migrated', 'old', 'SKILL.md'))
            .readAsStringSync(),
        'old');
  });

  test('.migrating 残留自愈续搬（上次搬到一半）', () {
    Directory(p.join(legacyHome.path, 'goals.migrating'))
        .createSync(recursive: true);
    wf(p.join(legacyHome.path, 'goals.migrating', 'half.json'), 'x');

    WangCaiPaths.migrateLegacyHome();
    expect(File(p.join(dataHome.path, 'goals', 'half.json')).existsSync(),
        isTrue);
    expect(
        Directory(p.join(legacyHome.path, 'goals.migrating')).existsSync(),
        isFalse);
  });

  test('旧家根的 todo 文件归拢进 dataDir(todo)，AGENTS.md 单文件搬家', () {
    wf(p.join(legacyHome.path, 'agent_todo.json'), '[]');
    wf(p.join(legacyHome.path, 'agent_todo_c1.json'), '[{"t":"x"}]');
    wf(p.join(legacyHome.path, 'AGENTS.md'), '# 指令');

    WangCaiPaths.migrateLegacyHome();
    expect(File(p.join(dataHome.path, 'todo', 'agent_todo.json')).existsSync(),
        isTrue);
    expect(
        File(p.join(dataHome.path, 'todo', 'agent_todo_c1.json'))
            .readAsStringSync(),
        '[{"t":"x"}]');
    expect(File(p.join(dataHome.path, 'AGENTS.md')).readAsStringSync(),
        '# 指令');
  });

  test('SQLite 旧库 copy 迁移：带走 journal，旧库原地保留；已有新库不重拷', () {
    final oldDb = wf(p.join(legacyHome.parent.path, 'fake_cwd', '.dart_tool',
        'sqflite_common_ffi', 'databases', 'tongyilite.db'),
        'SQLITE-MAGIC');
    wf('${oldDb.path}-journal', 'J');

    StorageService.legacyDbCandidatesForTest = [oldDb.path];
    final got = StorageService.migrateLegacyDbIfAny();
    expect(got.path, p.join(dataHome.path, 'wangcai.db'));
    expect(got.readAsStringSync(), 'SQLITE-MAGIC');
    expect(File('${got.path}-journal').readAsStringSync(), 'J');
    // 旧库原地保留（天然备份）。
    expect(oldDb.readAsStringSync(), 'SQLITE-MAGIC');

    // 新库已在 → 不再重拷（改候选也无效）。
    StorageService.legacyDbCandidatesForTest = [
      p.join(legacyHome.parent.path, 'nonexistent.db')
    ];
    expect(StorageService.migrateLegacyDbIfAny().path, got.path);
  });

  test('无旧库时不创建目标文件（openDatabase 前只定路径）', () {
    StorageService.legacyDbCandidatesForTest = [];
    final got = StorageService.migrateLegacyDbIfAny();
    expect(got.path, p.join(dataHome.path, 'wangcai.db'));
    expect(got.existsSync(), isFalse);
  });
}
