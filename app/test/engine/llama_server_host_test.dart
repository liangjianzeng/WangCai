// 假进程/假 health/假时钟驱动 LlamaServerHost 全路径：
// ready 流、参数与环境注入正确性（M0-3 校正）、崩溃重启预算、错误日志、停止清理。
import 'dart:async';
import 'dart:convert';
import 'dart:io';

// flutter_test 自带 EnginePhase（binding 内部用），hide 掉避免撞名。
import 'package:flutter_test/flutter_test.dart' hide EnginePhase;
import 'package:tongyi_lite/engine/bundled_manifests.dart';
import 'package:tongyi_lite/engine/engine_config.dart';
import 'package:tongyi_lite/engine/engine_host.dart';
import 'package:tongyi_lite/engine/engine_paths.dart';
import 'package:tongyi_lite/engine/engine_status.dart';
import 'package:tongyi_lite/engine/llama_server_host.dart';

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
  void exitWith(int code) {
    if (!_exit.isCompleted) _exit.complete(code);
  }
}

class Harness {
  final tmp = Directory.systemTemp.createTempSync('m1_host');
  late final paths = EnginePaths.root(tmp);
  final spawned = <FakeProcess>[];
  final capturedArgs = <List<String>>[];
  final capturedEnv = <Map<String, String>>[];
  final sleepLog = <Duration>[];
  bool healthOk = false;

  late final host = LlamaServerHost(
    instanceId: 'wangcai-npu',
    manifest: bundledManifests()['wangcai-npu']!,
    binaryPath: r'E:\repo\src\llama\build\bin\llama-server.exe',
    paths: paths,
    pathPrefixes: [r'E:\repo\ov\openvino\libs'],
    processRunner: _runner,
    healthProbe: (_, __) async => healthOk,
    portAllocator: () async => 8123,
    sleeper: (d) async {
      sleepLog.add(d);
      await Future<void>.delayed(Duration.zero);
    },
    maxRestartAttempts: 3,
    healthPollInterval: Duration.zero,
    parentEnv: const {'PATH': r'C:\Windows', 'SystemRoot': r'C:\Windows'},
  );

  Future<EngineProcess> _runner(String exe, List<String> args, Map<String, String> env) async {
    spawned.add(FakeProcess());
    capturedArgs.add(args);
    capturedEnv.add(env);
    return spawned.last;
  }

  Future<void> idle() => Future<void>.delayed(Duration.zero);
  Future<void> waitSpawns(int n) async {
    for (var i = 0; i < 10000 && spawned.length < n; i++) {
      await idle();
    }
    if (spawned.length < n) fail('spawn 数未达 $n（实际 ${spawned.length}）');
  }

  Future<void> waitForStatus(EnginePhase p, {int maxIters = 100000}) async {
    for (var i = 0; i < maxIters && host.status.phase != p; i++) {
      await idle();
    }
    if (host.status.phase != p) fail('状态未到 $p（实际 ${host.status}）');
  }

  void dispose() {
    for (final s in spawned) {
      s.stdoutCtl.close();
      s.stderrCtl.close();
    }
    tmp.deleteSync(recursive: true);
  }
}

EngineConfig testCfg({int? ctx, int? chunk, String? mmproj}) => EngineConfig(
      engineId: 'wangcai-npu',
      modelPath: r'E:\models\LFM3-1.7B-Q4_K_M.gguf',
      mmprojPath: mmproj,
      ctx: ctx,
      chunk: chunk,
      device: 'NPU',
      paramsB: 1.7,
    );

