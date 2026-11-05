// ============================================================
// 本地 GGUF 模型配置（桌面独立版 v0.0.3，设计 §12 / 计划 Phase 2）。
//
// 取代手机端"下载目录 + models_catalog.json"的模型观：桌面形态的模型 =
// 磁盘上已存在的 .gguf 文件 + 一份加载配置。条目持久化在与远程 API 配置
// （apiModels，见 api_model.dart）同一份 settings JSON 里（`localModels`
// 键），形状也刻意对齐 ApiModelConfig，方便 UI 与解析代码成对阅读。
//
// 与引擎的关系：engineId 为空 = Auto 路由（local_server_inference 按模型
// 能力挑引擎）；非空 = 钉死某引擎实例。参数优先级（Phase 3 落地）：
// 本条目的 customArgs > 引擎 defaultConfig > manifest 模板/preset。
// ============================================================

import 'dart:io';
import 'dart:math';

import 'package:path/path.dart' as p;

import '../engine/bundled_manifests.dart';
import '../platform/wangcai_paths.dart';
import 'model_info.dart';

/// 一个本地模型条目。
///
/// 字段说明：
/// - [id]         本地生成的唯一标识，`settings.defaultModelId` 以它引用默认模型。
/// - [name]       界面显示名（添加时默认取文件名去扩展名）。
/// - [modelPath]  .gguf 绝对路径（必需；文件被移走时 UI 显示"缺文件"而非删除条目）。
/// - [engineId]   绑定的引擎实例 id；null/空 = Auto 路由。
/// - [customArgs] 模型级自定义尾参（追加在引擎参数模板结果之后）；
///                null/空 = 不覆盖，交给引擎默认配置（见 Phase 3 优先级链）。
/// - [mmprojPath] 视觉塔（mmproj）.gguf；非空 = 该模型按视觉模型对待。
/// - [draftPath]  MTP/dspark 草稿模型路径（模型级参数，取代旧全局开关）。
/// - [ctx]        上下文长度覆盖；null = 用引擎/manifest 值。
/// - [chunk]      NPU prefill chunk（PREFILL_CHUNK_SIZE）覆盖；null = 引擎值。
/// - [gpuLayers]  GPU offload 层数覆盖；null = 引擎值。
class LocalModelConfig {
  final String id;
  final String name;
  final String modelPath;
  final String? engineId;
  final List<String>? customArgs;
  final String? mmprojPath;
  final String? draftPath;
  final int? ctx;
  final int? chunk;
  final int? gpuLayers;

  const LocalModelConfig({
    required this.id,
    required this.name,
    required this.modelPath,
    this.engineId,
    this.customArgs,
    this.mmprojPath,
    this.draftPath,
    this.ctx,
    this.chunk,
    this.gpuLayers,
  });

  /// 是否绑定了指名引擎（否则 Auto 路由）。
  bool get hasEngine => (engineId ?? '').isNotEmpty;

  /// 是否配置了视觉塔。
  bool get hasMmproj => (mmprojPath ?? '').isNotEmpty;

  /// 是否配置了投机草稿（MTP/dspark）。
  bool get hasDraft => (draftPath ?? '').isNotEmpty;

  /// 自定义尾参（去空白、滤空串）；空列表 = 不覆盖。
  List<String> get customArgsList =>
      (customArgs ?? const <String>[]).map((e) => e.trim()).where((e) => e.isNotEmpty).toList();

  /// 显示名兜底：name 为空时取文件名去扩展名。
  String get displayName =>
      name.trim().isNotEmpty ? name : p.basenameWithoutExtension(modelPath);

  LocalModelConfig copyWith({
    String? name,
    String? modelPath,
    String? engineId,
    List<String>? customArgs,
    String? mmprojPath,
    String? draftPath,
    int? ctx,
    int? chunk,
    int? gpuLayers,
    bool clearEngineId = false,
    bool clearCustomArgs = false,
    bool clearMmprojPath = false,
    bool clearDraftPath = false,
    bool clearCtx = false,
    bool clearChunk = false,
    bool clearGpuLayers = false,
  }) {
    return LocalModelConfig(
      id: id,
      name: name ?? this.name,
      modelPath: modelPath ?? this.modelPath,
      engineId: clearEngineId ? null : (engineId ?? this.engineId),
      customArgs: clearCustomArgs ? null : (customArgs ?? this.customArgs),
      mmprojPath: clearMmprojPath ? null : (mmprojPath ?? this.mmprojPath),
      draftPath: clearDraftPath ? null : (draftPath ?? this.draftPath),
      ctx: clearCtx ? null : (ctx ?? this.ctx),
      chunk: clearChunk ? null : (chunk ?? this.chunk),
      gpuLayers: clearGpuLayers ? null : (gpuLayers ?? this.gpuLayers),
    );
  }

  Map<String, dynamic> toJson() => {
        'id': id,
        'name': name,
        'modelPath': modelPath,
        if (hasEngine) 'engineId': engineId,
        if (customArgsList.isNotEmpty) 'customArgs': customArgsList,
        if (hasMmproj) 'mmprojPath': mmprojPath,
        if (hasDraft) 'draftPath': draftPath,
        if (ctx != null) 'ctx': ctx,
        if (chunk != null) 'chunk': chunk,
        if (gpuLayers != null) 'gpuLayers': gpuLayers,
      };

