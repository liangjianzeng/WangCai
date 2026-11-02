/// OpenAiService.buildMessages 多图投影单测：
/// - imagePaths 全量转 image_url parts（长图切块 = 多 part）；
/// - MIME 按扩展名（png 切块不能被标成 jpeg）；
/// - visionCapable=false 全部剥离为纯文本。
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:tongyi_lite/models/chat_message.dart';
import 'package:tongyi_lite/services/openai_service.dart';

void main() {
  late Directory tmp;

  setUp(() async {
    tmp = await Directory.systemTemp.createTemp('openai_msgs');
  });
  tearDown(() => tmp.delete(recursive: true));

  ChatMessage userWithImages(String a, String b) {
    return ChatMessage(
      id: 'u1',
      conversationId: 'c1',
      role: MessageRole.user,
      content: '看这两块',
      imagePath: a,
      imagePaths: [a, b],
    );
  }

  test('visionCapable=true：imagePaths 全量转 image_url part + 按扩展名 MIME',
      () async {
    final a = File('${tmp.path}/slice_a.jpg')..writeAsBytesSync([0xFF, 0xD8]);
    final b = File('${tmp.path}/slice_b.png')..writeAsBytesSync([0x89, 0x50]);

    final msgs = await OpenAiService.buildMessages(
      [userWithImages(a.path, b.path)],
      visionCapable: true,
    );
    final parts = msgs.single['content'] as List;
    expect(parts.length, 3, reason: '文本 + 两张图');
    expect(parts[0]['type'], 'text');
    expect(
      (parts[1]['image_url']['url'] as String).startsWith(
          'data:image/jpeg;base64,'),
      isTrue,
    );
    expect(
      (parts[2]['image_url']['url'] as String).startsWith(
          'data:image/png;base64,'),
      isTrue,
    );
  });

  test('visionCapable=false：图片全部剥离为纯文本', () async {
    final a = File('${tmp.path}/x.jpg')..writeAsBytesSync([0xFF, 0xD8]);
    final msgs = await OpenAiService.buildMessages(
      [userWithImages(a.path, a.path)],
      visionCapable: false,
    );
    expect(msgs.single['content'], '看这两块');
  });

  test('mimeForPath：按扩展名判定，未知扩展名回退 jpeg', () {
    expect(OpenAiService.mimeForPath('/a/b.png'), 'image/png');
    expect(OpenAiService.mimeForPath('/a/b.JPG'), 'image/jpeg');
    expect(OpenAiService.mimeForPath('/a/b.webp'), 'image/webp');
    expect(OpenAiService.mimeForPath('/a/b'), 'image/jpeg');
  });

  test('visionPaths 优先：模型只发切片，原图不进消息（用户视图不外泄）',
      () async {
    final original =
        File('${tmp.path}/orig.jpg')..writeAsBytesSync([0xFF, 0xD8]);
    final s0 = File('${tmp.path}/s_0.png')..writeAsBytesSync([0x89, 0x50]);
    final s1 = File('${tmp.path}/s_1.png')..writeAsBytesSync([0x89, 0x51]);

    final msg = ChatMessage(
      id: 'u1',
      conversationId: 'c1',
      role: MessageRole.user,
      content: '看这张长图',
      imagePath: original.path,
      imagePaths: [original.path],
      visionPaths: [s0.path, s1.path],
    );
    final msgs = await OpenAiService.buildMessages([msg],
        visionCapable: true);
    final parts = msgs.single['content'] as List;
    expect(parts.length, 3, reason: '文本 + 两张切片；原图不得混入');
    for (final p in parts.skip(1)) {
      expect((p['image_url']['url'] as String).startsWith('data:image/png'),
          isTrue,
          reason: '只应有 PNG 切片（原 jpg 混入即为视图串台）');
    }
  });

  test('切片文件已被清理 → 历史重发回退原图', () async {
    final original =
        File('${tmp.path}/orig.jpg')..writeAsBytesSync([0xFF, 0xD8]);
    final msg = ChatMessage(
      id: 'u1',
      conversationId: 'c1',
      role: MessageRole.user,
      content: '再看一次',
      imagePath: original.path,
      imagePaths: [original.path],
      visionPaths: ['${tmp.path}/gone_0.png', '${tmp.path}/gone_1.png'],
    );
    final msgs = await OpenAiService.buildMessages([msg],
        visionCapable: true);
    final parts = msgs.single['content'] as List;
    expect(parts.length, 2);
    expect((parts[1]['image_url']['url'] as String).startsWith(
        'data:image/jpeg'), isTrue);
  });

  test('ChatMessage.visionPaths：toMap/fromMap 往返 + modelImagePaths getter',
      () {
    final m = ChatMessage(
      id: 'u1',
      conversationId: 'c1',
      role: MessageRole.user,
      content: 'hi',
      imagePath: '/p/orig.jpg',
      imagePaths: ['/p/orig.jpg'],
      visionPaths: ['/p/orig_0.png', '/p/orig_1.png'],
    );
    final back = ChatMessage.fromMap(m.toMap());
    expect(back.visionPaths, ['/p/orig_0.png', '/p/orig_1.png']);
    expect(back.imagePaths, ['/p/orig.jpg']);
    expect(back.modelImagePaths, back.visionPaths);

    // 无 visionPaths：modelImagePaths 回退 imagePaths（旧数据行为不变）。
    final plain = ChatMessage(
      id: 'u2',
      conversationId: 'c1',
      role: MessageRole.user,
      content: 'hi',
      imagePath: '/p/a.jpg',
    );
    expect(plain.visionPaths, isNull);
    expect(plain.modelImagePaths, ['/p/a.jpg']);
    expect(ChatMessage.fromMap(plain.toMap()).visionPaths, isNull);
  });
}
