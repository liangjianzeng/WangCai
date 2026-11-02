// 按住说话回显浮层键盘场景回归（真机 bug：键盘打开时浮层被软键盘整个
// 盖住，看不到实时转写）。root overlay 不随 Scaffold 收缩，浮层必须
// 依赖 MediaQuery.viewInsets 自行抬升。
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:tongyi_lite/asr/hold_to_talk.dart';

void main() {
  Future<(BuildContext, OverlayEntry)> pumpOverlay(WidgetTester tester,
      HoldToTalkSession session) async {
    late BuildContext ctx;
    await tester.pumpWidget(MaterialApp(
      home: Scaffold(
        body: Builder(builder: (c) {
          ctx = c;
          return const SizedBox.expand();
        }),
      ),
    ));
    final entry = OverlayEntry(
        builder: (_) => buildHoldTalkOverlayForTest(session));
    Overlay.of(ctx, rootOverlay: true).insert(entry);
    return (ctx, entry);
  }

  double viewHeight(WidgetTester tester) =>
      tester.view.physicalSize.height / tester.view.devicePixelRatio;

  Rect decoratedCard(WidgetTester tester) => tester.getRect(find
      .descendant(
          of: find.byKey(const ValueKey('hold-overlay-card')),
          matching: find.byType(DecoratedBox))
      .first);

  testWidgets('键盘打开时浮层卡片整体位于键盘上方', (tester) async {
    const keyboard = 300.0;
    // FakeViewPadding 是物理像素（ViewPadding 语义），MediaQuery 是逻辑像素。
    tester.view.viewInsets =
        FakeViewPadding(bottom: keyboard * tester.view.devicePixelRatio);
    addTearDown(tester.view.reset);

    final session = HoldToTalkSession();
    final (_, entry) = await pumpOverlay(tester, session);
    addTearDown(entry.remove);
    await tester.pump();

    final card = decoratedCard(tester);
    expect(card.bottom, lessThan(viewHeight(tester) - keyboard),
        reason: '键盘打开时回显卡片不能沉到键盘后面');
  });

  testWidgets('键盘弹起/收起浮层自动抬升/回落（MediaQuery 依赖重建）', (tester) async {
    addTearDown(tester.view.reset);
    final session = HoldToTalkSession();
    final (_, entry) = await pumpOverlay(tester, session);
    addTearDown(entry.remove);
    await tester.pump();

    // 初始键盘收起：卡片贴底，距屏幕底 32。
    expect(decoratedCard(tester).bottom, closeTo(viewHeight(tester) - 32, 0.5));

    // 键盘弹起 → 浮层抬升（不重插浮层、不额外 setState）。
    tester.view.viewInsets =
        FakeViewPadding(bottom: 300 * tester.view.devicePixelRatio);
    await tester.pump();
    final lifted = decoratedCard(tester).bottom;
    expect(lifted, lessThan(viewHeight(tester) - 300));

    // 键盘收起 → 回落原位。
    tester.view.viewInsets = FakeViewPadding(bottom: 0);
    await tester.pump();
    expect(decoratedCard(tester).bottom, closeTo(viewHeight(tester) - 32, 0.5));
  });

  testWidgets('引擎未就绪：提示「引擎加载中」而非「请说话」，无声浪', (tester) async {
    addTearDown(tester.view.reset);
    final session = HoldToTalkSession();
    final (_, entry) = await pumpOverlay(tester, session);
    addTearDown(entry.remove);
    await tester.pump();

    expect(find.text('引擎加载中，请稍后…'), findsOneWidget,
        reason: '监听真正开始前不能提示「请说话」');
    expect(find.text('请说话…'), findsNothing);
    expect(find.byType(CircularProgressIndicator), findsOneWidget);
    expect(find.byIcon(Icons.mic), findsNothing,
        reason: '声浪（麦克风图标）只在引擎就绪后出现');
  });

  testWidgets('引擎就绪：切换为「请说话」+ 声浪动态', (tester) async {
    addTearDown(tester.view.reset);
    final session = HoldToTalkSession();
    final (_, entry) = await pumpOverlay(tester, session);
    addTearDown(entry.remove);
    await tester.pump();

    session.ready.value = true;
    await tester.pump();

    expect(find.text('请说话…'), findsOneWidget);
    expect(find.text('引擎加载中，请稍后…'), findsNothing);
    expect(find.byIcon(Icons.mic), findsOneWidget);
  });
}
