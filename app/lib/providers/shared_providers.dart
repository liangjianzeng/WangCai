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

// deviceInfoProvider（SoC 硬件信息）已随 Phase 4 删除：唯一消费者是天玑
// 芯片禁用 OpenCL 的手机端 GPU 后端判定（settings_screen GPU 卡一并移除）。
