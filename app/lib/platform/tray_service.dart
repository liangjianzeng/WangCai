// Windows 托盘驻留（设计 §3 / M3-a）：关窗 = 隐藏到托盘（进程驻留），
// 托盘单击唤起、右键菜单 显示/隐藏/退出。API 用法与拦截模式沿用 M0-2
// spike 的实测结论（preventClose 必须显式 set；退出走 destroy 不走 exit）。
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:tray_manager/tray_manager.dart';
import 'package:window_manager/window_manager.dart';

import '../services/settings_service.dart' show InferenceSettings;
import 'window_geometry.dart';

class TrayService with TrayListener, WindowListener {
  TrayService._();
  static final TrayService instance = TrayService._();

  /// 托盘「设置」菜单 → 让 HomeScreen 打开「更多」面板（配置入口）。
  /// TrayService 是单例（非 Riverpod widget），无法直接驱动 UI，
  /// 故用静态回调桥接；HomeScreen.initState 注册。
  static void Function()? onOpenSettingsPanel;

  bool _quitting = false;
  bool _initialized = false;
  String _baseTooltip = '汪柴 · 本地 AI 助手';

  /// 关窗行为（设置「更多 → 窗口」）：true = 关窗隐藏到托盘（默认）；
  /// false = 关窗直接退出。由 WangCaiApp 经 ref.listen 同步（syncFromSettings）。
  bool _closeToTray = true;

  // M3 托盘四色（voice-wakeup-min-spec §2）：IDLE=原版灰 / ARMED=黄 /
  // CAPTURE=绿 / SPEAK=蓝（资源 tool/gen_voice_assets.dart 生成，随仓固定）。
  static const _voiceIcons = {
    'idle': 'assets/tray_icon.ico',
    'armed': 'assets/tray/voice_armed.ico',
    'capture': 'assets/tray/voice_capture.ico',
    'speak': 'assets/tray/voice_speak.ico',
  };
  static const _voiceLabels = {
    'idle': '待命',
    'armed': '待唤醒',
    'capture': '聆听中',
    'speak': '播报中',
  };
  String _voiceKey = 'idle';

  /// 语音状态灯（VoiceService → 托盘；inference_gateway 订阅驱动）。
  /// 优先级：播报 > 识别 > 待唤醒 > 待命。幂等：状态未变不重设图标。
  Future<void> setVoiceStatus({
    required bool speaking,
    required bool capturing,
    required bool wakeListening,
  }) async {
    if (!Platform.isWindows || !_initialized) return;
    final key = speaking
        ? 'speak'
        : capturing
            ? 'capture'
            : wakeListening
                ? 'armed'
                : 'idle';
    if (key == _voiceKey) return;
    _voiceKey = key;
    try {
      await trayManager.setIcon(_voiceIcons[key]!);
      await trayManager.setToolTip('$_baseTooltip · ${_voiceLabels[key]}');
    } catch (e) {
      debugPrint('[TrayService] setVoiceStatus failed: $e');
    }
  }

  /// main.dart 的 initInferenceEngine 里调用（runApp 前，fork #10）。
  Future<void> init({String tooltip = '汪柴 · 本地 AI 助手'}) async {
    if (!Platform.isWindows || _initialized) return;
    _initialized = true;
    _baseTooltip = tooltip;
    await windowManager.ensureInitialized();
    // 关窗语义先行：监听 + preventClose 是「点关闭不杀进程」的根本，必须先于
    // 图标/菜单落地（M0-2 实测：不 set 时 Release 关窗即整个 app 退出，产品
    // 语义要求驻留）。2026-11-06 用户实测「关窗都死、右键毛都没有」——整段
    // init 被跳过所致，这里再保证图标那一步失败也不连坐关窗拦截。
    windowManager.addListener(this);
    await windowManager.setPreventClose(true);
    try {
      await trayManager.setIcon('assets/tray_icon.ico');
      await trayManager.setToolTip(tooltip);
      await trayManager.setContextMenu(Menu(items: [
        MenuItem(key: 'show', label: '显示窗口'),
        MenuItem(key: 'hide', label: '隐藏到托盘'),
        // 2026-11-06：托盘右键「设置」→ 显示窗口并打开「更多」面板（配置入口）。
        MenuItem(key: 'settings', label: '设置'),
        MenuItem.separator(),
        MenuItem(key: 'quit', label: '退出'),
      ]));
    } catch (e) {
      // 只降级托盘外观（没图标/菜单），关窗驻留与监听不受影响。
      debugPrint('[TrayService] tray icon/menu failed: $e');
    }
    trayManager.addListener(this);
    debugPrint('[TrayService] ready (preventClose + menu)');
  }

  /// 从设置同步关窗行为（WangCaiApp.build 直接调用；build watch 设置，
  /// 每次设置变化重建时同步，天然覆盖初始值）。
  void syncFromSettings(InferenceSettings settings) {
    _closeToTray = settings.closeToTray;
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
      case 'settings':
        _openSettingsPanel();
      case 'quit':
        quit();
    }
  }

  /// 托盘「设置」：显示窗口并让 HomeScreen 打开「更多」面板（配置入口）。
  /// onTrayMenuItemClick 是 void 接口，故 fire-and-forget 不 await。
  Future<void> _openSettingsPanel() async {
    await windowManager.show();
    await windowManager.focus();
    TrayService.onOpenSettingsPanel?.call();
  }

  @override
  Future<void> onWindowClose() async {
    // §3 产品模式：关窗默认 = 隐藏到托盘（M0-2 实测：挂起 close 请求会段错误，
    // 直接 hide 不悬挂）。_quitting 时放行 → destroy 真退出。
    // 2026-11-06：设置「关闭时最小化到托盘」关 → 关窗直接退出（quit 内部已
    // saveFromWindow + setPreventClose(false) + destroy）。
    if (_quitting) return;
    if (!_closeToTray) {
      await quit();
      return;
    }
    await WindowGeometry.saveFromWindow(); // v0.0.4 Phase 3：关窗前记忆几何
    await windowManager.hide();
  }
}
