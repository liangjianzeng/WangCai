import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../services/model_display_service.dart';

/// 持有「模型 ID → 用户自定义显示名称」的映射，并在变更时持久化到本地文件。
///
/// 聊天页右上角模型状态 chip 在模型加载后优先显示该名称，
/// 未设置时回落到默认的「模型就绪」状态文案。
class ModelDisplayNameNotifier extends StateNotifier<Map<String, String>> {
  final ModelDisplayNameService _service;

  ModelDisplayNameNotifier(this._service) : super(const {}) {
    _load();
  }

  Future<void> _load() async {
    final map = await _service.load();
    if (mounted) state = map;
  }

  /// 设置（或清空）某模型的自定义名称。空白名称等价于删除该条目。
  Future<void> setName(String modelId, String name) async {
    final trimmed = name.trim();
    final next = Map<String, String>.from(state);
    if (trimmed.isEmpty) {
      next.remove(modelId);
    } else {
      next[modelId] = trimmed;
    }
    state = next;
    try {
      await _service.save(next);
    } catch (_) {
      // 持久化失败不阻断 UI；内存状态已更新。
    }
  }

  /// 读取某模型的自定义名称（未设置返回 null）。
  String? nameFor(String? modelId) =>
      modelId == null ? null : state[modelId];
}

final modelDisplayNameServiceProvider =
    Provider<ModelDisplayNameService>((ref) => ModelDisplayNameService());

final modelDisplayNameProvider =
    StateNotifierProvider<ModelDisplayNameNotifier, Map<String, String>>((ref) {
  final service = ref.watch(modelDisplayNameServiceProvider);
  return ModelDisplayNameNotifier(service);
});
