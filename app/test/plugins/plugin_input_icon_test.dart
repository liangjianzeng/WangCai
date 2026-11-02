// 输入区图标的**样式一致性**钉死（2026-10-24 用户实测：「插件的样式不太对，应该和其他的那些
// 功能图标类似的样式封装」）。
//
// 为什么值得单独立一个文件：样式这类问题**不报错、不崩、功能全对**，只有人眼看得出 ——
// 而"人眼每次看"是不可能兑现的质检。所以把样式数值收成一个单真源（`PluginInputIcon` 的三个常量），
// 宿主附件按钮与两个内置插件图标都从这里取；这里钉三件事：
//   1. 外壳渲染出来确实是那套数值；
//   2. 插件**真的**用了这个外壳（不是自己 `new IconButton` —— 那才是分叉的起点）；
//   3. 宿主那边也走同一批常量（不许把 22/36/compact 再抄一遍字面量）。
// 第 2、3 条是源码级断言，与 `architecture_test.dart` 同一套路子（那种纪律本来就只能扫源码）。
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:tongyi_lite/plugins/plugin_input_icon.dart';

String _read(String p) => File(p).readAsStringSync();

void main() {
  group('输入区图标外壳（插件图标与功能图标一个模子）', () {
    test('三个样式常量就是宿主输入区那套（改一边不改另一边，这里先红）', () {
      expect(PluginInputIcon.kIconSize, 22);
      expect(PluginInputIcon.kBoxSize, 36);
      expect(PluginInputIcon.kDensity, VisualDensity.compact);
    });

    testWidgets('外壳渲染出来确实是 compact + 36×36 + padding 0 + 图标 22', (tester) async {
      await tester.pumpWidget(MaterialApp(
        home: Scaffold(
          body: PluginInputIcon(
            icon: Icons.graphic_eq_outlined,
            tooltip: '英语听写',
            onPressed: () {},
          ),
        ),
      ));
      final b = tester.widget<IconButton>(find.byType(IconButton));
      expect(b.visualDensity, VisualDensity.compact,
          reason: '默认密度是 48dp 见方，摆在一排 compact 图标里就是"多出来的一块"');
      expect(b.constraints, const BoxConstraints(minWidth: 36, minHeight: 36));
      expect(b.padding, EdgeInsets.zero);
      expect(tester.widget<Icon>(find.byType(Icon)).size, 22);
    });

    testWidgets('badgeCount>0 才挂 Badge（0 个附件还挂个 0 是噪声）', (tester) async {
      await tester.pumpWidget(const MaterialApp(
        home: Scaffold(
          body: PluginInputIcon(icon: Icons.add, tooltip: 't', badgeCount: 0),
        ),
      ));
      expect(find.byType(Badge), findsNothing, reason: '挂个 0 上去只是噪声');

      await tester.pumpWidget(const MaterialApp(
        home: Scaffold(
          body: PluginInputIcon(icon: Icons.add, tooltip: 't', badgeCount: 2),
        ),
      ));
      expect(find.byType(Badge), findsOneWidget);
      expect(find.text('2'), findsOneWidget);
    });

    test('两个内置插件都用这个外壳，不许自己 new IconButton（分叉的起点）', () {
      for (final p in <String>[
        'lib/plugins/builtin/en_dictation/en_dictation_plugin.dart',
        'lib/plugins/builtin/hello/hello_plugin.dart',
      ]) {
        final src = _read(p);
        expect(src, contains('PluginInputIcon('), reason: '$p 没走统一外壳 —— 图标样式又会各自长');
        expect(src, isNot(contains('IconButton(')),
            reason: '$p 自己 new 了 IconButton：宿主输入区改一次样式它就掉队');
      }
    });

    test('宿主附件按钮也走同一批常量（不许把 22/36/compact 再抄一遍字面量）', () {
      final src = _read('lib/screens/home_screen.dart');
      expect(src, contains('PluginInputIcon.kIconSize'),
          reason: '附件按钮的图标尺寸该取自单真源，抄字面量就是两份真相');
      expect(src, contains('PluginInputIcon.kBoxSize'));
      expect(src, contains('PluginInputIcon.kDensity'));
    });
  });
}
