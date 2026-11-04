// 路由三档纯函数（设计 §7.3）+ 绑定表回写（§7.2）的离线单测：
// 无 IO、无真机，规则表逐格断言 + 改道建议。
import 'package:flutter_test/flutter_test.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';
import 'package:wangcai/engine/bindings_store.dart';
import 'package:wangcai/engine/routing_policy.dart';

const npu = EngineCandidate(
    instanceId: 'wangcai-npu', kind: 'llamaServer', devices: ['NPU', 'CPU(OPENVINO0)']);
const cuda = EngineCandidate(
    instanceId: 'llamacpp-cuda', kind: 'llamaServer', devices: ['CUDA']);
const vulkan = EngineCandidate(
    instanceId: 'llamacpp-vulkan', kind: 'llamaServer', devices: ['Vulkan']);
const remote = EngineCandidate(
    instanceId: 'openai-remote', kind: 'remote', devices: ['remote']);
final all4 = [npu, cuda, vulkan, remote];

Binding b(EngineCandidate c, {double? tps, String status = BindingStatus.usable}) =>
    Binding(engineId: c.instanceId, modelId: 'm', lastDecodeTps: tps, status: status);

void main() {
  group('chooseEngine · speedFirst', () {
    test('有实测：t/s 最高者（不管设备）', () {
      final d = chooseEngine(RoutingRequest(
        tier: RoutingTier.speedFirst,
        candidates: all4,
        bindings: [b(vulkan, tps: 12), b(npu, tps: 7), b(cuda, tps: 42)],
      ));
      expect(d.instanceId, 'llamacpp-cuda');
      expect(d.reason, contains('42.0'));
    });

    test('无实测：设备启发 CUDA>Vulkan>NPU>CPU', () {
      final d = chooseEngine(RoutingRequest(
        tier: RoutingTier.speedFirst,
        candidates: all4,
      ));
      expect(d.instanceId, 'llamacpp-cuda');
      expect(d.reason, contains('设备启发'));
    });

    test('部分有实测：无实测者按启发先试跑（语义 2026-11-03 修正）', () {
      final d = chooseEngine(RoutingRequest(
        tier: RoutingTier.speedFirst,
        candidates: all4,
        bindings: [b(vulkan, tps: 3)],
      ));
      expect(d.instanceId, 'llamacpp-cuda',
          reason: 'CUDA 无实测且启发位次最高 → 先试跑出新实测');
    });

    test('CUDA 未装：退 Vulkan', () {
      final installed = [npu, const EngineCandidate(
          instanceId: 'llamacpp-vulkan', kind: 'llamaServer', devices: ['Vulkan']), remote];
      final d = chooseEngine(RoutingRequest(
          tier: RoutingTier.speedFirst, candidates: installed));
      expect(d.instanceId, 'llamacpp-vulkan');
    });

    test('无实测新引擎先于有实测慢引擎（防死锁：先跑出第一次实测）', () {
      final d = chooseEngine(RoutingRequest(
        tier: RoutingTier.speedFirst,
        candidates: all4,
        bindings: [b(npu, tps: 5)], // NPU 有历史实测；CUDA 新装无实测
      ));
      expect(d.instanceId, 'llamacpp-cuda',
          reason: 'CUDA deviceRank 更高且无实测 → 先试跑，不得被 NPU 历史实测压死');
    });
  });

  group('chooseEngine · npuFirst', () {
    test('一律 NPU（哪怕实测最慢）', () {
      final d = chooseEngine(RoutingRequest(
        tier: RoutingTier.npuFirst,
        candidates: all4,
        bindings: [b(cuda, tps: 42), b(npu, tps: 6)],
      ));
      expect(d.instanceId, 'wangcai-npu');
    });

    test('NPU 被 admission 拦：回落最快并带改道建议', () {
      final d = chooseEngine(RoutingRequest(
        tier: RoutingTier.npuFirst,
        candidates: all4,
        bindings: [b(cuda, tps: 42), b(vulkan, tps: 12)],
        blocked: {npu.instanceId: '4B@c>512 OUT_OF_HOST_MEMORY，建议 ctx≤512 或改 CUDA'},
      ));
      expect(d.instanceId, 'llamacpp-cuda');
      expect(d.suggestion, contains('OUT_OF_HOST_MEMORY'));
    });

    test('绑定表把 NPU 标 broken：同样改道', () {
      final d = chooseEngine(RoutingRequest(
        tier: RoutingTier.npuFirst,
        candidates: all4,
        bindings: [
          b(npu, status: BindingStatus.broken),
          b(cuda, tps: 42),
          b(vulkan, tps: 12),
        ],
      ));
      expect(d.instanceId, 'llamacpp-cuda');
    });
  });

  group('chooseEngine · auto', () {
    test('前台交互 = 最快（同 speed 规则）', () {
      final d = chooseEngine(RoutingRequest(
        tier: RoutingTier.auto,
        candidates: all4,
        bindings: [b(npu, tps: 7), b(cuda, tps: 42), b(vulkan, tps: 12)],
      ));
      expect(d.instanceId, 'llamacpp-cuda');
    });

    test('后台队列 = NPU 加权', () {
      final d = chooseEngine(RoutingRequest(
        tier: RoutingTier.auto,
        profile: TurnProfile.background,
        candidates: all4,
        bindings: [b(npu, tps: 7), b(cuda, tps: 42)],
      ));
      expect(d.instanceId, 'wangcai-npu');
      expect(d.reason, contains('后台'));
    });

    test('拔电（交互）= NPU 加权', () {
      final d = chooseEngine(RoutingRequest(
        tier: RoutingTier.auto,
        candidates: all4,
        bindings: [b(npu, tps: 7), b(cuda, tps: 42)],
        onBattery: true,
      ));
      expect(d.instanceId, 'wangcai-npu');
      expect(d.reason, contains('拔电'));
    });
  });

  group('兜底与无解', () {
    test('本地全被拦 + 远端可用 → 远端兜底并带建议', () {
      final d = chooseEngine(RoutingRequest(
        tier: RoutingTier.speedFirst,
        candidates: all4,
        blocked: {npu.instanceId: 'A', cuda.instanceId: 'B', vulkan.instanceId: 'C'},
      ));
      expect(d.instanceId, 'openai-remote');
      expect(d.suggestion, contains('A'));
    });

    test('什么都没有 → none + 引导安装', () {
      final d =
          chooseEngine(RoutingRequest(tier: RoutingTier.auto, candidates: const []));
      expect(d.instanceId, isNull);
      expect(d.suggestion, contains('安装'));
    });

    test('remote 未配置（installed=false）不作候选', () {
      final d = chooseEngine(RoutingRequest(
        tier: RoutingTier.speedFirst,
        candidates: [
          const EngineCandidate(instanceId: 'openai-remote', kind: 'remote', devices: ['remote'], installed: false),
        ],
      ));
      expect(d.instanceId, isNull);
    });
  });

  group('BindingsStore 回写（§7.2）', () {
    setUpAll(() {
      sqfliteFfiInit();
      databaseFactory = databaseFactoryFfi;
      BindingsStore.databaseFactoryFfiForTest = databaseFactoryFfi;
    });

    test('recordRun：unknown→usable、t/s 覆盖、maxStableCtx 单调最大', () async {
      final s = await BindingsStore.inMemory();
      addTearDown(s.close);
      await s.recordRun(
          engineId: 'e1', modelId: 'm1', decodeTps: 7.1, prefillTps: 14, ctx: 512);
      await s.recordRun(engineId: 'e1', modelId: 'm1', decodeTps: 8.2, ctx: 1024);
      await s.recordRun(engineId: 'e1', modelId: 'm1', decodeTps: 9.0, ctx: 256);
      final got = await s.get('e1', 'm1');
      expect(got!.status, BindingStatus.usable);
      expect(got.lastDecodeTps, 9.0);
      expect(got.lastPrefillTps, 14);
      expect(got.maxStableCtx, 1024, reason: '稳定 ctx 只增不减');
      expect(got.lastUsedAt, isNotNull);
    });

    test('broken 不被 recordRun 悄悄洗白；setStatus 手工置位', () async {
      final s = await BindingsStore.inMemory();
      addTearDown(s.close);
      await s.recordRun(engineId: 'e1', modelId: 'm1', decodeTps: 5);
      await s.setStatus('e1', 'm1', BindingStatus.broken);
      await s.recordRun(engineId: 'e1', modelId: 'm1', decodeTps: 6);
      expect((await s.get('e1', 'm1'))!.status, BindingStatus.broken);
      await s.setStatus('e1', 'm1', BindingStatus.recommended, qualityPass: true);
      final b2 = await s.get('e1', 'm1');
      expect(b2!.status, BindingStatus.recommended);
      expect(b2.qualityPass, isTrue);
    });

    test('forModel 只回该模型；remove 按引擎清', () async {
      final s = await BindingsStore.inMemory();
      addTearDown(s.close);
      await s.recordRun(engineId: 'e1', modelId: 'mA');
      await s.recordRun(engineId: 'e1', modelId: 'mB');
      await s.recordRun(engineId: 'e2', modelId: 'mA');
      expect((await s.forModel('mA')).map((e) => e.engineId).toSet(), {'e1', 'e2'});
      await s.remove('e1');
      expect(await s.forModel('mA'), hasLength(1));
      expect(await s.all(), hasLength(1));
    });
  });
}
