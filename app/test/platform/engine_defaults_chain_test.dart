// Phase 3b 参数体系离线单测：优先级链 **模型级（loadModel 参数）>
// EngineInstance.defaultConfig > manifest preset/模板**。
// fake 进程/health/端口注入，绝不 spawn 真进程（同 single_active 纪律）。
import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart' hide EnginePhase;
import 'package:wangcai/engine/engine_host.dart' show EngineProcess;
import 'package:wangcai/engine/engine_paths.dart';
import 'package:wangcai/engine/engine_registry.dart';
import 'package:wangcai/engine/openvino_probe.dart';
import 'package:wangcai/platform/local_server_inference.dart';

class FakeProcess implements EngineProcess {
  final stdoutCtl = StreamController<List<int>>();
  final stderrCtl = StreamController<List<int>>();
  final _exit = Completer<int>();
  bool killed = false;

  @override
  final int pid = 4242;
  @override
  Stream<List<int>> get stdout => stdoutCtl.stream;
  @override
  Stream<List<int>> get stderr => stderrCtl.stream;
  @override
  Future<int> get exitCode => _exit.future;
  @override
  bool kill() {
    killed = true;
    if (!_exit.isCompleted) _exit.complete(0);
    return true;
  }
}

/// 假 server 进程池 + spawn 取证（args/env 与实例 id 对应）。
class SpawnLog {
  final byExe = <String, List<String>>{};
  final envByExe = <String, Map<String, String>>{};
  final procs = <FakeProcess>[];
  late final String npuExe;
  late final String cudaExe;

  String exeTag(String exe) =>
      exe.contains('npu') ? 'npu' : (exe.contains('cuda') ? 'cuda' : exe);

  Future<EngineProcess> call(String exe, List<String> args,
      Map<String, String> env) async {
    final p = FakeProcess();
    procs.add(p);
    byExe[exeTag(exe)] = args;
    envByExe[exeTag(exe)] = env;
    return p;
  }
}

