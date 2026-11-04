// v0.0.4 Phase 2（真相源通电）：JsonlSessionStore.loadOrImport 对账语义 +
// write-through 串行化落盘 + header cwd 盖章（计划书 §3）。
// 文件系统全走临时目录注入，不碰 %APPDATA%。
import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

import 'package:wangcai/agent/session/event.dart';
import 'package:wangcai/agent/session/log.dart';
import 'package:wangcai/agent/session/store.dart';
import 'package:wangcai/models/chat_message.dart';
import 'package:wangcai/project/project.dart';
import 'package:wangcai/project/project_store.dart';

void main() {
  late Directory tmp;
  late Directory legacyBase;
  late ProjectStore projects;
  late JsonlSessionStore store;

  setUp(() {
    tmp = Directory.systemTemp.createTempSync('wc_wt_');
    legacyBase = Directory.systemTemp.createTempSync('wc_wt_legacy_');
    projects = ProjectStore(baseDirOverride: tmp.path);
    ProjectStore.testDefault = projects;
    JsonlSessionStore.legacyBaseOverrideForTest = legacyBase.path;
    JsonlSessionStore.projectIdResolver = (convId) async => Project.kDefaultId;
    store = JsonlSessionStore(projects: projects);
  });

  tearDown(() {
    ProjectStore.testDefault = null;
    JsonlSessionStore.legacyBaseOverrideForTest = null;
    JsonlSessionStore.projectIdResolver = null;
    if (tmp.existsSync()) tmp.deleteSync(recursive: true);
    if (legacyBase.existsSync()) legacyBase.deleteSync(recursive: true);
  });

  ChatMessage user(String text) => ChatMessage(
        id: 'u_${text.hashCode}',
        conversationId: 'c1',
        role: MessageRole.user,
        content: text,
      );
  ChatMessage assistant(String text) => ChatMessage(
        id: 'a_${text.hashCode}',
        conversationId: 'c1',
        role: MessageRole.assistant,
        content: text,
      );

  Future<File> sessionFile() async => File(
      '${await projects.sessionsDir(Project.kDefaultId)}/c1.jsonl');

  Future<List<String>> fileLines() async =>
      (await sessionFile()).readAsStringSync().trim().split('\n');

  test('未命中 + writeback：SQLite 历史导入并整体回写项目树（header 盖 cwd）', () async {
    final log = await store.loadOrImport(
        'c1', [user('你好'), assistant('你好呀')], writeback: true);

    expect(log.rawEvents.where((e) => e.type == kEventUserMessage).length, 1);
    expect(
        log.rawEvents.where((e) => e.type == kEventAssistantMessage).length, 1);
    final f = await sessionFile();
    expect(f.existsSync(), isTrue, reason: 'writeback 应落项目树');
    final lines = await fileLines();
    // 首行 header（无 type 键，判据 = conversationId+version）：
    // workspacePath/cwd 从项目派生（默认项目无工作目录 → 缺省）。
    final header = jsonDecode(lines.first) as Map<String, dynamic>;
    expect(header['conversationId'], 'c1');
    expect(header['version'], kSessionFormatVersion);
    expect(lines.length, greaterThanOrEqualTo(3));
    // user/assistant 事件在场。
    expect(lines.join('\n'), contains('user/message'));
    expect(lines.join('\n'), contains('assistant/message'));
  });

  test('fast path：JSONL 命中且不落后 → 直接用，不重写文件', () async {
    // 预置一份日志：1 user + 1 assistant。
    final log0 = SessionLog.fromEvents([]);
    log0.append(kEventUserMessage, {'content': '旧'},
        source: const {'kind': 'user'}, timeMs: 1);
    log0.append(kEventAssistantMessage, {'content': '答'},
        source: const {'kind': 'model', 'provider': 'x'}, timeMs: 2);
    await store.rewrite('c1', log0);
    final before = (await fileLines()).length;

    // history 比日志少（SQLite 被删过一行）→ fast path 保留 JSONL 真相。
    final log = await store.loadOrImport('c1', [user('旧')], writeback: true);
    expect(log.rawEvents.length, 2);
    expect((await fileLines()).length, before, reason: '命中不重写');
  });

  test('落后对账：JSONL 消息数 < SQLite 可导入数 → 整体重建回写', () async {
    // 预置只有 1 条 user 的落后日志。
    final log0 = SessionLog.fromEvents([]);
    log0.append(kEventUserMessage, {'content': '旧'},
        source: const {'kind': 'user'}, timeMs: 1);
    await store.rewrite('c1', log0);

    final log = await store.loadOrImport(
        'c1', [user('旧'), assistant('答1'), assistant('答2')],
        writeback: true);
    // 重建：1 user + 2 assistant 全量在场。
    expect(
        log.rawEvents.where((e) => e.type == kEventAssistantMessage).length, 2);
    final lines = await fileLines();
    expect(lines.where((l) => l.contains('assistant/message')).length, 2);
  });

  test('writeback=false：未命中只导入内存，不落盘', () async {
    final log = await store.loadOrImport('c1', [user('hi')], writeback: false);
    expect(log.rawEvents, isNotEmpty);
    expect((await sessionFile()).existsSync(), isFalse, reason: '只读调用不写盘');
  });

  test('appendEvent 串行化：连发多条事件，文件顺序与提交顺序一致', () async {
    final futures = <Future<void>>[];
    for (var i = 0; i < 20; i++) {
      futures.add(store.appendEvent(
        'c1',
        SessionEvent(
            type: kEventUserMessage,
            seq: i,
            timeMs: 1000 + i,
            data: {'content': 'e$i'},
            source: const {'kind': 'user'}),
      ));
    }
    await Future.wait(futures);

    final lines = await fileLines();
    expect(lines.first, contains('"conversationId":"c1"'),
        reason: '首事件触发 header 创建');
    final seqs = <int>[];
    for (final l in lines.skip(1)) {
      final j = jsonDecode(l) as Map<String, dynamic>;
      seqs.add(j['seq'] as int);
    }
    expect(seqs, [0, 1, 2, 3, 4, 5, 6, 7, 8, 9, 10, 11, 12, 13, 14, 15, 16, 17, 18, 19],
        reason: 'write-through 必须保序（同步广播 → 异步落盘）');
  });

  test('回合事件全量可回放：turn/step/tool 事件 write-through 后 load 还原', () async {
    final log0 = SessionLog.fromEvents([]);
    log0.append(kEventTurnStart, {'reason': null},
        source: const {'kind': 'user'}, timeMs: 1);
    log0.append(kEventUserMessage, {'content': '查天气'},
        source: const {'kind': 'user'}, timeMs: 2);
    log0.append(kEventToolCall, {'name': 'web_search', 'callId': 't1'},
        source: const {'kind': 'model', 'provider': 'x'}, timeMs: 3);
    log0.append(kEventToolResult, {'callId': 't1', 'content': '晴'},
        source: const {'kind': 'tool', 'callId': 't1'}, timeMs: 4);
    log0.append(kEventAssistantMessage, {'content': '今天晴'},
        source: const {'kind': 'model', 'provider': 'x'}, timeMs: 5);
    log0.append(kEventTurnEnd, {'reason': {'kind': 'completed'}},
        source: const {'kind': 'model', 'provider': 'x'}, timeMs: 6);
    for (final e in log0.rawEvents) {
      await store.appendEvent('c1', e);
    }
    // 校验 source kind 不被破坏。
    expect((await fileLines()).join('\n'), contains('tool/result'));

    final loaded = await store.load('c1');
    final types = loaded.rawEvents.map((e) => e.type).toList();
    expect(types,
        [kEventTurnStart, kEventUserMessage, kEventToolCall, kEventToolResult, kEventAssistantMessage, kEventTurnEnd]);
    // 崩溃修复不误伤已闭合回合。
    expect(loaded.rawEvents.last.type, kEventTurnEnd);
  });
}
