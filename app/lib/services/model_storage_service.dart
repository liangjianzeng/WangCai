// ============================================================
// Model Storage Service — 持久化模型文件存储管理
// 
// 设计目标：
// 1. 使用公共外部目录（/sdcard/TongYiLite/models）实现永久存储
//    - 重装 APK 后数据保留
//    - 用户可手动管理模型文件
// 2. 支持扫描多个位置查找已有模型
// ============================================================

import 'dart:io';
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';
import 'package:flutter/foundation.dart' show debugPrint;
import '../models/model_info.dart';

/// 模型存储服务 — 统一管理模型文件的存储位置
class ModelStorageService {
  static final ModelStorageService _instance = ModelStorageService._internal();
  factory ModelStorageService() => _instance;
  ModelStorageService._internal();

  // 持久化存储文件夹名（重装 APK 后仍保留，因为不在 app-private 目录下）
  static const String _appFolder = 'TongYiLite';

  /// 本应用包名。app 私有目录在不同调用路径下会有多种字符串写法
  /// （`/data/data/<pkg>` vs `/data/user/0/<pkg>`），统一以此折叠去重。
  static const String _packageName = 'com.dgxspark.tongyilite';

  /// 去重键：把「同一个 app 私有目录的不同路径写法」折叠成同一个键。
  ///
  /// Android 上 `/data/data/<pkg>`、`/data/user/0/<pkg>`、
  /// `/data/mirror/data_ce/null/0/<pkg>` 指向**同一个物理目录**（设备别名 bind mount，
  /// 且 `getApplicationDocumentsDirectory()` 在 Android 上返回的正是
  /// `/data/user/0/<pkg>/app_flutter` 形态），但字符串不同。
  ///
  /// 只按字符串去重 = 同一个模型目录被扫两遍 → 「模型管理 → 存储空间」里
  /// **每个模型列两遍、总占用翻倍**（真机实测 bug 的根因）。
  ///
  /// 做法：把包名之前的前缀（`/data/data/`、`/data/user/0/` …）统一折叠为
  /// `<appdata>`，包名之后的相对路径原样保留。
  static String pathDedupeKey(String path) {
    final idx = path.indexOf('/$_packageName/');
    if (idx >= 0) {
      return '<appdata>${path.substring(idx + _packageName.length + 1)}';
    }
    return path;
  }

  /// 单条路径的去重键：先尽量解析软链（`/sdcard` → `/storage/emulated/0`
  /// 这类真软链只有 realpath 才能折叠），再折叠 app 私有目录别名。
  Future<String> _dedupeKeyFor(String path) async {
    var effective = path;
    try {
      effective = await File(path).resolveSymbolicLinks();
    } catch (_) {}
    return pathDedupeKey(effective);
  }

  /// 按去重键过滤目录，保持入参顺序（首见者保留）。
  Future<List<Directory>> _dedupeDirs(List<String> paths) async {
    final seen = <String>{};
    final out = <Directory>[];
    for (final path in paths) {
      if (!seen.add(await _dedupeKeyFor(path))) continue;
      out.add(Directory(path));
    }
    return out;
  }

  /// 「已缓存模型 / 占用空间」统计所用的目录列表（主目录 + 内部 app_flutter +
  /// app docs 回退），**已去重**。
  ///
  /// 注意：外部存储被 scoped storage 拒绝后主目录会回退到内部
  /// `app_flutter/models`，而 app docs 目标也是 `app_flutter/models` ——
  /// 三者常是同一个物理目录，去重后通常只剩 1 个。这是正确结果，不是漏扫。
  Future<List<Directory>> candidateModelDirs() async {
    final paths = <String>[];
    try {
      paths.add((await getModelsRootDir()).path);
    } catch (_) {}
    paths.add('/data/data/$_packageName/app_flutter/models');
    try {
      final appDir = await getApplicationDocumentsDirectory();
      paths.add(p.join(appDir.path, 'models'));
    } catch (_) {}
    return _dedupeDirs(paths);
  }

