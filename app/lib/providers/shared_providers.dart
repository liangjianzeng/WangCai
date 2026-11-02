import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../platform/inference_backend.dart';
import '../platform/inference_gateway.dart';
import '../services/openai_service.dart';
import '../services/storage_service.dart';

// Shared providers to avoid circular dependencies between chat_provider, model_provider, etc.
// M1-c 收编：类型换成 InferenceBackend，平台分支收敛在 inference_gateway.dart（设计 §2.3）。
final inferenceServiceProvider =
    Provider<InferenceBackend>((ref) => createInferenceBackend());
final storageServiceProvider = Provider<StorageService>((ref) => StorageService());
final openAiServiceProvider = Provider<OpenAiService>((ref) => OpenAiService());

/// 设备硬件信息（SoC 等），惰性获取一次；用于按芯片禁用不支持的 GPU 后端
/// （如 MediaTek 天玑芯片上 OpenCL 不可用，Vulkan 优先）。
final deviceInfoProvider = FutureProvider<Map<String, String>>((ref) async {
  return ref.read(inferenceServiceProvider).getDeviceInfo();
});
