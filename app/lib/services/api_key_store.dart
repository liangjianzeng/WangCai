// API Key 安全存储（设计 §6.1）：密钥不落 inference_settings.json 明文。
//   生产 = flutter_secure_storage（Windows 走 DPAPI）；安全存储不可用时
//   fail-open 保留明文（连接不断，同 ssh secret_store 先例口径）。
//   load → [migrateApiKeysToSecure]+[overlayApiKeys]；save 前走 [redactApiKeys]。
import 'package:flutter_secure_storage/flutter_secure_storage.dart';

import '../models/api_model.dart';
import 'settings_service.dart' show InferenceSettings;

const String _keyPrefix = 'wangcai.apikey.';

abstract class ApiKeyStore {
  Future<String?> read(String modelId);
  Future<void> write(String modelId, String key);
  Future<void> delete(String modelId);
}

/// 生产实现（Windows=DPAPI；Android=Keystore）。
class SecureApiKeyStore implements ApiKeyStore {
  const SecureApiKeyStore([FlutterSecureStorage? storage])
      : _s = storage ??
            const FlutterSecureStorage(
                aOptions: AndroidOptions(encryptedSharedPreferences: true));

  final FlutterSecureStorage _s;

  @override
  Future<String?> read(String modelId) => _s.read(key: '$_keyPrefix$modelId');

  @override
  Future<void> write(String modelId, String key) =>
      _s.write(key: '$_keyPrefix$modelId', value: key);

  @override
  Future<void> delete(String modelId) async {
    if (await _s.containsKey(key: '$_keyPrefix$modelId')) {
      await _s.delete(key: '$_keyPrefix$modelId');
    }
  }
}

/// 测试/降级实现（安全存储不可用时的兜底：退回原语义=明文镜像）。
class MemoryApiKeyStore implements ApiKeyStore {
  final Map<String, String> _m = {};
  @override
  Future<String?> read(String modelId) async => _m[modelId];
  @override
  Future<void> write(String modelId, String key) async {
    _m[modelId] = key;
  }

  @override
  Future<void> delete(String modelId) async {
    _m.remove(modelId);
  }
}

/// 可替换点（测试注入 MemoryApiKeyStore；不可用环境注入 Memory 以 fail-open）。
ApiKeyStore apiKeyStore = SecureApiKeyStore();

/// 启动时一次性迁移：JSON 明文密钥 → 安全存储，JSON 侧清空。
/// 返回应落盘的设置（密钥已清）；已迁移/无密钥则原样返回（幂等）。
Future<InferenceSettings> migrateApiKeysToSecure(InferenceSettings s) async {
  final dirty = s.apiModels.any((m) => m.apiKey.isNotEmpty);
  if (!dirty) return s;
  final moved = <ApiModelConfig>[];
  for (final m in s.apiModels) {
    if (m.apiKey.isNotEmpty) {
      try {
        await apiKeyStore.write(m.id, m.apiKey);
      } catch (_) {
        moved.add(m); // 安全存储不可用：保留明文（fail-open）
        continue;
      }
      moved.add(m.copyWith(apiKey: ''));
    } else {
      moved.add(m);
    }
  }
  return s.copyWith(apiModels: moved);
}

/// 读取后叠加：内存态带上安全存储里的真实密钥（供 OpenAiService 发请求）。
/// 读不到（新机/被清）→ 空串，保持旧行为。
Future<InferenceSettings> overlayApiKeys(InferenceSettings s) async {
  if (s.apiModels.isEmpty) return s;
  final overlaid = <ApiModelConfig>[];
  for (final m in s.apiModels) {
    if (m.apiKey.isNotEmpty) {
      overlaid.add(m);
      continue;
    }
    try {
      final k = await apiKeyStore.read(m.id);
      overlaid.add(k == null || k.isEmpty ? m : m.copyWith(apiKey: k));
    } catch (_) {
      overlaid.add(m);
    }
  }
  return s.copyWith(apiModels: overlaid);
}

/// 落盘前清洗：内存态的密钥不写入 JSON（overlay 之后 state 里有真钥）。
InferenceSettings redactApiKeys(InferenceSettings s) => s.copyWith(
      apiModels: [
        for (final m in s.apiModels)
          m.apiKey.isEmpty ? m : m.copyWith(apiKey: ''),
      ],
    );

// 'copyWith 技巧'：用空壳 const 构造再逐字段覆盖，避免维护第二套字段清单。
