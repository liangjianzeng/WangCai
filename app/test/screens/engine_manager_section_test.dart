// M1-b 冒烟：引擎管理面板渲染 / 按钮可用性 / 无 lastConfig 重启提示。
// 注入临时目录 dev registry——只验 UI 与状态接线，绝不 spawn 进程。
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:wangcai/engine/engine_paths.dart';
import 'package:wangcai/engine/engine_registry.dart';
import 'package:wangcai/screens/engine_manager_section.dart';

void main() {
  late Directory tmp;

  setUp(() => tmp = Directory.systemTemp.createTempSync('wc_engmgr'));
  tearDown(() async {
    // Windows 迟写竞争（分叉 #7 同款）：删除带短重试。
    for (var i = 0; i < 20; i++) {
      try {
        if (tmp.existsSync()) tmp.deleteSync(recursive: true);
        return;
      } catch (_) {
        await Future<void>.delayed(const Duration(milliseconds: 50));
      }
    }
  });

  Future<void> pump(WidgetTester tester) async {
    final reg = EngineRegistry.dev(
      paths: EnginePaths.root(tmp),
      wangcaiServerExe: 'X:/fake/llama-server.exe',
      ovLibsDirs: const ['X:/fake/ov/libs'],
    );
    await tester.pumpWidget(ProviderScope(
      child: MaterialApp(
        home: Scaffold(
          body: ListView(
            children: [EngineManagerSection(registry: () async => reg)],
          ),
        ),
      ),
    ));
    await tester.pumpAndSettle();
  }

  Finder rowOf(String id) => find.byKey(ValueKey(id));

  testWidgets('渲染全部实例：NPU/未启用 GPU/远端占位', (tester) async {
    await pump(tester);
    expect(find.text('汪柴 · Intel NPU'), findsOneWidget);
    expect(find.textContaining('（未启用）'), findsNWidgets(2)); // vulkan+cuda
    expect(find.textContaining('M2 接入配置界面'), findsOneWidget); // remote 行
    expect(find.text('已停止'), findsNWidgets(3)); // 三个本地实例初始态
  });

  testWidgets('stopped 态：停止禁用，按上次配置重启可用', (tester) async {
    await pump(tester);
    final stop = tester.widget<TextButton>(
      find.descendant(
          of: rowOf('wangcai-npu'), matching: find.widgetWithText(TextButton, '停止')),
    );
    expect(stop.onPressed, isNull);
    final restart = tester.widget<TextButton>(
      find.descendant(of: rowOf('wangcai-npu'),
          matching: find.widgetWithText(TextButton, '按上次配置重启')),
    );
    expect(restart.onPressed, isNotNull);
  });

  testWidgets('无 lastConfig 时点重启 → 提示先去模型管理页加载', (tester) async {
    await pump(tester);
    await tester.tap(find.descendant(of: rowOf('wangcai-npu'),
        matching: find.widgetWithText(TextButton, '按上次配置重启')));
    await tester.pump();
    expect(
      find.text('该引擎还没有成功加载过配置，先在模型管理页加载模型'),
      findsOneWidget,
    );
  });
}
