import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

import 'package:wangcai/agent/skills/provider.dart';
import 'package:wangcai/agent/skills/skill.dart';

// ---------------------------------------------------------------------------
// v0.0.4.1 DSH project-root rank：项目级技能目录（Phase 5.2）。
// <ws>/.wangcai/skills 优先，兼容 <ws>/.dsh/skills；rank 300 压过用户/内置。
// ---------------------------------------------------------------------------

void main() {
  late Directory ws;

  setUp(() {
    ws = Directory.systemTemp.createTempSync('wc_projws_');
  });

  tearDown(() {
    if (ws.existsSync()) ws.deleteSync(recursive: true);
  });

  void writeSkill(String dir, String name, String desc, String body) {
    final d = Directory('${ws.path}/$dir/skills/$name')..createSync(recursive: true);
    File('${d.path}/SKILL.md').writeAsStringSync(
        'description: $desc\nwhenToUse: 场景\n---\n$body');
  }

  test('两目录都扫；rank 300；.wangcai 同名压过 .dsh', () async {
    writeSkill('.wangcai', 'deploy', '部署A', '走 A 流程');
    writeSkill('.dsh', 'deploy', '部署B', '走 B 流程');
    writeSkill('.dsh', 'legacy', '旧技能', 'L');

    final list = await loadProjectSkills(ws.path);
    expect(list.length, 3); // 同名不去重在这里，交给 rank 裁决
    expect(list.every((s) => s.rank == kRankProject), isTrue);

    final provider = SkillProvider(skills: [...loadBuiltinSkills(), ...list]);
    expect(provider.byName('deploy')!.description, '部署A');
    expect(provider.byName('legacy')!.description, '旧技能');
  });

  test('null/空 workspacePath → 空列表不炸', () async {
    expect(await loadProjectSkills(null), isEmpty);
    expect(await loadProjectSkills('   '), isEmpty);
    expect(await loadProjectSkills(r'Z:\不存在的目录'), isEmpty);
  });
}
