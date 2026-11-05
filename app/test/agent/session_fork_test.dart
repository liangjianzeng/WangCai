import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

import 'package:wangcai/agent/session/event.dart';
import 'package:wangcai/agent/session/log.dart';
import 'package:wangcai/agent/session/store.dart';
import 'package:wangcai/project/project.dart';
import 'package:wangcai/project/project_store.dart';

// ---------------------------------------------------------------------------
// v0.0.4.1 DSH session.fork 对齐：消息级分叉的 JSONL 前缀复制 +
// header forkedFrom/forkSeq 溯源。
// ---------------------------------------------------------------------------

void main() {
  late Directory tmp;
  late Directory legacyBase;

  setUp(() {
    tmp = Directory.systemTemp.createTempSync('wc_fork_');
    legacyBase = Directory.systemTemp.createTempSync('wc_fork_legacy_');
    ProjectStore.testDefault = ProjectStore(baseDirOverride: tmp.path);
    JsonlSessionStore.legacyBaseOverrideForTest = legacyBase.path;
    JsonlSessionStore.projectIdResolver = null;
  });

  tearDown(() {
    ProjectStore.testDefault = null;
    JsonlSessionStore.legacyBaseOverrideForTest = null;
    if (tmp.existsSync()) tmp.deleteSync(recursive: true);
    if (legacyBase.existsSync()) legacyBase.deleteSync(recursive: true);
  });

  Future<void> seedTwoTurns(JsonlSessionStore js) async {
    final log = SessionLog.fromEvents([]);
    log.append(kEventUserMessage, {'content': '问题一'},
        source: const {'kind': 'user'}, timeMs: 1);
    log.append(kEventAssistantMessage, {'content': '回答一'},
        source: const {'kind': 'model'}, timeMs: 2);
    log.append(kEventUserMessage, {'content': '问题二'},
        source: const {'kind': 'user'}, timeMs: 3);
    log.append(kEventAssistantMessage, {'content': '回答二'},
        source: const {'kind': 'model'}, timeMs: 4);
    await js.rewrite('src', log);
  }

  test('fork 截至 atSeq 复制前缀；源会话不动', () async {
    final js = JsonlSessionStore();
    await seedTwoTurns(js);

    await js.fork('src', 'dst', atSeq: 2); // 截至「回答一」

    final forked = await js.load('dst');
    expect(forked.rawEvents.map((e) => e.seq), [1, 2]);
    expect(
        forked.rawEvents.map((e) => e.data['content']), ['问题一', '回答一']);

    // 源完好无损（append-only，fork 是复制不是引用）。
    final src = await js.load('src');
    expect(src.rawEvents.length, 4);
  });

  test('fork header 带 forkedFrom/forkSeq 溯源；旧会话缺字段容错', () async {
    final js = JsonlSessionStore();
    await seedTwoTurns(js);
    await js.fork('src', 'dst', atSeq: 4);

    final file =
        File('${tmp.path}/projects/${Project.kDefaultId}/sessions/dst.jsonl');
    expect(file.existsSync(), isTrue);
    final head = jsonDecode(file.readAsLinesSync().first)
        as Map<String, dynamic>;
    expect(head['forkedFrom'], 'src');
    expect(head['forkSeq'], 4);

    // 旧 header（无 fork 字段）解析为 null，不炸。
    final legacyHead =
        parseHeaderLine('{"version":1,"conversationId":"old","createdAt":1}');
    expect(legacyHead, isNotNull);
    expect(legacyHead!.forkedFrom, isNull);
    expect(legacyHead.forkSeq, isNull);
  });
}
