/// P1 harness 机制回归（2026-10-01）：
/// - 通用重复调用守护（同工具 3/5/8 次渐进提醒，DSH repeat-tool-reminder）；
/// - save_skill 工具（模型自主创建技能 → 落盘 + 即时注册 → load_skill 闭环）；
/// - availableSkillsText 的 saveSkillAvailable 教唆门控。
library;

import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:tongyi_lite/agent/llm/adapter.dart';
import 'package:tongyi_lite/agent/loop/agent.dart';
import 'package:tongyi_lite/agent/loop/config.dart';
import 'package:tongyi_lite/agent/loop/failure.dart';
import 'package:tongyi_lite/agent/session/session.dart';
import 'package:tongyi_lite/agent/skills/load_skill_tool.dart';
import 'package:tongyi_lite/agent/skills/provider.dart';
import 'package:tongyi_lite/agent/skills/save_skill_tool.dart';
import 'package:tongyi_lite/agent/skills/skill.dart';
import 'package:tongyi_lite/agent/tool_definition.dart';
import 'package:tongyi_lite/agent/tool_registry.dart';

import '../helpers/fake_llm.dart';

ToolDefinition _countingTool(String name) {
  var n = 0;
  return ToolDefinition(
    name: name,
    description: '计数工具 $name',
    parameters: {'type': 'object', 'properties': {}, 'required': []},
    execute: (args) async => ToolResult(content: 'result-${++n}'),
  );
}

ReactLoopAgent _agent(LlmAdapter adapter, List<ToolDefinition> tools) {
  final registry = ToolRegistry();
  for (final t in tools) {
    registry.register(t);
  }
  return ReactLoopAgent(
    session: SessionLog.fromEvents(const []),
    adapter: adapter,
    registry: registry,
    modelId: 'test-model',
    providerKind: ProviderKind.local,
    systemPrompt: 'sys',
    config: const AgentConfig(),
    compaction: const NoCompactionPlugin(),
  );
}

