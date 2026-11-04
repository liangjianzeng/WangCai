// v0.0.4 Phase 3 窗口几何记忆（计划书 §4.1）：主窗口尺寸/最大化状态
// 持久化到 dataDir('window.json')。
//
// 刻意**不记忆窗口位置**：多显示器拔插后恢复旧坐标会把窗口放回不存在的
// 屏幕外（桌面应用经典陷阱）；只恢复尺寸 + 最大化，位置交还 Windows 级联。
// 关窗（隐藏到托盘）与退出（destroy 前）双钩子保存（tray_service）。
import 'dart:convert';
import 'dart:io';

import 'package:flutter/widgets.dart' show Size;
import 'package:window_manager/window_manager.dart';

import 'wangcai_paths.dart';

class WindowGeometry {
  final Size size;
  final bool maximized;
  const WindowGeometry({required this.size, required this.maximized});

  static File _file() => File(
      '${WangCaiPaths.dataDir('window.json').path}');

  /// 读取记忆（文件缺失/损坏/字段脏 → null，走默认尺寸）。
  static WindowGeometry? load() {
    try {
      final f = _file();
      if (!f.existsSync()) return null;
      final j = jsonDecode(f.readAsStringSync()) as Map<String, dynamic>;
      final w = (j['w'] as num?)?.toDouble();
      final h = (j['h'] as num?)?.toDouble();
      if (w == null || h == null || w < 200 || h < 150) return null;
      return WindowGeometry(
        size: Size(w, h),
        maximized: j['maximized'] == true,
      );
    } catch (_) {
      return null;
    }
  }

  /// 从当前窗口实况保存（关窗/退出钩子调用；失败静默）。
  static Future<void> saveFromWindow() async {
    try {
      final bounds = await windowManager.getBounds();
      final maximized = await windowManager.isMaximized();
      final f = _file();
      if (!f.parent.existsSync()) f.parent.createSync(recursive: true);
      await f.writeAsString(
          jsonEncode({
            'w': bounds.size.width.round(),
            'h': bounds.size.height.round(),
            'maximized': maximized,
          }),
          flush: true);
    } catch (_) {}
  }
}
