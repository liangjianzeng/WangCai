// ============================================================
// Model metadata, mirror entries, and download task state.
// All model configurations live in assets/models_catalog.json
// and are loaded dynamically via ModelCatalog.load().
// ============================================================

enum ModelType { text, vision }

String modelTypeLabel(ModelType type) {
  switch (type) {
    case ModelType.text:
      return 'text';
    case ModelType.vision:
      return 'vision';
  }
}

String modelTypeIcon(ModelType type) {
  switch (type) {
    case ModelType.text:
      return '\u{1F4AC}'; // 💬
    case ModelType.vision:
      return '\u{1F5BC}\u{FE0F}'; // 🖼️
  }
}

/// 去掉模型名里括号内的精度/量化说明（如 "Qwen3.5-0.8B (Q4_K_M MTP)" → "Qwen3.5-0.8B"），
/// 用于界面显示以缩短长度。仅去掉末尾的括号段；无括号时原样返回。
String cleanModelName(String name) {
  final trimmed = name.trim();
  final match = RegExp(r'\s*\([^()]*\)\s*$').firstMatch(trimmed);
  if (match == null) return trimmed;
  return trimmed.substring(0, match.start).trim();
}

/// 模型列表里由**图标**而不是 chip 表达的特性标签。渲染特性标签时必须剔掉，
/// 否则和主行的眼睛图标撞车（视觉模型一行里出现两个「视觉」）。
const Set<String> kModelIconCoveredTags = {'视觉', '视觉+语音'};

/// 模型管理页的特性标签清洗 —— 折叠态次行与展开区共用（渲染点见
/// `settings_screen` 的 `_modelMetaLine`），保证同一行里一条信息只出现一次。
///
/// 去掉：空串、目录里重复配置的、由主行眼睛图标表达的（[kModelIconCoveredTags]）、
/// 以及模型名（去括号后 [cleanModelName]）里已经写明的那部分。
/// [limit] 非空时只留前 N 条（折叠态只放最要紧的几个，全量留给展开区）。
List<String> modelFeatureTags(
  ModelConfig model, {
  int? limit,
  Set<String>? coveredTags,
}) {
  final covered = coveredTags ?? kModelIconCoveredTags;
  final name = cleanModelName(model.name).toLowerCase();
  final picked = <String>[];
  for (final raw in model.tags) {
    final tag = raw.trim();
    if (tag.isEmpty || covered.contains(tag)) continue;
    if (picked.contains(tag)) continue; // 同一标签在目录里配了两次
    if (tag.length > 1 && name.contains(tag.toLowerCase())) continue; // 名字里已有
    picked.add(tag);
    if (limit != null && picked.length >= limit) break;
  }
  return picked;
}

class MirrorEntry {
  final String url;
  final String source;

  const MirrorEntry(this.url, this.source);

  @override
  String toString() {
    final masked = url.replaceAll(RegExp(r'https://[^/]+'), 'https://***');
    return 'Mirror($source: $masked)';
  }

  factory MirrorEntry.fromJson(Map<String, dynamic> json) {
    return MirrorEntry(json['url'] as String, json['source'] as String);
  }
}

ModelType modelTypeFromJson(String value) {
  switch (value.toLowerCase()) {
    case 'vision':
      return ModelType.vision;
    case 'text':
    default:
      return ModelType.text;
  }
}

/// 多模态投影器（mmproj）配置 —— 用于「text + mmproj 两文件」形态的视觉模型。
///
/// 与 [ModelConfig] 的关系：
/// - 模型 `mmproj == null` 且 `type == vision` → **单文件自包含 VL**（如 QWEN3），
///   只需下载/加载主 gguf 一个文件，视觉编码器内置于其中；
/// - 模型 `mmproj != null` → **text + mmproj 两文件**（如 QWEN3.5），需额外下载/加载
///   投影器 gguf，主模型才能理解图片。
///
/// 原生层按 mmproj 是否存在决定是否加载投影器，两形态共用同一套加载路径。
class MmprojConfig {
  final List<MirrorEntry> mirrors;
  final int sizeBytes;
  final String sizeMBDisplay;
  final String? sha256Hash;