  /// 解析外部存储卷根下的模型目录。优先用 getExternalStorageDirectory() 推导的真实
  /// 卷根（如 /storage/emulated/0），回退到传统的 /sdcard 软链，避免硬编码路径在
  /// 部分机型/Android 版本上失效。
  Future<String> _resolveExternalModelsDir() async {
    try {
      final ext = await getExternalStorageDirectory();
      if (ext != null) {
        // ext = /storage/emulated/0/Android/data/<pkg>/files
        // 向上 4 级到达卷根 /storage/emulated/0
        var root = ext;
        for (var i = 0; i < 4 && root.parent.path != root.path; i++) {
          root = root.parent;
        }
        return p.join(root.path, _appFolder, 'models');
      }
    } catch (e) {
      debugPrint('[ModelStorage] Failed to resolve external root: $e');
    }
    return p.join('/sdcard', _appFolder, 'models');
  }

  /// 获取模型存储根目录（优先外部存储，回退到内部存储）。
  ///
  /// 目录解析涉及多次异步 IO（外部卷根推导 + 可写性验证），且外部不可写时
  /// 会回退到内部目录。若每次调用都重新解析，外部/内部切换会导致缓存状态
  /// 判断跳变（"飘忽"）。因此进程内只解析一次并缓存，保证后续调用返回一致。
  Future<Directory> getModelsRootDir() {
    return _rootDirFuture ??= _resolveRootDirOnce();
  }

  Future<Directory>? _rootDirFuture;

  Future<Directory> _resolveRootDirOnce() async {
    final externalPath = await _resolveExternalModelsDir();
    final externalDir = Directory(externalPath);
    try {
      if (!await externalDir.exists()) {
        await externalDir.create(recursive: true);
        debugPrint('[ModelStorage] Created directory: ${externalDir.path}');
      }

      // 验证可写性
      final testFile = File(p.join(externalDir.path, '.write_test'));
      await testFile.writeAsString('test');
      await testFile.delete();

      debugPrint('[ModelStorage] Using external storage: ${externalDir.path}');
      return externalDir;
    } catch (e) {
      debugPrint('[ModelStorage] Failed to use external storage: $e');
    }

    // 2. 回退到内部存储（app_flutter/models）
    return await _getFallbackDir();
  }

  /// 回退方案：使用内部存储（Flutter app_flutter 目录）
  Future<Directory> _getFallbackDir() async {
    // Flutter 的 app_flutter/models 路径
    final dir = Directory('/data/data/$_packageName/app_flutter/models');
    
    // 尝试创建目录
    try {
      if (!await dir.exists()) {
        await dir.create(recursive: true);
        debugPrint('[ModelStorage] Created internal directory: ${dir.path}');
      }
      debugPrint('[ModelStorage] Using internal storage: ${dir.path}');
      return dir;
    } catch (e) {
      debugPrint('[ModelStorage] Failed to create internal directory: $e');
      // 最后回退到 applicationDocumentsDirectory
      final appDir = await getApplicationDocumentsDirectory();
      final fallbackDir = Directory(p.join(appDir.path, 'models'));
      await fallbackDir.create(recursive: true);
      debugPrint('[ModelStorage] Fallback to app docs: ${fallbackDir.path}');
      return fallbackDir;
    }
  }

  /// 获取模型文件路径
  ///
  /// 主目录（/sdcard/TongYiLite/models）优先；文件不在时扫描候选目录
  /// （内部 app_flutter/models、Download、DCIM、app docs）。
  /// 旧版 App 把模型存在内部存储（app_flutter/models），只查主目录会把
  /// "已缓存"（isFullyCached 多目录判）和"可加载"（只查主目录）劈成两半。
  /// 找不到时仍返回主目录路径，保持原生"模型文件不存在"的错误语义。
  Future<String> getModelPath(String modelId) async {
    return await _findFile(modelId, '.gguf');
  }

  /// 获取 mmproj 投影器文件路径（text+mmproj 两文件形态的视觉模型）。
  Future<String> getMmprojPath(String modelId) async {
    return await _findFile(modelId, '.mmproj');
  }

