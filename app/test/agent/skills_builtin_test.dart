import 'package:flutter_test/flutter_test.dart';

import 'package:tongyi_lite/agent/skills/load_skill_tool.dart';
import 'package:tongyi_lite/agent/skills/provider.dart';
import 'package:tongyi_lite/agent/skills/skill.dart';

void main() {
  group('内置通用技能（2026-10-01 对齐官方规范重写正文）', () {
    test('内置技能清单：16 个通用 + stock-research 专精 + skill-creator 元技能', () {
      final skills = loadBuiltinSkills();
      final names = skills.map((s) => s.name).toSet();
      expect(names, containsAll([
        'web-research',
        'code-review',
        'translation',
        'writing-polish',
        'summarize',
        'data-analysis',
        'email-draft',
        'explain-code',
        'plan-todo',
        'file-report',
        'travel-planner',
        'meeting-notes',
        'resume-polish',
        'social-copy',
        'shopping-compare',
        'tutor',
        'stock-research',
        'skill-creator',
      ]));
      expect(skills.length, 18);
      // 每个技能都必须有 whenToUse 与非空 body（否则目录注入/正文加载没意义）。
      for (final s in skills) {
        expect(s.whenToUse, isNotEmpty, reason: '${s.name} 缺 whenToUse');
        expect(s.body, isNotEmpty, reason: '${s.name} 缺 body');
        // 文案精简约束：description/whenToUse 一行短句（目录每回合注入）。
        expect(s.description.length, lessThanOrEqualTo(20),
            reason: '${s.name} 描述过长（${s.description.length} 字）');
        expect(s.whenToUse.length, lessThanOrEqualTo(24),
            reason: '${s.name} whenToUse 过长（${s.whenToUse.length} 字）');
      }
    });

    test('正文质量下限：每个 body 是真执行手册（工作流+模板+验收），不是三句话', () {
      for (final s in loadBuiltinSkills()) {
        final lines =
            s.body.split('\n').where((l) => l.trim().isNotEmpty).length;
        expect(lines, greaterThanOrEqualTo(20),
            reason: '${s.name} 正文只有 $lines 行——回退成三句话了');
        expect(s.body, contains('## '),
            reason: '${s.name} 正文缺分节结构');
        expect(s.body.toLowerCase(), contains('验收'),
            reason: '${s.name} 正文缺验收清单');
      }
    });

    test('load_skill 工具可拉到每个新增技能的全文', () async {
      final provider = SkillProvider();
      final tool = createLoadSkillTool(provider);
      for (final name in [
        'translation',
        'writing-polish',
        'summarize',
        'data-analysis',
        'email-draft',
        'explain-code',
        'plan-todo',
        'file-report',
      ]) {
        final result = await tool.execute({'name': name});
        expect(result.content, contains('<skill name="$name">'),
            reason: 'load_skill 拉不到 $name');
      }
    });

    test('availableSkillsText 目录包含新增技能（API 模式 load_skill 前置）',
        () {
      final text = SkillProvider().availableSkillsText();
      expect(text, contains('translation'));
      expect(text, contains('data-analysis'));
      expect(text, contains('file-report'));
    });

    test('用户同名技能（rank 200）仍覆盖内置（rank 100）', () {
      final provider = SkillProvider();
      provider.registerUser(const Skill(
        name: 'translation',
        description: '用户自定义翻译技能',
        whenToUse: '自定义触发',
        body: '用户 body',
        rank: 0,
      ));
      final skill = provider.byName('translation');
      expect(skill!.rank, kRankUser);
      expect(skill.body, '用户 body');
      expect(provider.count, 18, reason: '同名覆盖不增加数量');
    });
  });
}