  const MmprojConfig({
    required this.mirrors,
    required this.sizeBytes,
    required this.sizeMBDisplay,
    this.sha256Hash,
  });

  String get bestMirrorUrl => mirrors.first.url;
  int get sizeMB => sizeBytes ~/ (1024 * 1024);

  @override
  String toString() => 'MmprojConfig(${sizeMBDisplay})';

  factory MmprojConfig.fromJson(Map<String, dynamic> json) {
    // mmproj 文件较小，用 sizeMB（而非主模型的 sizeGB）估算。
    final sizeMB = (json['sizeMB'] as num?)?.toDouble() ?? 0.0;
    return MmprojConfig(
      mirrors: (json['mirrors'] as List)
          .map((e) => MirrorEntry.fromJson(e as Map<String, dynamic>))
          .toList(),
      sizeBytes: (sizeMB * 1024 * 1024).round(),
      sizeMBDisplay: json['sizeMBDisplay'] as String? ?? '${sizeMB.toStringAsFixed(1)} MB',
      sha256Hash: json['sha256Hash'] as String?,
    );
  }
}

/// dspark 投机解码草稿头配置（如 Bonsai-27B-dspark-Q4_1.gguf，DFlash + Markov
/// head）。存在时加载主模型会自动带上草稿模型做投机加速；null 表示无草稿头。
class DsparkConfig {
  final List<MirrorEntry> mirrors;
  final int sizeBytes;
  final String sizeMBDisplay;

  const DsparkConfig({
    required this.mirrors,
    required this.sizeBytes,
    required this.sizeMBDisplay,
  });

  String get bestMirrorUrl => mirrors.first.url;
  int get sizeMB => sizeBytes ~/ (1024 * 1024);

  @override
  String toString() => 'DsparkConfig(${sizeMBDisplay})';

  factory DsparkConfig.fromJson(Map<String, dynamic> json) {
    final sizeMB = (json['sizeMB'] as num?)?.toDouble() ?? 0.0;
    return DsparkConfig(
      mirrors: (json['mirrors'] as List)
          .map((e) => MirrorEntry.fromJson(e as Map<String, dynamic>))
          .toList(),
      sizeBytes: (sizeMB * 1024 * 1024).round(),
      sizeMBDisplay: json['sizeMBDisplay'] as String? ?? '${sizeMB.toStringAsFixed(1)} MB',
    );
  }
}

/// 拆分 MoE（split-moe）专家包配置 —— 超大 MoE（>10B）统一承载形态。
///
/// 与 [ModelConfig] 的关系：
/// - 主 `.gguf`（-les 形态）已剥离路由专家，只含 dense 骨架
///   （attention/router/共享专家/token_embd/lm_head），常驻加载；
/// - 专家分片（layer_NNN.bin）+ manifest.json 落在 `{modelId}.experts/` 子目录，
///   由原生 slot runtime 按需流式装载（槽位窗口 + LES 前瞻预取）。
///
/// 目录布局（官方 MiniCPM-V Apps 对齐）：
/// ```
/// {modelsDir}/{modelId}.gguf                    主文件（专家已剥离）
/// {modelsDir}/{modelId}.experts/manifest.json   专家清单（schema v1）
/// {modelsDir}/{modelId}.experts/layer_000.bin   专家分片 ×N
/// ```
class SplitMoeConfig {
  /// manifest.json 的镜像列表（完整文件 URL）。
  final List<MirrorEntry> manifestMirrors;

  /// manifest.json 预期大小（字节，仅用于进度估算）。
  final int manifestSizeBytes;

