import 'package:plugin_kernel/plugin_kernel.dart';
import 'package:test/test.dart';

const manifest = PluginManifest(
  id: 'cfg-probe',
  name: '配置探针',
  description: 'd',
  inject: [],
  config: {'gapSeconds': 5},
  params: [
    PluginParam(name: 'gapSeconds', label: '间隔', type: PluginParamType.number, defaultValue: 5, min: 1, max: 30),
    PluginParam(name: 'readChinese', label: '念中文', type: PluginParamType.boolean, defaultValue: true),
    PluginParam(name: 'lastGap', label: '上次用的间隔', type: PluginParamType.number, defaultValue: 5, volatile: true),
  ],
);

void main() {
  group('四层合并', () {
    test('优先级：会话内 > 用户 > 方案档 > manifest.config > 参数默认', () {
      final s = ConfigStack(
        manifest: manifest,
        profile: const {'gapSeconds': 10},
        user: const {'gapSeconds': 7},
        session: const {'gapSeconds': 8},
      );
      expect(s.value('gapSeconds'), 8);
      expect(s.layerOf('gapSeconds'), ConfigLayer.session);
      expect(ConfigStack(manifest: manifest, profile: const {'gapSeconds': 10}, user: const {'gapSeconds': 7}).value('gapSeconds'), 7);
      expect(ConfigStack(manifest: manifest, profile: const {'gapSeconds': 10}).value('gapSeconds'), 10);
      expect(ConfigStack(manifest: manifest).value('gapSeconds'), 5, reason: 'manifest.config 层');
      expect(ConfigStack(manifest: manifest).layerOf('gapSeconds'), ConfigLayer.defaults);
    });

    test('存在性覆盖：用户显式写 false 就是覆盖，不能因为"和默认值一样"被当没填', () {
      // readChinese 默认 true；用户填 true 也要算"用户填过"（DSH 同款坑）。
      final s = ConfigStack(manifest: manifest, user: const {'readChinese': true});
      expect(s.value('readChinese'), true);
      expect(s.layerOf('readChinese'), ConfigLayer.user);
      final f = ConfigStack(manifest: manifest, user: const {'readChinese': false});
      expect(f.value('readChinese'), false);
      expect(f.layerOf('readChinese'), ConfigLayer.user);
    });

    test('resolveAll 说清每个值的来源（面板"来自方案档/已被你改过"）', () {
      final r = ConfigStack(manifest: manifest, profile: const {'gapSeconds': 12}).resolveAll();
      expect(r['gapSeconds'], 12);
      expect(r.layerOf('gapSeconds'), ConfigLayer.profile);
      expect(r.layerOf('readChinese'), ConfigLayer.defaults);
    });

    test('易变值不算变更（不会为它重载插件 / 提示"配置已改动"）', () {
      final a = ConfigStack(manifest: manifest, user: const {'gapSeconds': 5, 'lastGap': 3});
      final b = ConfigStack(manifest: manifest, user: const {'gapSeconds': 5, 'lastGap': 9});
      expect(a.sameExceptVolatile(b), isTrue);
      final c = ConfigStack(manifest: manifest, user: const {'gapSeconds': 6, 'lastGap': 3});
      expect(a.sameExceptVolatile(c), isFalse);
    });
  });

  group('带 revision 的存储', () {
    late ConfigStore store;
    setUp(() => store = ConfigStore());

    test('保存要带 expectedRevision；撞车就报冲突而不是默默覆盖', () async {
      final first = await store.patchUser(manifest: manifest, patch: const {'gapSeconds': 9}, expectedRevision: 0);
      expect(first.isOk, isTrue);
      expect(store.revisionOf('cfg-probe'), 1);

      final stale = await store.patchUser(manifest: manifest, patch: const {'gapSeconds': 3}, expectedRevision: 0);
      expect(stale.isErr, isTrue);
      // 原句钉住：乐观并发的判词是"谁改的"这件事的唯一出口，转述成「刷新」两字太松 ——
      // 产品就算把"别覆盖掉别人的改动"删掉、或把话说成"保存失败"，测试都不会红。
      expect(stale.failureOrNull?.message, contains('这份设置在你编辑期间被别人改过了'),
          reason: '要点破"你编辑期间有人改过"，不是笼统的保存失败');
      expect(stale.failureOrNull?.hint, contains('刷新看最新值再改，别覆盖掉别人的改动'),
          reason: '出路要连"别覆盖别人的改动"一起说，否则用户直接点重试就真覆盖了');
      expect(store.userOf('cfg-probe')['gapSeconds'], 9, reason: '过期写入绝不许覆盖新值');

      final fresh = await store.patchUser(manifest: manifest, patch: const {'gapSeconds': 3}, expectedRevision: 1);
      expect(fresh.isOk, isTrue);
      expect(store.userOf('cfg-probe')['gapSeconds'], 3);
    });

    test('没声明的参数直接拒（typo 不会留下永远读不到的死值）', () async {
      final r = await store.patchUser(manifest: manifest, patch: const {'gapSecnds': 3});
      expect(r.failureOrNull?.code, PluginFailureKind.configInvalid);
      expect(r.failureOrNull?.message, contains('gapSecnds'));
      expect(r.failureOrNull?.hint, contains('先在 params 里声明它，或删掉这一项'),
          reason: '死值的两条出路必须都说：只说"去声明"，用户不知道还能删');
    });

    test('数字参数越界在**写入口**就挡（不是运行时悄悄夹逼）', () async {
      // `ctx.numberConfig` 是照直读的，运行时没人夹逼：900 秒间隔会一路走到喇叭。
      final over = await store.patchUser(manifest: manifest, patch: const {'gapSeconds': 900});
      expect(over.failureOrNull?.code, PluginFailureKind.configInvalid);
      expect(over.failureOrNull?.message, contains('不能大于 30'));
      expect(over.failureOrNull?.message, contains('你填了 900'), reason: '要说清"你填了多少"，不然像插件自己有毛病');
      expect(store.userOf('cfg-probe'), isEmpty, reason: '被拒的写不许留下半个键');

      expect((await store.patchUser(manifest: manifest, patch: const {'gapSeconds': -3})).isErr, isTrue,
          reason: '下限同样要挡');
      expect((await store.patchUser(manifest: manifest, patch: const {'gapSeconds': 'abc'})).isErr, isTrue,
          reason: '"数字参数收到非数字"也是同一类错误');
      expect((await store.patchUser(manifest: manifest, patch: const {'gapSeconds': 7})).isOk, isTrue);
      expect((await store.patchUser(manifest: manifest, patch: const {'gapSeconds': '7'})).isOk, isTrue,
          reason: '数字串放行 —— 面板输入框交出来的就是字符串');
    });

    test('开关与选项也按声明判；config 里的自由键不判', () async {
      expect((await store.patchUser(manifest: manifest, patch: const {'readChinese': 'yes'})).isErr, isTrue,
          reason: '"yes" 会被 boolConfig 判成 false —— 静默反义比报错恶劣得多');
      expect((await store.patchUser(manifest: manifest, patch: const {'readChinese': false})).isOk, isTrue,
          reason: '显式 false 是合法覆盖');
      // manifest.config 里有、但没在 params 声明的键：结构归插件自己，不判值。
      expect((await store.patchUser(manifest: manifest, patch: const {'gapSeconds': 12})).isOk, isTrue);
    });

    test('patchPath 写单个值也走同一条判据', () async {
      final r = await store.patchPath(manifest: manifest, path: const ['gapSeconds'], value: 900);
      expect(r.failureOrNull?.message, contains('不能大于 30'));
      expect(store.userOf('cfg-probe'), isEmpty);
      // 子路径（深层结构）不判值 —— 那是插件自己的形状。
      expect((await store.patchPath(manifest: manifest, path: const ['gapSeconds', 'unit'], value: 900)).isOk, isTrue);
    });

    test('会话层归 store 所有（面板与内核从同一处读），而且不落盘', () async {
      await store.patchUser(manifest: manifest, patch: const {'gapSeconds': 7});
      store.setSessionOverride('cfg-probe', 'gapSeconds', 9);

      final stack = store.stackFor(manifest);
      expect(stack.value('gapSeconds'), 9, reason: '临时值该赢过用户层');
      expect(stack.layerOf('gapSeconds'), ConfigLayer.session,
          reason: '面板那句「本次会话临时」靠这个才不是空话；以前它活在 ctx 私人笔记本里，面板永远看不见');
      expect(store.userOf('cfg-probe'), {'gapSeconds': 7}, reason: '试试不该动用户的设置');
      expect(store.sessionOf('cfg-probe'), {'gapSeconds': 9});

      store.setSessionOverride('cfg-probe', 'gapSeconds', null);
      expect(store.stackFor(manifest).value('gapSeconds'), 7, reason: '撤掉临时值 = 回到用户层');
      expect(store.sessionOf('cfg-probe'), isEmpty);

      store.setSessionOverride('cfg-probe', 'readChinese', false);
      store.clearSessionOverrides('cfg-probe');
      expect(store.sessionOf('cfg-probe'), isEmpty, reason: '清空只清这一层，用户层不动');
      expect(store.userOf('cfg-probe'), {'gapSeconds': 7});
    });

    test('「先试试这组值」走同一套判据；被拒不许留下半个临时值', () async {
      final bad = store.trial(manifest: manifest, patch: const {'gapSeconds': 900});
      expect(bad.failureOrNull?.message, contains('不能大于 30'),
          reason: '"只是试试"也会真的念给用户听，越界一样得拒');
      expect(store.sessionOf('cfg-probe'), isEmpty, reason: '被拒的试值不许进会话层');

      expect(store.trial(manifest: manifest, patch: const {'gapSecnds': 3}).isErr, isTrue,
          reason: '未声明的键一样拒');

      expect(store.trial(manifest: manifest, patch: const {'gapSeconds': 8}).isOk, isTrue);
      expect(store.stackFor(manifest).value('gapSeconds'), 8);
      expect(store.userOf('cfg-probe'), isEmpty, reason: '试完不用记得"改回来" —— 它压根没进设置');
    });

    test('路径改写只动一个位置；传 null 即删除', () async {
      await store.patchUser(manifest: manifest, patch: const {'gapSeconds': 4});
      final r = await store.patchPath(manifest: manifest, path: const ['gapSeconds'], value: 11);
      expect(r.isOk, isTrue);
      expect(store.userOf('cfg-probe'), {'gapSeconds': 11});
      await store.patchPath(manifest: manifest, path: const ['gapSeconds'], value: null);
      expect(store.userOf('cfg-probe').containsKey('gapSeconds'), isFalse);
      expect(store.patchPath(manifest: manifest, path: const [], value: 1).isErr, isTrue);
    });

    test('patchPath 也拒未声明的参数（两个写入口必须一样严）', () async {
      // 以前只有 `patchUser` 查：绕过它走 `patchPath` 就能往 config 里塞死值 ——
      // 面板只列声明过的参数，用户改了没反应，也永远看不见自己写进去的那一行。
      final typo = await store.patchPath(manifest: manifest, path: const ['gapSecnds'], value: 3);
      expect(typo.failureOrNull?.code, PluginFailureKind.configInvalid);
      expect(typo.failureOrNull?.message, contains('gapSecnds'));
      expect(store.userOf('cfg-probe'), isEmpty, reason: '被拒的写不许留下半个键');

      // 子路径（`参数.子键`）跟着首段判：首段声明过就放行。
      final nested = await store.patchPath(manifest: manifest, path: const ['gapSeconds', 'unit'], value: '秒');
      expect(nested.isErr, isFalse, reason: '首段是声明过的参数，深层结构由插件自己管');

      // manifest.config 里有的键同样放行（与 patchUser 同一判据）。
      expect((await store.patchPath(manifest: manifest, path: const ['gapSeconds'], value: 7)).isOk, isTrue);
    });

    test('恢复默认只清用户层，方案档与默认保留', () async {
      store.setActiveProfile('日常听写');
      store.replaceProfile('日常听写', 'cfg-probe', const {'gapSeconds': 20});
      await store.patchUser(manifest: manifest, patch: const {'gapSeconds': 2});
      expect(store.stackFor(manifest).value('gapSeconds'), 2);
      store.resetUser('cfg-probe');
      expect(store.stackFor(manifest).value('gapSeconds'), 20, reason: '回到方案档，不是回到出厂默认');
      store.setActiveProfile(null);
      expect(store.stackFor(manifest).value('gapSeconds'), 5);
    });
  });
}
