// M2 DoD（设计 §9）· 真机四线：NPU(1.7B) / CUDA(4B 5060Ti) / Vulkan(iGPU) /
// 远端协议（用本地 llama-server 的 /v1 冒充 OpenAI 端点验证协议层）。
// 跑法（app/ 下，引擎三件套 env 同 gateway_npu_test）：
//   flutter test test/platform/m2_dod_test.dart
// skip 门控：CUDA/Vulkan 引擎未安装（商店产物不存在）→ 整体跳过，不阻塞 CI。
import 'dart:io';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';
import 'package:tongyi_lite/engine/bindings_store.dart';
import 'package:tongyi_lite/engine/engine_config.dart' show EngineConfig;
import 'package:tongyi_lite/engine/engine_paths.dart';
import 'package:tongyi_lite/engine/engine_store.dart';
import 'package:tongyi_lite/platform/local_server_inference.dart';
import 'package:tongyi_lite/platform/wangcai_paths.dart';
import 'package:tongyi_lite/providers/shared_providers.dart';

void main() {
  // 刻意不 ensureInitialized（M1-d 教训：binding 把 HttpClient mock 成 400，
  // 真机 health/SSE 全灭）。sqlite 用 ffi（测试进程没有插件注册）。
  setUpAll(() {
    sqfliteFfiInit();
    databaseFactory = databaseFactoryFfi;
    BindingsStore.databaseFactoryFfiForTest = databaseFactoryFfi;
  });

  final paths = WangCaiPaths.enginePaths();
  final store = EngineStore(paths);
  final cudaDir = Directory(
      '${paths.enginesDir.path}${Platform.pathSeparator}llamacpp-b12034-cuda');
  final vulkanDir = Directory(
      '${paths.enginesDir.path}${Platform.pathSeparator}llamacpp-b12034-vulkan');
  final modelDir = WangCaiPaths.modelsRoot();
  final qwen = File('${modelDir.path}${Platform.pathSeparator}Qwen3-4B-Q4_K_M.gguf');
  final lfm = File('${modelDir.path}${Platform.pathSeparator}LFM3-1.7B-Q4_K_M.gguf');
  final skipReason = (!Platform.isWindows ||
          !cudaDir.existsSync() ||
          !vulkanDir.existsSync() ||
          !qwen.existsSync() ||
          !lfm.existsSync())
      ? '需要 Windows + 商店已装 b12034 (cuda+vulkan) + Qwen3-4B/LFM3 gguf'
      : false;

  setUpAll(() {
    final inf = LocalServerInference.instance;
    inf.onLoadingLog = (m) {
      if (m != null) print('[engine] $m');
    };
  });

  tearDownAll(() async {
    try {
      await LocalServerInference.instance.unloadModel();
    } catch (_) {}
  });

  test(
    '探测：CUDA（Blackwell 驱动）与 Vulkan 设备枚举',
    () async {
      final cuda = await store.cuda();
      expect(cuda, isNotNull, reason: 'nvidia-smi 应可用');
      // ignore: avoid_print
      print('CUDA: ${cuda!.name} driver=${cuda.driverVersion} '
          'blackwellReady=${cuda.blackwellReady}');
      expect(cuda.blackwellReady, isTrue, reason: '5060Ti(sm_120) 需驱动 ≥570');

      final vulkanServer =
          store.findServerExe(vulkanDir) ?? store.findServerExe(cudaDir);
      expect(vulkanServer, isNotNull);
      final devices = await store.vulkanDevices(vulkanServer!);
      // ignore: avoid_print
      print('Vulkan devices: $devices');
      if (devices.isEmpty) {
        // 取证：原始输出（措辞解析失败 vs 命令失败要分得清）。
        final pr = await Process.run(vulkanServer, ['--list-devices']);
        // ignore: avoid_print
        print('RAW exit=${pr.exitCode} out=${pr.stdout} err=${pr.stderr}');
      }
      expect(devices, isNotEmpty, reason: '官方 server --list-devices 应枚举到 GPU');
    },
    timeout: const Timeout(Duration(minutes: 3)),
    skip: skipReason,
  );

  test(
    'CUDA 线：speed 档选 CUDA → 4B 答一问 → 绑定表回写 t/s',
    () async {
      final inf = LocalServerInference.instance;
      await inf.setRoutingTier('speed');
      // 自愈历史遗留的 broken（前轮失败 tearDown 未恢复时仍能跑）；
      // vulkan 标 broken：speed 档在 vulkan(实测 166 t/s) 在场时会选它
      // （策略正确行为），此测试专验 CUDA 线可用性 → 暂时屏蔽 vulkan。
      final b = await BindingsStore.open(WangCaiPaths.enginePaths());
      await b.setStatus('llamacpp-cuda', 'Qwen3-4B-Q4_K_M.gguf', BindingStatus.usable);
      await b.setStatus('llamacpp-vulkan', 'Qwen3-4B-Q4_K_M.gguf', BindingStatus.broken);
      addTearDown(() async {
        await b.setStatus(
            'llamacpp-vulkan', 'Qwen3-4B-Q4_K_M.gguf', BindingStatus.usable);
      });
      final ok = await inf.loadModel(qwen.path, nCtx: 4096); // 设置页默认 ctx
      expect(ok, isTrue, reason: 'CUDA 4B 加载失败（见 [engine] 日志）');
      final host = inf.debugHost()!;
      expect(host.instanceId, 'llamacpp-cuda', reason: 'vulkan 屏蔽后 speed 档应选 CUDA');
      expect(host.lastSpawnArgs, containsAllInOrder(['-ngl', '99']));

      final sb = StringBuffer();
      await for (final tok in inf.completionWithMessages(
          prompt: '2+2 等于几？只报数字', messagesJson: '[]', maxTokens: 24)) {
        sb.write(tok);
      }
      // ignore: avoid_print
      print('CUDA A: ${sb.toString().trim()}');
      expect(sb.toString().trim(), isNotEmpty);

      // 回写：绑定表必须出现 CUDA × Qwen3-4B 的实测行（recordRun 是
      // unawaited 异步，等它落库再查；modelId 口径 = basename 带后缀）。
      await Future<void>.delayed(const Duration(milliseconds: 500));
      final row = await b.get('llamacpp-cuda', 'Qwen3-4B-Q4_K_M.gguf');
      expect(row, isNotNull);
      expect(row!.lastDecodeTps ?? 0, greaterThan(0), reason: 't/s 必须回写');
      // ignore: avoid_print
      print('绑定回写: ${row.lastDecodeTps!.toStringAsFixed(1)} tok/s '
          'ctx=${row.maxStableCtx}');
      await inf.unloadModel();
    },
    timeout: const Timeout(Duration(minutes: 10)),
    skip: skipReason,
  );

  test(
    'Vulkan 线：CUDA 与 NPU 都不可用后 speed 档改道 Vulkan → 4B 答一问',
    () async {
      final inf = LocalServerInference.instance;
      await inf.setRoutingTier('speed');
      // 注意绑定表是全局共享 sqlite 连接（sqflite_ffi 同路径复用连接），
      // 全测试共享一个 store，tearDownAll 统一关（分测 close 会误伤他人）。
      final b = await BindingsStore.open(WangCaiPaths.enginePaths());
      // CUDA 与 NPU 都标 broken：速度档唯一可选 = Vulkan（无实测也按启发上）。
      await b.setStatus('llamacpp-cuda', 'Qwen3-4B-Q4_K_M.gguf', BindingStatus.broken);
      await b.setStatus('wangcai-npu', 'Qwen3-4B-Q4_K_M.gguf', BindingStatus.broken);
      addTearDown(() async {
        await b.setStatus(
            'llamacpp-cuda', 'Qwen3-4B-Q4_K_M.gguf', BindingStatus.usable);
        await b.setStatus(
            'wangcai-npu', 'Qwen3-4B-Q4_K_M.gguf', BindingStatus.usable);
      });
      final ok = await inf.loadModel(qwen.path, nCtx: 4096);
      expect(ok, isTrue, reason: 'Vulkan 4B 加载失败（见 [engine] 日志）');
      final host = inf.debugHost()!;
      expect(host.instanceId, 'llamacpp-vulkan', reason: 'CUDA broken → Vulkan');
      final sb = StringBuffer();
      await for (final tok in inf.completionWithMessages(
          prompt: '打个招呼，五个字以内', messagesJson: '[]', maxTokens: 24)) {
        sb.write(tok);
      }
      // ignore: avoid_print
      print('Vulkan A: ${sb.toString().trim()}');
      expect(sb.toString().trim(), isNotEmpty);
      await inf.unloadModel();
    },
    timeout: const Timeout(Duration(minutes: 10)),
    skip: skipReason,
  );

  test(
    'NPU 线：npuFirst 档一问 + 单 active 互斥（切 NPU 时 CUDA host 被停）',
    () async {
      final inf = LocalServerInference.instance;
      await inf.setRoutingTier('npu');
      final ok = await inf.loadModel(lfm.path, nCtx: 1024);
      expect(ok, isTrue, reason: 'NPU 1.7B 加载失败（见 [engine] 日志）');
      expect(inf.debugHost()!.instanceId, 'wangcai-npu');
      // 互斥：先前 CUDA 线的 host 若还在，必须已被停（baseUrl 为 null）。
      final reg = await inf.registry();
      expect(reg.hostOf('llamacpp-cuda').baseUrl, isNull);

      final sb = StringBuffer();
      await for (final tok in inf.completionWithMessages(
          prompt: '介绍你自己，一句话', messagesJson: '[]', maxTokens: 48)) {
        sb.write(tok);
      }
      // ignore: avoid_print
      print('NPU A: ${sb.toString().trim()}');
      expect(sb.toString().trim(), isNotEmpty);
      await inf.unloadModel();
    },
    timeout: const Timeout(Duration(minutes: 10)),
    skip: skipReason,
  );

  test(
    '远端协议线：RemoteOpenAiHost 指向本地 server /v1 → probe 出模型数',
    () async {
      final inf = LocalServerInference.instance;
      // 起一个本地 server 当「远端」端点（NPU 1.7B，协议同 OpenAI）。
      await inf.setRoutingTier('npu');
      expect(await inf.loadModel(lfm.path, nCtx: 512), isTrue);
      final base = inf.debugHost()!.baseUrl!;

      // RemoteOpenAiHost 属引擎注册表第 5 类：直接从 registry 拿。
      final reg = await inf.registry();
      final rh = reg.hostOf('openai-remote');
      await rh.start(EngineConfig(
        engineId: 'openai-remote',
        modelPath: '',
        remoteBaseUrl: base,
        remoteModel: 'lfm3',
      ));
      final caps = await rh.probe();
      expect(caps.nativeToolCall, isTrue, reason: 'probe /v1/models 200 才置位');
      // ignore: avoid_print
      print('远端协议线 OK: base=$base caps=${caps.devices}');
      await inf.unloadModel();
    },
    timeout: const Timeout(Duration(minutes: 10)),
    skip: skipReason,
  );
}
