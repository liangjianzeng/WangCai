import 'package:flutter_test/flutter_test.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

import 'package:tongyi_lite/models/chat_message.dart';
import 'package:tongyi_lite/services/storage_service.dart';

// ---------------------------------------------------------------------------
// StorageService 真库行为（sqflite_common_ffi，纯 Dart 跑 SQLite）
// ---------------------------------------------------------------------------

void main() {
  setUpAll(() {
    sqfliteFfiInit();
    databaseFactory = databaseFactoryFfi;
  });

  test('getMessages(limit) 取的是**最新** N 条且升序返回（2026-09-30 语义修正）', () async {
    final storage = StorageService();
    const conv = 'health-check-conv';
    final base = DateTime(2026, 9, 30, 12);
    for (var i = 0; i < 250; i++) {
      await storage.saveMessage(ChatMessage(
        id: 'm$i',
        conversationId: conv,
        role: MessageRole.user,
        content: 'msg-$i',
        timestamp: base.add(Duration(minutes: i)),
      ));
    }
    final msgs = await storage.getMessages(conv, limit: 200);
    expect(msgs.length, 200);
    // 最旧被裁：不含前 50 条；最新保留：末条是最后写入的。
    expect(msgs.first.content, 'msg-50');
    expect(msgs.last.content, 'msg-249');
    // 升序不变（调用方语义）。
    for (var i = 1; i < msgs.length; i++) {
      expect(
        msgs[i].timestamp.isAfter(msgs[i - 1].timestamp),
        isTrue,
        reason: '第 $i 条必须晚于前一条',
      );
    }
    // 未超限场景不变：全部返回、升序。
    final all = await storage.getMessages(conv, limit: 200);
    expect(all.length, 200);
    final few = await storage.getMessages('empty-conv', limit: 200);
    expect(few, isEmpty);
  });
}
