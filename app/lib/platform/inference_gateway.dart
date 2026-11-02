// 推理后端统一入口（设计 §2.3）：平台分支只允许出现在这里，
// provider / agent adapter / plugin host 一律只见 InferenceBackend。
import 'dart:io';

import 'package:flutter/foundation.dart' show debugPrint;
import 'package:sqflite/sqflite.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

import '../services/inference_service.dart';
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
    await LocalServerInference.instance.initialize();
    // M3-a：托盘驻留（关窗=隐藏；main.dart 零 vendored diff —— 分支收敛在此）。
    // 失败（如测试环境无插件）不阻断主流程。
    try {
      await TrayService.instance.init();
    } catch (e) {
      debugPrint('[TrayService] init skipped: $e');
    }
  } else {
    await InferenceService().initialize();
  }
}
