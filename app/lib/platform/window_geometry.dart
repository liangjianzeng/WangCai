// v0.0.4 Phase 3 窗口几何记忆（计划书 §4.1）：主窗口尺寸/最大化状态
// 持久化到 dataDir('window.json')。
//
// 刻意**不记忆窗口位置**：多显示器拔插后恢复旧坐标会把窗口放回不存在的
// 屏幕外（桌面应用经典陷阱）；只恢复尺寸 + 最大化，位置交还 Windows 级联。
// 关窗（隐藏到托盘）与退出（destroy 前）双钩子保存（tray_service）。
//
// 2026-11-06 消息 APP 形态：紧凑窄长窗模式（compactWindow）。
//   - compact=true 时窗口是窄高预设；normalSize 记忆开启前的普通尺寸，
//     关闭紧凑时恢复它（避免跳回默认丢用户尺寸）。
//   - WindowCompact.apply 切换时即把 w/h（紧凑/普通尺寸）写入 window.json，
//     故启动时 WindowGeometry.load() 读到的 size 已是当前形态尺寸，main.dart
//     无需特判紧凑启动。
import 'dart:convert';
import 'dart:io';

import 'package:flutter/widgets.dart' show Size;
import 'package:screen_retriever/screen_retriever.dart';
import 'package:window_manager/window_manager.dart';

import 'wangcai_paths.dart';

class WindowGeometry {
  final Size size;
  final bool maximized;

  /// 是否处于紧凑窄长窗模式。
  final bool compact;

  /// 开启紧凑前的普通尺寸（关闭紧凑时恢复它）；null = 未记忆。
  final Size? normalSize;

  const WindowGeometry({
    required this.size,
    required this.maximized,
    this.compact = false,
    this.normalSize,
  });

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
      final nw = (j['normalW'] as num?)?.toDouble();
      final nh = (j['normalH'] as num?)?.toDouble();
      return WindowGeometry(
        size: Size(w, h),
        maximized: j['maximized'] == true,
        compact: j['compact'] == true,
        normalSize: (nw != null && nh != null && nw >= 200 && nh >= 150)
            ? Size(nw, nh)
            : null,
      );
    } catch (_) {
      return null;
    }
  }

  /// 从当前窗口实况保存（关窗/退出钩子调用；失败静默）。
  /// 保留已有 compact 标志与 normalSize（紧凑模式下关窗不应丢普通尺寸记忆）。
  static Future<void> saveFromWindow() async {
    try {
      final bounds = await windowManager.getBounds();
      final maximized = await windowManager.isMaximized();
      final prev = load();
      final f = _file();
      if (!f.parent.existsSync()) f.parent.createSync(recursive: true);
      await f.writeAsString(
          jsonEncode({
            'w': bounds.size.width.round(),
            'h': bounds.size.height.round(),
            'maximized': maximized,
            'compact': prev?.compact ?? false,
            if (prev?.normalSize != null)
              'normalW': prev!.normalSize!.width.round(),
            if (prev?.normalSize != null)
              'normalH': prev!.normalSize!.height.round(),
          }),
          flush: true);
    } catch (_) {}
  }
}

/// 紧凑窄长窗（消息 APP 形态，2026-11-06）：窄高预设。
/// 开启 → 切到窄高预设并记忆普通尺寸；关闭 → 恢复普通尺寸。
/// 左栏收起由 UI 侧（home_screen）处理，本类只管窗口尺寸与持久化。
class WindowCompact {
  /// 紧凑窗宽度（窄，≈手机聊天宽度）。
  static const double width = 400;

  /// 紧凑窗高度占主屏工作区高的比例（长体）。
  static const double heightRatio = 0.85;

  /// 默认普通尺寸（无记忆时回落）。
  static const Size defaultNormal = Size(1280, 800);

  /// 紧凑预设尺寸：宽 [width]，高 = 主屏工作区高 * [heightRatio]。
  static Future<Size> compactSize() async {
    double workH = 900;
    try {
      final d = await screenRetriever.getPrimaryDisplay();
      workH = d.visibleSize?.height ?? d.size.height;
    } catch (_) {}
    return Size(width, (workH * heightRatio).clamp(480.0, 1400.0));
  }

  /// 应用紧凑模式：on = 切窄高并记忆普通尺寸；off = 恢复普通尺寸。
  static Future<void> apply(bool on) async {
    if (!Platform.isWindows) return;
    await windowManager.ensureInitialized();
    final prev = WindowGeometry.load();
    if (on) {
      // 记忆开启前的普通尺寸（仅当当前不是紧凑时）。
      final normal = prev?.normalSize ??
          (prev != null && !prev.compact ? prev.size : null);
      final cs = await compactSize();
      await windowManager.setSize(cs);
      await _write(cs, maximized: false, compact: true, normal: normal);
    } else {
      final normal = prev?.normalSize ?? defaultNormal;
      await windowManager.setSize(normal);
      await _write(normal, maximized: false, compact: false, normal: normal);
    }
  }

  static Future<void> _write(
    Size size, {
    required bool maximized,
    required bool compact,
    Size? normal,
  }) async {
    try {
      final f = WindowGeometry._file();
      if (!f.parent.existsSync()) f.parent.createSync(recursive: true);
      await f.writeAsString(
          jsonEncode({
            'w': size.width.round(),
            'h': size.height.round(),
            'maximized': maximized,
            'compact': compact,
            if (normal != null) 'normalW': normal.width.round(),
            if (normal != null) 'normalH': normal.height.round(),
          }),
          flush: true);
    } catch (_) {}
  }
}
