// 路由两档纯函数（2026-11-07 用户拍板重设计）+ 绑定表回写（§7.2）的离线单测：
// 无 IO、无真机，规则表逐格断言 + 拒绝建议。
// 核心立场：NPU 是本体；GPU/iGPU/CPU 是旁路扩展，只有 gpuSidecar 档（用户
// 显式选择）才走；NPU 不可满足 = 拒绝 + 指引，绝不自动改道。
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
  group('chooseEngine · gpuSidecar（旁路外挂，用户显式选择）', () {
    test('有实测：t/s 最高者（不管设备）', () {
      final d = chooseEngine(RoutingRequest(
        tier: RoutingTier.gpuSidecar,
        candidates: all4,
        bindings: [b(vulkan, tps: 12), b(npu, tps: 7), b(cuda, tps: 42)],
      ));
      expect(d.instanceId, 'llamacpp-cuda');
      expect(d.reason, contains('42.0'));
    });

    test('无实测：设备启发 CUDA>Vulkan>NPU>CPU', () {
      final d = chooseEngine(RoutingRequest(
        tier: RoutingTier.gpuSidecar,
        candidates: all4,
      ));
      expect(d.instanceId, 'llamacpp-cuda');
      expect(d.reason, contains('设备启发'));
    });

    test('部分有实测：无实测者按启发先试跑（语义 2026-11-03 修正）', () {
      final d = chooseEngine(RoutingRequest(
        tier: RoutingTier.gpuSidecar,
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
          tier: RoutingTier.gpuSidecar, candidates: installed));
      expect(d.instanceId, 'llamacpp-vulkan');
    });

    test('无实测新引擎先于有实测慢引擎（防死锁：先跑出第一次实测）', () {
      final d = chooseEngine(RoutingRequest(
        tier: RoutingTier.gpuSidecar,
        candidates: all4,
        bindings: [b(npu, tps: 5)], // NPU 有历史实测；CUDA 新装无实测
      ));
      expect(d.instanceId, 'llamacpp-cuda',
          reason: 'CUDA deviceRank 更高且无实测 → 先试跑，不得被历史实测压死');
    });
  });

  group('chooseEngine · npuFirst（核心档，2026-11-07 重设计）', () {
    test('一律 NPU（哪怕外挂实测更快）', () {
      final d = chooseEngine(RoutingRequest(
        tier: RoutingTier.npuFirst,
        candidates: all4,
        bindings: [b(cuda, tps: 42), b(npu, tps: 6)],
      ));
      expect(d.instanceId, 'wangcai-npu');
      expect(d.reason, contains('NPU 核心档'));
    });

    test('NPU 被 admission 拦：拒绝 + 指引，绝不自动改道 GPU（用户拍板核心语义）', () {
      // 兜底准入（2026-11-09）后，blocked 只剩无安全档的全禁入模型（Spark 这类
      // ctx 门槛违例已被网关兜底收敛，不再进 blocked）——本锚锁 chooseEngine
      // 对 blocked 的语义：拒绝 + 指引 + 绝不改道。
      final d = chooseEngine(RoutingRequest(
        tier: RoutingTier.npuFirst,
        candidates: all4,
        bindings: [b(cuda, tps: 42), b(vulkan, tps: 12)],
        blocked: {npu.instanceId: 'Qwen3.5-4B 在 NPU 引擎上编译即失败'},
      ));
      expect(d.instanceId, isNull,
          reason: 'NPU 跑不了就是跑不了——绝不静默滑进独显（2026-11-07 用户实测抱怨）');
      expect(d.suggestion, contains('GPU 外挂'),
          reason: '拒绝必须带可操作的指引：外挂在哪、怎么选');
      expect(d.reason, contains('编译即失败'),
          reason: '拒绝原因原文必须透传给用户（reason 主文案）');
    });

    test('绑定表把 NPU 标 broken：同样拒绝不改道', () {
      final d = chooseEngine(RoutingRequest(
        tier: RoutingTier.npuFirst,
        candidates: all4,
        bindings: [b(npu, status: BindingStatus.broken), b(cuda, tps: 42)],
      ));
      expect(d.instanceId, isNull);
    });

    test('NPU 根本没装：拒绝 + NPU 就绪指引（不发 GPU 下载信号）', () {
      const npuMissing = EngineCandidate(
          instanceId: 'wangcai-npu', kind: 'llamaServer',
          devices: ['NPU'], installed: false);
      final d = chooseEngine(RoutingRequest(
        tier: RoutingTier.npuFirst,
        candidates: [npuMissing, cuda],
      ));
      expect(d.instanceId, isNull);
      expect(d.needInstall, isNull,
          reason: '核心档绝不引导用户装 GPU 引擎来兜底');
      expect(d.reason, contains('NPU'));
    });
  });

  group('档位名兼容映射（routingTierFromName）', () {
    test("'auto' 并入 NPU 核心（旧改道语义已废）", () {
      expect(routingTierFromName('auto'), RoutingTier.npuFirst);
      expect(routingTierFromName('npu'), RoutingTier.npuFirst);
      expect(routingTierFromName(null), RoutingTier.npuFirst);
    });

    test("'speed'/'gpu' 延续为 GPU 外挂", () {
      expect(routingTierFromName('speed'), RoutingTier.gpuSidecar);
      expect(routingTierFromName('gpu'), RoutingTier.gpuSidecar);
    });
  });

  group('兜底与无解（外挂档内）', () {
    test('外挂档本地全被拦 + 远端可用 → 远端兜底并带建议', () {
      final d = chooseEngine(RoutingRequest(
        tier: RoutingTier.gpuSidecar,
        candidates: all4,
        blocked: {npu.instanceId: 'A', cuda.instanceId: 'B', vulkan.instanceId: 'C'},
      ));
      expect(d.instanceId, 'openai-remote');
      expect(d.suggestion, contains('B'));
    });

    test('外挂档什么都没有 → none + 引导安装', () {
      final d = chooseEngine(
          RoutingRequest(tier: RoutingTier.gpuSidecar, candidates: const []));
      expect(d.instanceId, isNull);
      expect(d.suggestion, contains('安装'));
    });

    test('remote 未配置（installed=false）不作候选', () {
      final d = chooseEngine(RoutingRequest(
        tier: RoutingTier.gpuSidecar,
        candidates: [
          const EngineCandidate(instanceId: 'openai-remote', kind: 'remote', devices: ['remote'], installed: false),
        ],
      ));
      expect(d.instanceId, isNull);
    });
  });

  group('按需下载信号（Phase 3c needInstall，仅外挂档）', () {
    const npuMissing = EngineCandidate(
        instanceId: 'wangcai-npu', kind: 'llamaServer', devices: ['NPU'], installed: false);
    const cudaMissing = EngineCandidate(
        instanceId: 'llamacpp-cuda', kind: 'llamaServer', devices: ['CUDA'], installed: false);
    const vulkanMissing = EngineCandidate(
        instanceId: 'llamacpp-vulkan', kind: 'llamaServer', devices: ['VULKAN'], installed: false);

    test('外挂档本地全未装且 cuda/vulkan 启用 → needInstall=cuda（快道优先）', () {
      final d = chooseEngine(RoutingRequest(
        tier: RoutingTier.gpuSidecar,
        candidates: const [npuMissing, cudaMissing, vulkanMissing],
      ));
      expect(d.instanceId, isNull);
      expect(d.needInstall, 'cuda');
      expect(d.suggestion, contains('下载'));
    });

    test('缺 cuda 已装 vulkan 时不触发下载（vulkan 直接胜出）', () {
      final d = chooseEngine(RoutingRequest(
        tier: RoutingTier.gpuSidecar,
        candidates: const [npuMissing, cudaMissing, vulkan],
      ));
      expect(d.instanceId, 'llamacpp-vulkan');
      expect(d.needInstall, isNull);
    });

    test('仅 vulkan 未装（候选里无 cuda）→ needInstall=vulkan', () {
      final d = chooseEngine(RoutingRequest(
        tier: RoutingTier.gpuSidecar,
        candidates: const [npuMissing, vulkanMissing],
      ));
      expect(d.needInstall, 'vulkan');
    });

    test('未装且未启用 → 不作下载建议（用户明确不要它）', () {
      final d = chooseEngine(RoutingRequest(
        tier: RoutingTier.gpuSidecar,
        candidates: const [
          npuMissing,
          EngineCandidate(
              instanceId: 'llamacpp-cuda',
              kind: 'llamaServer',
              devices: ['CUDA'],
              installed: false,
              enabled: false),
        ],
      ));
      expect(d.instanceId, isNull);
      expect(d.needInstall, isNull);
    });

    test('远端可用时优先兜底，不发下载信号', () {
      final d = chooseEngine(RoutingRequest(
        tier: RoutingTier.gpuSidecar,
        candidates: const [npuMissing, cudaMissing, remote],
      ));
      expect(d.instanceId, 'openai-remote');
      expect(d.needInstall, isNull);
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
