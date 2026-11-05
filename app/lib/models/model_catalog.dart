// ============================================================
// 模型目录加载器（配置文件驱动）
// 模型列表维护在 assets/models_catalog.json。
// 新增/调整模型只需改 JSON，无需改动代码或重新编译。
// 可选：把 [remoteUrl] 指向自有 CDN 上的同名 JSON，即可在发版后热更新模型列表。
// ============================================================

import 'dart:convert';

import 'package:dio/dio.dart';
import 'package:flutter/foundation.dart' show debugPrint;
import 'package:flutter/services.dart' show rootBundle;

import 'model_info.dart';

class ModelCatalog {
  /// 打包在 App 内的默认目录（兜底用）。
  static const String assetPath = 'assets/models_catalog.json';

  /// 可选的远程目录地址。设为 null 则只使用打包的 JSON。
  /// 部署到自有 CDN 后改成 "https://your-cdn.example.com/models_catalog.json"
  /// 即可热更新，无需发版。远程拉取失败会自动回退到打包版本。
  static const String? remoteUrl = null;

  static List<ModelConfig>? _cache;

  /// 加载模型目录（带内存缓存，进程内只解析一次）。
  static Future<List<ModelConfig>> load() async {
    if (_cache != null) return _cache!;

    List<ModelConfig> models;
    if (remoteUrl != null && remoteUrl!.isNotEmpty) {
      try {
        models = await _loadRemote(remoteUrl!);
      } catch (e) {
        // 远程不可达/解析失败 → 回退到打包 JSON，保证可用。
        models = await _loadBundled();
      }
    } else {
      models = await _loadBundled();
    }

    _cache = models;
    return models;
  }

  /// 强制重新加载（例如手动刷新、远程配置变更后）。
  static Future<List<ModelConfig>> reload() async {
    _cache = null;
    return load();
  }

  static Future<List<ModelConfig>> _loadBundled() async {
    final str = await rootBundle.loadString(assetPath);
    return _parse(str);
  }

  static Future<List<ModelConfig>> _loadRemote(String url) async {
    final resp = await Dio().get<String>(
      url,
      options: Options(receiveTimeout: const Duration(seconds: 8)),
    );
    return _parse(resp.data!);
  }

  static List<ModelConfig> _parse(String str) {
    final data = jsonDecode(str) as Map<String, dynamic>;
    final list = (data['models'] as List).cast<Map<String, dynamic>>();
    return list.map(ModelConfig.fromJson).toList();
  }
}

/// Lazily loaded list of all models from the catalog (assets JSON or remote).
Future<List<ModelConfig>> loadModelCatalog() async {
  try {
    return await ModelCatalog.load();
  } catch (e) {
    debugPrint('[ModelCatalog] Failed to load model catalog: $e');
    return [];
  }
}

/// Recommended model — the first one with recommended:true, or the smallest.
Future<ModelConfig?> recommendedModel() async {
  final models = await loadModelCatalog();
  if (models.isEmpty) return null;
  return models.firstWhere(
    (m) => m.recommended,
    orElse: () => models.reduce((a, b) => a.sizeBytes < b.sizeBytes ? a : b),
  );
}
