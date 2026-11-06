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
  /// 加载模型。桌面参数体系（v0.0.3 Phase 3）：null = 未表态，交由下层
  /// 优先级链 **模型级(此参数) > 引擎 defaultConfig > manifest 模板/preset**
  /// 逐档回落；非 null = 模型级显式意图（customArgs > defaultConfig > 模板）。
  ///  - [nCtx]/[chunk]/[gpuLayers]：LocalModelConfig 的覆盖项由此透传；
  ///  - [mmprojPath]/[draftPath]：视觉塔 / 投机草稿（模型级配置，非全局开关）；
  ///  - [customArgs]：模型级自定义尾参（追加在 argsTemplate 之后）；
  ///  - [engineId]：引擎钉选（null = Auto 路由；命中失败回落 Auto 并留痕）。
  /// 手机端参数组（gpuBackend/vkNoSubgroup/nUbatch/moe*/enableGpu/enableMtp）
  /// 已随 Phase 3「手机参数链路删除」退场。
  Future<bool> loadModel(
    String path, {
    int? nCtx,
    int? chunk,
    int? gpuLayers,
    String? mmprojPath,
    String? draftPath,
    List<String>? customArgs,
    String? engineId,
  });

  Future<void> unloadModel();

  // setOomGuard/setKvCacheType/setFlashAttn（手机端 JNI 推送三件套）已随
  // Phase 4 删除：OOM 守卫由 manifest admission 承担，KV/FA 由引擎参数链决定。

  Future<bool> isLoaded();
  Future<bool> isModelLoaded();
  Future<Map<String, dynamic>> getModelInfo();

  // ── 状态查询 ──────────────────────────────────────────────────────────
  Future<Map<String, int>> getMemoryInfo();
  Future<Map<String, dynamic>> getInferenceStats();

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

  // 语音三件套（supportsAudio/startRecording/stopRecording）已随 D4 裁决删除：
  // 语音走 VoiceService（sherpa 引擎族），不再挂推理后端的槽位。

  Future<Map<String, double>> benchmark({
    String prompt,
    int nRepeats,
  });

  /// 释放（同步签名与 InferenceService 对齐；异步清理由实现内部 fire-and-forget）。
  void dispose();
}
