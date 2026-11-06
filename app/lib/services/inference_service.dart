import 'dart:async';
import 'dart:convert';
import 'package:flutter/services.dart';
import 'package:flutter/foundation.dart' show debugPrint;

import '../platform/inference_backend.dart';

/// Android JNI 后端；Windows 用 LocalServerInference（同 [InferenceBackend] 契约）。
class InferenceService implements InferenceBackend {
  static const _channel = MethodChannel('com.dgxspark.tongyilite/inference');
  static const _tokenChannel = EventChannel('com.dgxspark.tongyilite/tokens');
  static const _loadingLogChannel = EventChannel('com.dgxspark.tongyilite/loading_logs');

  StreamSubscription<dynamic>? _loadingLogSubscription;
  StreamSubscription<dynamic>? _currentTokenSubscription;
  bool _initialized = false;

  // Loading log callback — invoked when native pushes a loading progress message.
  void Function(String? message)? onLoadingLog;

  static final InferenceService _instance = InferenceService._();
  factory InferenceService() => _instance;
  InferenceService._() {
    _setupLoadingLogListener();
  }

  /// Set up the EventChannel listener for native loading progress logs.
  void _setupLoadingLogListener() {
    if (_initialized) return; // already set up (singleton instance)
    _initialized = true;

    final stream = _loadingLogChannel.receiveBroadcastStream();
    _loadingLogSubscription = stream.listen((event) {
      // Handle both String and null events properly
      if (event == null) {
        // Null signals end of loading batch - ignore or handle separately
        debugPrint('[InferenceService] Loading batch complete');
        return;
      }
      final message = event.toString();
      if (message.isNotEmpty && message != 'null') {
        onLoadingLog?.call(message);
      }
    }, onError: (err) {
      debugPrint('[InferenceService] EventChannel error: $err');
      onLoadingLog?.call(null); // Signal error
    });
  }

  void dispose() {
    _loadingLogSubscription?.cancel();
    _initialized = false;
  }

  // ------------------------------------------------------------------
  // Initialization
  // ------------------------------------------------------------------
  Future<void> initialize() async {
    debugPrint('[InferenceService] Initializing native engine...');
    try {
      final result = await _channel.invokeMethod('init');
      debugPrint('[InferenceService] Native engine initialized: $result');
    } catch (e) {
      debugPrint('[InferenceService] Failed to initialize: $e');
      rethrow;
    }
  }

  // ------------------------------------------------------------------
  // Model management
  // ------------------------------------------------------------------
  /// Android JNI 通道（桌面版死路径：Windows 走 LocalServerInference）。
  /// 签名与 [InferenceBackend] 对齐（v0.0.3 Phase 3 瘦身）；JNI 协议字典里
  /// 的手机端键（enableGpu/gpuBackend/enableMtp/nUbatch/vkNoSubgroup/moe*）
  /// 用历史默认值填平 —— 原生侧代码不动，桌面侧永远不会调到差异化值。
  /// [chunk]/[customArgs]/[engineId] 无 JNI 对应物，忽略（Android 已退役）。
  @override
  Future<bool> loadModel(
    String path, {
    int? nCtx,
    int? chunk,
    int? gpuLayers,
    String? mmprojPath,
    String? draftPath,
    List<String>? customArgs,
    String? engineId,
  }) async {
    debugPrint('[InferenceService] Loading model from: $path '
        '(nCtx=$nCtx, gpuLayers=$gpuLayers'
        ', mmproj=$mmprojPath, draft=$draftPath)');
    try {
      final result = await _channel.invokeMethod('loadModel', {
        'path': path,
        'nCtx': nCtx ?? 4096,
        'enableGpu': true,
        'gpuLayers': gpuLayers ?? 20,
        'gpuBackend': 'auto',
        'enableMtp': false,
        'mmprojPath': mmprojPath,
        'draftPath': draftPath,
        'nUbatch': 0,
        'vkNoSubgroup': false,
        'moeManifest': null,
        'moeBank': 0,
        'moeSlotBytes': 0,
        'moeExpertsBytes': 0,
        'moeResidentBytes': 0,
      });
      debugPrint('[InferenceService] Model load result: $result');
      return result == true;
    } catch (e) {
      debugPrint('[InferenceService] Failed to load model: $e');
      rethrow;
    }
  }

