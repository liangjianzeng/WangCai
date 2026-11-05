import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:wangcai/agent/session/event.dart';
import 'package:wangcai/agent/session/log.dart';
import 'package:wangcai/widgets/trajectory_view.dart';

// ---------------------------------------------------------------------------
// v0.0.4.1 DSH ui-trajectory v1：事件台账 + 选中行 inspector。
//
// 经 initialLog 注入日志（零真实 IO——widget 测试的 FakeAsync 区里真实
// 文件 IO 不推进，会把测试吊死到 10 分钟超时；IO 链路本身由
// session_fork/session_title 存储层测试覆盖）。
// ---------------------------------------------------------------------------

SessionEvent _ev(String type, int seq, Map<String, dynamic> data) =>
    SessionEvent(
        type: type,
        seq: seq,
        timeMs: 1000 + seq * 1500,
        data: data,
        source: const {'kind': 'test'});

Future<void> settle(WidgetTester tester) async {
  for (var i = 0; i < 5; i++) {
    await tester.pump(const Duration(milliseconds: 80));
  }
}

Future<void> finish(WidgetTester tester) async {
  FocusManager.instance.primaryFocus?.unfocus();
  await tester.pump(const Duration(milliseconds: 100));
  await tester.pump(const Duration(milliseconds: 100));
}

void main() {
  final log = SessionLog.fromEvents([
    _ev(kEventUserMessage, 1, {'content': '你好呀'}),
    _ev(kEventAssistantMessage, 2, {'content': '你好，有什么可以帮你'}),
    _ev(kEventToolCall, 3, {'name': 'web_search'}),
  ]);

  Widget wrap() => MaterialApp(
      home: Scaffold(
          body: TrajectoryView(conversationId: 'src', initialLog: log)));

  testWidgets('台账渲染事件行；选中行开原始 JSON inspector', (tester) async {
    await tester.pumpWidget(wrap());
    await settle(tester);

    expect(find.textContaining('3 事件'), findsOneWidget);
    expect(find.textContaining('你好，有什么可以帮你'), findsOneWidget);
    expect(find.text('#3'), findsOneWidget);

    await tester.tap(find.text('#3'));
    await settle(tester);
    expect(find.textContaining('"tool/call"'), findsWidgets);
    await finish(tester);
  });

  testWidgets('过滤框按内容收敛行', (tester) async {
    await tester.pumpWidget(wrap());
    await settle(tester);
    expect(find.text('#1'), findsOneWidget);

    await tester.enterText(find.byType(TextField), '你好');
    await settle(tester);
    expect(find.text('#1'), findsOneWidget);
    expect(find.text('#3'), findsNothing);
    await finish(tester);
  });
}
