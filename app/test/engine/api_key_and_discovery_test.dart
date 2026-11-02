// M2-d 离线单测：API key 安全存储迁移/叠加/清洗（§6.1）+ /v1/models 发现
// 与绑定条目生成（§6 第 2 件事）。dio 用假 adapter，全程不联网。
import 'dart:typed_data';

import 'package:dio/dio.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';
import 'package:tongyi_lite/engine/bindings_store.dart';
import 'package:tongyi_lite/engine/remote_discovery.dart';
import 'package:tongyi_lite/models/api_model.dart';
import 'package:tongyi_lite/services/api_key_store.dart';
import 'package:tongyi_lite/services/settings_service.dart';

ApiModelConfig api(String id, String key) => ApiModelConfig(
    id: id, name: id, baseUrl: 'https://api.x.com', apiKey: key, model: 'm-$id');

void main() {
  setUpAll(() {
    sqfliteFfiInit();
    databaseFactory = databaseFactoryFfi;
    BindingsStore.databaseFactoryFfiForTest = databaseFactoryFfi;
  });
  tearDown(() {
    // 每例还原注入点，避免串台。
    apiKeyStore = MemoryApiKeyStore();
  });

  group('API key 安全存储（§6.1）', () {
    test('migrate：明文→store、JSON 清空、幂等', () async {
      final mem = MemoryApiKeyStore();
      apiKeyStore = mem;
      final s = InferenceSettings(apiModels: [api('a1', 'sk-123'), api('a2', '')]);
      final out = await migrateApiKeysToSecure(s);
      expect(out.apiModels[0].apiKey, '', reason: 'JSON 侧清空');
      expect(await mem.read('a1'), 'sk-123', reason: 'store 侧有真钥');
      final again = await migrateApiKeysToSecure(out);
      expect(again.apiModels[0].apiKey, '');
      expect(await mem.read('a1'), 'sk-123');
    });

    test('migrate fail-open：写不进去就保留明文（连接不断）', () async {
      apiKeyStore = _ThrowingStore();
      final s = InferenceSettings(apiModels: [api('a1', 'sk-123')]);
      final out = await migrateApiKeysToSecure(s);
      expect(out.apiModels[0].apiKey, 'sk-123', reason: 'fail-open 保留明文');
    });

    test('overlay：内存态带回真钥；redact：落盘前清干净', () async {
      final mem = MemoryApiKeyStore();
      apiKeyStore = mem;
      await mem.write('a1', 'sk-999');
      final base = InferenceSettings(apiModels: [api('a1', '')]);
      final withKey = await overlayApiKeys(base);
      expect(withKey.apiModels[0].apiKey, 'sk-999');
      final redacted = redactApiKeys(withKey);
      expect(redacted.apiModels[0].apiKey, '', reason: 'JSON 不落明文');
      expect(withKey.apiModels[0].apiKey, 'sk-999', reason: '内存态保留');
    });
  });

  group('远端模型发现（§6）', () {
    late Dio dio;
    late List<String> seenUrls;
    setUp(() {
      seenUrls = [];
      dio = Dio()..httpClientAdapter = _FakeAdapter((opts) {
        seenUrls.add('${opts.uri}');
        return ResponseBody.fromString(
          '{"object":"list","data":[{"id":"gpt-4o","object":"model"},'
          '{"id":"qwen2.5-32b-instruct"},{"object":"model"}]}',
          200,
          headers: {
            Headers.contentTypeHeader: [Headers.jsonContentType],
          },
        );
      });
    });

    test('discoverModels：解析 id 列表；base 无 /v1 自动补；带 Bearer', () async {
      final d = RemoteDiscovery(dio: dio);
      final ids = await d.discoverModels(
          baseUrl: 'https://api.x.com/', apiKey: 'sk-k');
      expect(ids, ['gpt-4o', 'qwen2.5-32b-instruct']);
      expect(seenUrls.single, contains('/v1/models'));
    });

    test('discoverAndBind：绑定表生成 api: 条目（remote/usable/baseUrl 留痕）',
        () async {
      final store = await BindingsStore.inMemory();
      addTearDown(store.close);
      final d = RemoteDiscovery(dio: dio);
      final ids = await d.discoverAndBind(
          bindings: store, baseUrl: 'https://api.x.com', apiKey: 'sk');
      expect(ids, hasLength(2));
      final rows = await store.forModel('api:gpt-4o');
      expect(rows.single.engineId, 'openai-remote');
      expect(rows.single.device, 'remote');
      expect(rows.single.status, BindingStatus.usable);
      expect(rows.single.presetJson, 'https://api.x.com');
    });
  });
}

class _ThrowingStore implements ApiKeyStore {
  @override
  Future<String?> read(String modelId) async => null;
  @override
  Future<void> write(String modelId, String key) async =>
      throw StateError('secure storage unavailable');
  @override
  Future<void> delete(String modelId) async {}
}

class _FakeAdapter implements HttpClientAdapter {
  _FakeAdapter(this.handler);
  final ResponseBody Function(RequestOptions opts) handler;

  @override
  void close({bool force = false}) {}

  @override
  Future<ResponseBody> fetch(RequestOptions options,
      Stream<Uint8List>? requestStream, Future<void>? cancelFuture) async {
    return handler(options);
  }
}
