import 'package:flutter_test/flutter_test.dart';

import 'package:tongyi_lite/agent/loop/agent.dart';
import 'package:tongyi_lite/agent/loop/config.dart';
import 'package:tongyi_lite/agent/loop/failure.dart';
import 'package:tongyi_lite/agent/llm/adapter.dart';
import 'package:tongyi_lite/agent/session/session.dart';
import 'package:tongyi_lite/agent/tool_definition.dart';
import 'package:tongyi_lite/agent/tool_registry.dart';
import 'package:tongyi_lite/providers/agent_stream_processor.dart';

import '../helpers/fake_llm.dart';

// 思考标签必须**拼接**出来：把标签字面量直接写进源码会被上游思考流过滤器
// 当成思考块吞掉（本仓实测），拼接后写盘才安全。
final String _open = String.fromCharCode(60) + 'think' + String.fromCharCode(62);
final String _close =
    String.fromCharCode(60) + '/think' + String.fromCharCode(62);

String _fill(int n, [String seed = '推理']) {
  const unit = '端侧小模型的思考独白内容用于填充长度';
  final b = StringBuffer();
  while (b.length < n) {
    b.write(unit);
  }
  return '$seed:${b.toString().substring(0, n)}';
}

ToolDefinition _weatherTool() => ToolDefinition(
      name: 'get_weather',
      description: '查询天气',
      parameters: {
        'type': 'object',
        'properties': {'city': {'type': 'string'}},
        'required': ['city'],
      },
      execute: (args) =>
          Future.value(ToolResult(content: 'Beijing: sunny 25C')),
    );

ToolRegistry _registry() {
  final reg = ToolRegistry();
  reg.register(_weatherTool());
  return reg;
}

ReactLoopAgent _agent(FakeLlmAdapter fake,
        {AgentConfig? config, LlmRetry? retry}) =>
    ReactLoopAgent(
      session: SessionLog.fromEvents(const []),
      adapter: fake,
      registry: _registry(),
      modelId: 'test-model',
      providerKind: ProviderKind.local,
      systemPrompt: '你是 TongYi-Lite 智能体',
      config: config,
      compaction: const NoCompactionPlugin(),
      retry: retry ??
          LlmRetry(
            maxRetries: 3,
            initialDelay: Duration.zero,
            maxDelay: Duration.zero,
          ),
    );

const _overflow = LlmFailure(
  code: LlmFailureCode.thinkingOverflow,
  message: '思考失控：已累计思考 9000 字仍无任何产出，已主动中止',
);