  Future<void> unloadModel() async {
    debugPrint('[InferenceService] Unloading model...');
    await _channel.invokeMethod('unloadModel');
  }

  // 手机端 JNI 推送三件套 setOomGuard/setKvCacheType/setFlashAttn 已随
  // Phase 4 删除（Android 原生层死通道；桌面侧由 admission + 引擎参数链承担）。

  Future<bool> isLoaded() async {
    final result = await _channel.invokeMethod('isLoaded');
    return result == true;
  }

  Future<Map<String, dynamic>> getModelInfo() async {
    return await _channel.invokeMethod('getModelInfo');
  }

  // ------------------------------------------------------------------
  // Memory
  // ------------------------------------------------------------------
  /// System + process memory snapshot:
  /// {sysTotalMB, sysAvailMB, sysUsedMB, procRssMB, modelMB}.
  ///
  /// NOTE: the platform channel always hands back `Map<Object?, Object?>`.
  /// Returning it directly as `Map<String, int>` throws a TypeError at runtime
  /// (which silently broke the memory panel), so convert explicitly.
  Future<Map<String, int>> getMemoryInfo() async {
    final r = await _channel.invokeMethod('getMemoryInfo');
    if (r is! Map) return {};
    final out = <String, int>{};
    r.forEach((k, v) {
      if (k == null) return;
      if (v is num) out[k.toString()] = v.toInt();
    });
    return out;
  }

  /// Returns the last generation's real stats from native: {n_gen, t_gen_ms,
  /// t_prompt_ms}. n_gen is the true llama.cpp token count and t_gen_ms is the
  /// pure generation time, so UI tok/s matches the native logcat line exactly.
  Future<Map<String, dynamic>> getInferenceStats() async {
    final r = await _channel.invokeMethod('getInferenceStats');
    if (r == null) return {};
    if (r is Map) return Map<String, dynamic>.from(r);
    try {
      final decoded = jsonDecode(r as String);
      if (decoded is Map) return Map<String, dynamic>.from(decoded);
    } catch (_) {}
    return {};
  }



  // ------------------------------------------------------------------
  // Streaming completion (raw prompt, no chat template)
  // ------------------------------------------------------------------
  Stream<String> completion({
    required String prompt,
    int maxTokens = 2048,
    double temperature = 0.7,
    double topP = 0.9,
  }) {
    final controller = StreamController<String>();

    // Set up the token event listener. Cancel any previous subscription so a
    // new generation doesn't deliver tokens to a stale controller (leak/dup).
    _currentTokenSubscription?.cancel();
    final subscription = _tokenChannel.receiveBroadcastStream().listen((event) {
      if (event != null) {
        controller.add(event.toString());
      }
    }, onError: (err) {
      controller.addError(err);
    });
    _currentTokenSubscription = subscription;

    debugPrint('[InferenceService] Invoking native completion, prompt="$prompt"');
    // Start inference on native side
    _channel.invokeMethod('completion', {
      'prompt': prompt,
      'maxTokens': maxTokens,
      'temperature': temperature,
      'topP': topP,
    }).then((result) {
      final resStr = result?.toString() ?? '';
      debugPrint('[InferenceService] Native completion done, len=${resStr.length}, preview="${resStr.substring(0, resStr.length.clamp(0, 50))}"');
      // Final result (may be empty if streaming used all tokens)
      controller.close();
      _currentTokenSubscription?.cancel();
      _currentTokenSubscription = null;
    }).catchError((err) {
      debugPrint('[InferenceService] Native completion error: $err');
      controller.addError(err);
      controller.close();
      _currentTokenSubscription?.cancel();
      _currentTokenSubscription = null;
    });

    return controller.stream;
  }

