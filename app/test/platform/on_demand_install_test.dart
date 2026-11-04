// Phase 3c 按需下载闭环离线单测：路由无本地引擎 → decision.needInstall →
// lastInstallSuggestion → installEngine（假 EngineStore 落位 exe）→ 实例装配
// + engines.json 持久化 → loadModel 重试成功。假进程，绝不 spawn 真进程、绝不联网。
import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart' hide EnginePhase;
import 'package:wangcai/engine/engine_paths.dart';
import 'package:wangcai/engine/engine_registry.dart';
import 'package:wangcai/engine/engine_store.dart';
import 'package:wangcai/engine/engine_host.dart' show EngineProcess;
import 'package:wangcai/engine/openvino_probe.dart';
import 'package:wangcai/platform/local_server_inference.dart';

class FakeProcess implements EngineProcess {
  final stdoutCtl = StreamController<List<int>>();
  final stderrCtl = StreamController<List<int>>();
  final _exit = Completer<int>();
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
    if (!_exit.isCompleted) _exit.complete(0);
    return true;
  }
}

/// 假引擎商店：不落网络，install() 直接在目标目录写出 llama-server.exe。
/// 记录 mirrors/目录透传，验证 installEngine 的参数接线。
class _FakeStore extends EngineStore {
  _FakeStore(super.paths, {this.destDir, this.failWith});
  final Directory? destDir;
  final String? failWith;
  List<String> lastMirrors = const [];
  Directory? lastDirArg;
  int progressCalls = 0;

  @override
  Future<InstallResult> install(StoreRelease release,
      {List<String> mirrorPrefixes = const [],
      void Function(int received, int total)? onProgress}) async {
    lastMirrors = mirrorPrefixes;
    lastDirArg = destDir;
    onProgress?.call(1, 2);
    progressCalls++;
    if (failWith != null) {
      return InstallResult(serverExe: null, dir: destDir?.path ?? '', error: failWith);
    }
    // 与 EngineStore 真实语义一致：override 为空 → 数据区 engines/（注入的 tmp）。
    final d = destDir ?? paths.enginesDir;
    d.createSync(recursive: true);
    final exe = '${d.path}${Platform.pathSeparator}llama-server.exe';
    File(exe).writeAsBytesSync([1]);
    return InstallResult(serverExe: exe, dir: d.path);
  }
}

