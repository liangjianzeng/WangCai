import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

import 'package:wangcai/agent/session/event.dart';
import 'package:wangcai/agent/session/log.dart';
import 'package:wangcai/agent/session/store.dart';
import 'package:wangcai/agent/session/title.dart';
import 'package:wangcai/project/project_store.dart';

// ---------------------------------------------------------------------------
// v0.0.4.1 DSH session-title 对齐：确定性标题推导（normalize 语义纯函数）
// + session/title 事件落 JSONL（log-only、seq 续号、ignorable 标记）。
// ---------------------------------------------------------------------------

void main() {
  group('deriveSessionTitle（DSH normalize 语义）', () {
    test('短文本原样；空白拍平为单行', () {
      expect(deriveSessionTitle('你好'), '你好');
      expect(deriveSessionTitle('  多行\n\t输入   合并  '), '多行 输入 合并');
      expect(deriveSessionTitle('   \n  '), '');
    });

    test('剥行首 markdown 结构标记', () {
      expect(deriveSessionTitle('# 标题党'), '标题党');
      expect(deriveSessionTitle('> 引用开场'), '引用开场');
      expect(deriveSessionTitle('- 列表项开头'), '列表项开头');
      // 正文中间的 '-' 不动。
      expect(deriveSessionTitle('a - b 保持'), 'a - b 保持');
    });

    test('CJK 主导截到 16 字并补省略号', () {
      final long = '这' * 30;
      final t = deriveSessionTitle(long);
      expect(t.length, 17); // 16 字 + …
      expect(t.endsWith('…'), isTrue);
      expect(deriveSessionTitle('短一点的中文标题', ), isNotNull);
    });

    test('西文按词截 8 词', () {
      final t = deriveSessionTitle(
          'one two three four five six seven eight nine ten');
      expect(t, 'one two three four five six seven eight…');
    });

    test('emoji 代理对不被劈开（码点安全）', () {
      // 46 个 'a' + 一个代理对 emoji + 尾巴，截断点恰好落在代理对内部。
      final s = '${'a' * 46}😀${'b' * 20}';
      final t = deriveSessionTitle(s);
      // 孤立高代理项会抛异常或产出乱码；这里只要求不劈半：
      expect(t.runes.any((r) => r >= 0xD800 && r <= 0xDBFF), isFalse);
    });
  });

  group('appendTitleEvent（JSONL log-only 续号）', () {
    late Directory tmp;
    late Directory legacyBase;

    setUp(() {
      tmp = Directory.systemTemp.createTempSync('wc_title_');
      legacyBase = Directory.systemTemp.createTempSync('wc_title_legacy_');
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

    test('seq 续号 + log-only + 可忽略标记', () async {
      final js = JsonlSessionStore();
      final log = SessionLog.fromEvents([]);
      log.append(kEventUserMessage, {'content': '你好'},
          source: const {'kind': 'user'}, timeMs: 1);
      log.append(kEventAssistantMessage, {'content': '在的'},
          source: const {'kind': 'model'}, timeMs: 2);
      await js.rewrite('c1', log);

      await js.appendTitleEvent('c1', '打招呼', source: 'auto');
      await js.appendTitleEvent('c1', '我改的名', source: 'user');

      final loaded = await js.load('c1');
      final titles =
          loaded.rawEvents.where((e) => e.type == kEventSessionTitle).toList();
      expect(titles.length, 2);
      expect(titles[0].seq, 3);
      expect(titles[0].data['title'], '打招呼');
      expect(titles[0].source?['kind'], 'auto');
      expect(titles[0].isIgnorable, isTrue);
      expect(titles[1].seq, 4);
      expect(titles[1].source?['kind'], 'user');

      // 模型历史不受标题事件污染（log-only 投影过滤）。
      expect(
          loaded.rawEvents
              .where((e) => e.type == kEventUserMessage ||
                  e.type == kEventAssistantMessage)
              .length,
          2);
    });
  });
}
