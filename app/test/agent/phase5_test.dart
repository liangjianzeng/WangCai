/// Phase 5 tests：hooks / skills / AGENTS.md 注入。
import 'dart:async';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:tongyi_lite/agent/hooks/hooks.dart';
import 'package:tongyi_lite/agent/llm/adapter.dart';
import 'package:tongyi_lite/agent/loop/agent.dart';
import 'package:tongyi_lite/agent/session/session.dart';
import 'package:tongyi_lite/agent/skills/provider.dart';
import 'package:tongyi_lite/agent/skills/skill.dart'
    show Skill, kRankUser, kRankBuiltin, loadBuiltinSkills;
import 'package:tongyi_lite/agent/tool_definition.dart';
import 'package:tongyi_lite/agent/tool_registry.dart';

/// 覆写 [LlmAdapter.generate] 的桩。
final class _FakeAdapter extends LlmAdapter {
  final List<LlmResult> _outcomes;
  int _calls;
  _FakeAdapter(this._outcomes) : _calls = 0;

  @override
  Future<LlmResult> generate(
    GenerateOptions options, {
    StreamController<String>? onToken,
    StreamController<String>? onThinking,
    Completer<void>? cancel,
  }) async {
    final idx = _calls < _outcomes.length ? _calls : _outcomes.length - 1;
    final result = _outcomes[idx];
    _calls++;
    return result;
  }

  int get calls => _calls;
}

/// 构建 ReactLoopAgent。
ReactLoopAgent _buildAgent({
  AgentHooks? hooks,
  SkillProvider? skills,
  String? agentsMd,
  LlmResult? result,
}) {
  final adapter = _FakeAdapter(result != null ? [result] : const []);
  return ReactLoopAgent(
    session: SessionLog.fromEvents(const []),
    adapter: adapter,
    registry: ToolRegistry(),
    modelId: 'test',
    providerKind: ProviderKind.local,
    systemPrompt: '测试系统',
    hooks: hooks,
    skills: skills,
    agentsMd: agentsMd,
  );
}

/// 取 system/message 事件的 content。
String? _systemContent(ReactLoopAgent agent) {
  for (final e in agent.session.rawEvents) {
    if (e.type == kEventSystemMessage) {
      return e.data['content'] as String?;
    }
  }
  return null;
}