  /// 专家分片镜像 base URL（以 `/` 结尾），分片相对路径由
  /// [layerBinPattern] 拼接。示例：
  /// `https://modelscope.cn/models/<repo>/resolve/master/MiniCPM-V-4.7-35B-A3B/`
  final List<MirrorEntry> expertsBaseMirrors;

  /// 专家分片数量（如 40 层 = 40 个 layer bin）。
  final int layerBinCount;

  /// 单个分片预期大小（字节）。manifest 的 per-entry exact_byte_length
  /// 是精确值（非估算），下载完整性校验可直接比对。
  final int layerBinSizeBytes;

  /// 分片相对路径模板（C/Java 双端 printf 风格），如 `experts/layer_%03d.bin`。
  final String layerBinPattern;

  /// in-place 形态（方案 C，2026-10-16）：不下载拆分专家包，直接下载官方
  /// 整包 gguf（单文件），引擎按 gguf 张量表原地 preadv 读专家区。
  /// 此时 manifest/分片字段全部不用，slot/experts 字节由目录元数据给出。
  final bool inplaceFullGguf;

  /// in-place：单槽全层驻留字节（Σ bytes_per_expert，全 MoE 层），
  /// 内存自适应 bank 公式用（packed 形态运行时从 manifest 求和）。
  final int slotBytesAllLayers;

  /// in-place：整包 gguf 内路由专家区总字节（常驻估算扣减用，
  /// = 专家区 Σ tensor bytes；dense 常驻 ≈ 文件大小 − 该值）。
  final int expertsBytes;

  const SplitMoeConfig({
    this.manifestMirrors = const [],
    this.manifestSizeBytes = 0,
    this.expertsBaseMirrors = const [],
    this.layerBinCount = 0,
    this.layerBinSizeBytes = 0,
    this.layerBinPattern = 'experts/layer_%03d.bin',
    this.inplaceFullGguf = false,
    this.slotBytesAllLayers = 0,
    this.expertsBytes = 0,
  });

  String? get bestManifestUrl =>
      manifestMirrors.isEmpty ? null : manifestMirrors.first.url;
  String? get bestExpertsBaseUrl =>
      expertsBaseMirrors.isEmpty ? null : expertsBaseMirrors.first.url;

  /// 专家分片相对路径（0-based index）。printf 风格模板
  /// `experts/layer_%03d.bin` → `experts/layer_007.bin`。
  String layerBinRelativePath(int index) {
    final m =
        RegExp(r'^(.*?)(%0(\d+)d)(.*)$').firstMatch(layerBinPattern);
    if (m == null) return layerBinPattern; // 无模板占位符 → 原样返回
    final width = int.parse(m.group(3)!);
    return '${m.group(1)}${index.toString().padLeft(width, '0')}${m.group(4)}';
  }

  /// 需要**额外**下载/存储的专家包字节（manifest + 全部分片）。
  /// in-place 形态专家就在整包主文件里 → 0（不重复计入下载体积）。
  int get expertsTotalBytes => inplaceFullGguf
      ? 0
      : manifestSizeBytes + layerBinCount * layerBinSizeBytes;

  @override
  String toString() => inplaceFullGguf
      ? 'SplitMoeConfig(inplace, slot ${formatBytes(slotBytesAllLayers)})'
      : 'SplitMoeConfig(bins=$layerBinCount x ${formatBytes(layerBinSizeBytes)})';

  static String formatBytes(int bytes) {
    if (bytes >= 1024 * 1024 * 1024) {
      return '${(bytes / 1024 / 1024 / 1024).toStringAsFixed(1)} GB';
    }
    if (bytes >= 1024 * 1024) return '${(bytes / 1024 / 1024).toStringAsFixed(0)} MB';
    return '${(bytes / 1024).toStringAsFixed(0)} KB';
  }

