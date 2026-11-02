// InferenceBackend：推理后端抽象（设计 §2.3 M1-c 收编点）。
// Android = JNI 直调 llama.cpp（InferenceService）；Windows = llama-server 子进程
// + OpenAI HTTP（LocalServerInference）。四个收编点（chat/model provider、
// agent LocalEngineAdapter、plugin host）只认这个接口，签名冻结。
//
// 语义约定（两实现必须一致，否则 provider 层分叉）：
//  - completionWithMessages 的 token 流原样透传（思考标签由上层过滤）；
//  - onLoadingLog 推送加载/引擎日志（null = 批次结束信号）；
//  - 未加载模型时 isModelLoaded=false，生成调用立即抛错（agent 快速失败）。
import 'dart:async';

abstract class InferenceBackend {
  /// 原生/引擎加载进度日志回调（与 InferenceService 同字段语义）。
  void Function(String? message)? onLoadingLog;

  Future<void> initialize();

  // ── 模型生命周期 ──────────────────────────────────────────────────────
  Future<bool> loadModel(
    String path, {
    int nCtx = 4096,
    bool enableGpu = true,
    int gpuLayers = 20,
    String gpuBackend = 'auto',
    bool enableMtp = false,
    String? mmprojPath,
    String? draftPath,
    int nUbatch = 0,
    bool vkNoSubgroup = false,
    String? moeManifest,
    int moeBank = 0,
    int moeSlotBytes = 0,
    int moeExpertsBytes = 0,
    int moeResidentBytes = 0,
  });

  Future<void> unloadModel();

  Future<void> setOomGuard({
    required bool enabled,
    int preHeadroomMb = 768,
    int postHeadroomMb = 1536,
  });

  Future<void> setKvCacheType(String type);
  Future<void> setFlashAttn(bool enabled);

  Future<bool> isLoaded();
  Future<bool> isModelLoaded();
  Future<Map<String, dynamic>> getModelInfo();

  // ── 状态查询 ──────────────────────────────────────────────────────────
  Future<Map<String, int>> getMemoryInfo();
  Future<Map<String, dynamic>> getInferenceStats();
  Future<Map<String, String>> getDeviceInfo();

  // ── 生成 ──────────────────────────────────────────────────────────────
  Stream<String> completion({
    required String prompt,
    int maxTokens = 2048,
    double temperature = 0.7,
    double topP = 0.9,
  });

  Stream<String> completionWithMessages({
    required String prompt,
    required String messagesJson,
    String? imagePath,
    List<String>? imagePaths,
    String? audioPath,
    int maxTokens = 2048,
    double temperature = 0.7,
    double topP = 0.9,
  });

  Future<String> complete({
    required String prompt,
    int maxTokens = 2048,
    double temperature = 0.7,
    double topP = 0.9,
  });

  Future<void> stopGeneration();
  Future<void> setEnableThinking(bool enable);
  Future<void> resetContext();

  // ── 语音（Windows 侧 M3 接入；Android 原生实现）────────────────────────
  Future<bool> supportsAudio();
  Future<bool> startRecording();
  Future<String?> stopRecording();

  Future<Map<String, double>> benchmark({
    String prompt,
    int nRepeats,
  });

  /// 释放（同步签名与 InferenceService 对齐；异步清理由实现内部 fire-and-forget）。
  void dispose();
}
