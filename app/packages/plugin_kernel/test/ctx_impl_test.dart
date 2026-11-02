import 'package:plugin_sdk/testing.dart';
import 'package:plugin_kernel/plugin_kernel.dart';
import 'package:test/test.dart';

PluginManifest _m({PluginTrust trust = PluginTrust.trusted, List<PluginPermission> perms = const []}) => PluginManifest(
      id: 'boundary-probe',
      name: '边界探针',
      description: 'd',
      trust: trust,
      permissions: perms,
      inject: const [],
      params: const [PluginParam(name: 'gap', label: '间隔', type: PluginParamType.number, defaultValue: 5)],
    );

void main() {
  mainStoreIsolation();
  late CapabilityRegistry caps;
  late SlotRegistry slots;
  late ConfigStore store;
  late InMemoryTraceSink trace;
  late PluginFiber fiber;

  KernelPluginCtx ctxFor(PluginManifest manifest, {Map<String, Object?> user = const {}}) {
    fiber = PluginFiber(
      plugin: _StubPlugin(manifest),
      epochOf: (_) => 'e',
      ctxFactory: (f) => KernelPluginCtx(
        fiber: f,
        manifest: manifest,
        capabilities: caps,
        slots: slots,
        config: store.stackFor(manifest, session: user),
        trace: trace,
        traceId: 'trace-of-${manifest.id}',
      ),
    );
    return fiber.ctxFactory(fiber) as KernelPluginCtx;
  }

  setUp(() {
    caps = CapabilityRegistry();
    slots = SlotRegistry();
    for (final d in kHostSlotContract) {
      slots.declare(d);
    }
    store = ConfigStore();
    trace = InMemoryTraceSink();
    caps.register(FakeStore(), ownerPluginId: 'app');
    caps.register(FakeInteract(), ownerPluginId: 'app');
  });

  group('未声明即拒（权限）', () {
    test('没声明 storage:plugin 就想用存储 → 拒，并告诉你加什么', () {
      final ctx = ctxFor(_m());
      final r = ctx.capabilities.require<Store>(ServiceKeys.store);
      expect(r.failureOrNull?.code, PluginFailureKind.permissionDenied);
      expect(r.failureOrNull?.message, contains('想要用 app.store'));
      expect(r.failureOrNull?.hint, contains('"storage:plugin"'));
    });

    test('声明了就放行', () async {
      final ctx = ctxFor(_m(perms: const [PluginPermission.pluginStorage]));
      final r = ctx.capabilities.require<Store>(ServiceKeys.store);
      expect(r.isOk, isTrue);
      await r.valueOrNull!.write('k', 'v');
      // 前缀由平台加（作者只写 'k'，落盘是 'plugin:<id>:k'）—— 见 _NamespacedStore。
      expect((caps.resolve<Store>(ServiceKeys.store).valueOrNull! as FakeStore).data['plugin:boundary-probe:k'], 'v');
    });

    test('能力本身没注册过 → 说的是"本机没有提供"，不是权限问题', () {
      final ctx = ctxFor(_m(perms: const [PluginPermission.speechRecognition]));
      final r = ctx.capabilities.require<Transcribe>(ServiceKeys.transcribe);
      expect(r.failureOrNull?.code, PluginFailureKind.missingCapability);
      expect(r.failureOrNull?.message, contains('这台机器没有提供能力'),
          reason: '「没有提供」四个字什么都能套；要说破是"这台机器"缺东西，人才会去装而不是去改插件');
    });

    test('hasPermission 按 wire 名判定（面板与运行时同一口径）', () {
      final ctx = ctxFor(_m(perms: const [PluginPermission.speechSynthesis]));
      expect(ctx.hasPermission(PluginPermission.speechSynthesis), isTrue);
      expect(ctx.hasPermission(PluginPermission.camera), isFalse);
    });
  });

  group('信任分级', () {
    test('非 trusted 插件不能替换能力实现', () async {
      final ctx = ctxFor(_m(trust: PluginTrust.declarative, perms: const [PluginPermission.pluginStorage]));
      final r = await ctx.capabilities.provide<Store>(ServiceKeys.store, FakeStore(seed: const {'hijack': '1'}));
      expect(r.failureOrNull?.code, PluginFailureKind.permissionDenied);
      // 原句断言：只转述成 contains('平台自带') 的话，产品把出路说没了自己不会红。
      expect(r.failureOrNull?.message, contains('级插件不能替换能力实现'),
          reason: '要说清是"谁的级别"不许 —— 否则作者以为是能力没装');
      expect(r.failureOrNull?.hint, contains('请由平台自带插件提供'), reason: '被拒也要给真正走得通的出路');
    });

    test('trusted 可替换，卸载后回退到宿主实现（离线 TTS 的接入方式）', () async {
      final ctx = ctxFor(_m(perms: const [PluginPermission.pluginStorage]));
      final hijack = FakeStore(seed: const {'untouched': '0'});
      final r = await ctx.capabilities.provide<Store>(ServiceKeys.store, hijack, priority: -1);
      expect(r.isOk, isTrue);
      final store = ctx.capabilities.require<Store>(ServiceKeys.store).valueOrNull!;
      await store.write('mine', '1');
      expect(hijack.data['plugin:boundary-probe:mine'], '1', reason: '写入确实进了顶替者的实现');
      await r.valueOrNull!();
      final back = ctx.capabilities.require<Store>(ServiceKeys.store).valueOrNull!;
      expect((await back.read('mine')).valueOrNull, isNull, reason: '卸载后回退到宿主实现，自然读不到顶替者的数据');
    });

    test('契约版本对不上的注册被拒（不许拿旧实现冒充新契约）', () async {
      final ctx = ctxFor(_m(perms: const [PluginPermission.pluginStorage]));
      final r = await ctx.capabilities.provide<Store>(
        const ServiceKey<Store>('app.store', contractVersion: 'v2'),
        FakeStore(),
      );
      expect(r.failureOrNull?.message, contains('注册的能力契约版本 v1 与键 v2 不一致'),
          reason: '整句钉住：两个版本号都在句里出现，作者才知道自己注册的是 v1、别人要的是 v2');
      expect(r.failureOrNull?.hint, contains('让 ServiceKey 与实现的 key 对齐'),
          reason: '出路必须可执行：改哪儿要说死');
      expect(r.failureOrNull?.code, PluginFailureKind.incompatibleContract);
    });
  });

  group('槽边界', () {
    test('只能在自己命名空间声明槽', () {
      final ctx = ctxFor(_m());
      expect(
        ctx.slots.declare(const SlotDef(id: 'boundary-probe.wordAction', kind: SlotKind.list, scope: SlotScope.session, ownerPluginId: 'boundary-probe', description: 'd')).isOk,
        isTrue,
      );
      final bad = ctx.slots.declare(const SlotDef(id: 'app.input.right2', kind: SlotKind.list, scope: SlotScope.root, ownerPluginId: 'app', description: 'd'));
      expect(bad.failureOrNull?.code, PluginFailureKind.permissionDenied);
      expect(bad.failureOrNull?.hint, contains('boundary-probe.'));
      expect(bad.failureOrNull?.message, contains('只能在自己命名空间下声明槽'),
          reason: '越界声明要说破"越界"这件事本身，只给个正确写法让人以为只是拼错');
    });

    test('id 前缀与 owner 不一致 = 结构错误（防"挂羊头"）', () {
      final ctx = ctxFor(_m());
      final r = ctx.slots.declare(const SlotDef(id: 'someone-else.thing', kind: SlotKind.list, scope: SlotScope.root, ownerPluginId: 'boundary-probe', description: 'd'));
      expect(r.failureOrNull?.code, PluginFailureKind.configInvalid);
      expect(r.failureOrNull?.message, contains('的命名空间与 owner'),
          reason: '"挂羊头"要当场点破：id 前缀和 owner 对不上是结构错误，不是权限问题');
      expect(r.failureOrNull?.hint, contains('槽 id 必须以'), reason: '出路要说死成可照抄的形状');
    });

    test('不能冒充别人填槽', () {
      final ctx = ctxFor(_m());
      final r = ctx.slots.register(const SlotContribution<Object?>(
        slotId: 'app.input.right',
        pluginId: 'some-other-plugin',
        id: 'x',
        label: 'x',
        payload: 'p',
      ));
      expect(r.failureOrNull?.code, PluginFailureKind.permissionDenied);
      expect(r.failureOrNull?.message, contains('some-other-plugin'));
      expect(r.failureOrNull?.message, contains('不能冒充别的插件填槽'),
          reason: '光报对方 id 不够，得说破这是"冒充"');
      expect(r.failureOrNull?.hint, contains('pluginId 必须是自己'));
    });

    test('填宿主槽可以，卸载 effect 后账本干净', () async {
      final ctx = ctxFor(_m());
      final r = ctx.slots.register(const SlotContribution<Object?>(
        slotId: 'app.input.right',
        pluginId: 'boundary-probe',
        id: 'chip',
        label: 'chip',
        payload: 'p',
      ));
      expect(r.isOk, isTrue);
      expect(ctx.slots.entries('app.input.right').map((e) => e.id), ['chip']);
      await fiber.ensure();
      await fiber.unload();
      expect(fiber.effectTree, isEmpty);
    });
  });

  group('配置与可观测性', () {
    test('会话内临时覆盖不落盘（"这次先按 8 秒"不该改走用户默认）', () async {
      final ctx = ctxFor(_m(perms: const [PluginPermission.pluginStorage]));
      await fiber.ensure();
      expect(ctx.numberConfig('gap', 5), 5);
      ctx.setSessionOverride('gap', 8);
      expect(ctx.numberConfig('gap', 5), 8);
      expect(store.userOf('boundary-probe'), isEmpty, reason: '临时值绝不写进用户配置');
    });

    test('numberConfig 容忍字符串（设置页存成 "5" 也不炸）', () {
      final ctx = ctxFor(_m());
      ctx.setSessionOverride('gap', '7.5');
      expect(ctx.numberConfig('gap', 5), 7.5);
      ctx.setSessionOverride('gap', 'abc');
      expect(ctx.numberConfig('gap', 4), 4);
    });

    test('每条日志都带 traceId 与 pluginId（接现成「推理日志」页）', () {
      final ctx = ctxFor(_m());
      ctx.log.info('抽到 12 个词');
      ctx.log.fail('没能播报', cause: '403');
      final recs = trace.forPlugin('boundary-probe');
      expect(recs.map((r) => r.message), ['抽到 12 个词', '没能播报']);
      expect(recs.every((r) => r.traceId == 'trace-of-boundary-probe'), isTrue);
      expect(recs.last.level, TraceLevel.fail);
      expect(recs.last.cause.toString(), contains('403'));
    });
  });
}