void main() {
  group('AgentStreamProcessor · 思考失控守卫口径（累计）', () {
    test('跨块累计：每块闭合后总量仍继续累加', () {
      final p = AgentStreamProcessor();
      // 三段各 300 字的思考：现行「当前块长」口径每块归零 → 永远不触发
      for (var i = 0; i < 3; i++) {
        p.add('$_open${_fill(300, '第${i}轮')}$_close');
      }
      expect(p.thinking.length, 0, reason: '闭合后当前块应清空');
      expect(p.totalThinkingChars, greaterThanOrEqualTo(900),
          reason: '累计口径必须跨块合计');
    });

    test('累计超阈值且无产出 → 判失控（现行块长口径会漏）', () {
      final p = AgentStreamProcessor();
      for (var i = 0; i < 25; i++) {
        p.add('$_open${_fill(300, '第${i}轮')}$_close');
      }
      expect(p.thinking.length, lessThan(6000), reason: '单块远未超阈值');
      expect(p.thinkingRunaway(6000), isTrue, reason: '累计 7500 字应判失控');
    });

    test('已产出答案 → 同长度不判失控（不误杀长推理）', () {
      final p = AgentStreamProcessor();
      p.add('$_open${_fill(7000)}$_close');
      p.add(_fill(200, '正式答案'));
      expect(p.producedAnything, isTrue);
      expect(p.thinkingRunaway(6000), isFalse);
    });

    test('寒暄不算产出（两句客套不能豁免 4 万字独白）', () {
      final p = AgentStreamProcessor();
      p.add('好的，我来看看。');
      p.add('$_open${_fill(7000)}');
      expect(p.producedAnything, isFalse);
      expect(p.thinkingRunaway(6000), isTrue);
    });

    test('工具调用算产出：长思考后正常发起调用不误杀', () {
      final p = AgentStreamProcessor();
      p.add('$_open${_fill(7000)}$_close');
      p.add('{"tool_call":"get_weather","arguments":{"city":"Beijing"}}');
      expect(p.hasToolCalls, isTrue);
      expect(p.producedAnything, isTrue);
      expect(p.thinkingRunaway(6000), isFalse);
    });
  });

  group('LlmRetry · 思考失控换条件重试', () {
    test('允许一次；用尽即止损', () {
      final r = LlmRetry(maxRetries: 3, initialDelay: Duration.zero);
      expect(r.isRetryable(_overflow), isTrue);
      expect(r.isRetryable(_overflow), isTrue); // isRetryable 不改状态
      return r.maybeBackoff(_overflow).then((_) {
        expect(r.isRetryable(_overflow), isFalse,
            reason: '思考失控只许重试一次');
      });
    });

    test('授予重试即置「下次强制不思考」，且读后即清', () async {
      final r = LlmRetry(maxRetries: 3, initialDelay: Duration.zero);
      await r.maybeBackoff(_overflow);
      expect(r.takeForceNoThinking(), isTrue);
      expect(r.takeForceNoThinking(), isFalse, reason: '一次性标志');
    });

    test('reset 清标志与思考重试预算（换步即重新计）', () async {
      final r = LlmRetry(maxRetries: 3, initialDelay: Duration.zero);
      await r.maybeBackoff(_overflow);
      r.reset();
      expect(r.takeForceNoThinking(), isFalse);
      expect(r.isRetryable(_overflow), isTrue);
    });
  });

  group('主循环 · 思考治理', () {
    test('思考失控后的那次重试，请求带 forceNoThinking', () async {
      final fake = FakeLlmAdapter([
        _overflow,
        const LlmResult(text: '北京晴，25C', toolCalls: []),
      ]);
      final agent = _agent(
        fake,
        config: const AgentConfig(
            maxStepsPerTurn: 6,
            maxTokensPerRound: 512,
            thinkingOnToolSteps: true), // 让正常步都思考，才能区分重试那次
      );

      final reason = await agent.kick('北京天气？');

      expect(reason.kind, TurnEndReasonKind.completed);
      expect(fake.calls, 2);
      expect(fake.allOptions[0].forceNoThinking, isFalse,
          reason: '正常步按配置允许思考');
      expect(fake.allOptions[1].forceNoThinking, isTrue,
          reason: '失控重试必须换条件（关思考重采样）');
    });

    test('连续两次失控 → 只重试一次即止损（不空转烧 token）', () async {
      final fake = FakeLlmAdapter([_overflow, _overflow, _overflow]);
      final agent = _agent(fake);

      final reason = await agent.kick('写个文件');

      expect(fake.calls, 2, reason: '1 次原始 + 1 次关思考重试');
      expect(reason.kind, TurnEndReasonKind.error);
      expect(agent.lastTurnAnswer, '', reason: '失败不得回溯历史旧答案冒充');
    });

    test('工具决策步默认不思考；组织答案的步允许思考', () async {
      final fake = FakeLlmAdapter([
        LlmResult(
            text: '',
            toolCalls: [
              ToolCall(
                  id: 'c1',
                  name: 'get_weather',
                  arguments: const {'city': '北京'})
            ]),
        const LlmResult(text: '北京晴 25C', toolCalls: []),
      ]);
      final agent = _agent(fake); // 默认 thinkingOnToolSteps = false

      final reason = await agent.kick('北京天气？');

      expect(reason.kind, TurnEndReasonKind.completed);
      expect(fake.allOptions[0].forceNoThinking, isTrue,
          reason: '工具决策步只需产出调用，长思考是失控高发区');
      expect(fake.allOptions[1].forceNoThinking, isFalse,
          reason: '工具结果已回填 → 本步组织最终答案，允许思考');
    });

    test('配置打开后工具步也允许思考（回退旧行为）', () async {
      final fake = FakeLlmAdapter([
        LlmResult(
            text: '',
            toolCalls: [
              ToolCall(
                  id: 'c1',
                  name: 'get_weather',
                  arguments: const {'city': '北京'})
            ]),
        const LlmResult(text: '北京晴 25C', toolCalls: []),
      ]);
      final agent = _agent(
        fake,
        config: const AgentConfig(
            maxStepsPerTurn: 6,
            maxTokensPerRound: 512,
            thinkingOnToolSteps: true),
      );

      await agent.kick('北京天气？');

      expect(fake.allOptions[0].forceNoThinking, isFalse);
    });
  });
}
