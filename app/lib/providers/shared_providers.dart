import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../services/inference_service.dart';
import '../services/openai_service.dart';
import '../services/storage_service.dart';

// Shared providers to avoid circular dependencies between chat_provider, model_provider, etc.
final inferenceServiceProvider = Provider<InferenceService>((ref) => InferenceService());
final storageServiceProvider = Provider<StorageService>((ref) => StorageService());
final openAiServiceProvider = Provider<OpenAiService>((ref) => OpenAiService());

/// 设备硬件信息（SoC 等），惰性获取一次；用于按芯片禁用不支持的 GPU 后端
/// （如 MediaTek 天玑芯片上 OpenCL 不可用，Vulkan 优先）。
final deviceInfoProvider = FutureProvider<Map<String, String>>((ref) async {
  return ref.read(inferenceServiceProvider).getDeviceInfo();
});