void main() {
  late Directory tmp;
  late EngineRegistry reg;
  late List<FakeProcess> spawned;
  final inf = LocalServerInference.instance;

  setUp(() async {
    tmp = Directory.systemTemp.createTempSync('wc_install');
    spawned = <FakeProcess>[];
    // 三个本地实例全部未装（binaryPath 缺失）→ 路由只能发下载信号。
    reg = EngineRegistry(
      paths: EnginePaths.root(tmp),
      instances: [
        EngineInstance(id: 'wangcai-npu', manifestId: 'wangcai-npu'),
        EngineInstance(id: 'llamacpp-cuda', manifestId: 'llamacpp-cuda'),
        EngineInstance(id: 'llamacpp-vulkan', manifestId: 'llamacpp-vulkan'),
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
    inf.attachRegistryForTest(reg, paths: EnginePaths.root(tmp));
    probeRunnerForTest = (_, __) async =>
        'OPENVINO2: GGML_OPENVINO_DEVICE=NPU - fake';
    inf.onBatteryForTest = false;
    await inf.setRoutingTier('speed');
    inf.engineStoreForTest = null;
    inf.lastInstallSuggestion = null;
  });

  tearDown(() async {
    inf.engineStoreForTest = null;
    inf.onBatteryForTest = null;
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

  Future<bool> load(String name) => inf.loadModel(
      '${tmp.path}${Platform.pathSeparator}$name', nCtx: 256);

  test('全未装 → 加载失败并挂 cuda 下载建议（cuda 快道优先）', () async {
    expect(await load('Generic-Fake.gguf'), isFalse);
    expect(inf.lastInstallSuggestion, 'cuda');
    expect(spawned, isEmpty, reason: '没装引擎绝不能凭空 spawn');
  });

  test('installEngine：镜像/目录透传 → exe 落位 → 实例装配 → 建议销账', () async {
    _FakeStore? captured;
    final custom = '${tmp.path}${Platform.pathSeparator}my_engines';
    inf.engineStoreForTest = (paths, dir) =>
        captured = _FakeStore(paths, destDir: dir);
    final err = await inf.installEngine('cuda',
        enginesDir: custom, mirrors: const ['https://ghproxy.net/']);
    expect(err, isNull);
    expect(captured!.lastMirrors, ['https://ghproxy.net/'],
        reason: 'settings.engineMirror 必须透传给下载器');
    expect(captured!.lastDirArg?.path, custom,
        reason: 'settings.enginesDir 必须成为安装根目录');
    expect(captured!.progressCalls, 1);

    final cuda = reg.instance('llamacpp-cuda')!;
    expect(cuda.enabled, isTrue);
    expect(cuda.binaryPath, isNotNull);
    expect(File(cuda.binaryPath!).existsSync(), isTrue);

    // engines.json 持久化（重启后还记得装在哪）
    final persisted = jsonDecode(
        File('${tmp.path}${Platform.pathSeparator}engines.json')
            .readAsStringSync()) as List;
    final row = persisted.firstWhere((e) => e['id'] == 'llamacpp-cuda');
    expect(row['binaryPath'], cuda.binaryPath);
    expect(row['enabled'], isTrue);
  });

  test('enginesDir 未配置 → override 传 null（数据区默认目录）', () async {
    _FakeStore? captured;
    inf.engineStoreForTest = (paths, dir) => captured = _FakeStore(paths, destDir: dir);
    expect(await inf.installEngine('vulkan'), isNull);
    expect(captured!.lastDirArg, isNull);
    expect(reg.instance('llamacpp-vulkan')!.enabled, isTrue);
  });

  test('安装失败 → 错误文案回 UI，实例保持未装配、建议不销账', () async {
    inf.engineStoreForTest = (paths, dir) =>
        _FakeStore(paths, destDir: dir, failWith: '所有镜像下载失败');
    final err = await inf.installEngine('cuda');
    expect(err, '所有镜像下载失败');
    expect(reg.instance('llamacpp-cuda')!.binaryPath, isNull,
        reason: '失败不得落位 exe（enabled 本就默认 true，不作断言）');
  });

  test('闭环全程：建议 → 安装 → 重试加载成功并销账', () async {
    expect(await load('Generic-Fake.gguf'), isFalse);
    expect(inf.lastInstallSuggestion, 'cuda');

    inf.engineStoreForTest = (paths, dir) => _FakeStore(paths, destDir: dir);
    expect(await inf.installEngine('cuda'), isNull);

    // 重试：这次路由有已装候选（cuda），速度档直接选中并 spawn fake server。
    expect(await load('Generic-Fake.gguf'), isTrue);
    expect(inf.lastInstallSuggestion, isNull);
    expect(reg.hostOf('llamacpp-cuda').baseUrl, isNotNull);
    expect(spawned, isNotEmpty);
  });


  group('discoverEngineExes：自选目录扫描识别（用户反馈 v0.0.3）', () {
    late Directory tmp;
    setUp(() {
      tmp = Directory.systemTemp.createTempSync('wc_discover');
    });
    tearDown(() {
      for (var i = 0; i < 10; i++) {
        try {
          if (tmp.existsSync()) tmp.deleteSync(recursive: true);
          return;
        } catch (_) {}
      }
    });

    File put(List<String> segs, String name) {
      var p = tmp.path;
      for (final s in segs) {
        p = '$p${Platform.pathSeparator}$s';
      }
      final d = Directory(p)..createSync(recursive: true);
      return File('${d.path}${Platform.pathSeparator}$name')
        ..writeAsBytesSync([1]);
    }

    test('目录名含 cuda/vulkan 即认领（嵌套 ≤2 层），未知目录跳过', () {
      final cuda = put(['my-cuda-build'], 'llama-server.exe');
      final vulkan = put(['deps', 'llama-vulkan-bin'], 'llama-server.exe');
      put(['random-tools'], 'llama-server.exe'); // 目录名无变体线索 → 跳过
      put(['empty'], 'README.txt');

      final found = EngineStore.discoverEngineExes(tmp);
      expect(found['cuda'], cuda.path);
      expect(found['vulkan'], vulkan.path);
      expect(found, hasLength(2));
    });

    test('商店标准目录名 llamacpp-<ver>-<variant> 命中；空目录返回空表', () {
      final dir = EngineStore.discoverEngineExes(
          Directory('${tmp.path}${Platform.pathSeparator}不存在'));
      expect(dir, isEmpty);

      put(['llamacpp-b12034-cuda'], 'llama-server.exe');
      final found = EngineStore.discoverEngineExes(tmp);
      expect(found.keys, ['cuda']);
    });
  });
}