  /// 解析失败（缺必需字段/类型不对）返回 null，由调用方丢弃条目。
  /// 对**任何**脏值宽容（`is String` 判型而非硬 cast）：settings JSON 可能
  /// 被手改坏，一条坏条目不能炸掉整个设置加载。
  static LocalModelConfig? fromJson(Map<String, dynamic> json) {
    String? s(String key) {
      final v = json[key];
      if (v == null) return null;
      if (v is! String) return null; // 类型不对 = 脏数据
      final t = v.trim();
      return t.isEmpty ? null : t;
    }

    int? i(String key) {
      final v = json[key];
      return v is num ? v.toInt() : null; // 非数值（含字符串数字）= 脏数据
    }

    final id = s('id');
    final modelPath = s('modelPath');
    if (id == null || modelPath == null) return null;
    final rawArgs = json['customArgs'];
    return LocalModelConfig(
      id: id,
      name: s('name') ?? '',
      modelPath: modelPath,
      engineId: s('engineId'),
      customArgs: rawArgs is List
          ? rawArgs
              .map((e) => e is String ? e : '')
              .where((e) => e.trim().isNotEmpty)
              .toList()
          : null,
      mmprojPath: s('mmprojPath'),
      draftPath: s('draftPath'),
      ctx: i('ctx'),
      chunk: i('chunk'),
      gpuLayers: i('gpuLayers'),
    );
  }
}

final _lmRandom = Random();

/// 本地登记条目的 id 前缀（`defaultModelId` 判别形态用，见
/// home_screen._initAutoLoadDefaultModel 的三分支解析）。
const String kLocalModelIdPrefix = 'lm_';

/// NPU 预置虚拟条目的 id 前缀：`defaultModelId = 'npu:<preset名>'`。
const String kNpuPresetIdPrefix = 'npu:';

/// 新条目 id：`lm_<millis>_<rand8hex>`。随机尾缀纪律同 project.dart 的
/// newProjectId —— Windows 时钟毫秒粒度，纯时间戳会撞。
String newLocalModelId() {
  final ms = DateTime.now().millisecondsSinceEpoch;
  final r = _lmRandom.nextInt(1 << 32).toRadixString(16).padLeft(8, '0');
  return '${kLocalModelIdPrefix}${ms}_$r';
}

/// preset 的 modelGlob → 大小写不敏感正则。与 local_server_inference 的
/// `_matchPreset` 同一形态 —— 模型管理页展示命中的就是加载时会命中的。
/// Windows 文件系统大小写不敏感，磁盘上实际可能是全小写文件名。
RegExp presetGlobToRegExp(String glob) {
  final pattern = glob.split('').map((c) {
    if (c == '*') return '.*';
    if (c == '?') return '.';
    return RegExp.escape(c);
  }).join();
  return RegExp('^${pattern}\$', caseSensitive: false);
}

/// NPU 预置缺文件 → catalog 下载条目（模型管理页「下载」按钮数据源，2026-11-05）。
///
/// 匹配判据 = catalog 条目的**落盘名** `{id}.gguf`（DownloadService 产物命名）
/// 命中预置的 modelGlob —— 与预置区扫描/引擎加载同一个 [presetGlobToRegExp]，
/// 保证「下回来的就是扫得到的」：Windows 文件系统大小写不敏感，小写 id 也能
/// 命中大写 glob（MiniCPM5 即如此）。同 glob 命中多条（如 MiniCPM5 的
/// Q4_K_M/Q8_0 两档）取 totalBytes 最小 —— NPU 主打线对体积/内存敏感。
/// 返回 null = catalog 无该预置对应条目 → UI 保留「手动放文件 + 重扫」指引。
ModelConfig? downloadEntryForNpuGlob(String? modelGlob, List<ModelConfig> catalog) {
  if (modelGlob == null || modelGlob.isEmpty) return null;
  final re = presetGlobToRegExp(modelGlob);
  ModelConfig? best;
  for (final m in catalog) {
    if (!re.hasMatch('${m.id}.gguf')) continue;
    if (best == null || m.totalBytes < best.totalBytes) best = m;
  }
  return best;
}

/// 把 wangcai-npu manifest 的 preset 解析成虚拟 [LocalModelConfig]：
/// 在模型库目录（[WangCaiPaths.modelsRoot]）扫 modelGlob 首个命中文件。
/// 缺文件返回 null（调用方静默跳过，不报错 —— 预置是便利入口不是承诺）。
///
/// id 固定 `npu:<preset名>`：默认模型星标与启动自动加载共用同一解析。
LocalModelConfig? resolveNpuPresetConfig(String presetName) {
  final manifest = bundledManifests()['wangcai-npu'];
  final preset = manifest?.presetByName(presetName);
  final glob = preset?.modelGlob;
  if (preset == null || glob == null || glob.isEmpty) return null;
  final dir = WangCaiPaths.modelsRoot();
  if (!dir.existsSync()) return null;
  final re = presetGlobToRegExp(glob);
  try {
    final names = dir
        .listSync()
        .whereType<File>()
        .where((f) => f.path.toLowerCase().endsWith('.gguf'))
        .map((f) => p.basename(f.path))
        .toList()
      ..sort();
    for (final name in names) {
      if (re.hasMatch(name)) {
        return LocalModelConfig(
          id: '$kNpuPresetIdPrefix$presetName',
          name: presetName,
          modelPath: p.join(dir.path, name),
        );
      }
    }
  } catch (_) {}
  return null;
}