class _StubPlugin implements AppPlugin {
  _StubPlugin(this.manifest);
  @override
  final PluginManifest manifest;
  @override
  Outcome<Disposable?> apply(PluginCtx ctx) => const Ok<Disposable?>(null);
  @override
  Future<Outcome<PluginRunResult>> run(PluginCtx ctx, PluginInput input) async => const Ok<PluginRunResult>(PluginRunResult());
}

void mainStoreIsolation() {
  group('存储按插件隔离（平台强制，不靠作者自觉）', () {
    test('两个插件写同名 key 也互不可见；keys() 只看得到自己的', () async {
      final caps = CapabilityRegistry()
        ..register(FakeStore(seed: const {'plugin:a:k': 'fromA'}), ownerPluginId: 'app');
      final slots = SlotRegistry();
      final trace = InMemoryTraceSink();

      Store storeFor(String id) {
        final m = PluginManifest(
          id: id,
          name: id,
          description: 'd',
          trust: PluginTrust.trusted,
          permissions: const [PluginPermission.pluginStorage],
          inject: const [],
        );
        final fiber = PluginFiber(
          plugin: _StubPlugin(m),
          epochOf: (_) => 'e',
          ctxFactory: (f) => KernelPluginCtx(
            fiber: f,
            manifest: m,
            capabilities: caps,
            slots: slots,
            config: ConfigStore().stackFor(m),
            trace: trace,
            traceId: 't-$id',
          ),
        );
        final ctx = fiber.ctxFactory(fiber) as KernelPluginCtx;
        return ctx.capabilities.require<Store>(ServiceKeys.store).valueOrNull!;
      }

      final a = storeFor('a');
      final b = storeFor('b');
      expect((await a.read('k')).valueOrNull, 'fromA');
      expect((await b.read('k')).valueOrNull, isNull, reason: 'b 绝不能读到 a 的数据');
      await b.write('k', 'fromB');
      expect((await a.read('k')).valueOrNull, 'fromA', reason: '别人的写入不许串台');
      expect((await b.read('k')).valueOrNull, 'fromB');
      expect((await a.keys()).valueOrNull, ['k'], reason: 'keys() 必须剥掉前缀且只看自己');
      expect((await b.keys()).valueOrNull, ['k']);
    });
  });
}