  factory SplitMoeConfig.fromJson(Map<String, dynamic> json) {
    final manifestSizeMB = (json['manifestSizeMB'] as num?)?.toDouble() ?? 0.0;
    final layerBinSizeMB = (json['layerBinSizeMB'] as num?)?.toDouble() ?? 0.0;
    final slotBytesAllLayersMB =
        (json['slotBytesAllLayersMB'] as num?)?.toDouble() ?? 0.0;
    final expertsBytesMB = (json['expertsBytesMB'] as num?)?.toDouble() ?? 0.0;
    return SplitMoeConfig(
      manifestMirrors: (json['manifestMirrors'] as List? ?? const [])
          .map((e) => MirrorEntry.fromJson(e as Map<String, dynamic>))
          .toList(),
      manifestSizeBytes: (manifestSizeMB * 1024 * 1024).round(),
      expertsBaseMirrors: (json['expertsBaseMirrors'] as List? ?? const [])
          .map((e) => MirrorEntry.fromJson(e as Map<String, dynamic>))
          .toList(),
      layerBinCount: json['layerBinCount'] as int? ?? 0,
      layerBinSizeBytes: (layerBinSizeMB * 1024 * 1024).round(),
      layerBinPattern: json['layerBinPattern'] as String? ?? 'experts/layer_%03d.bin',
      inplaceFullGguf: json['inplaceFullGguf'] as bool? ?? false,
      slotBytesAllLayers: (slotBytesAllLayersMB * 1024 * 1024).round(),
      expertsBytes: (expertsBytesMB * 1024 * 1024).round(),
    );
  }
}

class ModelConfig {
  final String id;
  final String name;
  final ModelType type;
  final List<MirrorEntry> mirrors;
  final int sizeBytes;
  final String sizeMBDisplay;
  final bool recommended;
  final int minRamMB;
  final String? sha256Hash;
  final bool mtp;

  /// 特性标签（如 "推荐" / "速度快"），用于 UI 展示的小 chip。
  final List<String> tags;

  /// 可选的 mmproj 投影器配置。null + type=vision → 单文件自包含 VL。
  final MmprojConfig? mmproj;

  /// 可选的 dspark 投机草稿头配置。null → 无投机草稿模型。
  final DsparkConfig? dspark;

  /// 可选的拆分 MoE 专家包配置（超大 MoE 统一承载）。非空 → 主 gguf 为
  /// -les 形态（专家已剥离），专家分片 + manifest 下载到 `{id}.experts/`。
  final SplitMoeConfig? splitMoe;

  const ModelConfig({
    required this.id,
    required this.name,
    required this.type,
    required this.mirrors,
    required this.sizeBytes,
    required this.sizeMBDisplay,
    this.recommended = false,
    this.minRamMB = 0,
    this.sha256Hash,
    this.mtp = false,
    this.tags = const [],
    this.mmproj,
    this.dspark,
    this.splitMoe,
  });

  String get bestMirrorUrl => mirrors.first.url;
  int get sizeMB => sizeBytes ~/ (1024 * 1024);

  /// 该模型是否支持视觉理解（type == vision）。
  /// 注意：单文件 VL 与 text+mmproj 两文件形态都归入 true，
  /// 原生层依据 [mmproj] 是否存在决定加载方式。
  bool get supportsVision => type == ModelType.vision;

  /// 需要 mmproj/dspark/splitMoe 的模型，其总下载体积
  /// （主 gguf + mmproj + dspark + 专家包）。
  int get totalBytes =>
      sizeBytes +
      (mmproj?.sizeBytes ?? 0) +
      (dspark?.sizeBytes ?? 0) +
      (splitMoe?.expertsTotalBytes ?? 0);

  @override
  String toString() => 'ModelConfig($id, ${sizeMBDisplay}, type=${modelTypeLabel(type)}, '
      'mmproj=${mmproj == null ? '单文件VL' : '两文件+mmproj'})';

