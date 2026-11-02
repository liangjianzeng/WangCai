import 'package:plugin_sdk/testing.dart';
import 'package:plugin_kernel/plugin_kernel.dart';
import 'package:test/test.dart';

class _Probe implements AppPlugin {
  _Probe({this.labels = const ['a', 'b', 'c'], this.throwOnDispose = const {}, this.throwOnApply = false, this.failOnApply = false});

  final List<String> labels;
  final Set<String> throwOnDispose;
  bool throwOnApply;
  bool failOnApply;

  int applyCount = 0;
  final List<String> disposeLog = [];

  /// 「注册到一半就失败」的那些贡献物的回收记录（专用，别混进 [disposeLog]，
  /// 那边有 `['c','b','a']` 的逆序断言）。
  final List<String> halfCleaned = [];

  @override
  PluginManifest get manifest => const PluginManifest(
        id: 'probe-one',
        name: '探针',
        description: 'fiber 生命周期被试',
        inject: [],
        trust: PluginTrust.trusted,
      );

  @override
  Outcome<Disposable?> apply(PluginCtx ctx) {
    applyCount++;
    if (throwOnApply) throw StateError('apply 炸了');
    if (failOnApply) {
      // 作者最常见的写法就是"先注册贡献、后发现参数不对"：贡献物已经挂进 effect 树了才 return Err。
      // 不这样写，「失败不许半激活」那条测试是空的 —— 把 fiber.dart 里 apply 失败路径上的
      // `await _disposeEffects();` 删掉，effectTree 照样 isEmpty，测不出任何回归。
      for (final l in labels) {
        final tag = 'half-$l';
        ctx.effect(() => halfCleaned.add(tag));
      }
      return Outcome.err<Disposable?>(code: PluginFailureKind.configInvalid, message: '参数不合契约', hint: '改一下参数');
    }
    for (final l in labels) {
      final tag = l;
      ctx.effect(() {
        disposeLog.add(tag);
        if (throwOnDispose.contains(tag)) throw StateError('$tag 回收失败');
      });
    }
    return const Ok<Disposable?>(null);
  }

  @override
  Future<Outcome<PluginRunResult>> run(PluginCtx ctx, PluginInput input) async => const Ok<PluginRunResult>(PluginRunResult(summary: 'ok'));
}