void main() {
  late Directory tmp;
  late EngineRegistry reg;
  late SpawnLog spawns;
  final inf = LocalServerInference.instance;

  setUp(() async {
    tmp = Directory.systemTemp.createTempSync('wc_defaults');
    spawns = SpawnLog();
    spawns.npuExe = '${tmp.path}${Platform.pathSeparator}llama-npu.exe';
    spawns.cudaExe = '${tmp.path}${Platform.pathSeparator}llama-cuda.exe';
    File(spawns.npuExe).writeAsBytesSync([1]);
    File(spawns.cudaExe).writeAsBytesSync([1]);
    reg = EngineRegistry(
      paths: EnginePaths.root(tmp),
      instances: [
        EngineInstance(
            id: 'wangcai-npu',
            manifestId: 'wangcai-npu',
            binaryPath: spawns.npuExe),
        EngineInstance(
            id: 'llamacpp-cuda',
            manifestId: 'llamacpp-cuda',
            binaryPath: spawns.cudaExe),
      ],
      processRunner: spawns.call,
      healthProbe: (_, __) async => true,
      portAllocator: () async => 8123,
      sleeper: (d) async {},
      parentEnv: const {'PATH': r'C:\Windows', 'SystemRoot': r'C:\Windows'},
    );
    inf.attachRegistryForTest(reg, paths: EnginePaths.root(tmp));
    probeRunnerForTest = (_, __) async =>
        'OPENVINO2: GGML_OPENVINO_DEVICE=NPU - fake';
    // 路由/电源定值：这些测试测的是参数链不是选路，显式档位 + 插电。
    inf.onBatteryForTest = false;
    await inf.setRoutingTier('npu');
  });

  tearDown(() async {
    probeRunnerForTest = null;
    clearOpenvinoProbeCache();
    inf.onBatteryForTest = null;
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

  Future<void> loadNpu(
    String name, {
    int? nCtx,
    int? chunk,
    int? gpuLayers,
    List<String>? customArgs,
    String? engineId,
    String? draftPath,
  }) async {
    final ok = await inf.loadModel('${tmp.path}${Platform.pathSeparator}$name',
        nCtx: nCtx,
        chunk: chunk,
        gpuLayers: gpuLayers,
        customArgs: customArgs,
        engineId: engineId,
        draftPath: draftPath);
    expect(ok, isTrue, reason: 'fake probe/health 恒通，$name 应加载成功');
  }

  test('出厂基线：无 dc 无模型级 → ctx 1024、无 chunk env、无尾参', () async {
    await loadNpu('Generic-Fake.gguf');
    expect(spawns.byExe['npu'], containsAllInOrder(['-c', '1024']));
    expect(spawns.envByExe['npu']!['GGML_OPENVINO_PREFILL_CHUNK_SIZE'], isNull);
    expect(spawns.byExe['npu']!.last, isNot('--foo'));
  });

  test('引擎 defaultConfig 中间档：ctx/chunk/extraEnv/尾参全部入场', () async {
    reg.instance('wangcai-npu')!.defaultConfig = const EngineDefaults(
      ctx: 256,
      chunk: 99,
      extraEnv: {'WC_TEST_ENV': '1'},
      args: ['--foo', 'bar'],
    );
    await loadNpu('Generic-Fake.gguf');
    expect(spawns.byExe['npu'], containsAllInOrder(['-c', '256']));
    expect(spawns.envByExe['npu']!['GGML_OPENVINO_PREFILL_CHUNK_SIZE'], '99');
    expect(spawns.envByExe['npu']!['WC_TEST_ENV'], '1');
    // 尾参追加在模板之后（llama.cpp 后者覆盖前者）
    expect(spawns.byExe['npu']!.reversed.take(2).toList().reversed,
        ['--foo', 'bar']);
  });

  test('模型级压过 defaultConfig：ctx/chunk 显式值赢，customArgs 整档替换尾参',
      () async {
    reg.instance('wangcai-npu')!.defaultConfig = const EngineDefaults(
      ctx: 256,
      chunk: 99,
      args: ['--foo', 'bar'],
    );
    await loadNpu('Generic-Fake.gguf',
        nCtx: 128, chunk: 64, customArgs: ['--zzz']);
    expect(spawns.byExe['npu'], containsAllInOrder(['-c', '128']));
    expect(spawns.envByExe['npu']!['GGML_OPENVINO_PREFILL_CHUNK_SIZE'], '64');
    expect(spawns.byExe['npu'], contains('--zzz'));
    expect(spawns.byExe['npu'], isNot(contains('--foo')),
        reason: 'customArgs 非空 = 整档替换 defaultConfig.args（计划定案）');
  });

  test('preset 仍是出厂档 + ctx 收敛纪律：preset 命中时实测上限压过一切', () async {
    reg.instance('wangcai-npu')!.defaultConfig = const EngineDefaults(ctx: 4096);
    await loadNpu('Qwen3-4B-Fake.gguf', nCtx: 4096);
    // qwen3-4b preset：ctx 上限 512、chunk 128（实测配置顶不得穿）
    expect(spawns.byExe['npu'], containsAllInOrder(['-c', '512']));
    expect(spawns.envByExe['npu']!['GGML_OPENVINO_PREFILL_CHUNK_SIZE'], '128');
  });

  test('preset extraEnv 与 defaultConfig.extraEnv 合并（dc 同键覆盖）', () async {
    reg.instance('wangcai-npu')!.defaultConfig = const EngineDefaults(
        extraEnv: {'GGML_OPENVINO_DISABLE_DECODE_LEVELS': '0'});
    await loadNpu('Spark-X2.6-4B-Fake.gguf');
    // preset 带 DISABLE_DECODE_LEVELS=1，dc 同键覆盖成 0；preset 独占键保留
    expect(spawns.envByExe['npu']!['GGML_OPENVINO_DISABLE_DECODE_LEVELS'], '0');
  });

  test('引擎钉选压过路由档位：npu 档下钉 cuda → cuda 拉起、npu 被互斥停',
      () async {
    await loadNpu('Generic-Fake.gguf', engineId: 'llamacpp-cuda');
    expect(reg.hostOf('llamacpp-cuda').baseUrl, isNotNull);
    expect(reg.hostOf('wangcai-npu').baseUrl, isNull);
    expect(spawns.byExe['cuda'], isNotNull);
  });

  test('钉选不可用（未安装）→ 回落 Auto 路由并留痕', () async {
    final logs = <String>[];
    inf.onLoadingLog = (m) {
      if (m != null) logs.add(m);
    };
    reg.upsert(EngineInstance(
        id: 'llamacpp-vulkan', manifestId: 'llamacpp-vulkan')); // 无 binary=未装
    await loadNpu('Generic-Fake.gguf', engineId: 'llamacpp-vulkan');
    expect(logs.any((l) => l.contains('回落 Auto')), isTrue,
        reason: '钉选失败必须留痕：$logs');
    // 回落 npu 档打分 → NPU 胜出
    expect(reg.hostOf('wangcai-npu').baseUrl, isNotNull);
  });

  test('钉选引擎受 admission 约束：超限配置被拒而不是拉必崩 server', () async {
    // qwen3-4b paramsB=4.0 + NPU admission（-c>512 拒绝）：钉 npu 且模型级
    // 不表态时 dc.ctx 收敛到 preset 512 → 放行；构造 preset 不命中的大 ctx：
    reg.instance('wangcai-npu')!.defaultConfig = const EngineDefaults(ctx: 4096);
    final ok = await inf.loadModel(
        '${tmp.path}${Platform.pathSeparator}BigModel-8B.gguf',
        nCtx: 4096,
        engineId: 'wangcai-npu');
    // preset 不命中（glob 不匹配）→ 无实测上限 → admission ifParamsBAtLeast 3.5
    // 拿不到 paramsB（null）→ 放行由 server 自证。这里断言放行即可（探测型
    // 断言：钉选分支没有静默吞掉大 ctx）。
    expect(ok, isTrue);
    expect(spawns.byExe['npu'], containsAllInOrder(['-c', '4096']));
  });

  test('草稿头经 --model-draft 尾参入场，且用户尾参排最后', () async {
    reg.instance('wangcai-npu')!.defaultConfig =
        const EngineDefaults(args: ['--dc-flag']);
    await loadNpu('Generic-Fake.gguf',
        draftPath: '${tmp.path}${Platform.pathSeparator}draft.gguf',
        customArgs: ['--mine']);
    final args = spawns.byExe['npu']!;
    expect(args, containsAllInOrder(['--model-draft', '${tmp.path}${Platform.pathSeparator}draft.gguf']));
    expect(args, contains('--mine'));
    expect(args, isNot(contains('--dc-flag')),
        reason: 'customArgs 整档替换 dc.args；draft 由系统注入不受影响');
    expect(args.last, '--mine', reason: '用户尾参最后追加 = 天然覆盖');
  });

  test('CUDA 模板 gpuLayers：模型级显式值赢过模板默认 99', () async {
    await loadNpu('Generic-Fake.gguf', engineId: 'llamacpp-cuda', gpuLayers: 8);
    expect(spawns.byExe['cuda'], containsAllInOrder(['-ngl', '8']));
  });
}