  Future<String> _findFile(String modelId, String suffix) async {
    final candidates = await _allCandidateDirs();
    // 快路径：各候选目录顶层精确查找
    for (final dir in candidates) {
      try {
        final file = File(p.join(dir.path, '$modelId$suffix'));
        if (await file.exists()) return file.path;
      } catch (_) {}
    }
    // 慢路径：递归查找。必须与 scanExistingModels 的递归扫描对称，否则
    // 子目录里的模型会被判成"已缓存"但永远加载失败（幽灵缓存）。
    // Download/DCIM 在扫描时也只查顶层，这里无需递归（避免扫全盘变慢）。
    for (final dir in candidates) {
      final dirPath = dir.path;
      if (dirPath == '/sdcard/Download' || dirPath == '/sdcard/DCIM') continue;
      try {
        if (!await dir.exists()) continue;
        final target = '$modelId$suffix';
        await for (final entity in dir.list(recursive: true)) {
          if (entity is File && p.basename(entity.path) == target) {
            return entity.path;
          }
        }
      } catch (_) {}
    }
    final dir = await getModelsRootDir();
    return p.join(dir.path, '$modelId$suffix');
  }

  /// 获取 dspark 投机草稿头文件路径（独立 GGUF，如 Bonsai-27B-dspark-Q4_1）。
  Future<String> getDsparkPath(String modelId) async {
    final dir = await getModelsRootDir();
    return p.join(dir.path, '${modelId}.dspark.gguf');
  }

  /// 获取拆分 MoE 专家包目录（`{modelId}.experts/`，含 manifest.json +
  /// layer_NNN.bin 分片）。目录可能尚不存在（未下载）。
  Future<Directory> getExpertsDir(String modelId) async {
    final dir = await getModelsRootDir();
    return Directory(p.join(dir.path, '$modelId.experts'));
  }

  // ---------------------------------------------------------------------
  // 删除：模型产物清单 + 多目录清扫
  // ---------------------------------------------------------------------

  /// 一个模型在磁盘上的**全部产物文件名**（含下载残留 `.tmp`）。
  ///
  /// 删除 / 取消下载必须按这份清单清扫。旧实现手写四个后缀
  /// `['.gguf', '.gguf.tmp', '.mmproj', '.mmproj.tmp']`，**漏了 dspark 草稿头**
  /// `{id}.dspark.gguf`（Bonsai-27B 一个就是 1.7GB），删完还留一地孤儿文件。
  static List<String> modelArtifactFileNames(String modelId) => [
        '$modelId.gguf',
        '$modelId.gguf.tmp',
        '$modelId.mmproj',
        '$modelId.mmproj.tmp',
        '$modelId.dspark.gguf',
        '$modelId.dspark.gguf.tmp',
      ];

  /// 拆分 MoE 专家包目录名（`{modelId}.experts/`）。
  static String modelExpertsDirName(String modelId) => '$modelId.experts';

  /// 在**单个**目录内按清单删除模型产物，返回真正删掉的路径。
  /// 单个文件删不掉（权限/占用）只跳过它，不影响其余文件。
  static Future<List<String>> deleteArtifactsIn(
      Directory dir, String modelId) async {
    final removed = <String>[];
    for (final name in modelArtifactFileNames(modelId)) {
      final path = p.join(dir.path, name);
      try {
        final f = File(path);
        if (await f.exists()) {
          await f.delete();
          removed.add(path);
        }
      } catch (e) {
        debugPrint('[ModelStorage] 删除失败 $path: $e');
      }
    }
    final expertsPath = p.join(dir.path, modelExpertsDirName(modelId));
    try {
      final experts = Directory(expertsPath);
      if (await experts.exists()) {
        await experts.delete(recursive: true);
        removed.add(expertsPath);
      }
    } catch (e) {
      debugPrint('[ModelStorage] 删除专家包失败 $expertsPath: $e');
    }
    return removed;
  }

