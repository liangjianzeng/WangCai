import 'dart:io';

import 'package:flutter/foundation.dart' show debugPrint;
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../models/model_info.dart';
import '../models/model_catalog.dart';
import '../models/local_model.dart';
import '../platform/inference_backend.dart';
import '../services/model_storage_service.dart';
import 'settings_provider.dart';
import 'shared_providers.dart' show inferenceServiceProvider;

/// Lifecycle phase of the currently loaded model.
enum ModelLifecyclePhase { idle, loading, loaded, unloading, error }

/// Full state of the model manager — richer than a simple enum so the UI can
/// display meaningful information at every stage.
class ModelState {
  final ModelLifecyclePhase phase;
  final String? modelId;
  final String? modelName;
  final String? errorMessage;

  /// Real-time loading progress messages from native (C++/Kotlin).
  /// Each entry is a human-readable log line describing the current step.
  final List<String> loadingLogs;

  const ModelState({
    this.phase = ModelLifecyclePhase.idle,
    this.modelId,
    this.modelName,
    this.errorMessage,
    this.loadingLogs = const [],
  });

  // ---- convenience factories ----
  static const idle = ModelState(phase: ModelLifecyclePhase.idle);

  factory ModelState.loading({String? modelId, String? modelName}) =>
      ModelState(
        phase: ModelLifecyclePhase.loading,
        modelId: modelId,
        modelName: modelName,
      );

  factory ModelState.loaded({String? modelId, String? modelName}) =>
      ModelState(
        phase: ModelLifecyclePhase.loaded,
        modelId: modelId,
        modelName: modelName,
      );

  static const unloading =
      ModelState(phase: ModelLifecyclePhase.unloading);

  factory ModelState.error({
    required String message,
    String? modelId,
    String? modelName,
  }) =>
      ModelState(
        phase: ModelLifecyclePhase.error,
        modelId: modelId,
        modelName: modelName,
        errorMessage: message,
      );

  // ---- derived helpers ----
  bool get isLoading => phase == ModelLifecyclePhase.loading;
  bool get isLoaded => phase == ModelLifecyclePhase.loaded;
  bool get isError => phase == ModelLifecyclePhase.error;

  /// The most recent loading log message (null if none).
  String? get latestLog => loadingLogs.isNotEmpty ? loadingLogs.last : null;

  /// Human-readable label for the chip in UI.
  String get phaseLabel {
    switch (phase) {
      case ModelLifecyclePhase.idle:
        return '未加载';
      case ModelLifecyclePhase.loading:
        return '加载中...';
      case ModelLifecyclePhase.loaded:
        return '已加载';
      case ModelLifecyclePhase.unloading:
        return '卸载中...';
      case ModelLifecyclePhase.error:
        return '错误';
    }
  }

  /// Color name for the chip in UI.
  String get phaseColor {
    switch (phase) {
      case ModelLifecyclePhase.idle:
        return 'grey';
      case ModelLifecyclePhase.loading:
        return 'blue';
      case ModelLifecyclePhase.loaded:
        return 'green';
      case ModelLifecyclePhase.unloading:
        return 'orange';
      case ModelLifecyclePhase.error:
        return 'red';
    }
  }

  @override
  String toString() =>
      'ModelState(phase: $phase, modelId: $modelId, modelName: $modelName, logs: ${loadingLogs.length})';
}

class ModelManagerNotifier extends StateNotifier<ModelState> {
  final InferenceBackend _inference;
  final Ref _ref;
  bool _isBusy = false;

  ModelManagerNotifier(this._inference, this._ref) : super(const ModelState()) {
    // Wire up loading log callback from native layer.
    _inference.onLoadingLog = (message) {
      if (state.isLoading && message != null) {
        final currentLogs = List<String>.from(state.loadingLogs);
        currentLogs.add(message);
        state = ModelState(
          phase: state.phase,
          modelId: state.modelId,
          modelName: state.modelName,
          errorMessage: state.errorMessage,
          loadingLogs: currentLogs,
        );
      }
    };
  }

  /// Whether a load/unload operation is in progress.
  bool get isBusy => _isBusy;

  // ---- Public getters exposing state fields (avoids direct `state.` access from UI). ----
  String? get modelId => state.modelId;
  String? get modelName => state.modelName;
  bool get isLoading => state.isLoading;
  bool get isLoadedState => state.isLoaded;
  bool get isErrorState => state.isError;
  
