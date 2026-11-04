import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';

// 回归测试：多行输入框外包 Focus(onKeyEvent) 后，按 Enter 应"直接发送"——
// 拦截发生在换行之前，文本不会追加 '\n'。这与 app 主聊天输入区的实现一致
// （home_screen.dart 的 _buildInputBar）。
void main() {
  testWidgets('回车被 Focus 拦截且不加换行', (tester) async {
    bool enterHandled = false;
    final controller = TextEditingController();

    await tester.pumpWidget(MaterialApp(
      home: Scaffold(
        body: Focus(
          canRequestFocus: false,
          onKeyEvent: (node, event) {
            if (event is KeyDownEvent &&
                event.logicalKey == LogicalKeyboardKey.enter) {
              enterHandled = true;
              return KeyEventResult.handled;
            }
            return KeyEventResult.ignored;
          },
          child: TextField(
            controller: controller,
            minLines: 2,
            maxLines: 8,
          ),
        ),
      ),
    ));

    await tester.tap(find.byType(TextField));
    await tester.pumpAndSettle();

    // 输入一段文字（不含换行）。
    await tester.enterText(find.byType(TextField), 'hello world');
    await tester.pumpAndSettle();
    expect(controller.text, 'hello world');

    // 按回车：应被 Focus 拦截（handled），且不插入换行。
    await tester.sendKeyEvent(LogicalKeyboardKey.enter);
    await tester.pumpAndSettle();

    expect(enterHandled, isTrue, reason: '回车应被 onKeyEvent 拦截');
    expect(controller.text, 'hello world', reason: '回车不应追加换行');
    expect(controller.text.contains('\n'), false,
        reason: '文本不得含换符');
  });
}