  factory ModelConfig.fromJson(Map<String, dynamic> json) {
    final sizeGB = (json['sizeGB'] as num?)?.toDouble() ?? 0.0;
    return ModelConfig(
      id: json['id'] as String,
      name: json['name'] as String,
      type: modelTypeFromJson(json['type'] as String? ?? 'text'),
      mirrors: (json['mirrors'] as List)
          .map((e) => MirrorEntry.fromJson(e as Map<String, dynamic>))
          .toList(),
      sizeBytes: (sizeGB * 1024 * 1024 * 1024).round(),
      sizeMBDisplay: json['sizeMBDisplay'] as String? ?? '${sizeGB.toStringAsFixed(1)} GB',
      recommended: json['recommended'] as bool? ?? false,
      minRamMB: json['minRamMB'] as int? ?? 0,
      sha256Hash: json['sha256Hash'] as String?,
      mtp: json['mtp'] as bool? ?? false,
      tags: (json['tags'] as List?)?.map((e) => e as String).toList() ??
          const [],
      mmproj: json['mmproj'] != null
          ? MmprojConfig.fromJson(json['mmproj'] as Map<String, dynamic>)
          : null,
      dspark: json['dspark'] != null
          ? DsparkConfig.fromJson(json['dspark'] as Map<String, dynamic>)
          : null,
      splitMoe: json['splitMoe'] != null
          ? SplitMoeConfig.fromJson(json['splitMoe'] as Map<String, dynamic>)
          : null,
    );
  }
}

// ===================================================================
// Download task state
// ===================================================================

enum DownloadState { idle, downloading, paused, completed, failed, verifying }

String downloadStateLabel(DownloadState state) {
  switch (state) {
    case DownloadState.idle: return '待下载';
    case DownloadState.downloading: return '下载中';
    case DownloadState.paused: return '已暂停';
    case DownloadState.completed: return '已完成';
    case DownloadState.failed: return '失败';
    case DownloadState.verifying: return '校验中';
  }
}

class DownloadTask {
  final String modelId;
  DownloadState state;
  int downloadedBytes;
  int totalBytes;

  /// 当前下载阶段（主模型 / 投影器 / 加速头），多文件模型用于 UI 展示。
  /// null = 单文件模型或未开始。
  String? stage;
  String? errorMessage;
  DateTime? startTime;
  DateTime? endTime;

  DownloadTask({
    required this.modelId,
    this.state = DownloadState.idle,
    this.downloadedBytes = 0,
    this.totalBytes = 0,
    this.stage,
    this.errorMessage,
    this.startTime,
    this.endTime,
  });

  double get progress => totalBytes > 0
      // catalog 的 sizeBytes 是按 sizeGB 估算的，实际下载文件可能更大，
      // downloadedBytes 可能短暂超过 totalBytes —— 进度条必须封顶到 100%，
      // 避免出现「进度超过 100%」的视觉异常。
      ? (downloadedBytes / totalBytes).clamp(0.0, 1.0)
      : 0.0;
  String get progressPercent => '${(progress * 100).toStringAsFixed(1)}%';

  String get downloadedDisplay {
    final mb = downloadedBytes / (1024 * 1024);
    if (mb >= 1024) return '${(mb / 1024).toStringAsFixed(1)} GB';
    return '${mb.toStringAsFixed(0)} MB';
  }

  String get totalDisplay {
    final mb = totalBytes / (1024 * 1024);
    if (mb >= 1024) return '${(mb / 1024).toStringAsFixed(1)} GB';
    return '${mb.toStringAsFixed(0)} MB';
  }

  DownloadTask copyWith({
    DownloadState? state,
    int? downloadedBytes,
    int? totalBytes,
    String? stage,
    String? errorMessage,
    DateTime? startTime,
    DateTime? endTime,
  }) {
    return DownloadTask(
      modelId: modelId,
      state: state ?? this.state,
      downloadedBytes: downloadedBytes ?? this.downloadedBytes,
      totalBytes: totalBytes ?? this.totalBytes,
      stage: stage ?? this.stage,
      errorMessage: errorMessage ?? this.errorMessage,
      startTime: startTime ?? this.startTime,
      endTime: endTime ?? this.endTime,
    );
  }
}