  /// Loading logs from native layer (for display in log screen)
  List<String> get loadingLogs => state.loadingLogs;

  /// Access the current lifecycle phase (exposed for UI code that needs it).
  ModelLifecyclePhase get phase => state.phase;

  /// Append a line to the inference log panel. Unlike native loading logs,
  /// this is emitted from Dart-side during model interactions and is allowed
  /// in any phase (especially [loaded]).
  void appendInferenceLog(String message) {
    final currentLogs = List<String>.from(state.loadingLogs);
    currentLogs.add(message);
    state = ModelState(
      phase: state.phase,
      modelId: state.modelId,
      modelName: state.modelName,
      errorMessage: state.errorMessage,
      loadingLogs: currentLogs,
    );
  }

  /// 清空推理日志列表（仅清展示层；原生后续日志仍会继续追加）。
  /// 注意：不要用 ref.invalidate(modelManagerProvider) 来"刷新"——那会重建
  /// notifier 并把状态复位为 idle，让已加载模型在 UI 上显示成"未加载"。
  void clearLogs() {
    state = ModelState(
      phase: state.phase,
      modelId: state.modelId,
      modelName: state.modelName,
      errorMessage: state.errorMessage,
      loadingLogs: const [],
    );
  }

  /// ID of the currently loaded model, or null if idle/error. (alias for convenience)
  String? get currentModelId => modelId;

  Future<ModelConfig?> currentModel() async {
    final mid = modelId;
    if (mid == null) return null;
    try {
      final models = await loadModelCatalog();
      return models.firstWhere((m) => m.id == mid);
    } on Exception catch (_) {
      return null;
    }
  }

  String get currentModelName {
    if (modelName != null && modelName!.isNotEmpty) return modelName!;
    if (modelId == null) return '未加载';
    try {
      final syncCache = loadModelCatalogSync();
      return syncCache.firstWhere((m) => m.id == modelId!).name;
    } on Exception catch (_) {
      return '$modelId';
    }
  }

  static List<ModelConfig>? _syncCache;
  static Future<void> ensureSyncCache() async {
    if (_syncCache == null) _syncCache = await loadModelCatalog();
  }

  static List<ModelConfig> loadModelCatalogSync() => _syncCache ?? [];

