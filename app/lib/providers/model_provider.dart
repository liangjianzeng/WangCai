import 'dart:convert';
import 'dart:io';

import 'package:flutter/foundation.dart' show debugPrint;
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../models/model_info.dart';
import '../models/model_catalog.dart';
import '../services/inference_service.dart';
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
  final InferenceService _inference;
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

      // 5. Call native inference engine to load the model.
      //    直接从持久化文件读取设置，避免 settingsProvider 异步 _load 完成前
      //    读到默认 enableGpu=false，导致启动后直接加载模型时 GPU 未生效。
      final gpu = settingsAll; // 同文件 load() 幂等，复用步骤 4 已读实例
      // 全局 MTP 总开关关闭时，即使某模型曾配置开启也强制不启用（可见可用控制）。
      final mtp = gpu.enableMtpFeature && gpu.mtpEnabled(modelId);
      // dspark 投机草稿头：全局开关 + 该模型开关都开启、目录声明且文件完整时
      // 才带上（MTP 启用时忽略，原生层二选一互斥）。任一环节不满足时给出
      // 明确原因写进推理日志，避免静默失败（此前用户开了开关却看不到生效）。
      String? draftPath;
      String? draftSkipReason;
      final dsparkConfig = config?.dspark;
      if (dsparkConfig == null) {
        draftSkipReason = '该模型目录未声明 dspark 草稿头';
      } else if (mtp) {
        draftSkipReason = 'MTP 已启用（与 dspark 互斥，原生层二选一）';
      } else if (!gpu.enableDsparkFeature) {
        draftSkipReason = '全局 dspark 开关未开启（设置→推理引擎→⚡dspark 加速）';
      } else if (!gpu.dsparkEnabled(modelId)) {
        draftSkipReason = '该模型 dspark 开关未开启（模型列表卡片）';
      } else {
        final storage = ModelStorageService();
        final dsparkFile = await storage.getDsparkPath(modelId);
        if (!File(dsparkFile).existsSync()) {
          draftSkipReason = '草稿文件不存在（${dsparkFile}）';
        } else {
          final dsSize = await File(dsparkFile).length();
          if (dsSize <= 0 ||
              dsSize < (dsparkConfig.sizeBytes * 0.99).round()) {
            final dsMb = (dsSize / (1024 * 1024)).toStringAsFixed(0);
            draftSkipReason =
                '草稿文件不完整（${dsMb}MB < 声明 ${dsparkConfig.sizeMB}MB）';
          } else {
            draftPath = dsparkFile;
          }
        }
      }
      debugPrint('[ModelManager] Calling loadModel(path=$path, '
          'enableGpu=${gpu.enableGpu}, gpuLayers=${gpu.gpuLayers}, '
          'gpuBackend=${gpu.gpuBackend}, contextSize=${gpu.contextSize}, '
          'enableMtp($modelId)=$mtp, draft=$draftPath, skip=$draftSkipReason)');
      // ---- 智能 MoE 加载路由（超大 MoE 统一架构，2026-10-14）----------
      // 拆分 MoE 模型（splitMoe 目录声明）：开关开启时走专家 slot 动态加载
      // （dense 常驻 + 专家按需 preadv 流式读入）；关闭时走整包全加载——
      // 但 -les 剥离版主文件不含专家张量，预期失败，加载日志明示原因。
      String? moeManifest;
      int moeBank = 0;
      int moeSlotBytes = 0; // 每层每专家字节（packed=geo.perLayer；in-place=全层和旧口径）