void main() {
  group('通用重复调用守护（3/5/8 渐进提醒）', () {
    test('同一工具第 3 次调用 → 结果尾部出现提醒，前两次没有', () async {
      final fake = FakeLlmAdapter([
        const LlmResult(text: '', toolCalls: [
          ToolCall(id: 'c1', name: 'search', arguments: {'q': 'x'}),
        ]),
        const LlmResult(text: '', toolCalls: [
          ToolCall(id: 'c2', name: 'search', arguments: {'q': 'x'}),
        ]),
        const LlmResult(text: '', toolCalls: [
          ToolCall(id: 'c3', name: 'search', arguments: {'q': 'x'}),
        ]),
        const LlmResult(text: '完成', toolCalls: []),
      ]);
      final agent = _agent(fake, [_countingTool('search')]);

      final reason = await agent.kick('查一下');

      expect(reason.kind, TurnEndReasonKind.completed);
      final results = agent.session.rawEvents
          .where((e) => e.type == kEventToolResult)
          .map((e) => e.data['content'] as String)
          .toList();
      expect(results.length, 3);
      expect(results[0].contains('[提醒'), isFalse);
      expect(results[1].contains('[提醒'), isFalse);
      expect(results[2].contains('[提醒：这是本回合第 3 次调用 search'), isTrue);
      // 重复调用走缓存不再真执行（计数工具只被执行 1 次）。
      expect(results[1], contains('重复调用提示'));
    });

    test('不同工具分别计数，互不干扰', () async {
      final fake = FakeLlmAdapter([
        const LlmResult(text: '', toolCalls: [
          ToolCall(id: 'a1', name: 'alpha', arguments: {}),
          ToolCall(id: 'b1', name: 'beta', arguments: {}),
        ]),
        const LlmResult(text: '', toolCalls: [
          ToolCall(id: 'a2', name: 'alpha', arguments: {}),
          ToolCall(id: 'b2', name: 'beta', arguments: {}),
        ]),
        const LlmResult(text: 'done', toolCalls: []),
      ]);
      final agent = _agent(fake, [_countingTool('alpha'), _countingTool('beta')]);

      await agent.kick('并行试试');

      final contents = agent.session.rawEvents
          .where((e) => e.type == kEventToolResult)
          .map((e) => '${e.data['name']}:${e.data['content']}')
          .toList();
      // 各自只到第 2 次 → 都不应出现提醒。
      expect(contents.where((c) => c.contains('[提醒')), isEmpty);
    });
  });

  group('save_skill（模型自主创建技能）', () {
    late Directory tmp;
    setUp(() => tmp = Directory.systemTemp.createTempSync('save_skill_test'));
    tearDown(() => tmp.deleteSync(recursive: true));

    test('保存 → 即时注册 → load_skill 可拉全文 → 落盘可被扫描', () async {
      final provider = SkillProvider(skills: const []);
      final save = createSaveSkillTool(provider, skillsDirOverride: tmp.path);

      final result = await save.execute({
        'name': '周报生成',
        'description': '按固定格式生成周报',
        'whenToUse': '用户要求写周报',
        'content': '## 步骤\n- 收集本周 todo\n- 按模板输出',
      });

      expect(result.isError, isFalse);
      expect(result.content, contains('已保存技能'));
      // 即时注册：本回合 provider 立即可见、load_skill 可拉。
      expect(provider.has('周报生成'), isTrue);
      final load = createLoadSkillTool(provider);
      final loaded = await load.execute({'name': '周报生成'});
      expect(loaded.isError, isFalse);
      expect(loaded.content, contains('<skill name="周报生成">'));
      expect(loaded.content, contains('收集本周 todo'));
      // 落盘：下回合 loadUserSkills 扫描即得（rank 200）。
      final scanned = await loadUserSkills(skillsDirOverride: tmp.path);
      expect(scanned.length, 1);
      expect(scanned.first.name, '周报生成');
      expect(scanned.first.rank, kRankUser);
    });

    test('同名再保存 = 覆盖，不新增目录', () async {
      final provider = SkillProvider(skills: const []);
      final save = createSaveSkillTool(provider, skillsDirOverride: tmp.path);
      await save.execute({
        'name': 's1',
        'description': 'd1',
        'whenToUse': 'w1',
        'content': 'v1',
      });
      await save.execute({
        'name': 's1',
        'description': 'd2',
        'whenToUse': 'w2',
        'content': 'v2',
      });
      final scanned = await loadUserSkills(skillsDirOverride: tmp.path);
      expect(scanned.length, 1);
      expect(scanned.first.body, contains('v2'));
    });

    test('缺必填参数 → error 结果（不落盘）', () async {
      final provider = SkillProvider(skills: const []);
      final save = createSaveSkillTool(provider, skillsDirOverride: tmp.path);
      final r = await save.execute({'name': 'x'});
      expect(r.isError, isTrue);
      expect(provider.count, 0);
      expect(tmp.listSync().length, 0);
    });
  });

  group('availableSkillsText 的 save_skill 门控', () {
    test('saveSkillAvailable=false 不教唆 save_skill', () {
      final p = SkillProvider(skills: [
        const Skill(
            name: 'a',
            description: 'd',
            whenToUse: 'w',
            body: 'b',
            rank: kRankBuiltin),
      ]);
      final text = p.availableSkillsText();
      expect(text, isNot(contains('save_skill')));
    });

    test('saveSkillAvailable=true 给出沉淀指引', () {
      final p = SkillProvider(skills: [
        const Skill(
            name: 'a',
            description: 'd',
            whenToUse: 'w',
            body: 'b',
            rank: kRankBuiltin),
      ]);
      final text = p.availableSkillsText(
          loadSkillAvailable: true, saveSkillAvailable: true);
      expect(text, contains('load_skill'));
      expect(text, contains('save_skill'));
    });
  });
}