  /// Load a model into memory. If another model is currently loaded it will
  /// be unloaded first automatically (single-model constraint).
  Future<bool> loadModel(String modelId) async {
    if (_isBusy) return false;

    // Check if the same model is already loaded → no-op success.
    final cur = state.modelId;
    if (cur == modelId && state.isLoaded) return true;

    _isBusy = true;
    try {
      // 1. If a different model is currently loaded, unload it first.
      if (_currentModelId != null && _currentModelId != modelId) {
        debugPrint('[ModelManager] Unloading previous model before switching to $modelId');
        await unloadModel();
      }

      // 2. Ensure the catalog sync cache is populated (it's loaded lazily and
      //    was previously never triggered, so modelName was always null → the
      //    status sheet showed "未知模型"). Then look up the display name.
      await ModelManagerNotifier.ensureSyncCache();
      String? displayName = _lookupModelName(modelId);

      // 3. Set state to loading with empty logs — native will push updates.
      state = ModelState(
        phase: ModelLifecyclePhase.loading,
        modelId: modelId,
        modelName: displayName,
        loadingLogs: const [],
      );

      final path = await getModelPath(modelId);
      if (path == null) {
        debugPrint('[ModelManager] File not found: $modelId.gguf');
        state = ModelState.error(
          message: '模型文件不存在，请重新下载',
          modelId: modelId,
          modelName: displayName,
        );
        return false;
      }

      // 4. 视觉模型：解析 mmproj（text+mmproj 两文件形态需投影器文件）。
      //    按模型「图片理解」开关优先（方案 P4，2026-10-15）；未显式配置的
      //    模型回退全局「默认加载视觉投影器」（autoLoadMmproj）。关闭时
      //    mmproj 传 null：不加载视觉塔，省 ~0.9GB 回给 bank/KV。
      final config = _lookupModelConfig(modelId);
      String? mmprojPath;
      final settingsAll = await _ref.read(settingsServiceProvider).load();
      final autoMmproj = settingsAll.visionEnabled(modelId);
      if (config != null &&
          config.type == ModelType.vision &&
          autoMmproj) {
        if (config.mmproj != null) {
          final storage = ModelStorageService();
          mmprojPath = await storage.getMmprojPath(modelId);
          // 只查 existsSync() 不够：mmproj 若损坏/不完整（例如下载中断残留的
          // .mmproj.tmp，或体积为 0）仍会 exists → 传给原生 mtmd_init 加载损坏
          // 文件，视觉推理时崩溃。这里做完整性复核：文件存在、无残留 .tmp、非空。
          final mmFile = File(mmprojPath);
          final mmTmp = File('$mmprojPath.tmp');
          final mmOk = mmFile.existsSync() &&
              !(await mmTmp.exists()) &&
              await mmFile.length() > 0;
          if (!mmOk) {
            debugPrint('[ModelManager] Missing/broken mmproj for $modelId');
            state = ModelState.error(
              message: '缺少或不完整的 mmproj 投影器，请在模型管理页重新下载完整模型',
              modelId: modelId,
              modelName: displayName,
            );
            return false;
          }
        }
        debugPrint('[ModelManager] Vision model $modelId: '
            '${mmprojPath == null ? '单文件VL' : 'text+mmproj ($mmprojPath)'} — '
            '原生图像理解已启用。');
        state = ModelState(
          phase: ModelLifecyclePhase.loading,
          modelId: modelId,
          modelName: displayName,
          loadingLogs: ['🧠 视觉模型：原生图像理解已启用（mmproj）'],
        );
      }

      // 5. Call inference engine to load the model.
      //    直接从持久化文件读取设置，避免 settingsProvider 异步 _load 完成前
      //    读到默认值，导致启动后直接加载模型时配置未生效。
      //    （v0.0.3 Phase 3：手机端参数链路——MTP/dspark 全局开关、split-MoE
      //    路由、oom 守卫/KV 精度/FA 推送——已整体退场；这些是 Android JNI
      //    线的遗产，桌面 llama-server 由 manifest/引擎配置接管。）
      final gpu = settingsAll; // 同文件 load() 幂等，复用步骤 4 已读实例
      debugPrint('[ModelManager] Calling loadModel(path=$path, '
          'contextSize=${gpu.contextSize}, gpuLayers=${gpu.gpuLayers})');
      final logs = List<String>.from(state.loadingLogs);
      // 把模型实际加载的绝对路径作为第一条日志输出，方便在「推理日志」页直接看到
      // 模型从哪个目录加载，定位缓存位置。
      logs.insert(0, '模型加载地址: $path');
      if (mmprojPath != null) {
        logs.insert(1, '投影器地址: $mmprojPath');
      }
      state = ModelState(
        phase: ModelLifecyclePhase.loading,
        modelId: modelId,
        modelName: displayName,
        loadingLogs: logs,
      );
      final ok = await _inference.loadModel(
        path,
        nCtx: gpu.contextSize,
        gpuLayers: gpu.gpuLayers,
        // null = 单文件自包含 VL 或文本模型（视觉塔在 llama-server 侧成对入场）
        mmprojPath: mmprojPath,
      );

      if (ok) {
        // Preserve loading logs so the log screen can still show them after load completes.
        state = ModelState(
          phase: ModelLifecyclePhase.loaded,
          modelId: modelId,
          modelName: displayName,
          loadingLogs: List<String>.from(state.loadingLogs),
        );
        // 把思考模式开关同步到原生层（原生侧引擎重启后会复位为默认 false）。
        await _inference.setEnableThinking(gpu.enableThinking);
        debugPrint('[ModelManager] Loaded: $modelId ($displayName), '
            'enableThinking=${gpu.enableThinking}');
        return true;
      } else {
        String errorMsg = '模型加载失败（原生层返回 false）';
        // Provide a more helpful error for common failure modes.
        if (state.latestLog != null && state.latestLog!.contains('内存')) {
          errorMsg = '内存不足，无法加载此模型。请关闭其他应用后重试，或选择更小的模型（如 Qwen3-0.6B）。';
        } else if (config != null && config.type == ModelType.vision) {
          // 只有加载日志真的提到 mmproj 才归因投影器，否则别误导排查方向。
          final lastLog = state.latestLog ?? '';
          errorMsg = lastLog.contains('mmproj')
              ? '视觉模型加载失败：mmproj 投影器加载出错，请查看加载日志。'
              : '视觉模型加载失败，最后一步日志：$lastLog';
        }
        state = ModelState.error(
          message: errorMsg,
          modelId: modelId,
          modelName: displayName,
        );
        debugPrint('[ModelManager] Load returned false for $modelId');
        return false;
      }
    } on Exception catch (e, st) {
      String? displayName = _lookupModelName(modelId);

      state = ModelState.error(
        message: '加载异常: $e',
        modelId: modelId,
        modelName: displayName,
      );
      debugPrint('[ModelManager] Load failed: $e\n$st');
      return false;
    } finally {
      _isBusy = false;
      // _isBusy 不在 ModelState 里：复位为 false 不会自动通知 UI 重建，
      // 导致「卸载 / 加载到内存」等按钮停留在禁用态（模型加载完成后
      // 按钮"显示但不可点击"）。复制当前状态触发一次重建，恢复可用。
      state = ModelState(
        phase: state.phase,
        modelId: state.modelId,
        modelName: state.modelName,
        errorMessage: state.errorMessage,
        loadingLogs: List<String>.from(state.loadingLogs),
      );
    }
  }

