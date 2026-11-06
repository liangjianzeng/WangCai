// 世代自适应网关级单测（2026-11-05）：探测→世代→clamp→实测上抬→OOM 回退
// 全链离线验证。fake 进程/health/端口（同 engine_defaults_chain 纪律），
// 绑定表走 sqlite ffi（同 m2_dod）。红线：3720 无实测时行为与 v0.0.5 逐位一致。
import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart' hide EnginePhase;
import 'package:sqflite_common_ffi/sqflite_ffi.dart';
import 'package:wangcai/engine/bindings_store.dart';
import 'package:wangcai/engine/engine_paths.dart';
import 'package:wangcai/engine/engine_registry.dart';
import 'package:wangcai/engine/llama_server_host.dart';
import 'package:wangcai/engine/npu_profiles.dart';
import 'package:wangcai/engine/openvino_probe.dart';
import 'package:wangcai/platform/local_server_inference.dart';

import '../helpers/fake_process.dart';

void main() {
  setUpAll(() {
    sqfliteFfiInit();
    databaseFactory = databaseFactoryFfi;
    BindingsStore.databaseFactoryFfiForTest = databaseFactoryFfi;
  });

  late Directory tmp;
  late EnginePaths paths;
  late EngineRegistry reg;
  late List<FakeProcess> procs;
  bool oomOnSpawn = false;
  final inf = LocalServerInference.instance;

  const enum3720 = 'OPENVINO3: GGML_OPENVINO_DEVICE=NPU - '
      'Intel(R) AI Boost (NPU 3720) (24576 MiB, 14991 MiB free)';
  const enum3820 = 'OPENVINO2: GGML_OPENVINO_DEVICE=NPU - '
      'Intel(R) AI Boost (NPU 3820) (24576 MiB, 20480 MiB free)';

  setUp(() async {
    tmp = Directory.systemTemp.createTempSync('wc_gen_adapt');
    paths = EnginePaths.root(tmp);
    procs = [];
    oomOnSpawn = false;
    final npuExe = '${tmp.path}${Platform.pathSeparator}llama-npu.exe';
    File(npuExe).writeAsBytesSync([1]);
    reg = EngineRegistry(
      paths: paths,
      instances: [
        EngineInstance(
            id: 'wangcai-npu', manifestId: 'wangcai-npu', binaryPath: npuExe),
      ],
      processRunner: (exe, args, env) async {
        final p = FakeProcess();
        procs.add(p);
        if (oomOnSpawn && exe.contains('npu')) {
          // spawn 即吐驱动 OOM 行：pipe 未接管时数据先入缓冲，监听后送达。
          p.stderrCtl
              .add(utf8.encode('0.19 E ZE_RESULT_ERROR_OUT_OF_HOST_MEMORY\n'));
        }
        return p;
      },
      healthProbe: (_, __) async => !oomOnSpawn,
      prewarmCompletion: (_) async {},
      portAllocator: () async => 8123,
      sleeper: (d) async {},
      parentEnv: const {'PATH': r'C:\Windows', 'SystemRoot': r'C:\Windows'},
    );
    inf.attachRegistryForTest(reg, paths: paths);
    inf.onBatteryForTest = false;
    inf.npuDriverForTest = () async => '32.0.100.3800';
    await inf.setRoutingTier('npu');
  });

  tearDown(() async {
    probeRunnerForTest = null;
    clearOpenvinoProbeCache();
    profileOverrideForTest = null;
    inf.onBatteryForTest = null;
    inf.npuDriverForTest = null;
    try {
      await inf.unloadModel();
    } catch (_) {}
    for (var i = 0; i < 10; i++) {
      try {
        if (tmp.existsSync()) tmp.deleteSync(recursive: true);
        return;
      } catch (_) {
        await Future<void>.delayed(const Duration(milliseconds: 50));
      }
    }
  });

  Future<bool> load(String name, {int? nCtx}) => inf.loadModel(
      '${tmp.path}${Platform.pathSeparator}$name', nCtx: nCtx);

  // 纪律：sqflite_common_ffi 对同一路径的 open 共享底层库 —— 测试辅助**绝不
  // close**（会把网关缓存的句柄一起关成 database_closed；m2_dod 同样只开不关）。
  Future<Binding?> readBinding(String modelId) async =>
      (await BindingsStore.open(paths)).get('wangcai-npu', modelId);

  Future<void> seedStable(String modelId, int ctx) async {
    final b = await BindingsStore.open(paths);
    await b.recordRun(
        engineId: 'wangcai-npu', modelId: modelId, device: 'NPU', ctx: ctx);
  }

  test('回归锚·3720 无实测：4B nCtx4096 收敛 512 + chunk128，逐位同 v0.0.5',
      () async {
    probeRunnerForTest = (_, __) async => enum3720;
    expect(await load('Qwen3-4B-anchor.gguf', nCtx: 4096), isTrue);
    final h = reg.hostOf('wangcai-npu') as LlamaServerHost;
    expect(h.lastSpawnArgs, containsAllInOrder(['-dev', 'OPENVINO3']));
    expect(h.lastSpawnArgs, containsAllInOrder(['-c', '512']));
    expect(h.lastSpawnEnv?['GGML_OPENVINO_PREFILL_CHUNK_SIZE'], '128');
    // 探测摘要 + 驱动注入随成功加载落实例。
    expect(h.lastNpuInfo?.generation, NpuGeneration.ultra1);
    final inst = reg.instance('wangcai-npu')!;
    expect(inst.lastNpuInfo?['generation'], 'ultra1');
    // 驱动版本是 unawaited 追补：轮询落位。
    for (var i = 0; i < 20 && inst.lastNpuInfo?['driver'] == null; i++) {
      await Future<void>.delayed(const Duration(milliseconds: 50));
    }
    expect(inst.lastNpuInfo?['driver'], '32.0.100.3800');
  });

  test('驱动版本会话级缓存：两次成功加载只付一次 CIM（复查 2026-11-06）',
      () async {
    var queries = 0;
    inf.npuDriverForTest = () async {
      queries++;
      return '32.0.100.3800';
    };
    probeRunnerForTest = (_, __) async => enum3720;
    expect(await load('Qwen3-4B-dv1.gguf', nCtx: 4096), isTrue);
    // 追补是 unawaited：等 driver 落 lastNpuInfo（网关侧先写记忆再写摘要，
    // 摘要落位 = 记忆已就位）再二载，避免竞态假绿。
    for (var i = 0;
        i < 20 &&
            reg.instance('wangcai-npu')!.lastNpuInfo?['driver'] == null;
        i++) {
      await Future<void>.delayed(const Duration(milliseconds: 50));
    }
    expect(await load('Qwen3-4B-dv2.gguf', nCtx: 4096), isTrue);
    expect(queries, 1, reason: '同一会话第二载必须命中驱动记忆，不再起 CIM 查询');
    expect(reg.instance('wangcai-npu')!.lastNpuInfo?['driver'],
        '32.0.100.3800');
  });

  test('保守起步·二代 3820：无实测不赌，仍按一代先验 512', () async {
    probeRunnerForTest = (_, __) async => enum3820;
    expect(await load('Qwen3-4B-gen2.gguf', nCtx: 4096), isTrue);
    final h = reg.hostOf('wangcai-npu') as LlamaServerHost;
    expect(h.lastNpuInfo?.generation, NpuGeneration.ultra2);
    expect(h.lastSpawnArgs, containsAllInOrder(['-c', '512']));
  });

  test('实测上探：该机跑成功过 4096 → 上限与 admission 双双让位实测', () async {
    probeRunnerForTest = (_, __) async => enum3820;
    await seedStable('Qwen3-4B-up.gguf', 4096);
    expect(await load('Qwen3-4B-up.gguf', nCtx: 4096), isTrue,
        reason: 'maxStableCtx=4096：clamp 抬到实测档，ctx 门槛规则被实测豁免');
    final h = reg.hostOf('wangcai-npu') as LlamaServerHost;
    expect(h.lastSpawnArgs, containsAllInOrder(['-c', '4096']));
  });

  test('实测上探不外溢：别的模型没跑过 → 仍 512', () async {
    probeRunnerForTest = (_, __) async => enum3820;
    await seedStable('Qwen3-4B-a.gguf', 4096);
    expect(await load('Qwen3-4B-b.gguf', nCtx: 4096), isTrue);
    final h = reg.hostOf('wangcai-npu') as LlamaServerHost;
    expect(h.lastSpawnArgs, containsAllInOrder(['-c', '512']));
  });

  test('档案数据位：注入 ultra2 覆盖（lfm3→4096）驱动 clamp，一代不受影响',
      () async {
    probeRunnerForTest = (_, __) async => enum3820;
    profileOverrideForTest = {
      NpuGeneration.ultra2: const NpuProfile(
        generation: NpuGeneration.ultra2,
        ctxOverrides: {'lfm3-1.7b': 4096},
      ),
    };
    expect(await load('LFM3-1.7B-prof.gguf', nCtx: 8192), isTrue);
    final h = reg.hostOf('wangcai-npu') as LlamaServerHost;
    expect(h.lastSpawnArgs, containsAllInOrder(['-c', '4096']),
        reason: 'ultra2 档案覆盖位赢过 preset 1024 先验');
    // 同档案对一代机不生效（覆盖表按世代隔离）。
    probeRunnerForTest = (_, __) async => enum3720;
    clearOpenvinoProbeCache();
    expect(await load('LFM3-1.7B-prof1.gguf', nCtx: 8192), isTrue);
    expect(h.lastSpawnArgs, containsAllInOrder(['-c', '1024']));
  });

  test('失败回退：实测档执行期 OOM → 收回上抬，重载回落出厂先验', () async {
    probeRunnerForTest = (_, __) async => enum3720;
    await seedStable('Qwen3-4B-demote.gguf', 4096);
    // 第一载：实测档放行 → spawn 即 OOM → 加载失败 + demoteCtx。
    oomOnSpawn = true;
    expect(await load('Qwen3-4B-demote.gguf', nCtx: 4096), isFalse);
    expect((await readBinding('Qwen3-4B-demote.gguf'))!.maxStableCtx, isNull,
        reason: '被证伪的实测上抬必须收回');
    // 第二载：回到出厂先验。
    oomOnSpawn = false;
    expect(await load('Qwen3-4B-demote.gguf', nCtx: 4096), isTrue);
    final h = reg.hostOf('wangcai-npu') as LlamaServerHost;
    expect(h.lastSpawnArgs, containsAllInOrder(['-c', '512']));
  });

  test('demoteCtx store 语义：低于失败值保留 / 无行空转（失败不证伪更低档）',
      () async {
    final b = await BindingsStore.inMemory();
    await b.recordRun(engineId: 'e', modelId: 'm', ctx: 512);
    await b.demoteCtx(engineId: 'e', modelId: 'm', failedCtx: 4096);
    expect((await b.get('e', 'm'))!.maxStableCtx, 512,
        reason: 'failedCtx=4096 > 实测 512：512 是已验证档位，不动');
    await b.demoteCtx(engineId: 'e', modelId: 'm', failedCtx: 512);
    expect((await b.get('e', 'm'))!.maxStableCtx, isNull,
        reason: '实测档被同档失败证伪 → 收回');
    await b.demoteCtx(
        engineId: 'e', modelId: 'ghost', failedCtx: 1024); // 无行 → 静默
    await b.close();
  });
}