  /// 删除模型的全部产物（主 gguf + mmproj + dspark + 专家包目录），
  /// **遍历全部候选目录**——与 [isFullyCached] / [scanExistingModels] 用同一套
  /// 查找范围。
  ///
  /// 为什么必须多目录（2026-10-30 用户反馈「删除点了没反应，再进列表还在」）：
  /// 判「已缓存」走 [isFullyCached] 的多目录判据，而旧 `deleteModel` 只删
  /// `getModelsRootDir()` 一个目录 —— 预置/历史遗留在 `app_flutter/models`、
  /// `Download`、`DCIM` 里的文件根本删不到，下次进页面 [ModelStorageService]
  /// 的多目录校验又把它认回「已缓存」，看起来就像删除按钮坏了。
  ///
  /// 返回已删除的路径列表（空 = 一个都没删掉，通常意味着文件不在候选目录内
  /// 或没有存储权限），调用方可据此给用户真实反馈。
  Future<List<String>> deleteModelArtifacts(String modelId) async {
    final paths = <String>[];
    try {
      paths.add((await getModelsRootDir()).path);
    } catch (_) {}
    try {
      paths.addAll((await _allCandidateDirs()).map((d) => d.path));
    } catch (_) {}
    final dirs = await _dedupeDirs(paths);

    final removed = <String>[];
    for (final dir in dirs) {
      removed.addAll(await deleteArtifactsIn(dir, modelId));
    }
    debugPrint('[ModelStorage] 删除 $modelId：${removed.length} 项 '
        '（扫过 ${dirs.length} 个候选目录）');
    return removed;
  }

  /// Check if model file exists locally
  Future<bool> isModelCached(String modelId) async {
    try {
      final path = await getModelPath(modelId);
      return File(path).exists();
    } catch (_) {
      return false;
    }
  }

  /// 判断模型是否「完整」地缓存在磁盘上 —— 这是「能否当作已缓存 / 可加载」的
  /// 唯一可靠判据。
  ///
  /// 仅检查 `.gguf` 是否存在（[isModelCached]）会漏掉两类故障：
  ///  ① catalog 里 `sizeBytes` 与实文件不符时，一个被截断/不完整的 `.gguf`
  ///   仍会被当成已缓存；
  ///  ② 下载中途暂停/失败若残留 `.gguf` 或 `.gguf.tmp`，会被误判为可加载，
  ///   用户点击「加载」后因为模型文件不全而直接失败。
  ///
  /// 因此要求：`.gguf` 存在、实文件大小 ≥ catalog 预期大小的 99%（catalog 未给
  /// 大小时退化为仅存在性判断）、且不存在未完成的 `.gguf.tmp` 部分文件。
  ///
  /// text+mmproj 两文件形态（[ModelConfig.mmproj] 非空）还需 mmproj 文件完整存在，
  /// 否则视觉模型无法加载（缺投影器）。
  Future<bool> isFullyCached(ModelConfig model) async {
    // 多位置查找：全盘扫描（scanExistingModels）能找到 Download/DCIM/内部目录
    // 里的模型，而轻量校验若只查主目录会漏判 → 同一模型"时好时坏"。
    // 这里遍历所有候选目录，任一目录内模型完整即视为已缓存。
    try {
      for (final dir in await _allCandidateDirs()) {
        if (!await dir.exists()) continue;
        if (await _isFullyCachedIn(dir, model)) return true;
      }
      return false;
    } catch (_) {
      return false;
    }
  }

