import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

import 'package:wangcai/models/chat_message.dart';
import 'package:wangcai/services/storage_service.dart';

// ---------------------------------------------------------------------------
// StorageService 真库行为（sqflite_common_ffi，纯 Dart 跑 SQLite）
// ---------------------------------------------------------------------------

void main() {
  late Directory tmp;

  setUpAll(() {
    sqfliteFfiInit();
    databaseFactory = databaseFactoryFfi;
  });

  // 2026-11-05 隔离修复：本文件此前直写 %APPDATA%\WangCai\wangcai.db 真库
  //（health-check-conv 250 行垃圾 + 无清理）。真机开着 WangCai.exe 时
  // 全量测试直接 database is locked 假败，平时则污染用户数据。
  setUp(() {
    tmp = Directory.systemTemp.createTempSync('wc_storage_');
    StorageService.dbPathOverrideForTest = '${tmp.path}/test.db';
  });

  tearDown(() async {
    StorageService.dbPathOverrideForTest = null;
    await StorageService.closeForTest();
    if (tmp.existsSync()) tmp.deleteSync(recursive: true);
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

  test('v9 genMeta 列：生图消息带 imagePaths + 溯源元数据落库往返', () async {
    final storage = StorageService();
    const conv = 'imggen-conv';
    const meta =
        '{"seed":42,"size":"1024x1024","ms":18300,"model":"E:/Unsloth/models","prompt":"柴犬"}';
    await storage.saveMessage(ChatMessage(
      id: 'img1',
      conversationId: conv,
      role: MessageRole.assistant,
      content: '🎨 生成 1 张 · 1024x1024 · seed 42 · 18.3s',
      imagePaths: ['${tmp.path}/imagegen/img-1-42_1.png'],
      genMeta: meta,
    ));
    // 不带 genMeta 的普通消息不受影响（null 默认）。
    await storage.saveMessage(ChatMessage(
      id: 'txt1',
      conversationId: conv,
      role: MessageRole.user,
      content: '普通文本',
    ));
    final msgs = await storage.getMessages(conv);
    expect(msgs, hasLength(2));
    final img = msgs.firstWhere((m) => m.id == 'img1');
    expect(img.genMeta, meta);
    expect(img.imagePaths, hasLength(1));
    // 溯源字段可解析（同 seed 重生成的数据源）。
    final parsed = jsonDecode(img.genMeta!) as Map<String, dynamic>;
    expect(parsed['seed'], 42);
    expect(parsed['prompt'], '柴犬');
    final plain = msgs.firstWhere((m) => m.id == 'txt1');
    expect(plain.genMeta, isNull);
    // toMap 契约同步（fromMap 的镜像面）。
    expect(img.toMap()['genMeta'], meta);
  });
}
