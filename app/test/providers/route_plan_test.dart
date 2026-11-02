import 'package:tongyi_lite/models/api_model.dart';
import 'package:tongyi_lite/providers/chat_provider.dart';
import 'package:tongyi_lite/services/settings_service.dart';
import 'package:flutter_test/flutter_test.dart';

// ---------------------------------------------------------------------------
// 生成路由决策（2026-09-29 修复"没勾默认模型却莫名自动加载本地模型"）
//
// 不变量：无本地意图（未加载模型 且 未勾选默认）时，绝不返回本地加载计划
// ——出厂占位 id 不得成为隐式加载触发器；有激活 API 走 API，没有则报错指引。
// ---------------------------------------------------------------------------

const _api = ApiModelConfig(
  id: 'api-1',
  name: 'DeepSeek',
  baseUrl: 'https://api.deepseek.com/v1',
  apiKey: 'sk-test',
  model: 'deepseek-chat',
);

InferenceSettings _settings({
  String? defaultModelId,
  List<ApiModelConfig> apiModels = const [],
  String? activeApiModelId,
}) =>
    InferenceSettings(
      defaultModelId: defaultModelId,
      apiModels: apiModels,
      activeApiModelId: activeApiModelId,
    );

void main() {
  group('planGenerationRoute：无本地意图', () {
    test('未勾默认+未加载+API 激活 → 直接走 API（不加载本地）', () {
      final plan = planGenerationRoute(
        settings: _settings(apiModels: [_api], activeApiModelId: 'api-1'),
        localLoaded: false,
        loadedModelId: null,
        fallbackModelId: 'qwen3.5-2b-mtp-ud-q4_k_xl',
      );
      expect(plan.useApi, isTrue);
      expect(plan.localModelId, isNull);
      expect(plan.error, isNull);
    });

    test('未勾默认+未加载+无 API → failure（绝不隐式加载占位模型）', () {
      final plan = planGenerationRoute(
        settings: _settings(),
        localLoaded: false,
        loadedModelId: null,
        fallbackModelId: 'qwen3.5-2b-mtp-ud-q4_k_xl',
      );
      expect(plan.useApi, isFalse);
      expect(plan.localModelId, isNull);
      expect(plan.error, isNotNull);
      expect(plan.error, contains('未配置任何模型'));
    });

    test('API 已配置但未激活，视同无 API → failure', () {
      final plan = planGenerationRoute(
        settings: _settings(apiModels: [_api]),
        localLoaded: false,
        loadedModelId: null,
        fallbackModelId: 'qwen3.5-2b-mtp-ud-q4_k_xl',
      );
      expect(plan.error, isNotNull);
    });
  });

  group('planGenerationRoute：有本地意图', () {
    test('勾选了默认+未加载 → local(默认模型)', () {
      final plan = planGenerationRoute(
        settings: _settings(defaultModelId: 'qwen3.5-4b'),
        localLoaded: false,
        loadedModelId: null,
        fallbackModelId: 'qwen3.5-2b-mtp-ud-q4_k_xl',
      );
      expect(plan.useApi, isFalse);
      expect(plan.localModelId, 'qwen3.5-4b');
    });

    test('已加载 X+无默认 → local(X)（沿用已加载，不换模型）', () {
      final plan = planGenerationRoute(
        settings: _settings(),
        localLoaded: true,
        loadedModelId: 'bonsai-27b',
        fallbackModelId: 'qwen3.5-2b-mtp-ud-q4_k_xl',
      );
      expect(plan.useApi, isFalse);
      expect(plan.localModelId, 'bonsai-27b');
    });

    test('已加载 X+默认 Y → local(X)：已加载优先（local-first 语义不变）', () {
      final plan = planGenerationRoute(
        settings: _settings(defaultModelId: 'qwen3.5-4b'),
        localLoaded: true,
        loadedModelId: 'bonsai-27b',
        fallbackModelId: 'qwen3.5-2b-mtp-ud-q4_k_xl',
      );
      expect(plan.localModelId, 'bonsai-27b');
    });
  });

  group('resolveExplicitLocalTarget：智能体显式本地驱动', () {
    test('agentModelId 优先', () {
      expect(
        resolveExplicitLocalTarget(
          agentModelId: 'm1',
          defaultModelId: 'm2',
          localLoaded: true,
          loadedModelId: 'm3',
        ),
        'm1',
      );
    });

    test('无 agentModelId → 默认勾选', () {
      expect(
        resolveExplicitLocalTarget(
          agentModelId: null,
          defaultModelId: 'm2',
          localLoaded: true,
          loadedModelId: 'm3',
        ),
        'm2',
      );
    });

    test('无指定+已加载 → 已加载模型', () {
      expect(
        resolveExplicitLocalTarget(
          agentModelId: null,
          defaultModelId: null,
          localLoaded: true,
          loadedModelId: 'm3',
        ),
        'm3',
      );
    });

    test('什么都没有 → null（调用方必须报错，不许隐式加载占位 id）', () {
      expect(
        resolveExplicitLocalTarget(
          agentModelId: null,
          defaultModelId: null,
          localLoaded: false,
          loadedModelId: null,
        ),
        isNull,
      );
    });

    test('空字符串视同未指定', () {
      expect(
        resolveExplicitLocalTarget(
          agentModelId: '',
          defaultModelId: '',
          localLoaded: false,
          loadedModelId: null,
        ),
        isNull,
      );
    });
  });
}