  // ------------------------------------------------------------------
  // Streaming completion with chat history (applies chatml template)
  // @param messagesJson JSON array of {role, content} for conversation history.
  //   The [prompt] is appended as the final user message before generation.
  // ------------------------------------------------------------------
  Stream<String> completionWithMessages({
    required String prompt,
    required String messagesJson,
    String? imagePath,
    List<String>? imagePaths,
    String? audioPath,
    int maxTokens = 2048,
    double temperature = 0.7,
    double topP = 0.9,
  }) {
    final controller = StreamController<String>();

    _currentTokenSubscription?.cancel();
    final subscription = _tokenChannel.receiveBroadcastStream().listen((event) {
      if (event != null) {
        controller.add(event.toString());
      }
    }, onError: (err) {
      controller.addError(err);
    });
    _currentTokenSubscription = subscription;

    debugPrint('[InferenceService] Invoking completionWithMessages, prompt="$prompt", msgs=$messagesJson, image=$imagePath, images=${imagePaths?.length ?? 0}, audio=$audioPath');
    _channel.invokeMethod('completionWithMessages', {
      'prompt': prompt,
      'messagesJson': messagesJson,
      'imagePath': imagePath,
      // 多图（长图切块/多图上传）：原生视觉按序逐张编码（≤10）。
      if (imagePaths != null && imagePaths.isNotEmpty) 'imagePaths': imagePaths,
      'audioPath': audioPath,
      'maxTokens': maxTokens,
      'temperature': temperature,
      'topP': topP,
    }).then((result) {
      final resStr = result?.toString() ?? '';
      debugPrint('[InferenceService] completionWithMessages done, len=${resStr.length}, preview="${resStr.substring(0, resStr.length.clamp(0, 50))}"');
      controller.close();
      _currentTokenSubscription?.cancel();
      _currentTokenSubscription = null;
    }).catchError((err) {
      debugPrint('[InferenceService] completionWithMessages error: $err');
      controller.addError(err);
      controller.close();
      _currentTokenSubscription?.cancel();
      _currentTokenSubscription = null;
    });

    return controller.stream;
  }

  // ------------------------------------------------------------------
  // Non-streaming completion (for benchmarks, model selection, etc.)
  // ------------------------------------------------------------------
  Future<String> complete({
    required String prompt,
    int maxTokens = 2048,
    double temperature = 0.7,
    double topP = 0.9,
  }) async {
    return await _channel.invokeMethod('completion', {
      'prompt': prompt,
      'maxTokens': maxTokens,
      'temperature': temperature,
      'topP': topP,
    });
  }

  // ------------------------------------------------------------------
  // Stop / benchmark
  // ------------------------------------------------------------------
  Future<void> stopGeneration() async {
    // Cancel the token stream so no further tokens reach a closed controller.
    _currentTokenSubscription?.cancel();
    _currentTokenSubscription = null;
    await _channel.invokeMethod('stopGeneration');
  }

  /// 设置是否允许 Qwen3 思考模式。false = 直接作答（默认）。
  Future<void> setEnableThinking(bool enable) async {
    try {
      await _channel.invokeMethod('setEnableThinking', {'enable': enable});
    } catch (e) {
      debugPrint('[InferenceService] setEnableThinking failed: $e');
    }
  }

  /// 清空 KV 缓存，开始全新对话（多轮追加式缓存下，避免旧对话污染新对话）。
  Future<void> resetContext() async {
    try {
      await _channel.invokeMethod('resetContext');
    } catch (e) {
      debugPrint('[InferenceService] resetContext failed: $e');
    }
  }

  /// 当前模型是否已加载（查询原生引擎 isLoaded，权威状态）。
  /// 本地引擎 adapter 在生成前用它快速失败：模型未加载时直接抛非重试失败，
  /// 避免 native COMPLETION_ERROR 被归一化为可重试的 transport 导致 agent 空转。
  Future<bool> isModelLoaded() async {
    try {
      return await _channel.invokeMethod<bool>('isLoaded') == true;
    } catch (e) {
      debugPrint('[InferenceService] isModelLoaded failed: $e');
      return false;
    }
  }

  // 语音输入三件套（supportsAudio/startRecording/stopRecording）已随 D4 裁决删除：
  // 端侧拾音归 VoiceService（sherpa 引擎族），不再走推理通道。

  Future<Map<String, double>> benchmark({
    String prompt = 'List 5 common fruits.',
    int nRepeats = 3,
  }) {
    final result = _channel.invokeMethod('benchmark', {
      'prompt': prompt,
      'nRepeats': nRepeats,
    });
    return result.then((data) => Map<String, double>.from(data));
  }

  // ------------------------------------------------------------------
  // Dispose (called when app shuts down)
  // ------------------------------------------------------------------
}
