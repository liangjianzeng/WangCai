// 推理后端统一入口（设计 §2.3）：平台分支只允许出现在这里，
// provider / agent adapter / plugin host 一律只见 InferenceBackend。
import 'dart:io';

import 'package:flutter/foundation.dart' show debugPrint;
import 'package:sqflite/sqflite.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

import '../services/inference_service.dart';
import '../voice/voice_service.dart';
import 'inference_backend.dart';
import 'local_server_inference.dart';
import 'tray_service.dart';

/// Provider 层工厂：Windows → llama-server 子进程网关；其余 → JNI InferenceService。
InferenceBackend createInferenceBackend() =>
    Platform.isWindows ? LocalServerInference.instance : InferenceService();

/// 启动门控初始化（main.dart 与 home_screen 自动加载共用）。
Future<void> initInferenceEngine() async {
  // 桌面（Windows 打包版）：sqflite 走 common_ffi —— StorageService 会话库与
  // BindingsStore 绑定表共用全局 databaseFactory。Android 走原生插件，不碰。
  if (!Platform.isAndroid && !Platform.isIOS) {
    sqfliteFfiInit();
    databaseFactory = databaseFactoryFfi;
  }
  if (Platform.isWindows) {
    // M3-a：托盘驻留（关窗=隐藏；main.dart 零 vendored diff —— 分支收敛在此）。
    // 2026-11-06 修：托盘先于引擎初始化——原先引擎抛异常（强杀留下的孤儿
    // llama-server 让启动账本扫描炸即如此）会把整段托盘带走：没图标、没右键
    // 菜单、且 setPreventClose 没设 → 点关闭直接退进程（用户实测「关窗都死、
    // 右键毛都没有」）。托盘与引擎互不依赖，失败（如测试环境无插件）均不阻断。
    try {
      await TrayService.instance.init();
      _bindTrayVoice();
    } catch (e) {
      debugPrint('[TrayService] init skipped: $e');
    }
    await LocalServerInference.instance.initialize();
  } else {
    await InferenceService().initialize();
  }
}

/// 托盘语音状态灯（M3 spec 四色）：门面状态/待命麦 → 托盘图标。
/// 订阅挂进程级单例上（本函数只被 init 调一次；测试环境 TrayService 未
/// init 时 setVoiceStatus 自守 no-op）。
void _bindTrayVoice() {
  final vs = VoiceService.instance;
  void push() => TrayService.instance.setVoiceStatus(
      speaking: vs.speaking,
      capturing: vs.capturing,
      wakeListening: vs.wakeMicOn.value);
  vs.states.listen((_) => push());
  vs.wakeMicOn.addListener(push);
  push();
}
