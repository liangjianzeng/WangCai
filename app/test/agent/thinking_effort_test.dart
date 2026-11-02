import 'package:flutter_test/flutter_test.dart';

import 'package:tongyi_lite/agent/llm/thinking_effort.dart';

void main() {
  group('思考强度 · 族探测（各家发各家认的字段，先具体后通用）', () {
    test('DeepSeek / Kimi 走 thinking.type，跑在 vLLM 上也不改发模板参数', () {
      expect(detectThinkingFamily('deepseek-reasoner'),
          ThinkingFamily.thinkingType);
      expect(detectThinkingFamily('deepseek-v3.2-exp'),
          ThinkingFamily.thinkingType);
      expect(detectThinkingFamily('kimi-k2-thinking-turbo'),
          ThinkingFamily.thinkingType);
      // 自托管上跑 deepseek：厂商族优先，不能被 vLLM 分流抢走
      expect(
          detectThinkingFamily('deepseek-r1-distill',
              baseUrl: 'http://127.0.0.1:8090/v1'),
          ThinkingFamily.thinkingType);
    });

    test('GLM 走 thinking.enabled，Claude 走 budget，Gemini 走 thinking_config',
        () {
      expect(detectThinkingFamily('glm-4.6'), ThinkingFamily.thinkingEnabled);
      expect(detectThinkingFamily('claude-sonnet-4-5'),
          ThinkingFamily.anthropicThinking);
      expect(detectThinkingFamily('gemini-3-flash'),
          ThinkingFamily.geminiThinkingConfig);
    });

    test('OpenAI o/gpt-5 系与 grok/minimax 走 reasoning_effort', () {
      for (final m in ['gpt-5', 'gpt-5.1-mini', 'o3-mini', 'o4-mini',
        'grok-4-fast', 'minimax-m2']) {
        expect(detectThinkingFamily(m), ThinkingFamily.reasoningEffort,
            reason: m);
      }
    });

    test('Qwen 按端点分流：DashScope 顶层开关，自托管走 chat_template_kwargs',
        () {
      expect(
          detectThinkingFamily('qwen3-30b-a3b',
              baseUrl: 'https://dashscope.aliyuncs.com/compatible-mode/v1'),
          ThinkingFamily.qwenEnableThinking);
      expect(
          detectThinkingFamily('qwen3-4b-instruct',
              baseUrl: 'http://192.168.1.20:8000/v1'),
          ThinkingFamily.vllmChatTemplateKwargs);
    });

    test('族不明的云端端点什么都不发（绝不盲传把用户打成不可用）', () {
      expect(detectThinkingFamily('some-unknown-model',
          baseUrl: 'https://api.somevendor.example/v1'), ThinkingFamily.none);
      // 明显 OpenAI 才允许 reasoning_effort
      expect(detectThinkingFamily('some-unknown-model',
          baseUrl: 'https://api.openai.com/v1'),
          ThinkingFamily.reasoningEffort);
    });
  });

  group('思考强度 · 请求体映射（唯一真源）', () {
    test('不干预 = 一个字段都不发（与旧版逐字节一致）', () {
      for (final f in ThinkingFamily.values) {
        expect(
            thinkingWireFields(
                effort: ThinkingEffort.passthrough, family: f, maxTokens: 8192),
            isEmpty,
            reason: '${f.name} 不该发任何思考字段');
      }
      // 未知族同样不发
      expect(
          thinkingWireFields(
              effort: ThinkingEffort.high,
              family: ThinkingFamily.none,
              maxTokens: 8192),
          isEmpty);
    });

    test('reasoning_effort 族：四档取值合法，off 退到最省的 minimal', () {
      expect(
          thinkingWireFields(
              effort: ThinkingEffort.low,
              family: ThinkingFamily.reasoningEffort)['reasoning_effort'],
          'low');
      expect(
          thinkingWireFields(
              effort: ThinkingEffort.medium,
              family: ThinkingFamily.reasoningEffort)['reasoning_effort'],
          'medium');
      expect(
          thinkingWireFields(
              effort: ThinkingEffort.high,
              family: ThinkingFamily.reasoningEffort)['reasoning_effort'],
          'high');
      expect(
          thinkingWireFields(
              effort: ThinkingEffort.off,
              family: ThinkingFamily.reasoningEffort)['reasoning_effort'],
          'minimal');
    });

    test('Anthropic：budget_tokens 必须严格小于 max_tokens（否则 400）', () {
      final w = thinkingWireFields(
          effort: ThinkingEffort.high,
          family: ThinkingFamily.anthropicThinking,
          maxTokens: 3000);
      final budget = (w['thinking'] as Map)['budget_tokens'] as int;
      expect(budget, lessThan(3000));
      expect(budget, greaterThan(0));
      expect((w['thinking'] as Map)['type'], 'enabled');
      // 小预算端点也不能倒挂
      final tiny = thinkingWireFields(
          effort: ThinkingEffort.high,
          family: ThinkingFamily.anthropicThinking,
          maxTokens: 400);
      expect((tiny['thinking'] as Map)['budget_tokens'],
          lessThanOrEqualTo(400));
      // 关思考发显式 disabled，而不是不发（让模型确实别想）
      final off = thinkingWireFields(
          effort: ThinkingEffort.off,
          family: ThinkingFamily.anthropicThinking,
          maxTokens: 8192);
      expect((off['thinking'] as Map)['type'], 'disabled');
    });

    test('Gemini：关思考用 0 而不是缺省（缺省=模型自适应，档位要可控）', () {
      final off = thinkingWireFields(
          effort: ThinkingEffort.off,
          family: ThinkingFamily.geminiThinkingConfig,
          maxTokens: 8192);
      expect((off['thinking_config'] as Map)['thinking_budget'], 0);
      expect((off['thinking_config'] as Map)['include_thoughts'], false);
      final high = thinkingWireFields(
          effort: ThinkingEffort.high,
          family: ThinkingFamily.geminiThinkingConfig,
          maxTokens: 8192);
      expect((high['thinking_config'] as Map)['thinking_budget'], 4096);
      expect((high['thinking_config'] as Map)['include_thoughts'], true);
    });

    test('开关制族（DeepSeek/Kimi/GLM）只发布尔开关，不发预算数字', () {
      final ds = thinkingWireFields(
          effort: ThinkingEffort.high, family: ThinkingFamily.thinkingType);
      expect(ds, {'thinking': {'type': 'enabled'}});
      expect(
          thinkingWireFields(
              effort: ThinkingEffort.off, family: ThinkingFamily.thinkingType),
          {'thinking': {'type': 'disabled'}});
      final glm = thinkingWireFields(
          effort: ThinkingEffort.low,
          family: ThinkingFamily.thinkingEnabled);
      expect(glm, {'thinking': {'enabled': true}});
      expect(
          thinkingWireFields(
              effort: ThinkingEffort.off,
              family: ThinkingFamily.thinkingEnabled),
          {'thinking': {'enabled': false}});
    });

    test('vLLM：模板 kwargs + 顶层开关各带一份（SGLang 只认顶层）', () {
      final w = thinkingWireFields(
          effort: ThinkingEffort.medium,
          family: ThinkingFamily.vllmChatTemplateKwargs,
          maxTokens: 8192);
      expect(w['enable_thinking'], true);
      final kw = w['chat_template_kwargs'] as Map;
      expect(kw['enable_thinking'], true);
      expect(kw['thinking_budget'], 2048);
      expect(
          (thinkingWireFields(
                  effort: ThinkingEffort.off,
                  family: ThinkingFamily.vllmChatTemplateKwargs,
                  maxTokens: 8192)['chat_template_kwargs'] as Map)[
              'enable_thinking'],
          false);
    });

    test('映射结果里绝不出现别家族专属字段（防严格端点 400）', () {
      final allowed = {
        ThinkingFamily.reasoningEffort: {'reasoning_effort'},
        ThinkingFamily.anthropicThinking: {'thinking'},
        ThinkingFamily.geminiThinkingConfig: {'thinking_config'},
        ThinkingFamily.thinkingType: {'thinking'},
        ThinkingFamily.thinkingEnabled: {'thinking'},
        ThinkingFamily.qwenEnableThinking: {
          'enable_thinking',
          'thinking_budget'
        },
        ThinkingFamily.vllmChatTemplateKwargs: {
          'chat_template_kwargs',
          'enable_thinking'
        },
        ThinkingFamily.none: <String>{},
      };
      for (final f in ThinkingFamily.values) {
        for (final e in ThinkingEffort.values) {
          final keys = thinkingWireFields(
                  effort: e, family: f, maxTokens: 8192)
              .keys
              .toSet();
          expect(keys.difference(allowed[f]!), isEmpty,
              reason: '${f.name} + ${e.name} 发出了越界字段');
        }
      }
    });
  });

  group('思考强度 · 设置落盘往返', () {
    test('字符串 ↔ 枚举：未知/缺省一律回落不干预（旧配置零影响）', () {
      for (final k in ['off', 'low', 'medium', 'high']) {
        expect(thinkingEffortToKey(thinkingEffortFromKey(k)), k);
      }
      expect(thinkingEffortFromKey(null), ThinkingEffort.passthrough);
      expect(thinkingEffortFromKey('ultra'), ThinkingEffort.passthrough);
      expect(thinkingEffortToKey(ThinkingEffort.passthrough), isNull);
    });

    test('族覆盖字符串往返，未知串 = null（回到自动探测）', () {
      for (final k in ['reasoning_effort', 'anthropic', 'gemini',
        'thinking_type', 'thinking_enabled', 'qwen', 'vllm', 'none']) {
        expect(thinkingFamilyToKey(thinkingFamilyFromKey(k)), k);
      }
      expect(thinkingFamilyFromKey('xxx'), isNull);
      expect(thinkingFamilyToKey(null), isNull);
    });
  });
}