  /// 桌面本地模型加载通道（v0.0.3 Phase 2）：直接吃 [LocalModelConfig]
  /// （用户登记的 .gguf 绝对路径），不经过下载目录 catalog 解析。
  ///
  /// 与 [loadModel]（catalog id 版）的差异：
  /// · 手机端专属链路全部不进（MoE 路由 / MTP 全局开关 / oom 守卫推送 /
  ///   KV 精度——桌面 NPU/llama-server 线用不上）；
  /// · Phase 3 已接线：`cfg.engineId` → 路由钉选（不可用回落 Auto），
  ///   `cfg.customArgs` → 自定义尾参（优先级链模型级档位），ctx/chunk/
  ///   gpuLayers 覆盖项透传给后端走 **模型级 > 引擎 defaultConfig >
  ///   manifest preset** 回落；preset 命中时仍按实测上限收敛 ctx（纪律不动）。
  ///   模型未表态的项不再兜底手机端全局（contextSize/gpuLayers），让位
  ///   引擎默认与出厂 preset。
  Future<bool> loadModelByLocalConfig(LocalModelConfig cfg) async {
    if (_isBusy) return false;
    final cur = state.modelId;
    if (cur == cfg.id && state.isLoaded) return true;

    _isBusy = true;
    try {
      if (_currentModelId != null && _currentModelId != cfg.id) {
        await unloadModel();
      }
      final file = File(cfg.modelPath);
      if (!await file.exists() || await file.length() == 0) {
        state = ModelState.error(
          message: '模型文件不存在或为空：${cfg.modelPath}',
          modelId: cfg.id,
          modelName: cfg.displayName,
        );
        return false;
      }
      final settingsAll = await _ref.read(settingsServiceProvider).load();
      final logs = <String>['模型加载地址: ${cfg.modelPath}'];
      if (cfg.hasMmproj) logs.add('投影器地址: ${cfg.mmprojPath}');
      if (cfg.hasDraft) logs.add('投机草稿地址: ${cfg.draftPath}');
      if (cfg.hasEngine) {
        logs.add('指定引擎: ${cfg.engineId}（钉选；不可用时自动回落 Auto）');
      }
      if (cfg.customArgsList.isNotEmpty) {
        logs.add('自定义尾参: ${cfg.customArgsList.join(' ')}');
      }
      state = ModelState(
        phase: ModelLifecyclePhase.loading,
        modelId: cfg.id,
        modelName: cfg.displayName,
        loadingLogs: logs,
      );
      final ok = await _inference.loadModel(
        cfg.modelPath,
        // ctx 单口子（2026-11-06 拍板）：模型级未表态 → 全局滑杆档
        // （InferenceSettings.contextSize，默认 4096）；引擎 defaultConfig
        // 仍能压过它（优先级链在 local_server_inference），preset 已不带 ctx。
        // chunk/gpuLayers 未表态仍传 null 走引擎/出厂回落。
        nCtx: cfg.ctx ?? settingsAll.contextSize,
        chunk: cfg.chunk,
        gpuLayers: cfg.gpuLayers,
        mmprojPath: cfg.hasMmproj ? cfg.mmprojPath : null,
        draftPath: cfg.hasDraft ? cfg.draftPath : null,
        customArgs: cfg.customArgsList.isNotEmpty ? cfg.customArgsList : null,
        engineId: cfg.hasEngine ? cfg.engineId : null,
      );
      if (ok) {
        state = ModelState(
          phase: ModelLifecyclePhase.loaded,
          modelId: cfg.id,
          modelName: cfg.displayName,
          loadingLogs: List<String>.from(state.loadingLogs),
        );
        await _inference.setEnableThinking(settingsAll.enableThinking);
        return true;
      }
      state = ModelState.error(
        message: '模型加载失败，最后一步日志：${state.latestLog ?? '（无）'}',
        modelId: cfg.id,
        modelName: cfg.displayName,
      );
      return false;
    } on Exception catch (e, st) {
      state = ModelState.error(
        message: '加载异常: $e',
        modelId: cfg.id,
        modelName: cfg.displayName,
      );
      debugPrint('[ModelManager] LocalConfig load failed: $e\n$st');
      return false;
    } finally {
      _isBusy = false;
      state = ModelState(
        phase: state.phase,
        modelId: state.modelId,
        modelName: state.modelName,
        errorMessage: state.errorMessage,
        loadingLogs: List<String>.from(state.loadingLogs),
      );
    }
  }