void main() {
  late Harness h;
  setUp(() => h = Harness());
  tearDown(() => h.dispose());

  test('launch→model loaded→health：launching→warming→ready + baseUrl', () async {
    await h.host.start(testCfg(ctx: 1024, chunk: 256));
    await h.waitSpawns(1);
    expect(h.host.status.phase, EnginePhase.launching);

    h.spawned[0].emitOut('0.19.2 I srv  server_run_i: model loaded\n');
    await h.waitForStatus(EnginePhase.warming);

    h.healthOk = true;
    await h.waitForStatus(EnginePhase.ready);
    expect(h.host.baseUrl, 'http://127.0.0.1:8123/v1');
  });

  test('参数注入（M0-3 校正）：无 -st；-np 1 -fa 1 -dev OPENVINO3 --jinja；mmproj 成对可选', () async {
    await h.host.start(testCfg(ctx: 1024, chunk: 256));
    await h.waitSpawns(1);
    final args = h.capturedArgs[0];
    expect(args, isNot(contains('-st')));
    expect(args, containsAllInOrder(['-np', '1']));
    expect(args, containsAllInOrder(['-fa', '1']));
    expect(args, containsAllInOrder(['-dev', 'OPENVINO3']));
    expect(args, contains('--jinja'));
    expect(args, containsAllInOrder(['--port', '8123']));
    expect(args, isNot(contains('--mmproj'))); // 未配 mmproj → 成对删除

    h.healthOk = true;
    await h.host.stop();
    await h.host.start(testCfg(ctx: 512, mmproj: r'E:\models\mmproj.gguf'));
    await h.waitSpawns(2);
    expect(h.capturedArgs[1], containsAllInOrder(['--mmproj', r'E:\models\mmproj.gguf']));
    expect(h.capturedArgs[1], containsAllInOrder(['-c', '512']));
  });

  test('env 注入：per-profile 缓存目录（D6）、chunk、设备；残留清除', () async {
    await h.host.start(testCfg(ctx: 1024, chunk: 128));
    await h.waitSpawns(1);
    final env = h.capturedEnv[0];
    final cfg = testCfg(ctx: 1024, chunk: 128);
    expect(env['GGML_OPENVINO_CACHE_DIR'],
        h.paths.cacheDirFor(cfg.profileId).path);
    expect(env['GGML_OPENVINO_DEVICE'], 'NPU');
    expect(env['GGML_OPENVINO_PREFILL_CHUNK_SIZE'], '128');
    expect(env['PATH'], startsWith(r'E:\repo\src\llama\build\bin;E:\repo\ov\openvino\libs'));
    // 独立缓存目录已创建（D6）
    expect(await h.paths.cacheDirFor(cfg.profileId).exists(), isTrue);
  });

  test('崩溃重启预算 3 次（1s/4s/16s）后置 error（M1-d 看门狗 DoD）', () async {
    await h.host.start(testCfg(ctx: 1024));
    for (var i = 1; i <= 4; i++) {
      await h.waitSpawns(i);
      h.spawned[i - 1].exitWith(1);
      await h.idle();
    }
    await h.waitForStatus(EnginePhase.error);
    expect(h.spawned, hasLength(4)); // 1 初始 + 3 重启
    // sleepLog 混有 health 轮询的 Duration.zero 心跳，只校验退避档。
    expect(h.sleepLog.where((d) => d > Duration.zero).toList(), [
      const Duration(seconds: 1),
      const Duration(seconds: 4),
      const Duration(seconds: 16),
    ]);
  });

  test('错误日志（ZE_RESULT/OOM 词表）→ error 且不重启', () async {
    await h.host.start(testCfg(ctx: 1024));
    await h.waitSpawns(1);
    h.spawned[0].emitOut('ZE_RESULT_ERROR_OUT_OF_HOST_MEMORY in pfnAppendGraphExecute\n');
    await h.waitForStatus(EnginePhase.error);
    expect(h.spawned, hasLength(1), reason: '编译/执行错误是配置问题，重启无益');
  });

  test('stop：kill 进程、账本清理、状态 stopped', () async {
    await h.host.start(testCfg(ctx: 1024));
    await h.waitSpawns(1);
    final ledgerDir = h.paths.ledgerDir;
    final files = ledgerDir.existsSync()
        ? ledgerDir.listSync().where((e) => e.path.endsWith('.port.json')).toList()
        : <FileSystemEntity>[];
    expect(files, hasLength(1));

    await h.host.stop();
    expect(h.host.status.phase, EnginePhase.stopped);
    expect(h.spawned[0].killed, isTrue);
    expect(h.host.lastConfig, isNotNull);
    final after = ledgerDir.existsSync()
        ? ledgerDir.listSync().where((e) => e.path.endsWith('.port.json')).toList()
        : <FileSystemEntity>[];
    expect(after, isEmpty);
  });
}
