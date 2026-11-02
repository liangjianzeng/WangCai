import 'package:plugin_sdk/testing.dart';
import 'package:plugin_kernel/plugin_kernel.dart';
import 'package:test/test.dart';

const ttsKey = ServiceKey<Capability>('app.tts');
const ttsKeyV2 = ServiceKey<Capability>('app.tts', contractVersion: 'v2');

/// 带名字的实现，好断言"到底是谁在服务"。
class _Named extends FakeCapability {
  _Named(this.who, {bool available = true, String? reason, int version = 1})
      : super(ServiceKey<Capability>('app.tts', contractVersion: 'v$version'), available: available, unavailableReason: reason);
  final String who;
}

_Named impl(String who, {bool available = true, String? reason, int version = 1}) =>
    _Named(who, available: available, reason: reason, version: version);

void main() {
  late CapabilityRegistry reg;
  setUp(() => reg = CapabilityRegistry());

  group('注册与遮蔽', () {
    test('priority 越小越优先（与槽同一套心智，平台里只有一套优先级）', () async {
      await reg.register(impl('host'), ownerPluginId: 'app');
      await reg.register(impl('offline'), ownerPluginId: 'offline-tts', priority: -1);
      final r = reg.resolve<Capability>(ttsKey);
      expect((r.valueOrNull! as _Named).who, 'offline', reason: 'priority -1 的实现必须盖住 priority 0 的');
    });

    test('同 id 同 priority 冲突：报错并指名占用者 + 给出出路', () async {
      await reg.register(impl('host'), ownerPluginId: 'app');
      final r = reg.register(impl('other'), ownerPluginId: 'another');
      expect(r.failureOrNull?.code, PluginFailureKind.configInvalid);
      expect(r.failureOrNull?.message, contains('已被 app 以 priority 0 提供'));
      expect(r.failureOrNull?.hint, contains('例如 -1'));
    });

    test('遮蔽者卸载后自动回退到被遮蔽者（遮蔽 ≠ 销毁）', () async {
      await reg.register(impl('host'), ownerPluginId: 'app');
      final off = await reg.register(impl('offline'), ownerPluginId: 'offline-tts', priority: -1);
      expect(reg.resolve<Capability>(ttsKey).isOk, isTrue);
      await off.valueOrNull!();
      expect(reg.resolve<Capability>(ttsKey).isOk, isTrue, reason: '顶掉的实现本来就没被销毁');
      expect(reg.list('app.tts').length, 1);
    });

    test('顶层实现谎称不可用时，resolve 给的是**它的理由**，不是笼统的"不可用"', () async {
      await reg.register(impl('host', available: false, reason: '还没加载离线语音模型'), ownerPluginId: 'app');
      expect(reg.isAvailable('app.tts'), isFalse);
      expect(reg.unavailableReason('app.tts'), contains('离线语音模型'));
      final r = reg.resolve<Capability>(ttsKey, consumerPluginId: 'dict');
      expect(r.failureOrNull?.code, PluginFailureKind.missingCapability);
      // 实测：这条分支（实现自己报了不可用理由）的出路是「见「设置」页对应开关」——
      // 因为东西**在机器上**、只是被开关关着，指去能力清单反而绕远。
      expect(r.failureOrNull?.hint, contains('见「设置」页对应开关'),
          reason: '能力"被关着"与"本机根本没有"是两句话，出路必须分开指');
    });

    test('顶层不可用但低优先级可用 → 能用（能力不齐不等于功能不能用）', () async {
      await reg.register(impl('host', available: false, reason: '没网'), ownerPluginId: 'app');
      await reg.register(impl('offline'), ownerPluginId: 'offline-tts', priority: -1);
      expect(reg.isAvailable('app.tts'), isTrue);
      expect(reg.resolve<Capability>(ttsKey).isOk, isTrue);
    });
  });

  group('契约版本协商', () {
    test('只有 v1 实现却要 v2 → incompatibleContract 且说清本机有哪些版本', () async {
      await reg.register(impl('host'), ownerPluginId: 'app');
      final r = reg.resolve<Capability>(ttsKeyV2);
      expect(r.failureOrNull?.code, PluginFailureKind.incompatibleContract);
      expect(r.failureOrNull?.message, contains('只有 v1'), reason: '要说清本机到底有什么版本');
      expect(r.failureOrNull?.message, contains('本插件要 v2'), reason: '再说清插件要什么，两边一对才知道差在哪');
      expect(r.failureOrNull?.hint, contains('升级 app 或该插件'),
          reason: '两字「升级」不指对象：升 app 还是升插件，是两条完全不同的出路');
    });

    test('v1/v2 双实现共存（弃用期双读的实现基础）', () async {
      await reg.register(impl('host'), ownerPluginId: 'app');
      await reg.register(impl('host-v2', version: 2), ownerPluginId: 'app', priority: 0);
      expect(reg.resolve<Capability>(ttsKey).isOk, isTrue);
      expect(reg.resolve<Capability>(ttsKeyV2).isOk, isTrue);
    });
  });

  group('变更通知与预算', () {
    test('实现集变化 → revision 变化并通知订阅者（fiber 靠它自动重载）', () async {
      expect(reg.revisionOf('app.tts'), 0);
      final off = await reg.register(impl('host'), ownerPluginId: 'app');
      expect(reg.revisionOf('app.tts'), 1);
      var hits = 0;
      reg.subscribe((_) => hits++);
      await off.valueOrNull!();
      expect(hits, 1);
      expect(reg.revisionOf('app.tts'), 2);
    });

    test('未注册的能力：available=false 且理由说"本机没有提供"', () {
      expect(reg.isAvailable('nope.nope'), isFalse);
      expect(reg.unavailableReason('nope.nope'), contains('没有提供'));
      expect(reg.resolve<Capability>(const ServiceKey<Capability>('nope.nope')).failureOrNull?.code,
          PluginFailureKind.missingCapability);
    });

    test('warmUp 抛异常被吞（预热失败只影响性能，不影响可用性）', () async {
      reg.register(_GrumpyWarmUp(), ownerPluginId: 'app');
      await reg.warmUpAll(); // 不该抛
      expect(reg.isAvailable('app.speak'), isTrue);
    });

    test('probe 走真自检（面板"测试一下"按钮）', () async {
      reg.register(_Probeable(available: true), ownerPluginId: 'app');
      expect((await reg.probe('net.search')).isOk, isTrue);
      reg.clear();
      reg.register(_Probeable(available: false), ownerPluginId: 'app');
      final r = await reg.probe('net.search');
      expect(r.isErr, isTrue);
      // isNotNull 只证明"有个字段"；出路至少要是一句能照着做的话（≥6 字），不是"出错了"三个字。
      expect((r.failureOrNull?.hint ?? '').trim().length, greaterThan(6),
          reason: 'probe 失败也要给出路，不能只报"不可用"');
    });

    test('本机没有这个能力 → resolve 与 probe 都说得出"这台机器没有提供能力 X"', () async {
      final r = reg.resolve<Capability>(const ServiceKey<Capability>('no.such.thing'));
      expect(r.isErr, isTrue);
      expect(r.failureOrNull?.message, contains('这台机器没有提供能力'),
          reason: '插件"待功能"只说明它要什么，不说明本机有什么；'
              '这句是用户唯一能看到"不是插件坏了，是这台机器没接通"的地方');
      expect(r.failureOrNull?.message, contains('no.such.thing'), reason: '要点名是哪个能力');
      expect(r.failureOrNull?.code, PluginFailureKind.missingCapability);

      final p = await reg.probe('no.such.thing');
      expect(p.isErr, isTrue);
      expect(p.failureOrNull?.message, contains('这台机器没有提供能力'),
          reason: '面板「试一下」按的就是 probe —— 两条路对同一件事的说法必须一致');
    });

    test('本机有什么能力只有一个问法：list()（不再另开一份 id 清单）', () async {
      await reg.register(impl('host'), ownerPluginId: 'app');
      expect(reg.list().map((e) => e.key.id), contains('app.tts'));
      expect(reg.list('app.tts').single.ownerPluginId, 'app');
    });
  });
}

class _GrumpyWarmUp extends FakeCapability {
  _GrumpyWarmUp() : super(const ServiceKey<Capability>('app.speak'), available: true);
  @override
  Future<void> warmUp() async => throw StateError('拉音色列表失败');
}

class _Probeable extends FakeCapability {
  _Probeable({required bool available}) : super(const ServiceKey<Capability>('net.search'), available: available);
  @override
  Future<Outcome<void>> probe() async => available
      ? const Ok<void>(null)
      : Outcome.err<void>(code: PluginFailureKind.missingCapability, message: '搜索服务不可达', hint: '检查内网 SearXNG');
}