  /// 判断 [model] 是否「完整」地缓存在目录 [dir] 下。
  ///
  /// 仅检查 `.gguf` 是否存在会漏掉两类故障：
  ///  ① catalog 里 `sizeBytes` 与实文件不符时，一个被截断/不完整的 `.gguf`
  ///   仍会被当成已缓存；
  ///  ② 下载中途暂停/失败若残留 `.gguf` 或 `.gguf.tmp`，会被误判为可加载。
  /// 因此要求：`.gguf` 存在、实文件大小 ≥ catalog 预期大小的 99%（catalog 未给
  /// 大小时退化为仅存在性判断）。
  ///
  /// text+mmproj 两文件形态（[ModelConfig.mmproj] 非空）还需 mmproj 文件完整存在。
  ///
  /// 自愈：当主文件已完整存在时，顺带清理上次中断下载残留的 `.tmp`（如重下时
  /// 流被截断留下的 `.mmproj.tmp`）。此前「存在 .tmp 即判未缓存」会把一个
  /// 已完整可用的模型永久误判为「未下载」——点击下载又重复拉取投影器，正是
  /// 用户反馈的 bug。完整主文件 + 残留 .tmp 时，.tmp 只是过期残留，删掉即可。
  Future<bool> _isFullyCachedIn(Directory dir, ModelConfig model) async {
    try {
      // 完成判定：文件存在、非空、无残留 .tmp 即完整（不再按 catalog 估算大小卡百分比）。
      if (!await _isCompleteFile(File(p.join(dir.path, '${model.id}.gguf')))) {
        return false;
      }
      await _cleanStaleTmp(dir, model.id, '.gguf');
      // mmproj 两文件形态：投影器必须完整存在，否则视为未缓存。
      final mm = model.mmproj;
      if (mm != null) {
        if (!await _isCompleteFile(File(p.join(dir.path, '${model.id}.mmproj')))) {
          return false;
        }
        await _cleanStaleTmp(dir, model.id, '.mmproj');
      }
      // dspark 投机草稿头：必须完整存在，否则投机加速无法启用。
      final ds = model.dspark;
      if (ds != null) {
        if (!await _isCompleteFile(
            File(p.join(dir.path, '${model.id}.dspark.gguf')))) {
          return false;
        }
        await _cleanStaleTmp(dir, model.id, '.dspark.gguf');
      }
      // 拆分 MoE 专家包：manifest + 全部分片必须完整存在（分片大小精确
      // 匹配 manifest 的 exact_byte_length——错误/截断分片不允许当已缓存）。
      // inplaceFullGguf 形态专家在整包主文件里，无专家目录可查。
      final sm = model.splitMoe;
      if (sm != null && !sm.inplaceFullGguf) {
        final expertsDir = Directory(p.join(dir.path, '${model.id}.experts'));
        if (!await _isCompleteFile(
            File(p.join(expertsDir.path, 'manifest.json')))) {
          return false;
        }
        if (!await expertsDir.exists()) return false;
        final expected = <String>{};
        for (var i = 0; i < sm.layerBinCount; i++) {
          expected.add(p.basename(sm.layerBinRelativePath(i)));
        }
        final sizes = <String, int>{};
        try {
          await for (final e in expertsDir.list()) {
            if (e is File && e.path.endsWith('.bin')) {
              sizes[p.basename(e.path)] = await e.length();
            }
          }
        } catch (_) {
          return false;
        }
        for (final name in expected) {
          final len = sizes[name];
          if (len == null || len == 0) return false;
          if (sm.layerBinSizeBytes > 0 && len != sm.layerBinSizeBytes) {
            return false;
          }
        }
      }
      return true;
    } catch (_) {
      return false;
    }
  }

  /// 完成判定：文件存在、非空、无残留 `.tmp` 即完整。
  /// 不再按 catalog 估算大小卡百分比——下载中断残留 `.tmp` 会被识别为不完整。
  Future<bool> _isCompleteFile(File file) async {
    try {
      if (!await file.exists()) return false;
      if (await file.length() == 0) return false;
      final tmp = File('${file.path}.tmp');
      if (await tmp.exists()) return false;
      return true;
    } catch (_) {
      return false;
    }
  }

  /// 主文件（`.gguf` / `.mmproj`）已完整时，清理上次中断下载残留的对应 `.tmp`。
  /// 失败静默忽略（尽力而为的自愈），不影响缓存判定结果。
  Future<void> _cleanStaleTmp(Directory dir, String modelId, String suffix) async {
    try {
      final tmp = File(p.join(dir.path, '$modelId$suffix.tmp'));
      if (await tmp.exists()) {
        await tmp.delete();
        debugPrint('[ModelStorage] 清理残留 $suffix.tmp: ${tmp.path}');
      }
    } catch (_) {}
  }

  /// 返回所有可能的模型存储目录（主目录 + 内部 + Download + DCIM + app docs），
  /// 与 [scanExistingModels] 的扫描范围保持一致，避免"主目录 vs 多位置"矛盾。
  ///
  /// 已按 [pathDedupeKey] 去重：`/data/data/<pkg>` 与 `/data/user/0/<pkg>` 是同一
  /// 物理目录，不去重会让"存在性检查/递归查找"对同一目录重复遍历两遍。
  Future<List<Directory>> _allCandidateDirs() async {
    final paths = <String>[];

    paths.add(await _resolveExternalModelsDir());

    // 内部存储（app_flutter/models）
    paths.add('/data/data/$_packageName/app_flutter/models');

    // 系统广目录（用户手动放入模型文件）
    paths.add('/sdcard/Download');
    paths.add('/sdcard/DCIM');

    // 回退目录（applicationDocumentsDirectory/models）
    try {
      final appDir = await getApplicationDocumentsDirectory();
      paths.add(p.join(appDir.path, 'models'));
    } catch (_) {}

    // 注意：去重后仍保留原始字符串形态，`_findFile` 对 Download/DCIM
    // 的字符串判断依赖这一点。
    return _dedupeDirs(paths);
  }

