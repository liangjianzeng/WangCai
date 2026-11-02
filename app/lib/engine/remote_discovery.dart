// 远端模型发现（设计 §6 第 2 件事）：GET {base}/v1/models → 模型 id 列表
// → 绑定条目（openai-remote × api:<modelId>）。dio 可注入，测试离线。
import 'package:dio/dio.dart';

import 'bindings_store.dart';

class RemoteDiscovery {
  RemoteDiscovery({Dio? dio})
      : _dio = dio ??
            Dio(BaseOptions(
              connectTimeout: const Duration(seconds: 8),
              receiveTimeout: const Duration(seconds: 12),
            ));

  final Dio _dio;

  static String _v1(String base) => base.endsWith('/v1')
      ? base
      : '${base.replaceAll(RegExp(r'/+$'), '')}/v1';

  Future<List<String>> discoverModels(
      {required String baseUrl, String? apiKey}) async {
    final res = await _dio.get('${_v1(baseUrl)}/models',
        options: Options(headers: {
          if (apiKey != null && apiKey.isNotEmpty)
            'Authorization': 'Bearer $apiKey',
        }));
    final data = res.data is Map ? res.data['data'] : null;
    if (data is! List) return const [];
    return [
      for (final e in data)
        if (e is Map && e['id'] != null) '${e['id']}',
    ];
  }

  /// 发现并写入绑定表（远端条目：device='remote'、status=usable；baseUrl
  /// 记在 presetJson 供路由展示。远端实测 t/s 无本地 timings 口径，不回写）。
  Future<List<String>> discoverAndBind({
    required BindingsStore bindings,
    required String baseUrl,
    String? apiKey,
    String engineId = 'openai-remote',
  }) async {
    final ids = await discoverModels(baseUrl: baseUrl, apiKey: apiKey);
    for (final id in ids) {
      await bindings.put(Binding(
        engineId: engineId,
        modelId: 'api:$id',
        device: 'remote',
        status: BindingStatus.usable,
        presetJson: baseUrl,
      ));
    }
    return ids;
  }
}
