import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

import 'package:tongyi_lite/agent/skills/provider.dart';
import 'package:tongyi_lite/agent/skills/skill.dart';

void main() {
  late Directory tmp;

  setUp(() {
    tmp = Directory.systemTemp.createTempSync('user_skills_test');
  });

  tearDown(() {
    tmp.deleteSync(recursive: true);
  });

  group('用户技能落盘（设置页技能管理 UI 链路）', () {
    test('writeUserSkill → loadUserSkills 扫描到（同名同描述，rank 200）',
        () async {
      await writeUserSkill(
        name: '法律文书助手',
        description: '起草合同/协议类文书',
        whenToUse: '用户要求起草合同、协议',
        body: '## 步骤\n- 明确双方与标的',
        skillsDirOverride: tmp.path,
      );
      final skills = await loadUserSkills(skillsDirOverride: tmp.path);
      expect(skills.length, 1);
      expect(skills.first.name, '法律文书助手');
      expect(skills.first.description, '起草合同/协议类文书');
      expect(skills.first.whenToUse, '用户要求起草合同、协议');
      expect(skills.first.body, contains('明确双方与标的'));
      expect(skills.first.rank, kRankUser);
    });

    test('更新：同名覆盖不新增目录', () async {
      await writeUserSkill(
          name: 's1',
          description: 'v1',
          whenToUse: 't',
          body: 'b1',
          skillsDirOverride: tmp.path);
      await writeUserSkill(
          name: 's1',
          description: 'v2',
          whenToUse: 't',
          body: 'b2',
          skillsDirOverride: tmp.path);
      final skills = await loadUserSkills(skillsDirOverride: tmp.path);
      expect(skills.length, 1);
      expect(skills.first.description, 'v2');
      expect(skills.first.body, contains('b2'));
    });

    test('改名：previousName 迁移目录，旧名消失', () async {
      await writeUserSkill(
          name: 'old-name',
          description: 'd',
          whenToUse: 't',
          body: 'b',
          skillsDirOverride: tmp.path);
      final dirName = await writeUserSkill(
          name: 'new name',
          previousName: 'old-name',
          description: 'd',
          whenToUse: 't',
          body: 'b',
          skillsDirOverride: tmp.path);
      expect(dirName, 'new-name');
      final skills = await loadUserSkills(skillsDirOverride: tmp.path);
      expect(skills.map((s) => s.name), ['new-name']);
    });

    test('deleteUserSkill 删除目录；不存在返回 false', () async {
      await writeUserSkill(
          name: 'gone',
          description: 'd',
          whenToUse: 't',
          body: 'b',
          skillsDirOverride: tmp.path);
      expect(await deleteUserSkill('gone', skillsDirOverride: tmp.path), true);
      expect(await loadUserSkills(skillsDirOverride: tmp.path), isEmpty);
      expect(await deleteUserSkill('gone', skillsDirOverride: tmp.path),
          false);
    });

    test('sanitize：非法字符剔除；纯符号名报错', () async {
      expect(sanitizeSkillDirName('  my skill  '), 'my-skill');
      expect(sanitizeSkillDirName('a/b\\c:d*e?f"g<h>i|j.k'),
          'abcdefghijk');
      expect(sanitizeSkillDirName('///...'), isNull);
      expect(
        () => writeUserSkill(
            name: '???',
            description: 'd',
            whenToUse: 't',
            body: 'b',
            skillsDirOverride: tmp.path),
        throwsArgumentError,
      );
    });

    test('buildSkillMarkdown 与 Skill.parse 兼容（含 invocation）', () {
      final md = buildSkillMarkdown(
        description: '翻译',
        whenToUse: '翻译请求',
        invocation: 'tool: web_search',
        body: '正文第一行',
      );
      final skill = Skill.parse(md, name: 'x');
      expect(skill.description, '翻译');
      expect(skill.whenToUse, '翻译请求');
      expect(skill.invocation, 'tool: web_search');
      expect(skill.body, '正文第一行');
    });
  });
}