void main() {
  late _Probe probe;
  late String epoch;
  late List<FiberState> seen;
  late PluginFiber fiber;

  PluginFiber buildFiber() => PluginFiber(
        plugin: probe,
        epochOf: (_) => epoch,
        onStateChange: (_, s) => seen.add(s),
        ctxFactory: (f) => _ForwardingCtx(manifest: probe.manifest, fiber: f),
      );

  setUp(() {
    probe = _Probe();
    epoch = 'e1';
    seen = [];
    fiber = buildFiber();
  });

  group('六态与单飞', () {
    test('首次 ensure 走完 pending→loading→active', () async {
      expect(fiber.state, FiberState.pending);
      final r = await fiber.ensure();
      expect(r.isOk, isTrue);
      expect(fiber.state, FiberState.active);
      expect(seen, [FiberState.loading, FiberState.active]);
      expect(probe.applyCount, 1);
    });

    test('重复 ensure 幂等（不重复 apply）', () async {
      await fiber.ensure();
      await fiber.ensure();
      await fiber.ensure();
      expect(probe.applyCount, 1);
    });

    test('并发 ensure 只迁移一次（inertia 单飞：狂点开关不会注册两遍）', () async {
      final rs = await Future.wait([fiber.ensure(), fiber.ensure(), fiber.ensure(), fiber.ensure()]);
      expect(rs.every((r) => r.isOk), isTrue);
      expect(probe.applyCount, 1, reason: '并发加载必须共享同一次迁移');
      expect(seen.where((s) => s == FiberState.loading).length, 1);
    });

    test('apply 抛异常 → failed 并留下可读原因；retry 后转 active', () async {
      probe = _Probe(throwOnApply: true);
      fiber = buildFiber();
      final r = await fiber.ensure();
      expect(fiber.state, FiberState.failed);
      expect(r.failureOrNull?.message, contains('插件启动时出了点问题'));
      expect(r.failureOrNull?.hint, contains('停用再启用试试；仍不行看诊断树'),
          reason: '失败态的出路要具体到动作（停用再启用 / 看诊断树），isNotNull 什么都保不住');
      expect(fiber.lastFailure?.cause.toString(), contains('apply 炸了')); // 原始异常进日志不进 UI

      probe.throwOnApply = false;
      final r2 = await fiber.retry();
      expect(r2.isOk, isTrue);
      expect(fiber.state, FiberState.active);
      expect(seen, containsAllInOrder([FiberState.failed, FiberState.pending, FiberState.loading, FiberState.active]));
    });

    test('apply 返回 Err → failed（不是"半激活"）', () async {
      probe = _Probe(failOnApply: true);
      fiber = buildFiber();
      final r = await fiber.ensure();
      expect(r.isErr, isTrue);
      expect(fiber.state, FiberState.failed);
      expect(fiber.effectTree, isEmpty, reason: '失败的 fiber 不许留下半个贡献物');
      // 光"树空了"还不够：回收器必须**真的跑过**，否则槽里留着条目而插件是 failed ——
      // 面板说"它占着这个位置"，点了没反应，全程零红字（第 22 条那一族的静默症状）。
      expect(probe.halfCleaned, ['half-c', 'half-b', 'half-a'],
          reason: 'apply 失败要按登记的**逆序**把半成品回收干净（第 85 轮由失败输出的 Actual 定的次序，'
              '不是照着想象写的），而不是只把树清空了事');
    });
  });

  group('epoch 自动重载', () {
    test('依赖实现被替换 → 下次 ensure 先卸后装（不需要重启 app）', () async {
      await fiber.ensure();
      expect(probe.applyCount, 1);
      epoch = 'e2'; // 模拟 app.tts 的实现被离线插件替换 → revision bump
      final r = await fiber.ensure();
      expect(r.isOk, isTrue);
      expect(probe.applyCount, 2);
      expect(probe.disposeLog, ['c', 'b', 'a'], reason: '重载前必须把上一次的回收干净');
      expect(seen, containsAllInOrder([FiberState.active, FiberState.unloading, FiberState.disposed, FiberState.loading, FiberState.active]));
    });

    test('epoch 未变 → 绝不无谓重载', () async {
      await fiber.ensure();
      await fiber.ensure();
      expect(probe.applyCount, 1);
      expect(seen.where((s) => s == FiberState.loading).length, 1);
    });
  });

  group('回收', () {
    test('disposer 逆序执行', () async {
      await fiber.ensure();
      await fiber.unload();
      expect(probe.disposeLog, ['c', 'b', 'a']);
      expect(fiber.state, FiberState.disposed);
      expect(fiber.effectTree, isEmpty);
    });

    test('unload 幂等（重复调用不会二次回收）', () async {
      await fiber.ensure();
      await fiber.unload();
      await fiber.unload();
      await fiber.unload();
      expect(probe.disposeLog, ['c', 'b', 'a']);
    });

    test('单个 disposer 抛错只记账，其余照常回收', () async {
      probe = _Probe(labels: const ['a', 'bad', 'c'], throwOnDispose: const {'bad'});
      fiber = buildFiber();
      await fiber.ensure();
      await fiber.unload();
      expect(probe.disposeLog, ['c', 'bad', 'a'], reason: '中间那个抛了，后面的必须照常回收');
    });

    test('卸载时取消令牌被取消（在飞的循环必须停下来）', () async {
      await fiber.ensure();
      final token = fiber.cancelToken;
      expect(token.isCancelled, isFalse);
      await fiber.unload(reason: '用户禁用');
      expect(token.isCancelled, isTrue);
      expect(token.reason, '用户禁用');
    });

    test('卸载后重新 ensure 能再起来（禁用→启用的真实路径）', () async {
      await fiber.ensure();
      await fiber.unload();
      final r = await fiber.ensure();
      expect(r.isOk, isTrue);
      expect(fiber.state, FiberState.active);
      expect(probe.applyCount, 2);
    });
  });
}

/// 把 `ctx.effect` 转发到 fiber 的薄壳（真实链路里 KernelPluginCtx 就是这么做的）。
class _ForwardingCtx extends FakePluginCtx {
  _ForwardingCtx({required super.manifest, required this.fiber}) : super(harness: FakeCapabilityHarness());
  final PluginFiber fiber;

  @override
  Disposable effect(Disposable disposer) {
    final off = super.effect(disposer);
    return fiber.addEffect(EffectNode('forwarded', dispose: () async {
      await disposer();
      await off();
    }));
  }
}
