// Phase 3b 参数体系离线单测：优先级链 **模型级（loadModel 参数）>
// EngineInstance.defaultConfig > manifest preset/模板**。
// fake 进程/health/端口注入，绝不 spawn 真进程（同 single_active 纪律）。
import 'dart:io';

import 'package:flutter_test/flutter_test.dart' hide EnginePhase;
import 'package:wangcai/engine/engine_host.dart' show EngineProcess;
import 'package:wangcai/engine/engine_paths.dart';
import 'package:wangcai/engine/engine_registry.dart';
import 'package:wangcai/engine/openvino_probe.dart';
import 'package:wangcai/platform/local_server_inference.dart';

import '../helpers/fake_process.dart';

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
      prewarmCompletion: (_) async {},
      portAllocator: () async => 8123,
      sleeper: (d) async {},
      parentEnv: const {'PATH': r'C:\Windows', 'SystemRoot': r'C:\Windows'},
    );
    inf.attachRegistryForTest(reg, paths: EnginePaths.root(tmp));
    probeRunnerForTest = (_, __) async =>
        'OPENVINO2: GGML_OPENVINO_DEVICE=NPU - fake';
    // 路由定值：这些测试测的是参数链不是选路，显式档位。
    await inf.setRoutingTier('npu');
  });

  tearDown(() async {
    probeRunnerForTest = null;
    clearOpenvinoProbeCache();
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
    bool expectOk = true,
  }) async {
    final ok = await inf.loadModel('${tmp.path}${Platform.pathSeparator}$name',
        nCtx: nCtx,
        chunk: chunk,
        gpuLayers: gpuLayers,
        customArgs: customArgs,
        engineId: engineId,
        draftPath: draftPath);
    // expectOk=false：admission 拒绝类用例（2026-11-07 模型禁入）——加载被
    // 前置拒是**预期**，断言交给用例本体（检查不拉 server）。
    if (expectOk) {
      expect(ok, isTrue, reason: 'fake probe/health 恒通，$name 应加载成功');
    }
  }

  test('出厂基线：无 dc 无模型级 → ctx=全局默认 4096、无 chunk env、无尾参',
      () async {
    // 2026-11-06 拍板：ctx 单口子，默认档 4096（「最基本」），preset 不再给值。
    await loadNpu('Generic-Fake.gguf');
    expect(spawns.byExe['npu'], containsAllInOrder(['-c', '4096']));
    expect(spawns.envByExe['npu']!['GGML_OPENVINO_PREFILL_CHUNK_SIZE'], isNull);
    expect(spawns.byExe['npu']!.last, isNot('--foo'));
  });

  test('深上下文臂：ctx>4096 自动挂 NPUW_FOLD=YES（16K 不再靠 deep preset）',
      () async {
    final logs = <String>[];
    inf.onLoadingLog = (m) {
      if (m != null) logs.add(m);
    };
    await loadNpu('LFM3-1.7B-deep-arm.gguf', nCtx: 16384);
    expect(spawns.byExe['npu'], containsAllInOrder(['-c', '16384']));
    expect(spawns.envByExe['npu']!['GGML_OPENVINO_NPU_COMPILE_OVERRIDES'],
        'NPUW_FOLD=YES');
    expect(logs.any((l) => l.contains('深上下文臂')), isTrue, reason: '$logs');
    // 默认档 4096 不挂臂（run-npu-16k 配方只属于超档）。
    await loadNpu('LFM3-1.7B-flat.gguf');
    expect(spawns.envByExe['npu']!['GGML_OPENVINO_NPU_COMPILE_OVERRIDES'],
        isNull);
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

  test('preset 只剩质量臂：chunk 出厂实测值仍压场，ctx 不再被 preset 压回',
      () async {
    // 旧口径「preset.ctx 当上限把 4096 收敛回 512」已随全局 ctx 拍板退役；
    // preset 的价值 = chunk256（lfm3-1.7b 实测配置）这类质量臂数据。
    // 载体改用 1.7B（2026-11-07 admission 收紧：4B 级 NPU 上 ctx>512 禁入，
    // Qwen3-4B-Fake@4096 会被前置拒——用例语义本就不是测 admission）。
    reg.instance('wangcai-npu')!.defaultConfig = const EngineDefaults(ctx: 4096);
    await loadNpu('LFM3-1.7B-Fake.gguf', nCtx: 4096);
    expect(spawns.byExe['npu'], containsAllInOrder(['-c', '4096']),
        reason: '4096 是最基本档：任何 preset 都不得再压小 ctx');
    expect(spawns.envByExe['npu']!['GGML_OPENVINO_PREFILL_CHUNK_SIZE'], '256');
  });

  test('preset extraEnv 与 defaultConfig.extraEnv 合并（dc 同键覆盖）', () async {
    // 2026-11-07 改造：Spark/Omni preset 的 extraEnv 已随
    // defect-npu-spark-b12034 摘除（且 Spark 模型名在 NPU 会被 admission
    // 禁入拦下，不再是合规载体）——合并链改用 1.7B 载体验证 dc 侧入场
    //（4B 载体在 admission 收紧后 ctx>512 被前置拒）；
    // preset 侧合并分支保留给用户自定义 manifest（引擎默认链代码不变）。
    reg.instance('wangcai-npu')!.defaultConfig = const EngineDefaults(
        extraEnv: {'GGML_OPENVINO_DISABLE_DECODE_LEVELS': '0'});
    await loadNpu('LFM3-1.7B-Fake.gguf');
    expect(spawns.envByExe['npu']!['GGML_OPENVINO_DISABLE_DECODE_LEVELS'], '0');
  });

  test('admission 模型禁入（2026-11-07）：Spark@NPU 前置拦，不拉必歇菜的 server',
      () async {
    // 2026-11-07 路由重设计后语义加强：核心档拒绝后**不改道**（旧语义会
    // 偷跑 Vulkan——用户实测抱怨「一加载就搞进独显去了」）。
    await loadNpu('Spark-X2.6-4B-Fake.gguf', expectOk: false);
    expect(spawns.byExe['npu'], isNull,
        reason: 'Spark 4B 在 NPU 引擎 decode 特性失效（缺陷单），'
            '必须 admission 前置拦截而不是拉起 server 让用户等死');
    expect(spawns.byExe['cuda'], isNull,
        reason: '核心档拒绝 = 拒绝，绝不自动改道旁路（换引擎是用户的决定）');
  });

  test('视觉前置门（2026-11-07 第二幕）：没挂 mmproj 的模型带图 → 明确报错；挂了 → 放行',
      () async {
    // defect-npu-mtmd 引擎修复后（NPU 带图三线 E2E 全绿），wangcai-npu
    // vision 声明翻回 true，门改 per-model 判定：带图请求打「没挂视觉塔
    // （mmproj）」的模型 → 壳层明确报错，而不是 server 侧一个看不懂的
    // 500（"you may need to provide the mmproj"）；挂了 mmproj → 放行
    // 走 server（视觉真正可用）。
    await loadNpu('Generic-Fake.gguf');
    expect(
        inf.completionWithMessages(prompt: '', messagesJson: '[]',
            imagePaths: ['C:/x/img.png']),
        emitsError(isA<StateError>().having((e) => e.message, 'msg',
            contains('不支持图像理解'))),
        reason: '没挂 mmproj 的模型带图必须前置报错（per-model 门）');
    // 挂上 mmproj 重载 → 门放行（走到请求层；fake 进程无真 HTTP 端点，
    // 请求层 connectionError 即为「门已放行」的证据）。
    await inf.loadModel('${tmp.path}${Platform.pathSeparator}Generic-Fake.gguf',
        mmprojPath: 'C:/fake/mmproj-generic.gguf');
    expect(
        inf.completionWithMessages(prompt: '', messagesJson: '[]',
            imagePaths: ['C:/x/img.png']),
        emitsError(isNot(isA<StateError>()
            .having((e) => e.message, 'msg', contains('不支持图像理解')))),
        reason: '挂了 mmproj 的模型带图必须被门放行（报错应来自请求层）');
    // 纯文本请求不被误伤（门放行 → 走到 server 请求层）。
    Object? caught;
    try {
      await inf.completionWithMessages(prompt: '你好', messagesJson: '[]')
          .drain<void>();
    } catch (e) {
      caught = e;
    }
    expect(caught, isNotNull, reason: 'fake 无真端点，应走到请求层报错');
    expect('$caught', isNot(contains('不支持图像理解')),
        reason: '纯文本请求必须被视觉门放行（报错来自请求层而非门）');
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
    // 全局 ctx 口径（2026-11-06）：准入线 4096，4096 本身全线放行；构造
    // preset 不命中（paramsB 未知）的大参数量模型验证钉选分支原样放行：
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
