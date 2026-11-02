// 「能力」Tab 的归属钉死（2026-10-24 用户定案）。
//
// 用户原话：插件和 skill 是"智能体能力拓展的核心面"，不该并开发者里；原生能力（上下文压缩、
// 智能体、人格）该是默认打开的一档，插件/技能单独成梯队管理。
// 这类"东西在不在正确的地方"的规矩，运行时行为测不出来（放错 Tab 一样能跑），
// 只能像 `architecture_test.dart` 那样扫源码 —— 别嫌它土，它守的是用户找不找得到的问题。
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

void main() {
  final src = File('lib/screens/settings_screen.dart').readAsStringSync();

  group('能力 Tab（插件 + 技能 + 原生能力同处管理，不塞开发者）', () {
    test('TabBar 里有「能力」，TabController 长度跟着 tabs 走', () {
      expect(src, contains("text: '能力'"), reason: '「能力」Tab 被删了 = 用户又找不到插件入口了');
      expect(src, contains('TabController(length: 7'),
          reason: '加了 Tab 忘了改 length，TabBar 与 TabBarView 会当场对不上');
    });

    test('插件入口在「能力」Tab 里，而且**只有这一处**', () {
      final devAt = src.indexOf('class DevSettingsBody');
      final capAt = src.indexOf('class CapabilitySettingsBody');
      expect(devAt, greaterThan(-1), reason: '读不到 DevSettingsBody = 文件结构变了，这条检查得跟着改');
      expect(capAt, greaterThan(-1));
      expect('PluginsEntryTile'.allMatches(src).length, 1,
          reason: '整个设置页只许有**一处**插件入口（两处 = 两个真相，用户会看见两个"插件"）；'
              '类本身声明在 plugins_screen.dart，不在本文件');
      final capRegion = src.substring(capAt, devAt > capAt ? devAt : src.length);
      expect(capRegion, contains('PluginsEntryTile('), reason: '插件入口必须挂在「能力」Tab 下');
      final devRegion = src.substring(devAt);
      expect(devRegion, isNot(contains('const PluginsEntryTile(')),
          reason: '开发者 Tab 不许再留插件入口（那是 Dev Agent/SSH 的地盘）');
    });

    test('「能力」Tab 同时管插件与技能（不是一半）', () {
      final capRegion = src.substring(
        src.indexOf('class CapabilitySettingsBody'),
        src.indexOf('class DevSettingsBody'),
      );
      // 2026-10-25 harness 第八轮：技能管理抽成共享 SkillsManagementBody
      // （智能体面板/能力面板/左栏技能面板三处共用），能力面板以**内嵌**
      // 方式接入——管理动作就地完成，不再跳智能体面板。
      expect(capRegion, contains('SkillsManagementBody()'),
          reason: '能力面板没内嵌技能 Body = 用户又得跨面板找管理入口');
      expect('await loadUserSkills()'.allMatches(src).length, 1,
          reason: 'loadUserSkills 只许在共享 Body 里调用一次（两处 = 两个真相）');
      expect(src, contains('loadBuiltinSkills'));
      expect(capRegion, contains('PluginsEntryTile('));
    });

    test('原生能力那一档带真开关（不是只读展示，用户要能当场打开）', () {
      final capRegion = src.substring(
        src.indexOf('class CapabilitySettingsBody'),
        src.indexOf('class DevSettingsBody'),
      );
      for (final s in <String>[
        'setAgentEnabled',
        'setAgentCompactEnabled',
        'setAgentSubagentEnabled',
      ]) {
        expect(capRegion, contains(s), reason: '$s 没接上：那一档只是摆设，用户还得跑去别处开');
      }
    });
  });
}
