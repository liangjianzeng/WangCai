// 推理后端统一入口（设计 §2.3）：平台分支只允许出现在这里，
// provider / agent adapter / plugin host 一律只见 InferenceBackend。
import 'dart:io';

import '../services/inference_service.dart';
import 'inference_backend.dart';
import 'local_server_inference.dart';

/// Provider 层工厂：Windows → llama-server 子进程网关；其余 → JNI InferenceService。
InferenceBackend createInferenceBackend() =>
    Platform.isWindows ? LocalServerInference.instance : InferenceService();

/// 启动门控初始化（main.dart 与 home_screen 自动加载共用）。
Future<void> initInferenceEngine() async {
  if (Platform.isWindows) {
    await LocalServerInference.instance.initialize();
  } else {
    await InferenceService().initialize();
  }
}
