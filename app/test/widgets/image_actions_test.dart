// 生图消息的图片复制/另存锚（用户 2026-11-10 验收）：此前图片操作只藏在
// 长按/右键**图片本身**才弹的弹层里，动作行复制键只管文本——体感=没有入口。
// 本轮补三处可见入口：动作行图标 / 消息右键菜单 / 全屏预览工具栏。
// 动作落地本身（PowerShell 起进程写剪贴板 / win32 保存框起原生窗口）在
// 测试机不安全，这里只钉入口存在性与多图选张弹层，不点完成动作。
import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:wangcai/widgets/chat_bubble.dart';

Widget _wrap(Widget child) => MaterialApp(home: Scaffold(body: child));

void main() {
  // 当天 09:30 → 页脚时间必显 '09:30'（_formatTime 同日走 HH:mm），
  // 右键测试拿它当**中性落点**：MarkdownBody(selectable) 的
  // TextSelectionGestureDetector 会在桌面端吃掉正文上的次击，
  // 页脚时间戳是普通 Text，不被选择件认领，ContextMenuRegion 才能赢。
  final now = DateTime.now();
  final ts = DateTime(now.year, now.month, now.day, 9, 30);

  group('MessageActionsRow 复制图片/另存图片图标', () {
    testWidgets('带图消息 → 出现 copy_all + save_alt 两枚可见图标', (tester) async {
      await tester.pumpWidget(_wrap(MessageActionsRow(
        content: '已生成 1 张图片',
        timestamp: ts,
        isUser: false,
        imagePaths: const ['C:/wc/out/a.png'],
      )));
      await tester.pump();
      expect(find.byIcon(Icons.copy_all), findsOneWidget);
      expect(find.byIcon(Icons.save_alt), findsOneWidget);
    });

    testWidgets('纯文本消息 → 不出现图片动作', (tester) async {
      await tester.pumpWidget(_wrap(MessageActionsRow(
        content: '纯文本回复',
        timestamp: ts,
        isUser: false,
      )));
      await tester.pump();
      expect(find.byIcon(Icons.copy_all), findsNothing);
      expect(find.byIcon(Icons.save_alt), findsNothing);
    });

    testWidgets('路径全空串 = 无图处理（不出现半残图标）', (tester) async {
      await tester.pumpWidget(_wrap(MessageActionsRow(
        content: 'x',
        timestamp: ts,
        isUser: false,
        imagePaths: const ['', ''],
      )));
      await tester.pump();
      expect(find.byIcon(Icons.copy_all), findsNothing);
      expect(find.byIcon(Icons.save_alt), findsNothing);
    });

    testWidgets('多图点复制图片 → 先弹选张（图片 1/图片 2），不直接落剪贴板',
        (tester) async {
      await tester.pumpWidget(_wrap(MessageActionsRow(
        content: '已生成 2 张图片',
        timestamp: ts,
        isUser: false,
        imagePaths: const ['C:/wc/out/a.png', 'C:/wc/out/b.png'],
      )));
      await tester.pump();
      await tester.tap(find.byIcon(Icons.copy_all));
      await tester.pumpAndSettle();
      expect(find.text('图片 1'), findsOneWidget);
      expect(find.text('图片 2'), findsOneWidget);
    });
  });

  group('ChatBubble 消息右键菜单的图片入口', () {
    Future<void> rightClickOn(WidgetTester tester, Finder f) async {
      final g = await tester.startGesture(tester.getCenter(f),
          buttons: kSecondaryButton);
      await g.up();
      await tester.pumpAndSettle();
    }

    testWidgets('带图消息 → 右键菜单在复制全文之外多复制图片/另存图片…',
        (tester) async {
      await tester.pumpWidget(_wrap(ChatBubble(
        role: 'assistant',
        content: '已生成 1 张图片',
        timestamp: ts,
        imagePaths: const ['C:/wc/out/a.png'],
      )));
      await tester.pumpAndSettle();
      await rightClickOn(tester, find.text('09:30'));
      expect(find.text('复制全文'), findsOneWidget);
      expect(find.text('复制图片'), findsOneWidget);
      expect(find.text('另存图片…'), findsOneWidget);
    });

    testWidgets('纯文本消息 → 右键菜单照旧只有复制全文', (tester) async {
      await tester.pumpWidget(_wrap(ChatBubble(
        role: 'assistant',
        content: '纯文本回复内容',
        timestamp: ts,
      )));
      await tester.pumpAndSettle();
      await rightClickOn(tester, find.text('09:30'));
      expect(find.text('复制全文'), findsOneWidget);
      expect(find.text('复制图片'), findsNothing);
      expect(find.text('另存图片…'), findsNothing);
    });
  });
}
