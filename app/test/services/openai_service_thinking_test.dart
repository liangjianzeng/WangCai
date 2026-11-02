import 'package:flutter_test/flutter_test.dart';

import 'package:tongyi_lite/models/api_model.dart';
import 'package:tongyi_lite/services/openai_service.dart';

/// 思考强度字段落到请求体后的**可用性防线**：族判错时不能让整条 API 智能体
/// 不可用（严格端点对未知字段直接 400/422），必须能整组去掉重发。
ApiModelConfig _cfg({String? effort, String? family}) => ApiModelConfig(
      id: 'm1',
      name: '测试端点',
      baseUrl: 'https://api.example.com/v1',
      apiKey: 'k',
      model: 'some-model',
      thinkingEffort: effort,
      thinkingFamily: family,
    );

void main() {
  group('400 兜底：去掉被拒字段再发一次', () {
    Map<String, dynamic> body() => {
          'model': 'm',
          'messages': const [],
          'stream': true,
          'stream_options': const {'include_usage': true},
          'max_tokens': 1024,
          'chat_template_kwargs': const {'enable_thinking': true},
          'enable_thinking': true,
        };

    test('点名 chat_template_kwargs → 只去思考字段，usage 与其余字段留着', () {
      final r = OpenAiService.bodyWithoutRejectedFields(
          body(), "Error: Unexpected value for 'chat_template_kwargs'");
      expect(r, isNotNull);
      expect(r!.containsKey('chat_template_kwargs'), isFalse);
      expect(r.containsKey('enable_thinking'), isFalse);
      expect(r.containsKey('stream_options'), isTrue);
      expect(r.containsKey('max_tokens'), isTrue);
    });

    test('不点名、只说 unknown parameter → 思考字段整组去掉（宁可丢档位）', () {
      final r = OpenAiService.bodyWithoutRejectedFields(
          body(), '400 Bad Request: unknown parameter in request body');
      expect(r, isNotNull);
      expect(r!.containsKey('chat_template_kwargs'), isFalse);
      expect(r.containsKey('enable_thinking'), isFalse);
      expect(r.containsKey('stream_options'), isTrue,
          reason: 'stream_options 更基础，不因泛化报错被顺带丢掉');
    });

    test('原有 stream_options 兜底不受影响（回归）', () {
      final r = OpenAiService.bodyWithoutRejectedFields(
          body(), "1 validation error: 'stream_options' Extra inputs are not permitted");
      expect(r, isNotNull);
      expect(r!.containsKey('stream_options'), isFalse);
      expect(r.containsKey('chat_template_kwargs'), isTrue,
          reason: '报错没点思考字段，就不该顺带动思考档位');
    });

    test('真实业务错误（鉴权/超长）不乱去字段，交回调用方报错', () {
      expect(
          OpenAiService.bodyWithoutRejectedFields(body(), '401 Unauthorized'),
          isNull);
      expect(
          OpenAiService.bodyWithoutRejectedFields(
              body(), 'This model’s maximum context length is 8192 tokens'),
          isNull);
    });

    test('body 里没有可去字段时返回 null（不空转重试）', () {
      expect(
          OpenAiService.bodyWithoutRejectedFields(
              {'model': 'm', 'messages': const []}, 'unknown parameter'),
          isNull);
    });
  });

  group('每条 API 配置独立存思考档位（不做全局 bool）', () {
    test('思考档位与族覆盖随配置落盘并可往返', () {
      final c = _cfg(effort: 'high', family: 'vllm');
      final back = ApiModelConfig.fromJson(c.toJson());
      expect(back.thinkingEffort, 'high');
      expect(back.thinkingFamily, 'vllm');
    });

    test('旧配置（无这两个键）读出 null = 不干预，行为与旧版一致', () {
      final legacy = ApiModelConfig.fromJson({
        'id': 'm1',
        'name': '老配置',
        'baseUrl': 'https://api.example.com/v1',
        'apiKey': 'k',
        'model': 'some-model',
      });
      expect(legacy.thinkingEffort, isNull);
      expect(legacy.thinkingFamily, isNull);
    });

    test('copyWith 能显式清除（关档位 ≠ 不改；两者必须可区分）', () {
      final c = _cfg(effort: 'low', family: 'qwen');
      expect(c.copyWith(thinkingEffort: 'off').thinkingEffort, 'off');
      expect(c.copyWith(clearThinkingEffort: true).thinkingEffort, isNull);
      expect(c.copyWith(clearThinkingFamily: true).thinkingFamily, isNull);
      expect(c.copyWith().thinkingEffort, 'low', reason: '不传即保持原值');
    });
  });
}