void main() {
  group('AgentHooks', () {
    test('pre-step 默认允许', () async {
      final hooks = AgentHooks();
      final ctx = PreStepContext(turn: 1, step: 1, modelId: 'm', history: []);
      expect(await hooks.shouldProceed(ctx), true);
    });

    test('pre-step reject 否决 step', () async {
      final hooks = AgentHooks();
      hooks.onPreStep((ctx) async =>
          PreStepDecisionResult(PreStepDecision.reject, reason: 'denied'));
      final ctx = PreStepContext(turn: 1, step: 1, modelId: 'm', history: []);
      expect(await hooks.shouldProceed(ctx), false);
    });

    test('tools/result 被触发（read-only）', () {
      final hooks = AgentHooks();
      final names = <String>[];
      hooks.onToolsResult((call, result) => names.add(call.name));
      final call = ToolCall(id: 'c1', name: 'web_search', arguments: const {});
      hooks.notifyResult(call, ToolResult(content: 'ok', isError: false));
      expect(names, equals(['web_search']));
    });

    test('tools/result 异常不中断', () {
      final hooks = AgentHooks();
      hooks.onToolsResult((call, result) => throw Exception('boom'));
      final call = ToolCall(id: 'c1', name: 'web_search', arguments: const {});
      // notifyResult 应吞掉 listener 异常，不抛出。
      hooks.notifyResult(call, ToolResult(content: 'ok'));
      expect(true, isTrue);
    });
  });

  group('SkillProvider', () {
    test('内置 skill 非空', () {
      final p = SkillProvider();
      expect(p.count, greaterThan(0));
      expect(p.byName('web-research'), isNotNull);
    });

    test('availableSkillsText 含 <available_skills> 与 load_skill 链路提示', () {
      final p = SkillProvider();
      final text = p.availableSkillsText(loadSkillAvailable: true);
      expect(text.trim(), startsWith('<available_skills>'));
      expect(text, contains('</available_skills>'));
      expect(text, contains('web-research'));
      // WP2c：目录之后给出"目录 → load_skill 加载全文"链路说明。
      expect(text, contains('load_skill'));
    });

    test('load_skill 未注册时注入文本不教唆调用 load_skill（本地档定案）', () {
      final p = SkillProvider();
      final text = p.availableSkillsText(loadSkillAvailable: false);
      expect(text.trim(), startsWith('<available_skills>'));
      expect(text, contains('web-research'));
      expect(text, isNot(contains('load_skill')));
    });

    test('skillText 含 <skill>', () {
      final p = SkillProvider();
      final text = p.skillText('web-research');
      expect(text, contains('<skill name="web-research">'));
      expect(text, contains('</skill>'));
    });

    test('注册用户 skill（rank 200）', () {
      final p = SkillProvider();
      p.registerUser(Skill(
        name: 'custom',
        description: 'user skill',
        whenToUse: 'when',
        body: 'body',
        rank: kRankUser,
      ));
      expect(p.byName('custom'), isNotNull);
    });

    test('同名用户 skill 覆盖内置（去重保留高 rank）', () {
      final p = SkillProvider(skills: [
        Skill(
            name: 'web-research',
            description: 'builtin',
            whenToUse: 'w',
            body: 'b',
            rank: kRankBuiltin),
        Skill(
            name: 'web-research',
            description: 'user',
            whenToUse: 'w',
            body: 'b',
            rank: kRankUser),
      ]);
      expect(p.count, 1);
      expect(p.byName('web-research')!.description, 'user');
    });

    test('Skill.parse：frontmatter + --- 分隔正文', () {
      final s = Skill.parse(
        '# my-skill\n'
        'description: 做某事。\n'
        'whenToUse: 需要时。\n'
        'invocation: tool: demo\n'
        '---\n'
        '## 使用\n'
        '步骤一。\n',
        name: 'my-skill',
      );
      expect(s.description, '做某事。');
      expect(s.whenToUse, '需要时。');
      expect(s.invocation, 'tool: demo');
      expect(s.body, startsWith('## 使用'));
      expect(s.body, contains('步骤一。'));
    });

    test('loadUserSkills：扫描目录（override）', () async {
      final dir = Directory.systemTemp.createTempSync('tyl_skills_test');
      try {
        final skillDir = Directory('${dir.path}/pdf-tools')..createSync();
        File('${skillDir.path}/SKILL.md').writeAsStringSync(
            'description: PDF 处理。\n'
            'whenToUse: 处理 PDF 时。\n'
            '---\n'
            '用 pdf 工具处理。\n');
        // 坏目录：没有 SKILL.md，应被跳过。
        Directory('${dir.path}/empty-dir').createSync();

        final skills = await loadUserSkills(skillsDirOverride: dir.path);
        expect(skills.length, 1);
        expect(skills.single.name, 'pdf-tools');
        expect(skills.single.rank, kRankUser);
        expect(skills.single.description, 'PDF 处理。');

        // 合并进 provider：rank 200 排在内置（100）之前。
        final p = SkillProvider(
            skills: [...loadBuiltinSkills(), ...skills]);
        expect(p.byName('pdf-tools'), isNotNull);
        expect(p.skills.first.rank, kRankUser);
      } finally {
        dir.deleteSync(recursive: true);
      }
    });

    test('loadUserSkills：目录不存在返回空', () async {
      final skills = await loadUserSkills(
          skillsDirOverride: 'Z:/definitely/not/here');
      expect(skills, isEmpty);
    });
  });

  group('system prompt 注入 (Phase 5)', () {
    test('system prompt 含 <available_skills>', () {
      final p = SkillProvider();
      final agent = _buildAgent(skills: p);
      final content = _systemContent(agent);
      expect(content, isNotNull);
      expect(content, contains('<available_skills>'));
      expect(content, contains('web-research'));
    });

    test('system prompt 含 workspace:guidance', () {
      final agent = _buildAgent(agentsMd: '规则: 简短回答');
      final content = _systemContent(agent);
      expect(content, contains('<workspace:guidance>'));
      expect(content, contains('规则: 简短回答'));
      expect(content, contains('</workspace:guidance>'));
    });

    test('同时含 skills 与 guidance', () {
      final p = SkillProvider();
      final agent = _buildAgent(skills: p, agentsMd: '规则: 简短');
      final content = _systemContent(agent);
      expect(content, contains('<available_skills>'));
      expect(content, contains('<workspace:guidance>'));
    });
  });

  group('pre-step hook 否决 turn', () {
    test('pre-step reject 后 turn 以 error 结束', () async {
      final hooks = AgentHooks();
      hooks.onPreStep((ctx) async =>
          PreStepDecisionResult(PreStepDecision.reject, reason: 'block'));
      final agent = _buildAgent(hooks: hooks);
      final controller = StreamController<String>();
      final reason = await agent.kick('test', onToken: controller);
      controller.close();
      expect(reason.kind, TurnEndReasonKind.error);
    });
  });
}