// [守卫常驻口径 2026-10-30 · 决策档 §12.18] 守卫只算 bank×perLayer 会漏掉 decode 窗口
// （预取配方 8+6/层 × n_moe_layers ⇒ 14×层数 个槽），11 GB 档机型上因此放过载、真机放机过。
// 常驻由知道 manifest 几何的 Dart 侧算准后显式传给 JNI（JNI 预检时拿不到层数），
// 口径 = (bank + 14×层数) × perLayer，与 K90 实测峰值 RSS 2812 MB 对表（估 2.85 GB，差 1.5 %）。
      int moeResidentBytes = 0; // split-MoE 常驻（bank 槽 + decode 窗口），0=交回 JNI 旧公式
      int moeExpertsBytes = 0; // in-place 整包：gguf 内专家区字节（oom 预检扣减）
      String smartMoeLog = '';
      final sm = config?.splitMoe;
      if (sm != null) {
        if (gpu.smartMoeEnabled) {
          // 形态判定：inplaceFullGguf（方案 C）= 官方整包原地读，无分片子目录；
          // 否则为 packed-bins（MiniCPM 生产形态）= manifest + N 分片。
          final storage = ModelStorageService();
          final expertsDir = await storage.getExpertsDir(modelId);
          final mf = File('${expertsDir.path}/manifest.json');
          var binsOk = sm.inplaceFullGguf; // 原地形态：整包文件本身即专家表
          if (!sm.inplaceFullGguf) {
            // 加载前快检：manifest + 全部分片存在且非空（下载器已做精确字节
            // 校验，这里只防「文件被用户清理/传输中断」的残缺包进原生层）。
            binsOk = await mf.exists() && await mf.length() > 0;
            if (binsOk) {
              for (var i = 0; i < sm.layerBinCount && binsOk; i++) {
                final name = sm.layerBinRelativePath(i).split('/').last;
                final bf = File('${expertsDir.path}/$name');
                binsOk = await bf.exists() && await bf.length() > 0;
              }
            }
          }
          if (binsOk) {
            moeManifest = sm.inplaceFullGguf ? path : mf.path;
            // ---- 内存自适应热专家 bank（2026-10-15，方案 P3；15:5x 小米13 修正）----
            // bank 是 GPU pinned（UMA 直接扣 MemAvailable，不可回收），且主权重/
            // draft 加载同样吃掉可用内存——小米13 实测 bank=39 加载后 MemAvail
            // 掉到 580MB 被 lmkd 杀（OomAdj=200）。公式按"加载后仍留 1.5G 安全
            // 线"倒推：
            // bank = clamp(8, floor(0.8 × budget / slot_bytes), 32)
            //   budget = MemAvailable − 安全线(1.5G) − 主权重(常驻×0.95)
            //            − KV(contextSize×0.03MB/tok) − dspark 在机 − mmproj 在机
            // slot_bytes：packed 从 manifest 求和；in-place 用目录元数据。
            // 常驻主权重：packed = -les 主文件；in-place = 整包 − 专家区。
            final memAvailMb = _readMemAvailableMb();
            final geo = sm.inplaceFullGguf ? null : await _moeManifestBankGeo(mf);
            // [守卫口径修正 2026-10-30 · 决策档 §12.9/§12.17] JNI 的 oom-guard 公式是
            // `bank × moe_slot_bytes`，其缺省常量 1351680（1.289 MiB）= **每层每专家**字节
            // ⇒ 它要的是 perLayer。这里曾传 total（全层和；35B-A3B = 40×1.29MB ≈ 51.6MB），
            // 于是 bank=256 时权重估算被抬到 14.69 GB（真值 ≈ dense 1.55GB + 256×1.29MB
            // + 0.25GB ≈ 2.12GB），740（MemAvailable 6.0GB）**被自己的守卫拒绝加载 35B**。
            // 与下方 :427「用 perLayer 判定形态，不能用 total」是同一颗雷，只是没修到守卫这路。
            // bank 选取本来就用 geo.perLayer（见下），故此改动不影响 bank，只修守卫读数。
            // in-place 整包形态维持旧口径（原地读专家区，见 :417 else 分支注释）。
            final slotBytes = sm.inplaceFullGguf
                ? (sm.slotBytesAllLayers > 0 ? sm.slotBytesAllLayers : null)
                : (geo != null && geo.perLayer > 0 ? geo.perLayer : geo?.total);
            moeSlotBytes = slotBytes ?? 0;
            moeExpertsBytes = sm.inplaceFullGguf ? sm.expertsBytes : 0;
            var autoBank = 16; // 兜底：读不到内存/manifest 时维持旧稳态值
            var bankLog = '自动(兜底16)';
            if (memAvailMb != null && slotBytes != null && slotBytes > 0) {
              final slotMb = slotBytes / (1024 * 1024);
              final kvMb = (gpu.contextSize * 30 / 1000).round();
              final residentBytes =
                  ((config?.sizeBytes ?? 0) - moeExpertsBytes).clamp(0, 1 << 62);
              final mainWeightMb = (residentBytes * 0.95) / (1024 * 1024);
              double budgetMb = (memAvailMb - 1536 - kvMb).toDouble() - mainWeightMb;
              if (draftPath != null) {
                budgetMb -= (await File(draftPath).length()) / (1024 * 1024);
              }
              if (mmprojPath != null) {
                budgetMb -= (await File(mmprojPath).length()) / (1024 * 1024);
              }
              // 物理内存模型（2026-10-16 查案修正）：slot base 按（family×bpe）
              // 分组、prefill 段组内共享（virtualize 实测 656 slots=282MiB，
              // 旧「54MB×bank」是按每层独立复制的错误口径）。bank 的边际成本
              // = 每层每专家字节（packed ~1.29MB）；decode 窗口（JNI 预取配方
              // 8+6/层 × n_moe_layers）是与 bank 无关的固定成本，一并预留。
              // bank=256(=n_expert) 时 JNI 不再 clamp prefill ubatch →
              // 单遍专家流（每层 unique ≤ 256 恒成立，prefill 冷读 ≈ 地板）。
              if (geo != null && geo.perLayer > 0) {
                final bpeLayerMb = geo.perLayer / (1024 * 1024);
                budgetMb -= 14.0 * geo.layers * bpeLayerMb; // decode 窗口固定成本
                autoBank = (0.8 * budgetMb / bpeLayerMb).floor().clamp(8, 256);
                bankLog =
                    '自动(MemAvailable ${memAvailMb}MB, 预算 ${budgetMb.round()}MB, '
                    'slot/层 ${bpeLayerMb.toStringAsFixed(2)}MB × ${geo.layers}层, 上限256)';
              } else {
                // in-place 形态（slotBytesAllLayers 口径）保守沿用旧公式。
                final bankCap = slotMb <= 4 ? 256 : 32;
                autoBank = (0.8 * budgetMb / slotMb).floor().clamp(8, bankCap);
                bankLog =
                    '自动(MemAvailable ${memAvailMb}MB, 预算 ${budgetMb.round()}MB, slot ${slotMb.toStringAsFixed(1)}MB, 上限$bankCap)';
              }
            }
            // 手动覆写仅对 packed-bins（MiniCPM，slot/层~1.29MB）有意义；
            // in-place 整包口径庞大，沿用内存自适应 autoBank。小槽手动上限
            // 256（=n_expert，再大纯属浪费：每层 unique ≤ 256 恒成立）。
            // 注意口径：用 perLayer（1.29MB）判定形态，不能用 total（54MB，
            // 是全层和，会把 packed 误判成大槽锁死 64——2026-10-16 实测踩坑）。
            final perLayerMb = geo?.perLayer != null && geo!.perLayer > 0
                ? geo.perLayer / (1024 * 1024)
                : (slotBytes ?? 0) / (1024 * 1024);
            final manualCap = perLayerMb > 0 && perLayerMb <= 4 ? 256 : 64;
            final manual = sm.inplaceFullGguf ? null : gpu.moeBankOverride(modelId);
            moeBank = (manual != null && manual >= 8 && manual <= manualCap)
                ? manual
                : autoBank;
            if (geo != null && geo.perLayer > 0) {
              moeResidentBytes = (moeBank + 14 * geo.layers) * geo.perLayer;
            }
            smartMoeLog = sm.inplaceFullGguf
                ? '智能 MoE 加载: 开启 ✓（官方整包原地读专家 '
                    '${SplitMoeConfig.formatBytes(sm.expertsBytes)}，bank=$moeBank ${manual != null ? '手动覆写' : bankLog}）'
                : '智能 MoE 加载: 开启 ✓（专家分片 ${sm.layerBinCount} 片完整，bank=$moeBank ${manual != null ? '手动覆写' : bankLog}）';
          } else {
            debugPrint('[ModelManager] splitMoe bins incomplete for $modelId');
            state = ModelState.error(
              message: '专家分片不完整，请在模型管理页重新下载该模型（智能 MoE 加载需要 manifest + 全部专家分片）',
              modelId: modelId,
              modelName: displayName,
            );
            return false;
          }
        } else {
          smartMoeLog =
              '智能 MoE 加载: 关闭 — 将尝试整包全加载（-les 剥离版主文件不含专家张量，'
              '预期失败；如失败请在设置→推理引擎开启「智能 MoE 加载」后重试）';
        }
        debugPrint('[ModelManager] splitMoe: manifest=$moeManifest bank=$moeBank');
      }
      // 把 MTP/dspark 实际启用状态写进推理日志（loadingLogs），让「推理引擎
      // 日志」页与启动日志都能确认该模型加载时投机加速是否真的生效——此前只
      // debugPrint 到 logcat，App 内查看不到。
      final mtpLogs = List<String>.from(state.loadingLogs);
      // 把模型实际加载的绝对路径作为第一条日志输出，方便在「推理日志」页直接看到
      // 模型从哪个目录加载（外部存储 vs 内部 vs app-docs），定位缓存位置。
      mtpLogs.insert(0, '模型加载地址: $path');
      if (mmprojPath != null) {
        mtpLogs.insert(1, '投影器地址: $mmprojPath');
      }
      if (draftPath != null) {
        mtpLogs.insert(1, '投机草稿地址: $draftPath');
      }
      if (mtp) {
        mtpLogs.add('MTP 加速: 开启 ✓');
      } else if (draftPath != null) {
        mtpLogs.add('dspark 投机加速: 开启 ✓');
      } else {
        mtpLogs.add('投机加速: 关闭 — $draftSkipReason');
      }
      // OOM 内存守卫设置（设置→推理引擎→内存守卫）：每次加载前推送到原生层，
      // 原生侧在预检/加载后判定时读取。关闭守卫时日志里明示风险。
      await _inference.setOomGuard(
        enabled: gpu.oomGuardEnabled,
        preHeadroomMb: gpu.oomPreHeadroomMb,
        postHeadroomMb: gpu.oomPostHeadroomMb,
      );
      mtpLogs.add(gpu.oomGuardEnabled
          ? '内存守卫: 开启（预检余量 ${gpu.oomPreHeadroomMb}MB，加载后余量 ${gpu.oomPostHeadroomMb}MB）'
          : '内存守卫: 关闭 ⚠️（超大模型可强行加载，内存不足时可能整机死机）');
      // KV 缓存精度（设置→推理引擎→KV 精度）：每次加载前推送到原生层。
      // 默认 Q4；f16 = 不量化（混合架构 GPU 卸载需 K 为 F16，否则注意力链
      // 被踢回 CPU）；FA 关闭时 V 恒 F16，FA 开启时 V 跟随 K 的量化格式。
      await _inference.setKvCacheType(gpu.kvCacheType);
      mtpLogs.add('KV 精度: ${gpu.kvCacheType == 'q8_0' ? 'Q8' : (gpu.kvCacheType == 'f16' ? 'F16（K 不量化）' : 'Q4')}'
          '（K ${gpu.kvCacheType == 'f16' ? 'F16' : '量化'} / V 为 ${gpu.flashAttn ? '同 K（FA 开）' : 'F16'}）');
      // flash attention（设置→推理引擎）：默认关。hybrid 架构原生层会强制关闭。
      await _inference.setFlashAttn(gpu.flashAttn);
      if (smartMoeLog.isNotEmpty) {
        mtpLogs.add(smartMoeLog);
      }
      state = ModelState(
        phase: ModelLifecyclePhase.loading,
        modelId: modelId,
        modelName: displayName,
        loadingLogs: mtpLogs,
      );
      final ok = await _inference.loadModel(
        path,
        enableGpu: gpu.enableGpu,
        gpuLayers: gpu.gpuLayers,
        gpuBackend: gpu.gpuBackend,
        nCtx: gpu.contextSize,
        enableMtp: mtp,
        mmprojPath: mmprojPath, // null = 单文件自包含 VL；两文件形态由原生 mtmd_init 加载
        draftPath: draftPath,
        nUbatch: gpu.gpuNUbatch, // 0=自动（统一512）；>0 拆小 prefill burst
        vkNoSubgroup: gpu.vkNoSubgroup,
        moeManifest: moeManifest,
        moeBank: moeBank,
        moeSlotBytes: moeSlotBytes,
        moeExpertsBytes: moeExpertsBytes,
        moeResidentBytes: moeResidentBytes,
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

/// 读 /proc/meminfo 的 MemAvailable（MB）。非 Android 环境或读取失败返回 null
/// （单测/桌面），由调用方兜底。Android 上该文件 world-readable，无需权限。
int? _readMemAvailableMb() {
  if (!Platform.isAndroid) return null;
  try {
    final txt = File('/proc/meminfo').readAsStringSync();
    final m = RegExp(r'MemAvailable:\s+(\d+)\s+kB').firstMatch(txt);
    return m == null ? null : int.parse(m.group(1)!) ~/ 1024;
  } catch (_) {
    return null;
  }
}

/// 从 split-MoE manifest.json 求「单专家全层驻留字节」：Σ entries[].bytes_per_expert
/// （entries = 层 × tensor family，同一专家在所有层/投影上的 slot 总大小）。
/// 解析失败返回 null，由调用方兜底。
/// manifest bank 几何信息：total = Σ 全部 entries bytes_per_expert（= 单专家
/// 全层全族驻留字节，旧口径）；perLayer = 单专家单层全族字节（bank 的真实
/// 边际内存成本——slot base 按 (family×bpe) 分组、prefill 段组内共享，见
/// llama-model-loader::virtualize_expert_tensor 实测 656 slots = 282MiB）；
/// layers = MoE 层数。
Future<({int total, int perLayer, int layers})?> _moeManifestBankGeo(
    File manifest) async {
  try {
    final j = jsonDecode(await manifest.readAsString());
    if (j is! Map || j['entries'] is! List) return null;
    int sum = 0;
    final layers = <int>{};
    for (final e in (j['entries'] as List)) {
      final b = e is Map ? e['bytes_per_expert'] : null;
      if (b is! int || b <= 0) return null;
      sum += b;
      final l = e is Map ? e['layer'] : null;
      if (l is int) layers.add(l);
    }
    if (sum <= 0 || layers.isEmpty) return null;
    return (total: sum, perLayer: sum ~/ layers.length, layers: layers.length);
  } catch (_) {
    return null;
  }
}
