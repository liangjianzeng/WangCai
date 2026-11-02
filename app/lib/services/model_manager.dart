import 'dart:io';

import '../models/model_catalog.dart';
import '../models/model_info.dart';
import 'model_storage_service.dart';

/// Manages model caching and local storage.
/// Delegates download logic to DownloadService; this class only handles
/// file-system queries (isModelCached, getCachedSize, allModels, etc.).
///
/// 模型目录由 [ModelCatalog] 从 assets/models_catalog.json（可选远程）加载，
/// 不再写死在代码里。应用启动时需调用一次 [init()]。
///
/// **持久化策略**：使用 [ModelStorageService] 管理存储路径，优先使用外部存储，
/// 确保重新安装 APK 后模型文件不丢失。
class ModelManager {
  static final ModelManager _instance = ModelManager._internal();
  factory ModelManager() => _instance;
  ModelManager._internal();

  List<ModelConfig> _models = const [];

  /// 应用启动时调用一次：从配置文件（可选远程）加载模型目录。
  Future<void> init() async {
    _models = await ModelCatalog.load();
  }

  /// 所有可用模型（加载完成前为空列表）。
  List<ModelConfig> get allModels => _models;

  /// 取推荐/默认模型。
  ModelConfig? get recommendedModel {
    if (_models.isEmpty) return null;
    for (final m in _models) {
      if (m.recommended) return m;
    }
    return _models.first;
  }

  /// 按 ID 取模型。
  ModelConfig? getModel(String id) {
    for (final m in _models) {
      if (m.id == id) return m;
    }
    return null;
  }

  /// 获取模型文件的完整路径
  Future<String?> getModelPath(String modelId) async {
    try {
      final storage = ModelStorageService();
      final path = await storage.getModelPath(modelId);
      if (File(path).existsSync()) {
        return path;
      }
    } catch (_) {}
    return null;
  }

  /// Check if model file exists locally
  Future<bool> isModelCached(String modelId) async {
    final storage = ModelStorageService();
    return await storage.isModelCached(modelId);
  }

  /// Get local file size if cached
  Future<int> getCachedSize(String modelId) async {
    final storage = ModelStorageService();
    return await storage.getCachedSize(modelId);
  }

  /// Check total cached model size in bytes
  Future<int> getTotalCachedSize() async {
    final storage = ModelStorageService();
    return await storage.getTotalCachedSize();
  }

  /// Scan for existing models on device (for recovery after reinstall)
  Future<List<String>> scanExistingModels() async {
    final storage = ModelStorageService();
    return await storage.scanExistingModels();
  }

}
