import 'dart:convert';

import 'package:plugin_kernel/plugin_kernel.dart';
import 'package:test/test.dart';

/// 与 app 的宿主能力清单一致（`lib/plugins/plugin_host.dart`）。
const _hostCaps = {
  'app.store',
  'app.interact',
  'app.speak',
  'app.capture',
  'llm.complete',
  'llm.vision',
  'asr.transcribe',
  'net.search',
};

void main() {
  group('声明式脚手架', () {
    test('默认生成物当场通过自己的校验器（绝不发跑不起来的骨架给人）', () {
      final files = generatePluginFiles(ScaffoldSpec(
        id: 'poem-recite',
        name: '古诗抽查',
        description: '拍照抽诗、按间隔背诵',
      ));
      expect(files.keys, containsAll(<String>['plugin.json', 'prompt.md', 'README.md']));
      final check = selfCheckGenerated(files, knownCapabilityIds: _hostCaps);
      expect(check.isOk, isTrue, reason: check.failureOrNull?.hint ?? check.failureOrNull?.message);
      expect(files['prompt.md'], contains('{{userInstruction}}'), reason: '提示词必须留用户附加要求入口');
    });

    test('plugin.json 由 PluginManifest.toJson 生成，能被解析器原样读回（生成器与解析器同源）', () {
      final spec = ScaffoldSpec(id: 'word-cards', name: '单词卡', description: 'd');
      final files = generatePluginFiles(spec);
      final back = PluginManifest.fromJson(jsonDecode(files['plugin.json']!) as Map<String, dynamic>);
      final origin = spec.manifest();
      expect(back.id, origin.id);
      expect(back.params.map((p) => p.name), origin.params.map((p) => p.name));
      expect(back.permissions.map((p) => p.wireName), origin.permissions.map((p) => p.wireName));
      expect(back.flow!.steps.map((s) => s.op), origin.flow!.steps.map((s) => s.op));
      expect(back.trust, PluginTrust.declarative, reason: '声明式插件的信任级不许被脚手架写歪');
    });

    test('flow 的每一步都带了 op 所需权限；漏权限当场被拒（不是跑一半才炸）', () {
      final files = generatePluginFiles(ScaffoldSpec(
        id: 'no-perm-one',
        name: '漏权限',
        description: 'd',
        permissions: const [PluginPermission.camera], // 故意漏掉 tts / llm:vision
      ));
      final r = selfCheckGenerated(files, knownCapabilityIds: _hostCaps);
      expect(r.isErr, isTrue);
      expect(r.failureOrNull?.message, contains('生成的 plugin.json 没通过校验'),
          reason: '只断「plugin.json」五个字，产品说"plugin.json 不存在"也算过 —— 要说破是**校验没过**');
      expect(r.failureOrNull?.hint, anyOf(contains('tts'), contains('llm')));
    });

    test('inject 了本机没有的能力 → 自检就报出来（比装机后面板显示"缺功能"更早）', () {
      final files = generatePluginFiles(ScaffoldSpec(
        id: 'needs-ghost',
        name: '幽灵能力',
        description: 'd',
        inject: ['app.store', 'app.ghost'],
        permissions: const [PluginPermission.pluginStorage],
      ));
      final report = validateManifestText(files['plugin.json']!, knownCapabilityIds: _hostCaps);
      expect(report.issues.any((i) => i.code == ValidationIssueCode.unknownCapability), isTrue);
    });

    test('非法 id 当场被拒（id 规则是契约，不能靠装机后试错）', () {
      final files = generatePluginFiles(ScaffoldSpec(id: 'BAD_ID', name: 'x', description: 'd'));
      final r = selfCheckGenerated(files, knownCapabilityIds: _hostCaps);
      expect(r.isErr, isTrue);
      // isNotEmpty 等于没断：hint 是 _clip(detail,118)，产品换成固定「校验没过」也照样绿。
      // 判词必须把**是哪个 id** 说给用户看，否则作者只能自己猜哪一段不合规。
      expect(r.failureOrNull?.hint, contains('BAD_ID'),
          reason: '拒绝必须点名（哪个 id 违反了 id 规则），不许只说"不合法"');
    });
  });

  group('命令式脚手架', () {
    test('生成的 Dart 骨架自带四条作者纪律（effect / Outcome / 取消复查 / 不 throw）', () {
      final files = generatePluginFiles(ScaffoldSpec(
        id: 'word-cards',
        name: '单词卡',
        description: '按间隔念单词',
        kind: ScaffoldKind.dart,
      ));
      final dart = files.keys.firstWhere((k) => k.endsWith('.dart'));
      expect(dart, 'word_cards_plugin.dart');
      final src = files[dart]!;
      expect(src, contains('ctx.effect('));
      expect(src, contains('Outcome<'));
      expect(src, contains('throwIfCancelled'));
      expect(src, isNot(contains('throw ')));
      expect(src, contains("id: 'word-cards'"), reason: 'manifest id 必须与目录一致');
      expect(src, contains("slotId: 'app.input.right'"), reason: '默认示范填宿主图标位');
      final r = selfCheckGenerated(files, knownCapabilityIds: _hostCaps);
      expect(r.isOk, isTrue);
    });


    // —— 另外三条纪律判据也各自要能单独逼红（自检不是只盯着回收那一条）——
    Map<String, String> _dartFiles(String id) => generatePluginFiles(ScaffoldSpec(
          id: id,
          name: id,
          description: 'd',
          kind: ScaffoldKind.dart,
        ));

    test('骨架里冒出 throw → 自检拒绝，并且说清"一律返回 Outcome"', () {
      final files = _dartFiles('throwy-one');
      final key = files.keys.firstWhere((k) => k.endsWith('.dart'));
      final broken = {key: files[key]! + '\nObject? boom() { throw StateError(\"偏要抛\"); }\n'};
      final r = selfCheckGenerated(broken, knownCapabilityIds: _hostCaps);
      expect(r.isErr, isTrue, reason: '模板漂移出 throw 就发出去，等于平台亲自教作者违反第一条纪律');
      expect(r.failureOrNull?.hint, contains('出现了 throw'));
      expect(r.failureOrNull?.hint, contains('Outcome'));
    });

    test('骨架不再返回 Outcome → 只点这一条，不把别的三条一起误报', () {
      final files = _dartFiles('no-outcome-one');
      final key = files.keys.firstWhere((k) => k.endsWith('.dart'));
      final broken = {key: files[key]!.replaceAll('Outcome<', 'Object?>')};
      final r = selfCheckGenerated(broken, knownCapabilityIds: _hostCaps);
      expect(r.isErr, isTrue);
      expect(r.failureOrNull?.hint, contains('Outcome'));
      expect(r.failureOrNull?.hint, isNot(contains('ctx.effect')),
          reason: '骨架里回收还在却报它，作者就会去动没坏的地方 —— 误报比漏报更消耗信任');
    });

    test('骨架丢掉 await 边界的取消复查 → 点名"取消令牌复查"', () {
      final files = _dartFiles('no-cancel-one');
      final key = files.keys.firstWhere((k) => k.endsWith('.dart'));
      final broken = {key: files[key]!.replaceAll('throwIfCancelled', '// 不复查取消令牌')};
      final r = selfCheckGenerated(broken, knownCapabilityIds: _hostCaps);
      expect(r.isErr, isTrue,
          reason: '不复查取消令牌的插件在用户关掉面板之后还在念下一个单词 —— 这是平台最容易被感知的失态');
      expect(r.failureOrNull?.message, contains('不符合作者纪律'),
          reason: '要点破这是"作者纪律"问题（生成物不合规），不是运行不起来');
      expect(r.failureOrNull?.hint, contains('await 边界的取消令牌复查'),
          reason: '「取消令牌」四个字太松：要说破缺的是 **await 边界的复查**，作者才知道往哪儿补');
    });

    test('四条判据同时坏 → 四条都列出来，不许只报第一条', () {
      final files = _dartFiles('all-bad-one');
      final key = files.keys.firstWhere((k) => k.endsWith('.dart'));
      final broken = {
        key: files[key]!
            .replaceAll('ctx.effect(', '// ctx.effect(')
            .replaceAll('Outcome<', 'Object?>')
            .replaceAll('throwIfCancelled', '// 不复查') +
            '\nObject? boom() { throw StateError(\"偏要抛\"); }\n'
      };
      final r = selfCheckGenerated(broken, knownCapabilityIds: _hostCaps);
      expect(r.isErr, isTrue);
      final hint = r.failureOrNull?.hint ?? '';
      expect(hint.split('；').where((p) => p.trim().isNotEmpty).length, greaterThanOrEqualTo(3),
          reason: '一次跑完就把所有违规说完；只报第一条 = 作者改一条跑一次，来回四趟');
    });

    test('缺 effect 回收的骨架会被自检拦下（自检不是走过场）', () {
      final files = generatePluginFiles(ScaffoldSpec(
        id: 'leaky-one',
        name: '漏回收',
        description: 'd',
        kind: ScaffoldKind.dart,
      ));
      final key = files.keys.firstWhere((k) => k.endsWith('.dart'));
      final broken = {key: files[key]!.replaceAll('ctx.effect(chip.valueOrNull!);', '// 忘了挂回收')};
      final r = selfCheckGenerated(broken, knownCapabilityIds: _hostCaps);
      expect(r.isErr, isTrue);
      expect(r.failureOrNull?.hint, contains('ctx.effect'));
    });
  });
}
