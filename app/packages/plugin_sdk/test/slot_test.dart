import 'package:plugin_sdk/plugin_sdk.dart';
import 'package:test/test.dart';

const appRoot = SlotDef(
  id: 'app.input.right',
  kind: SlotKind.list,
  scope: SlotScope.sessionMaybe,
  ownerPluginId: 'app',
  description: '输入条右侧图标位',
);

SlotContribution<Object?> c(
  String plugin,
  String id, {
  String slot = 'app.input.right',
  int order = 0,
  int priority = 0,
  String? key,
  Object? payload,
  Object? Function(Map<String, Object?>)? select,
}) =>
    SlotContribution<Object?>(
      slotId: slot,
      pluginId: plugin,
      id: id,
      label: '$plugin/$id',
      order: order,
      priority: priority,
      key: key,
      payload: payload ?? '$plugin:$id',
      select: select,
    );

void main() {
  late SlotRegistry reg;
  setUp(() {
    reg = SlotRegistry();
    expect(reg.declare(appRoot).isOk, isTrue);
  });

  group('声明', () {
    test('非法槽 id 被拒并给出命名规范', () {
      for (final bad in ['InputRight', 'input', 'a.b.Cd', 'app.input.right.leaf.extra']) {
        final r = reg.declare(SlotDef(id: bad, kind: SlotKind.list, scope: SlotScope.root, ownerPluginId: 'app', description: 'd'));
        expect(r.isErr, isTrue, reason: bad);
        expect(r.failureOrNull?.hint, contains('<owner>'));
      // 判据原句钉住：规则（几段、字符集）是契约，测试以前只转述成 contains('<owner>')，
      // 产品把规则句子改成别的说法（甚至删掉字符集说明）也不会红。
      expect(r.failureOrNull?.message, matches(RegExp(r'^槽 id ".+" 不合法$')),
      reason: '形状钉住：必须把**坏的那个 id 原样引号回显**，退化成笼统一句「不合法」作者就得自己猜');
      expect(r.failureOrNull?.hint, contains('段为小写字母/数字'),
          reason: '规则的原文只出现在 hint 里（实测：message 是「槽 id \"X\" 不合法」）');
      }
      expect(isValidSlotId('dictation.wordAction'), isTrue);
      expect(isValidSlotId('app.input.right'), isTrue);
    });

    test('两个 owner 抢同一个槽 → 后来者被拒且指名原 owner', () {
      reg.declare(const SlotDef(id: 'app.x.y', kind: SlotKind.list, scope: SlotScope.root, ownerPluginId: 'app', description: 'd'));
      final r = reg.declare(const SlotDef(id: 'app.x.y', kind: SlotKind.list, scope: SlotScope.root, ownerPluginId: 'other', description: 'd'));
      expect(r.isErr, isTrue);
      expect(r.failureOrNull?.message, contains('已由 app 声明'));
    });
  });

  group('注册期守卫： kinds 要的东西没给，就当场说清（这几句话以前测试里一个字都没有）', () {
    test('keyed 槽不带 key → 拒，并警告"拼错的 key 永不渲染"', () {
      reg.declare(const SlotDef(
          id: 'hello.k.tray', kind: SlotKind.keyed, scope: SlotScope.root, ownerPluginId: 'hello', description: 'd'));
      final r = reg.register(c('hello', 'x', slot: 'hello.k.tray'));
      expect(r.isErr, isTrue, reason: r.failureOrNull?.message);
      expect(r.failureOrNull?.message, contains('是 keyed 槽，注册必须带 key'));
      expect(r.failureOrNull?.hint, contains('拼错的 key 永不渲染'),
          reason: 'keyed 槽最坏的坑就是 key 拼错后静默不显示，判词必须提前点名');
    });

    test('chain 槽不给 select → 拒，并说明 select 必须是纯函数', () {
      reg.declare(const SlotDef(
          id: 'hello.c.tray', kind: SlotKind.chain, scope: SlotScope.root, ownerPluginId: 'hello', description: 'd'));
      final r = reg.register(c('hello', 'x', slot: 'hello.c.tray'));
      expect(r.isErr, isTrue, reason: r.failureOrNull?.message);
      expect(r.failureOrNull?.message, contains('是 chain 槽，注册必须提供 select'));
      expect(r.failureOrNull?.hint, contains('select 必须是纯函数'),
          reason: 'chain 槽靠 select 选人，写成有副作用的函数会时好时坏 —— 判词要说死');
    });

    test('list 槽带 key → 拒（key 只属于 keyed 槽）', () {
      final r = reg.register(c('app', 'x', slot: 'app.input.right', key: 'oops'));
      expect(r.isErr, isTrue, reason: r.failureOrNull?.message);
      expect(r.failureOrNull?.message, contains('槽，不接受 key'));
      expect(r.failureOrNull?.hint, contains('key 只用于 keyed 槽'));
    });

    test('超出 maxEntries → 拒，并说清"先卸载不需要的插件"', () {
      reg.declare(const SlotDef(
        id: 'hello.l.tray',
        kind: SlotKind.list,
        scope: SlotScope.root,
        ownerPluginId: 'hello',
        description: 'd',
        maxEntries: 1,
      ));
      expect(reg.register(c('hello', 'a', slot: 'hello.l.tray')).isOk, isTrue);
      final r = reg.register(c('hello', 'b', slot: 'hello.l.tray'));
      expect(r.isErr, isTrue, reason: r.failureOrNull?.message);
      expect(r.failureOrNull?.message, contains('最多 1 个条目，已满'));
      expect(r.failureOrNull?.hint, contains('先卸载不需要的插件'),
          reason: '槽满的出路在插件侧卸载，不是让人去关别的功能');
    });
  });

  group('declare-then-fill', () {
    test('填一个还不存在的槽不报错，等 owner 声明时自动生效', () {
      final r = reg.register(c('hello', 'h', slot: 'hello.tray'));
      expect(r.isOk, isTrue);
      expect(reg.entries('hello.tray'), isEmpty);
      reg.declare(const SlotDef(id: 'hello.tray', kind: SlotKind.list, scope: SlotScope.root, ownerPluginId: 'hello', description: 'd'));
      expect(reg.entries('hello.tray').map((e) => e.id), ['h']);
    });

    test('卸载 disposer 在 pending 态与生效态都干净（幂等）', () async {
      final d1 = reg.register(c('hello', 'pending1', slot: 'hello.tray2'));
      final disposer = d1.valueOrNull!;
      await disposer();
      await disposer(); // 幂等
      reg.declare(const SlotDef(id: 'hello.tray2', kind: SlotKind.list, scope: SlotScope.root, ownerPluginId: 'hello', description: 'd'));
      expect(reg.entries('hello.tray2'), isEmpty);

      final d2 = reg.register(c('hello', 'live', slot: 'app.input.right'));
      final off = d2.valueOrNull!;
      await off();
      await off();
      expect(reg.entries('app.input.right'), isEmpty);
    });
  });

  group('list 槽', () {
    test('order 升序，同 order 按注册序（后注册者靠后）', () {
      reg.register(c('a', 'x', order: 10));
      reg.register(c('b', 'y', order: 0));
      reg.register(c('c', 'z', order: 10));
      expect(reg.entries('app.input.right').map((e) => e.id), ['y', 'x', 'z']);
    });

    test('不同插件同 order 共存（不打架）', () {
      reg.register(c('a', 'x', order: 0));
      reg.register(c('b', 'y', order: 0));
      expect(reg.entries('app.input.right').length, 2);
    });
  });

  group('single 槽（遮蔽语义）', () {
    setUp(() {
      reg.declare(const SlotDef(
        id: 'app.composer.takeover',
        kind: SlotKind.single,
        scope: SlotScope.session,
        ownerPluginId: 'app',
        description: '整条输入区接管（听写播控条这种）',
      ));
    });

    test('只渲染最低 priority 的存活者', () {
      reg.register(c('dictation', 'bar', slot: 'app.composer.takeover', priority: 10));
      reg.register(c('voice', 'bar', slot: 'app.composer.takeover', priority: 0));
      final shown = reg.entries('app.composer.takeover');
      expect(shown.length, 1);
      expect(shown.single.pluginId, 'voice');
    });

    test('同格同 priority 冲突：报错并**指名占用者**（不是静默丢弃）', () {
      reg.register(c('dictation', 'bar', slot: 'app.composer.takeover', priority: 5));
      final r = reg.register(c('voice', 'bar', slot: 'app.composer.takeover', priority: 5));
      expect(r.isErr, isTrue);
      expect(r.failureOrNull?.message, contains('已被 dictation 以 priority 5 占用'));
      expect(r.failureOrNull?.hint, contains('priority'));
    });

    test('占用者崩溃让位（abdicate）后，下一个存活者顶上', () {
      reg.register(c('dictation', 'bar', slot: 'app.composer.takeover', priority: 0));
      reg.register(c('voice', 'bar', slot: 'app.composer.takeover', priority: 5));
      expect(reg.entries('app.composer.takeover').single.pluginId, 'dictation');
      expect(reg.reportEntryError('app.composer.takeover', 'bar', pluginId: 'dictation'), isTrue);
      expect(reg.entries('app.composer.takeover').single.pluginId, 'voice');
    });

    test('全部让位 → 渲染空（宿主回落到默认输入区）', () {
      reg.register(c('dictation', 'bar', slot: 'app.composer.takeover'));
      reg.reportEntryError('app.composer.takeover', 'bar', pluginId: 'dictation');
      expect(reg.entries('app.composer.takeover'), isEmpty);
    });
  });

  group('keyed 槽', () {
    setUp(() {
      reg.declare(const SlotDef(
        id: 'app.tool.view',
        kind: SlotKind.keyed,
        scope: SlotScope.session,
        ownerPluginId: 'app',
        description: '按工具名派发的工具卡',
      ));
    });

    test('缺 key 直接拒（typo 的 key 永不渲染）', () {
      final r = reg.register(c('p', 'v', slot: 'app.tool.view'));
      expect(r.isErr, isTrue);
      expect(r.failureOrNull?.message, contains('必须带 key'));
    });

    test('同 key 再注册 = 替换（不是并存）', () {
      reg.register(c('p1', 'v', slot: 'app.tool.view', key: 'read_file', payload: 'old'));
      reg.register(c('p2', 'v2', slot: 'app.tool.view', key: 'read_file', payload: 'new'));
      final e = reg.entries('app.tool.view', key: 'read_file');
      expect(e.length, 1);
      expect(e.single.contribution.payload, 'new');
    });

    test('查不存在的 key 返回空（而不是渲染别人的卡）', () {
      reg.register(c('p1', 'v', slot: 'app.tool.view', key: 'read_file'));
      expect(reg.entries('app.tool.view', key: 'read_flie'), isEmpty); // typo
    });
  });

  group('chain 槽', () {
    setUp(() {
      reg.declare(const SlotDef(
        id: 'app.chat.node',
        kind: SlotKind.chain,
        scope: SlotScope.session,
        ownerPluginId: 'app',
        description: '消息节点接管链',
      ));
    });

    test('缺 select 直接拒（decline 决策必须在此处，不能藏在组件里）', () {
      final r = reg.register(c('p', 'n', slot: 'app.chat.node'));
      expect(r.isErr, isTrue);
      expect(r.failureOrNull?.message, contains('select'));
    });

    test('第一个 select 非 null 者当选；全 null → 宿主默认渲染', () {
      reg.register(c('dictation', 'card', slot: 'app.chat.node', priority: 10, select: (d) => d['kind'] == 'wordlist' ? d : null));
      reg.register(c('code', 'card', slot: 'app.chat.node', priority: 0, select: (d) => d['kind'] == 'code' ? d : null));
      expect(reg.entries('app.chat.node', ownerData: {'kind': 'wordlist'}).single.pluginId, 'dictation');
      expect(reg.entries('app.chat.node', ownerData: {'kind': 'code'}).single.pluginId, 'code');
      expect(reg.entries('app.chat.node', ownerData: {'kind': 'text'}), isEmpty);
    });

    test('select 被反复调用不改变账本（纯函数要求的最低保证）', () {
      var calls = 0;
      reg.register(c('p', 'n', slot: 'app.chat.node', select: (d) {
        calls++;
        return d['mine'] == true ? d : null;
      }));
      final data = {'mine': true};
      reg.entries('app.chat.node', ownerData: data);
      reg.entries('app.chat.node', ownerData: data);
      expect(calls, 2);
      expect(reg.entries('app.chat.node', ownerData: data).length, 1);
      expect(data, {'mine': true}); // select 没 ability 篡改 ownerData
    });
  });

  group('容量与通知', () {
    test('不是 keyed 槽就不接受 key（判据要指到该改的人：作者）', () {
      expect(
          reg.declare(const SlotDef(
            id: 'app.single.plain',
            kind: SlotKind.single,
            scope: SlotScope.root,
            ownerPluginId: 'app',
            description: '单占位，不分组',
          )).isOk,
          isTrue);
      final r = reg.register(SlotContribution<Object?>(
        slotId: 'app.single.plain',
        pluginId: 'p1',
        id: 'a',
        label: 'A',
        key: 'group-1',
        payload: 'a',
      ));
      expect(r.isErr, isTrue, reason: 'single 槽带 key 是作者对槽语义的理解错了');
      expect(r.failureOrNull?.message, contains('不接受 key'),
          reason: '要说出是哪个槽、哪种槽 —— 只报"参数不对"作者只能猜');
      expect(r.failureOrNull?.message, contains('app.single.plain'));
    });

    test('maxEntries 满了拒绝后来者', () {
      reg.declare(const SlotDef(
        id: 'app.input.dock',
        kind: SlotKind.list,
        scope: SlotScope.session,
        ownerPluginId: 'app',
        description: '只允许一个常驻坞',
        maxEntries: 1,
      ));
      expect(reg.register(c('a', 'x', slot: 'app.input.dock')).isOk, isTrue);
      final r = reg.register(c('b', 'y', slot: 'app.input.dock'));
      expect(r.isErr, isTrue);
      expect(r.failureOrNull?.message, contains('最多 1 个'));
    });

    test('同一微任务内多次变更只通知一次（microtask-batched）', () async {
      var hits = 0;
      reg.subscribe((_) => hits++);
      reg.register(c('a', 'x'));
      reg.register(c('b', 'y'));
      reg.register(c('c', 'z'));
      expect(hits, 0); // 同步内不通知
      await Future<void>.delayed(Duration.zero);
      expect(hits, 1);
      reg.reportEntryError('app.input.right', 'x');
      await Future<void>.delayed(Duration.zero);
      expect(hits, 2);
    });

    test('versionOf 单调递增，反注册后不再收到通知', () async {
      final v0 = reg.versionOf('app.input.right');
      reg.register(c('a', 'x'));
      await Future<void>.delayed(Duration.zero);
      expect(reg.versionOf('app.input.right'), greaterThan(v0));
      var hits = 0;
      final off = reg.subscribe((_) => hits++);
      await off();
      reg.register(c('b', 'y'));
      await Future<void>.delayed(Duration.zero);
      expect(hits, 0);
    });

    test('监听器抛异常被吞（注册表变更不可被观察者否决）', () async {
      reg.subscribe((_) => throw StateError('观察者炸了'));
      expect(() => reg.register(c('a', 'x')), returnsNormally);
      await Future<void>.delayed(Duration.zero);
      expect(reg.entries('app.input.right').length, 1);
    });
  });

  group('诊断快照', () {
    test('snapshot 足够回答"为什么没显示"（DSH LiveCompositionNode 同形）', () {
      reg.register(c('dictation', 'chip', order: 5));
      reg.register(c('dictation', 'bar', slot: 'app.chat.node', key: null));
      final snap = reg.snapshot('app.input.right');
      expect(snap.single.keys, containsAll(['slot', 'registrant', 'id', 'order', 'priority', 'active']));
      expect(snap.single['registrant'], 'dictation');
      expect(snap.single['active'], isTrue);
    });

    test('让位的条目还在账本上，只是 active=false（面板要说"已让位"，不许凭空消失）', () {
      reg.register(c('dictation', 'chip'));
      expect(reg.reportEntryError('app.input.right', 'chip'), isTrue);

      // 渲染视图里它确实没了（single 槽只剩活的）……
      expect(reg.entries('app.input.right').map((e) => e.id), isEmpty, reason: '界面上不该还有它');
      // ……但体检必须还看得见它登记过什么、为什么不活。
      final snap = reg.snapshot('app.input.right');
      expect(snap, hasLength(1));
      expect(snap.single['id'], 'chip');
      expect(snap.single['active'], isFalse, reason: '消失 = 用户永远不知道自己的入口被摘了');
    });
  });
}