  /// Unload the currently loaded model from memory.
  Future<bool> unloadModel() async {
    final curId = state.modelId;
    if (_isBusy || curId == null) return true;
    final id = curId;
    String? name = state.modelName;
    _isBusy = true;
    try {
      state = ModelState(phase: ModelLifecyclePhase.unloading);

      debugPrint('[ModelManager] Calling unloadModel() for $id');
      await _inference.unloadModel();

      debugPrint('[ModelManager] Unloaded: $id ($name)');
      state = const ModelState(); // reset to idle (default phase=idle)
      return true;
    } on Exception catch (e, st) {
      debugPrint('[ModelManager] Unload failed: $e\n$st');
      // Stay in idle — we don't want to get stuck.
      state = const ModelState();
      return false;
    } finally {
      _isBusy = false;
      // 同 loadModel：_isBusy 复位不在 ModelState 里，复制当前状态触发
      // 重建，让「加载到内存」等按钮从禁用态恢复。
      state = ModelState(
        phase: state.phase,
        modelId: state.modelId,
        modelName: state.modelName,
        errorMessage: state.errorMessage,
        loadingLogs: List<String>.from(state.loadingLogs),
      );
    }
  }

  /// Keep a reference for the old unloadModel() path compatibility.
  String? get _currentModelId => state.modelId;

  Future<bool> isModelCached(String modelId) async => await getModelPath(modelId) != null;

  Future<String?> getModelPath(String modelId) async {
    final storage = ModelStorageService();
    return await storage.getModelPath(modelId);
  }

  Future<int> getCachedSize(String modelId) async {
    final storage = ModelStorageService();
    return await storage.getCachedSize(modelId);
  }

  Future<int> getTotalCachedSize() async {
    final storage = ModelStorageService();
    return await storage.getTotalCachedSize();
  }

  /// Look up a model's display name from the cached catalog (best-effort).
  /// 返回清理后的名称：去掉括号内的精度/量化说明，界面显示更短。
  static String? _lookupModelName(String modelId) {
    final syncCache = loadModelCatalogSync();
    for (final m in syncCache) {
      if (m.id == modelId) return cleanModelName(m.name);
    }
    return null;
  }

  /// Look up full ModelConfig from the cached catalog.
  static ModelConfig? _lookupModelConfig(String modelId) {
    final syncCache = loadModelCatalogSync();
    for (final m in syncCache) {
      if (m.id == modelId) return m;
    }
    return null;
  }
}

/// Provider — declared after the notifier class so the reference resolves.
final modelManagerProvider = StateNotifierProvider<ModelManagerNotifier, ModelState>((ref) {
  final inference = ref.read(inferenceServiceProvider);
  return ModelManagerNotifier(inference, ref);
});
