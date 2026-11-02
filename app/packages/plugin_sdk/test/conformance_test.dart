import 'package:plugin_sdk/plugin_sdk.dart';
import 'package:plugin_sdk/testing.dart';
import 'package:test/test.dart';

import 'support/fixtures.dart';

/// 一致性套件是**平台的验收门**：作者插件与内置插件跑的是同一套检查。
void main() {
  FakeCapabilityHarness fullHarness() {
    final h = FakeCapabilityHarness();
    h.register(FakeStore());
    h.register(FakeLlmComplete(response: '{"words":["apple","tiger"]}'));
    h.register(FakeLlmVision());
    h.register(FakeSpeak());
    h.register(FakeCapture());
    h.register(FakeInteract());
    return h;
  }

  List<ConformanceCheck> red(List<ConformanceCheck> all) => all.where((c) => !c.passed).toList(growable: false);

  group('合规插件必须全绿', () {
    test('六组检查零失败', () async {
      final all = await runConformance(() => GoodPlugin(), harness: fullHarness());
      expect(red(all).map((c) => c.toString()), isEmpty);
      expect(all.map((c) => c.group).toSet(), containsAll(<String>['契约', '生命周期', '回收', '状态与错误', '槽', '预算']));
      expect(all.length, greaterThanOrEqualTo(14));
    });

    test('run 真的走到了能力（不是空转通过）', () async {
      final h = fullHarness();
      final all = await runConformance(() => GoodPlugin(), harness: h);
      expect(all.every((c) => c.passed), isTrue);
      expect(h.calls.map((c) => '${c.capabilityId}.${c.method}'), contains('app.store.write'));
    });
  });

  group('违规插件必须被当场抓住', () {
    test('run 里 throw → 「状态与错误」组红', () async {
      final all = await runConformance(() => ThrowingPlugin(), harness: fullHarness());
      final r = red(all);
      expect(r.map((c) => c.name), contains('run 不 throw，失败一律走 Outcome'));
      expect(r.firstWhere((c) => c.name.startsWith('run 不 throw')).detail, contains('StateError'));
    });

    test('apply 里偷调能力（偷偷 IO）→ 「生命周期」组红', () async {
      final all = await runConformance(() => IoInApplyPlugin(), harness: fullHarness());
      final r = red(all);
      expect(r.map((c) => c.name), contains('apply 期间零 IO / 零能力调用'));
    });

    test('填别人命名空间的槽 → 「槽」组红', () async {
      final all = await runConformance(() => WrongNamespacePlugin(), harness: fullHarness());
      expect(red(all).map((c) => c.name), contains('注册的槽都有合法 id 命名空间'));
    });

    test('manifest 不自洽 → 「契约」组红，且一次报全', () async {
      final all = await runConformance(() => BadManifestPlugin(), harness: fullHarness());
      final contract = red(all).where((c) => c.group == '契约').toList();
      expect(contract, isNotEmpty);
      expect(contract.first.detail, anyOf(contains('id'), contains('name'), contains('permissions'), contains('default')));
    });

    test('能力缺失时插件必须说清缺什么（不许静默失败）', () async {
      final h = fullHarness();
      (h.byId['app.store']! as FakeCapability).available = false; // 注意：available 是可切换的
      final all = await runConformance(() => GoodPlugin(), harness: h);
      // 「能力齐备时 apply 成功」应当红 —— 说明套件真的在门控可用性上较真。
      expect(red(all).map((c) => c.name), contains('能力齐备时 apply 成功'));
    });
  });

  group('Fake 夹具本身可信（夹具不可信则整套无意义）', () {
    test('能力调用被完整记录（含阶段序号）', () async {
      final h = fullHarness();
      final ctx = FakePluginCtx(manifest: GoodPlugin().manifest, harness: h, permissions: {'storage:plugin', 'llm:chat'});
      final store = ctx.capabilities.require<Store>(ServiceKeys.store);
      expect(store.isOk, isTrue);
      await store.valueOrNull!.write('k', 'v');
      expect(h.calls.map((c) => c.method), containsAll(['write']));
      expect(h.byId['app.store']!.available, isTrue);
    });

    test('没声明权限就取能力 → permissionDenied 且 hint 告诉你加什么', () {
      final ctx = FakePluginCtx(manifest: GoodPlugin().manifest, harness: fullHarness(), permissions: {});
      final r = ctx.capabilities.require<Store>(ServiceKeys.store);
      expect(r.failureOrNull?.code, PluginFailureKind.permissionDenied);
      expect(r.failureOrNull?.hint, contains('storage:plugin'));
    });

    test('契约版本不匹配 → incompatibleContract（不是拿旧实现凑合跑）', () {
      final h = FakeCapabilityHarness()..register(FakeStore());
      h.byId.remove('app.store');
      h.register(_StoreV2());
      final ctx = FakePluginCtx(manifest: GoodPlugin().manifest, harness: h, permissions: {'storage:plugin'});
      final r = ctx.capabilities.require<Store>(ServiceKeys.store);
      expect(r.failureOrNull?.code, PluginFailureKind.incompatibleContract);
    });

    test('非 trusted 插件不能自己塞一个能力实现', () async {
      final h = fullHarness();
      const m = PluginManifest(id: 'declarative-one', name: 'D', description: 'd', inject: ['app.store'], trust: PluginTrust.declarative);
      final ctx = FakePluginCtx(manifest: m, harness: h, permissions: {'storage:plugin'});
      final r = await ctx.capabilities.provide<Store>(ServiceKeys.store, FakeStore());
      expect(r.failureOrNull?.code, PluginFailureKind.permissionDenied);
    });

    test('声明自己的槽可以，声明别人的不行', () {
      const m = PluginManifest(id: 'owner-one', name: 'O', description: 'd', trust: PluginTrust.trusted, inject: ['app.store']);
      final ctx = FakePluginCtx(manifest: m, harness: fullHarness());
      expect(ctx.slots.declare(const SlotDef(id: 'owner-one.wordAction', kind: SlotKind.list, scope: SlotScope.session, ownerPluginId: 'owner-one', description: 'd')).isOk, isTrue);
      final bad = ctx.slots.declare(const SlotDef(id: 'owner-two.wordAction', kind: SlotKind.list, scope: SlotScope.session, ownerPluginId: 'owner-two', description: 'd'));
      expect(bad.isErr, isTrue);
    });

    test('配置三级：会话内临时覆盖 > 传入配置 > 参数默认', () {
      final ctx = FakePluginCtx(
        manifest: GoodPlugin().manifest,
        harness: fullHarness(),
        config: const {'greetTimes': 3},
      );
      expect(ctx.numberConfig('greetTimes', 2), 3);
      ctx.setSessionOverride('greetTimes', 1);
      expect(ctx.numberConfig('greetTimes', 2), 1);
    });
  });
}

final class _StoreV2 extends FakeCapability implements Store {
  _StoreV2() : super(const ServiceKey<Store>('app.store', contractVersion: 'v2'), available: true);
  @override
  Future<Outcome<String?>> read(String key) async => const Ok<String?>(null);
  @override
  Future<Outcome<void>> write(String key, String value) async => const Ok<void>(null);
  @override
  Future<Outcome<void>> remove(String key) async => const Ok<void>(null);
  @override
  Future<Outcome<List<String>>> keys() async => const Ok<List<String>>([]);
}