  /// Get local file size if cached
  Future<int> getCachedSize(String modelId) async {
    try {
      final path = await getModelPath(modelId);
      final file = File(path);
      if (await file.exists()) {
        return await file.length();
      }
    } catch (_) {}
    return 0;
  }

  /// Check total cached model size in bytes
  Future<int> getTotalCachedSize() async {
    try {
      final dir = await getModelsRootDir();
      if (!await dir.exists()) return 0;
      
      int total = 0;
      await for (final entity in dir.list(recursive: true)) {
        if (entity is File &&
            (entity.path.endsWith('.gguf') ||
                entity.path.endsWith('.mmproj') ||
                entity.path.endsWith('.bin'))) {
          total += await entity.length();
        }
      }
      return total;
    } catch (_) {
      return 0;
    }
  }

  /// Scan for existing models on device（多位置扫描）
  ///
  /// 目录级去重：`/data/data/<pkg>` 与 `/data/user/0/<pkg>` 是同一物理目录，
  /// 重复扫描只是白耗 IO（且会把同一个模型 id 反复 add）。
  Future<List<String>> scanExistingModels() async {
    final cachedIds = <String>{};
    final seenDirs = <String>{};

    Future<void> scanAt(String path, {bool recursive = true}) async {
      if (!seenDirs.add(await _dedupeKeyFor(path))) return;
      await _scanDirectory(Directory(path), cachedIds, recursive: recursive);
    }

    // 1. 扫描外部存储主目录（递归，模型通常直接放这里）
    await scanAt(await _resolveExternalModelsDir());

    // 2. 扫描内部存储（app_flutter/models）- Flutter 默认存储位置
    await scanAt('/data/data/$_packageName/app_flutter/models');

    // 3. 扫描 Download / DCIM 目录（仅顶层，避免递归扫全盘导致极慢/权限异常）
    await scanAt('/sdcard/Download', recursive: false);
    await scanAt('/sdcard/DCIM', recursive: false);

    // 4. 回退到 applicationDocumentsDirectory
    try {
      final appDir = await getApplicationDocumentsDirectory();
      await scanAt(p.join(appDir.path, 'models'));
    } catch (_) {}

    debugPrint('[ModelStorage] Found ${cachedIds.length} cached models: $cachedIds');
    return cachedIds.toList();
  }

  /// Scan directory for .gguf files. [recursive] 控制是否递归子目录；
  /// 系统广目录（Download/DCIM）应传 false，避免扫全盘。
  Future<void> _scanDirectory(Directory dir, Set<String> cachedIds, {bool recursive = true}) async {
    if (!await dir.exists()) return;
    
    try {
      await for (final entity in dir.list(recursive: recursive)) {
        if (entity is File && entity.path.endsWith('.gguf')) {
          final id = p.basenameWithoutExtension(entity.path);
          cachedIds.add(id);
        }
      }
    } catch (e) {
      debugPrint('[ModelStorage] Scan error in ${dir.path}: $e');
    }
  }

  /// Format file size for display
  static String formatSize(int bytes) {
    if (bytes >= 1024 * 1024 * 1024) {
      return '${(bytes / 1024 / 1024 / 1024).toStringAsFixed(1)} GB';
    }
    if (bytes >= 1024 * 1024) {
      return '${(bytes / 1024 / 1024).toStringAsFixed(0)} MB';
    }
    if (bytes >= 1024) {
      return '${(bytes / 1024).toStringAsFixed(0)} KB';
    }
    return '$bytes B';
  }

  /// Get the public storage path for user reference
  static String getPublicStoragePath() => p.join('/sdcard', _appFolder, 'models');
}

/// Global singleton access
final modelStorageService = ModelStorageService();
