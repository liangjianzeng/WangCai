// Windows 托盘驻留（设计 §3 / M3-a）：关窗 = 隐藏到托盘（进程驻留），
// 托盘单击唤起、右键菜单 显示/隐藏/退出。API 用法与拦截模式沿用 M0-2
// spike 的实测结论（preventClose 必须显式 set；退出走 destroy 不走 exit）。
import 'dart:io';

import 'package:tray_manager/tray_manager.dart';
import 'package:window_manager/window_manager.dart';

import 'window_geometry.dart';

class TrayService with TrayListener, WindowListener {
  TrayService._();
  static final TrayService instance = TrayService._();

  bool _quitting = false;
  bool _initialized = false;

  /// main.dart 的 initInferenceEngine 里调用（runApp 前，fork #10）。
  Future<void> init({String tooltip = '汪柴 · 本地 AI 助手'}) async {
    if (!Platform.isWindows || _initialized) return;
    _initialized = true;
    await windowManager.ensureInitialized();
    await trayManager.setIcon('assets/tray_icon.ico');
    await trayManager.setToolTip(tooltip);
    await trayManager.setContextMenu(Menu(items: [
      MenuItem(key: 'show', label: '显示窗口'),
      MenuItem(key: 'hide', label: '隐藏到托盘'),
      MenuItem.separator(),
      MenuItem(key: 'quit', label: '退出'),
    ]));
    trayManager.addListener(this);
    windowManager.addListener(this);
    // window_manager 的关窗拦截是显式开关（M0-2 实测：不 set 时 Release 关窗
    // 即整个 app 退出，产品语义要求驻留）。
    await windowManager.setPreventClose(true);
  }

  /// 卸载模型后退出（退出前释放 NPU/显存进程，避免驻留 server）。
  Future<void> quit() async {
    _quitting = true;
    try {
      await WindowGeometry.saveFromWindow(); // v0.0.4 Phase 3：退出前记忆几何
      await windowManager.setPreventClose(false);
      await windowManager.destroy(); // 正确退出路径（M0-2 实测）
    } catch (_) {
      exit(0);
    }
  }

  @override
  void onTrayIconMouseDown() {
    windowManager.show(); // 单击托盘 = 唤起
  }

  @override
  void onTrayMenuItemClick(MenuItem item) {
    switch (item.key) {
      case 'show':
        windowManager.show();
      case 'hide':
        windowManager.hide();
      case 'quit':
        quit();
    }
  }

  @override
  Future<void> onWindowClose() async {
    // §3 产品模式：关窗 = 隐藏到托盘（M0-2 实测：挂起 close 请求会段错误，
    // 直接 hide 不悬挂）。_quitting 时放行 → destroy 真退出。
    if (_quitting) return;
    await WindowGeometry.saveFromWindow(); // v0.0.4 Phase 3：关窗前记忆几何
    await windowManager.hide();
  }
}
