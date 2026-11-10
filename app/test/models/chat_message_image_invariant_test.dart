// ChatMessage imagePath/imagePaths 双向不变量（2026-11-10 真机 bug 定案）：
// 「imagePath 恒等于首张」此前只在正方向成立——生图消息只传 imagePaths 时
// imagePath 为 null，气泡渲染判 imagePath → n=1 整张不显示。构造期双向补齐
// 后，DB 旧行（imagePath=null + imagePaths 有值）读取即修复。
import 'package:flutter_test/flutter_test.dart';

import 'package:wangcai/models/chat_message.dart';

ChatMessage _msg({String? imagePath, List<String>? imagePaths}) =>
    ChatMessage(
      id: 'm1',
      conversationId: 'c1',
      role: MessageRole.assistant,
      content: 'x',
      imagePath: imagePath,
      imagePaths: imagePaths,
    );

void main() {
  group('imagePath/imagePaths 双向不变量', () {
    test('只传 imagePaths（生图消息形态）→ imagePath 补齐为首张', () {
      final m = _msg(imagePaths: ['/a/1.png', '/a/2.png']);
      expect(m.imagePath, '/a/1.png');
      expect(m.imagePaths, ['/a/1.png', '/a/2.png']);
    });

    test('只传 imagePath（旧链路形态）→ imagePaths 补齐为单元素', () {
      final m = _msg(imagePath: '/a/1.png');
      expect(m.imagePath, '/a/1.png');
      expect(m.imagePaths, ['/a/1.png']);
    });

    test('两个都传（home_screen 用户消息形态）→ 原样保留', () {
      final m = _msg(imagePath: '/a/1.png', imagePaths: ['/a/1.png', '/a/2.png']);
      expect(m.imagePath, '/a/1.png');
      expect(m.imagePaths, ['/a/1.png', '/a/2.png']);
    });

    test('都为空 → 都为 null（无图消息不受影响）', () {
      final m = _msg();
      expect(m.imagePath, isNull);
      expect(m.imagePaths, isNull);
    });

    test('空串 imagePath 归一为 null', () {
      final m = _msg(imagePath: '');
      expect(m.imagePath, isNull);
      expect(m.imagePaths, isNull);
    });

    test('fromMap 往返：DB 旧行（imagePath=null + imagePaths 有值）读取即修复',
        () {
      final broken = {
        'id': 'm2',
        'conversationId': 'c1',
        'role': 'assistant',
        'content': '🎨 生成 1 张',
        'imagePath': null,
        'imagePaths': '["/d/img.png"]',
        'timestamp': DateTime.now().millisecondsSinceEpoch,
      };
      final m = ChatMessage.fromMap(broken);
      expect(m.imagePath, '/d/img.png', reason: '旧行读取时由构造器补齐首张');
      expect(m.imagePaths, ['/d/img.png']);
    });
  });
}
