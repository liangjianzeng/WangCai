// M0-2 冒烟入口：tray_manager + window_manager Windows 驻留验证（设计 §3）。
//
// 自动时间线（无需人工点击，产出 m0_tray_smoke.log 作为 DoD 证据）：
//   t0   托盘图标/菜单/悬浮提示就绪，窗口显示
//   t3s  隐藏到托盘 → 进程存活 3s（证明驻留：无窗口期不退出）
//   t6s  双击/程序化恢复显示
//   t8s  关闭请求 → 应被拦截为"隐藏到托盘"而非退出
//   t11s 写 done 并退出（exit 0）
//
// 运行：flutter run -d windows -t lib/tray_smoke.dart（cwd=app/）
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:tray_manager/tray_manager.dart';
import 'package:window_manager/window_manager.dart';

final File _logFile = File('m0_tray_smoke.log');

void smokeLog(String s) {
  _logFile.writeAsStringSync('${DateTime.now().toIso8601String()} $s\n',
      mode: FileMode.append);
}

final _trayListener = _TrayListener();
final _winListener = _WinListener();

/// 真退标志：置位后 onWindowClose 放行（M1 真 App 同款退出模式，冒烟顺带验证它）。
bool _quitting = false;

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  _logFile.writeAsStringSync('');
  await windowManager.ensureInitialized();
  await trayManager.setIcon('assets/tray_icon.ico');
  await trayManager.setToolTip('汪柴 M0 冒烟');
  await trayManager.setContextMenu(Menu(items: [
    MenuItem(key: 'show', label: '显示窗口'),
    MenuItem(key: 'hide', label: '隐藏到托盘'),
    MenuItem.separator(),
    MenuItem(key: 'quit', label: '退出'),
  ]));
  trayManager.addListener(_trayListener);
  windowManager.addListener(_winListener);
  // window_manager 的关窗拦截是显式开关，仅 override onWindowClose 不生效
  // （M0-2 实测：不 set 时 Release 关窗即整个 app 退、Debug 段错误）。
  await windowManager.setPreventClose(true);
  await windowManager.setTitle('汪柴 M0 冒烟');
  await windowManager.setSize(const Size(420, 300));
  smokeLog('launched: tray icon+menu ready, window shown');
  _runTimeline();
  runApp(const MaterialApp(home: _SmokePage()));
}

Future<void> _runTimeline() async {
  await Future<void>.delayed(const Duration(seconds: 3));
  await windowManager.hide();
  smokeLog('hidden-to-tray: process must stay alive');
  await Future<void>.delayed(const Duration(seconds: 3));
  smokeLog('alive-while-hidden: residency OK');
  await windowManager.show();
  smokeLog('shown-again');
  await Future<void>.delayed(const Duration(seconds: 2));
  await windowManager.close(); // 应被 onWindowClose 拦截为 hide，不退出
  smokeLog('close-requested: intercept expected (no exit)');
  await Future<void>.delayed(const Duration(seconds: 2));
  smokeLog('alive-after-close-intercept: clean-quit-via-destroy');
  _quitting = true;
  await windowManager.setPreventClose(false);
  await windowManager.destroy(); // 正确退出路径（exit(0) 会在 debug 引擎退出时段错误）
  smokeLog('exited');
}

class _TrayListener with TrayListener {
  @override
  void onTrayIconMouseDown() {
    smokeLog('tray-click: show');
    windowManager.show();
  }

  @override
  void onTrayMenuItemClick(MenuItem item) {
    smokeLog('tray-menu: ${item.key}');
    switch (item.key) {
      case 'show':
        windowManager.show();
      case 'hide':
        windowManager.hide();
      case 'quit':
        _quitting = true;
        windowManager.destroy();
    }
  }
}

class _WinListener with WindowListener {
  @override
  Future<void> onWindowClose() async {
    // 设计 §3 产品模式：关窗 = 直接隐藏到托盘（不悬挂 close 请求——挂起不打理会段错误，
    // M0-2 实测）；_quitting 时放行 → destroy 真退出。
    if (_quitting) {
      smokeLog('onWindowClose passthrough (quitting)');
      return;
    }
    smokeLog('onWindowClose -> hide-to-tray');
    await windowManager.hide();
  }
}

class _SmokePage extends StatelessWidget {
  const _SmokePage();

  @override
  Widget build(BuildContext context) {
    return const Scaffold(
      body: Center(child: Text('汪柴 M0 tray smoke')),
    );
  }
}
