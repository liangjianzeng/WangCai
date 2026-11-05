import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

import 'package:wangcai/models/conversation.dart';
import 'package:wangcai/services/storage_service.dart';

// ---------------------------------------------------------------------------
// v0.0.4.1 DSH rename-pins：conversations.titlePinned（SQLite v8）
// 存储往返 + 模型 toMap/fromMap 一致性。
// ---------------------------------------------------------------------------

void main() {
  late Directory tmp;

  setUpAll(() {
    sqfliteFfiInit();
    databaseFactory = databaseFactoryFfi;
  });

  setUp(() {
    tmp = Directory.systemTemp.createTempSync('wc_conv_title_');
    StorageService.dbPathOverrideForTest = '${tmp.path}/test.db';
  });

  tearDown(() async {
    StorageService.dbPathOverrideForTest = null;
    await StorageService.closeForTest();
    if (tmp.existsSync()) tmp.deleteSync(recursive: true);
  });

  test('新建默认未钉住；改名钉住后持久化并保持', () async {
    final db = StorageService();
    final c = await db.createConversation(title: '新对话');

    var list = await db.getAllConversations();
    expect(list.firstWhere((e) => e.id == c.id).titlePinned, isFalse);

    await db.updateConversation(id: c.id, title: '我的会话', titlePinned: true);
    list = await db.getAllConversations();
    final reloaded = list.firstWhere((e) => e.id == c.id);
    expect(reloaded.title, '我的会话');
    expect(reloaded.titlePinned, isTrue);

    // 钉住后仅更新条数不得清掉钉住标记（update 只动传入字段）。
    await db.updateConversation(id: c.id, messageCount: 5);
    list = await db.getAllConversations();
    expect(list.firstWhere((e) => e.id == c.id).titlePinned, isTrue);
  });

  test('Conversation toMap/fromMap 保 titlePinned', () {
    final c = Conversation(id: 'x', title: 't', titlePinned: true);
    expect(Conversation.fromMap(c.toMap()).titlePinned, isTrue);
    expect(
        Conversation.fromMap({
          'id': 'y',
          'title': 't',
          'createdAt': 0,
          'updatedAt': 0,
        }).titlePinned,
        isFalse);
  });
}
