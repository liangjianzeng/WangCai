
import 'package:tongyi_lite/agent/llm/adapter.dart';
import 'package:tongyi_lite/agent/llm/openai_adapter.dart';
import 'package:tongyi_lite/agent/loop/agent.dart';
import 'package:tongyi_lite/agent/loop/config.dart';
import 'package:tongyi_lite/agent/loop/failure.dart';
import 'package:tongyi_lite/agent/session/session.dart';
import 'package:tongyi_lite/agent/skills/load_skill_tool.dart';
import 'package:tongyi_lite/agent/skills/provider.dart';
import 'package:tongyi_lite/agent/skills/skill.dart';
import 'package:tongyi_lite/agent/tool_definition.dart';
import 'package:tongyi_lite/agent/tool_registry.dart';
import '../helpers/fake_llm.dart';
import 'package:flutter_test/flutter_test.dart';

// ---------------------------------------------------------------------------
// 批次二：WP2（API 档对齐）+ WP3（本地档强化）
// ---------------------------------------------------------------------------

// LLM 桩用共享的 FakeLlmAdapter（test/helpers/fake_llm.dart）。

/// 记录型压缩桩：记录每次 decide 的 reason，按 [result] 应答。
class RecordingCompaction implements CompactionPlugin {
  final CompactionResult result;
  final List<String?> reasons = [];
  int calls = 0;

  RecordingCompaction(this.result);

  @override
  Future<CompactionResult> decide({
    required SessionRef ref,
    required int turn,
    required int step,
    required String? reason,
  }) async {
    calls++;
    reasons.add(reason);
    return result;
  }
}

ToolDefinition _timeTool() => ToolDefinition(
      name: 'get_time',
      description: '获取当前时间',
      parameters: const {'type': 'object'},
      execute: (_) async => const ToolResult(content: '12:00'),
    );

ReactLoopAgent _agent(
  LlmAdapter adapter, {
  AgentConfig? config,
  CompactionPlugin? compaction,
}) {
  final registry = ToolRegistry();
  registry.register(_timeTool());
  return ReactLoopAgent(
    session: SessionLog.fromEvents(const []),
    adapter: adapter,
    registry: registry,
    modelId: 'test-model',
    providerKind: ProviderKind.local,
    systemPrompt: '你是 TongYi-Lite 智能体',
    config: config,
    compaction: compaction ?? const NoCompactionPlugin(),
  );
}

