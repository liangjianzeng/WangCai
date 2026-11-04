// M2-e 调度护栏离线单测（§7.3）：单 active 互斥 + 空闲超时卸载。
// fake 进程/health/端口注入，绝不 spawn 真进程。
import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart' hide EnginePhase;
import 'package:flutter_riverpod/flutter_riverpod.dart' show ProviderContainer;
import 'package:wangcai/engine/engine_config.dart';
import 'package:wangcai/engine/engine_paths.dart';
import 'package:wangcai/engine/engine_registry.dart';
import 'package:wangcai/engine/engine_status.dart' show EnginePhase;
import 'package:wangcai/engine/engine_host.dart' show EngineProcess;
import 'package:wangcai/engine/llama_server_host.dart' show LlamaServerHost;
import 'package:wangcai/platform/local_server_inference.dart';
import 'package:wangcai/providers/shared_providers.dart';

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

  void emitOut(String s) => stdoutCtl.add(utf8.encode(s));
}

void main() {
  late Directory tmp;
  late EngineRegistry reg;
  late File dummyNpu;
  late File dummyCuda;
  final spawned = <FakeProcess>[];

  setUp(() {
    tmp = Directory.systemTemp.createTempSync('wc_single');
    dummyNpu = File('${tmp.path}${Platform.pathSeparator}llama-npu.exe')
      ..writeAsBytesSync([1]);
    dummyCuda = File('${tmp.path}${Platform.pathSeparator}llama-cuda.exe')
      ..writeAsBytesSync([1]);
    spawned.clear();
    reg = EngineRegistry(
      paths: EnginePaths.root(tmp),
      instances: [
        EngineInstance(
            id: 'wangcai-npu',
            manifestId: 'wangcai-npu',
            binaryPath: dummyNpu.path),
        EngineInstance(
            id: 'llamacpp-cuda',
            manifestId: 'llamacpp-cuda',
            binaryPath: dummyCuda.path),
      ],
      processRunner: (exe, args, env) async {
        final p = FakeProcess();
        spawned.add(p);
        return p;
      },
      healthProbe: (_, __) async => true,
      portAllocator: () async => 8123,
      sleeper: (d) async {},
      parentEnv: const {'PATH': r'C:\Windows', 'SystemRoot': r'C:\Windows'},
    );
    LocalServerInference.instance
        .attachRegistryForTest(reg, paths: EnginePaths.root(tmp));
  });

  tearDown(() async {
    try {
      await LocalServerInference.instance.unloadModel();
    } catch (_) {}
    LocalServerInference.instance.idleUnloadForTest = null;
    for (var i = 0; i < 10; i++) {
      try {
        if (tmp.existsSync()) tmp.deleteSync(recursive: true);
        return;
      } catch (_) {
        await Future<void>.delayed(const Duration(milliseconds: 50));
      }
    }
  });

  test('单 active 互斥：NPU 已就绪时加载走 CUDA，NPU 被停', () async {
    // 1) 先把 NPU 拉到 ready（等价于用户先在 NPU 上聊过）。
    final npuHost = reg.hostOf('wangcai-npu') as LlamaServerHost;
    await npuHost.start(EngineConfig(
        engineId: 'wangcai-npu',
        modelPath: '${tmp.path}${Platform.pathSeparator}LFM3-1.7B-Q4_K_M.gguf',
        ctx: 1024));
    expect(await npuHost.waitReady(const Duration(seconds: 5)), isTrue);
    expect(npuHost.baseUrl, isNotNull);

    // 2) loadModel 无路由意图数据 → speed 启发：CUDA(deviceRank 0) 胜出。
    final inf = LocalServerInference.instance;
    final ok = await inf.loadModel(
        '${tmp.path}${Platform.pathSeparator}Qwen3-4B-Fake.gguf',
        nCtx: 256);
    expect(ok, isTrue, reason: 'cuda 加载应成功（fake probe 恒通）');

    // 3) 互斥：NPU 已被停；CUDA ready。
    expect(reg.hostOf('wangcai-npu').baseUrl, isNull,
        reason: '单 active：旧引擎必须被停');
    expect(reg.hostOf('wangcai-npu').status.phase, EnginePhase.stopped);
    expect(reg.hostOf('llamacpp-cuda').baseUrl, isNotNull);
  });

  test('空闲超时卸载：注入 250ms → 到期自动 unload + 日志留痕', () async {
    final inf = LocalServerInference.instance;
    final logs = <String>[];
    inf.onLoadingLog = (m) {
      if (m != null) logs.add(m);
    };
    // 注入必须在 loadModel 前：加载成功的尾部就会启动计时器。
    inf.idleUnloadForTest = const Duration(milliseconds: 250);
    expect(
        await inf.loadModel(
            '${tmp.path}${Platform.pathSeparator}Qwen3-4B-Fake.gguf',
            nCtx: 256),
        isTrue);
    expect(await inf.isModelLoaded(), isTrue);
    await Future<void>.delayed(const Duration(milliseconds: 700));
    expect(await inf.isModelLoaded(), isFalse, reason: '空闲到期应自动卸载');
    expect(logs.any((l) => l.contains('空闲超时')), isTrue, reason: '留痕：${logs.last}');
    expect(reg.hostOf('llamacpp-cuda').status.phase, EnginePhase.stopped);
  });

  test('卸载后计时器不复活（无二次触发）', () async {
    final inf = LocalServerInference.instance;
    expect(
        await inf.loadModel(
            '${tmp.path}${Platform.pathSeparator}Qwen3-4B-Fake.gguf',
            nCtx: 256),
        isTrue);
    inf.idleUnloadForTest = const Duration(milliseconds: 120);
    await inf.unloadModel();
    await Future<void>.delayed(const Duration(milliseconds: 300));
    expect(await inf.isModelLoaded(), isFalse);
    expect(spawned.where((p) => p.killed), isNotEmpty);
  });

  test('ProviderContainer 引擎注入仍解析到单例（接线无回归）', () async {
    final c = ProviderContainer(overrides: [
      inferenceServiceProvider
          .overrideWithValue(LocalServerInference.instance),
    ]);
    addTearDown(c.dispose);
    expect(c.read(inferenceServiceProvider), same(LocalServerInference.instance));
  });
}