void main() {
  group('WP3b 分阶段预算', () {
    test('工具调用步用 tokensPerRound，工具结果后的步用 maxTokensFinalRound',
        () async {
      final call = ToolCall(
          id: 'call_1', name: 'get_time', arguments: <String, dynamic>{});
      final fake = FakeLlmAdapter([
        LlmResult(text: '', toolCalls: [call]),
        LlmResult(text: '现在是 12:00', toolCalls: const []),
      ]);
      final agent = _agent(
        fake,
        config: const AgentConfig(
          maxStepsPerTurn: 4,
          maxTokensPerRound: 100,
          maxTokensFinalRound: 500,
        ),
      );

      final reason = await agent.kick('现在几点？');

      expect(reason.kind, TurnEndReasonKind.completed);
      expect(fake.calls, 2);
      expect(fake.allOptions[0].maxTokens, 100); // 工具调用步：紧预算
      expect(fake.allOptions[1].maxTokens, 500); // 工具结果后的回答步：大预算
    });

    test('maxTokensFinalRound=null（API 档）恒用统一预算', () async {
      final call = ToolCall(
          id: 'call_1', name: 'get_time', arguments: <String, dynamic>{});
      final fake = FakeLlmAdapter([
        LlmResult(text: '', toolCalls: [call]),
        LlmResult(text: 'ok', toolCalls: const []),
      ]);
      final agent = _agent(
        fake,
        config: const AgentConfig(
          maxStepsPerTurn: 4,
          maxTokensPerRound: 300,
        ),
      );

      await agent.kick('hi');

      expect(fake.allOptions[0].maxTokens, 300);
      expect(fake.allOptions[1].maxTokens, 300);
    });

    test('双档出厂值：local 分阶段 / api 统一大预算', () {
      final local = AgentConfig.forRoute(AgentRoute.local);
      final api = AgentConfig.forRoute(AgentRoute.api);
      expect(local.maxTokensPerRound, 1024);
      expect(local.maxTokensFinalRound, 2048);
      expect(local.contextTokenBudget, isNull); // 挂载点接 settings 后注入
      expect(api.maxTokensPerRound, 8192);
      expect(api.maxStepsPerTurn, 16);
      expect(api.allowParallelTools, isTrue);
      expect(api.maxTokensFinalRound, isNull);
    });
  });

  group('WP3a 主动压缩', () {
    test('估算超预算 → 触发 compaction.decide（proactive）', () async {
      final fake = FakeLlmAdapter([LlmResult(text: 'ok', toolCalls: const [])]);
      final compaction = RecordingCompaction(
          const CompactionResult(CompactionResultKind.success));
      final agent = _agent(
        fake,
        config: const AgentConfig(
          maxStepsPerTurn: 2,
          contextTokenBudget: 1, // 必然超（system+user 就超 1 tok）
        ),
        compaction: compaction,
      );

      await agent.kick('hi');

      expect(compaction.calls, 1);
      expect(compaction.reasons.first, contains('proactive'));
    });

    test('预算充足 → 不触发 decide', () async {
      final fake = FakeLlmAdapter([LlmResult(text: 'ok', toolCalls: const [])]);
      final compaction =
          RecordingCompaction(const CompactionResult(CompactionResultKind.failure));
      final agent = _agent(
        fake,
        config: const AgentConfig(
          maxStepsPerTurn: 2,
          contextTokenBudget: 1 << 30,
        ),
        compaction: compaction,
      );

      await agent.kick('hi');

      expect(compaction.calls, 0);
    });
  });

  group('WP2c load_skill 工具', () {
    test('已知技能 → 返回 <skill> 全文；未知/缺参 → 可读错误', () async {
      final provider = SkillProvider(skills: [
        Skill.parse(
          '---\ndescription: 联网调研\nwhenToUse: 需要多源检索时\n'
          'invocation: tool: web_search\n---\n先搜中文再搜英文。',
          name: 'web-research',
        ),
      ]);
      final tool = createLoadSkillTool(provider);

      final ok = await tool.execute({'name': 'web-research'});
      expect(ok.isError, isFalse);
      expect(ok.content, contains('<skill name="web-research">'));
      expect(ok.content, contains('先搜中文再搜英文'));

      final unknown = await tool.execute({'name': 'nope'});
      expect(unknown.isError, isTrue);
      expect(unknown.content, contains('未知技能'));

      final missing = await tool.execute(const {});
      expect(missing.isError, isTrue);
    });
  });

  group('WP2b 前缀稳定', () {
    test('buildOpenAiToolsSchema 按 name 排序（tools 数组逐字节稳定）', () {
      final t1 = _timeTool();
      final t2 = ToolDefinition(
        name: 'aaa_first',
        description: 'x',
        parameters: const {'type': 'object'},
        execute: (_) async => const ToolResult(content: ''),
      );
      final a = buildOpenAiToolsSchema([t1, t2]);
      final b = buildOpenAiToolsSchema([t2, t1]);
      final namesA = a.map((s) => s['function']['name']).toList();
      final namesB = b.map((s) => s['function']['name']).toList();
      expect(namesA, ['aaa_first', 'get_time']);
      expect(namesA, namesB); // 输入顺序无关
    });
  });

  group('WP2e usage 透传', () {
    test('assembler 捕获 usage 事件（SSE 末块）', () {
      final assembler = OpenAiNativeStreamAssembler();
      assembler.addEvent({'type': 'text', 'text': 'hi'});
      assembler.addEvent({
        'type': 'usage',
        'usage': {'prompt_tokens': 120, 'completion_tokens': 8},
      });
      expect(assembler.usage, isNotNull);
      expect(assembler.usage!['prompt_tokens'], 120);
    });
  });
}
