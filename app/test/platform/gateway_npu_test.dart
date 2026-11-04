// M1-d DoD · NPU 真机三问（可重复回归）。
// 跑法（app/ 下；flutter_tester 不在仓库内，须显式指引擎路径）：
//   export WANGCAI_NPU_E2E=1
//   export WANGCAI_MODEL_DIR=E:/DTXY/WangCai/models
//   export WANGCAI_SERVER_EXE=E:/DTXY/WangCai/src/llama/build/bin/llama-server.exe
//   export WANGCAI_OV_LIBS=E:/DTXY/WangCai/ov/openvino/libs
//   flutter test test/platform/gateway_npu_test.dart
// 缺任一环境（装机用户机器/CI）时整体 skip——不阻塞常规测试。
//
// 覆盖链路：账本扫孤儿 → manifest 渲染（无 -st）→ spawn llama-server →
// /health 就绪 → SSE 流式三问（每问两 prompt）→ 卸载清理。
import 'dart:io';

import 'package:flutter_test/flutter_test.dart' hide EnginePhase;
import 'package:wangcai/engine/engine_status.dart' show EnginePhase;
import 'package:wangcai/engine/process_ledger.dart';
import 'package:wangcai/platform/local_server_inference.dart';
import 'package:wangcai/platform/wangcai_paths.dart';

const _rounds = [
  ['介绍你自己，一句话', '你是谁？'],
  ['比较大小：9.11 和 9.9 哪个大？直接给答案', '为什么？'],
  ['2+2 等于几？只报数字', '再加 1 呢？'],
];

void main() {
  final modelDir = WangCaiPaths.modelsRoot();
  final modelFile = File('${modelDir.path}${Platform.pathSeparator}LFM3-1.7B-Q4_K_M.gguf');
  // 真机 E2E 显式开启（WANGCAI_NPU_E2E=1）：flutter test 并行跑多套件会同时
  // 抢 NPU（每模型 ~20GB 编译缓存互踩），文件在场 ≠ 允许全量测试里真加载。
  final skipReason = (!Platform.isWindows ||
          Platform.environment['WANGCAI_NPU_E2E'] != '1' ||
          !modelFile.existsSync())
      ? '需要 Windows + WANGCAI_NPU_E2E=1 + LFM3-1.7B-Q4_K_M.gguf（WANGCAI_MODEL_DIR，真机 E2E）'
      : false;

  test(
    'LocalServerInference：NPU 加载 LFM3-1.7B 并三问三答',
    () async {
      final inf = LocalServerInference.instance;
      final engineLogs = <String>[];
      inf.onLoadingLog = (m) {
        if (m != null) engineLogs.add(m);
        // ignore: avoid_print
        print('[engine] $m');
      };

      await inf.initialize();
      final t0 = DateTime.now();
      final ok = await inf.loadModel(modelFile.path, nCtx: 1024);
      if (!ok) {
        final h = inf.debugHost();
        // 现场取证：loader 级失败（0xC0000135）只能从 spawn 上下文找根因。
        // ignore: avoid_print
        print('spawn exe=${h?.binaryPath}');
        // ignore: avoid_print
        print('spawn args=${h?.lastSpawnArgs?.join(' ')}');
        final pe = h?.lastSpawnEnv?.entries
            .firstWhere((e) => e.key.toUpperCase() == 'PATH',
                orElse: () => const MapEntry('PATH', '(无)'))
            .value;
        // ignore: avoid_print
        print('spawn PATH head=${pe?.split(';').take(4).join(' | ')}');
        // ignore: avoid_print
        print('spawn engineEnv=${h?.lastSpawnEnv?.entries.where((e) => e.key.toUpperCase().startsWith('GGML_')).toList()}');
      }
      expect(ok, isTrue, reason: 'loadModel 失败：${engineLogs.join('\n')}');
      // ignore: avoid_print
      print('引擎就绪，耗时 ${DateTime.now().difference(t0).inMilliseconds}ms');
      // 引擎日志必须出现过（日志驱动进度的证据）且不含 server 拒参数词。
      expect(engineLogs, isNotEmpty);
      expect(engineLogs.join('\n'), isNot(contains('invalid argument')));

      var pass = 0;
      var total = 0;
      for (final round in _rounds) {
        for (final prompt in round) {
          total++;
          final sb = StringBuffer();
          await for (final tok in inf.completionWithMessages(
            prompt: prompt,
            messagesJson: '[]',
            maxTokens: 96,
          )) {
            sb.write(tok);
          }
          final text = sb.toString().trim();
          // ignore: avoid_print
          print('Q: $prompt\nA: ${text.length > 160 ? '${text.substring(0, 160)}…' : text}');
          if (text.isNotEmpty) pass++;
        }
      }
      expect(pass, total, reason: '$pass/$total 有产出（见上方 Q/A）');

      final stats = await inf.getInferenceStats();
      expect(stats['n_gen'], greaterThan(0), reason: 'stats=$stats');
      await inf.unloadModel();
      expect(await inf.isModelLoaded(), isFalse);
    },
    timeout: const Timeout(Duration(minutes: 10)),
    skip: skipReason,
  );

  test(
    '改配置（ctx 1024→512）重启 → per-profile 缓存目录必换（D6），且能再答一问',
    () async {
      final inf = LocalServerInference.instance;
      await inf.initialize();

      expect(await inf.loadModel(modelFile.path, nCtx: 1024), isTrue);
      final h1 = inf.debugHost()!;
      final cache1 = h1.lastSpawnEnv?['GGML_OPENVINO_CACHE_DIR'];
      expect(cache1, isNotNull);

      expect(await inf.loadModel(modelFile.path, nCtx: 512), isTrue,
          reason: '改 ctx 属改配置：applyPreset=start 语义，必须重启换 profile');
      final h2 = inf.debugHost()!;
      final cache2 = h2.lastSpawnEnv?['GGML_OPENVINO_CACHE_DIR'];
      expect(cache2, isNotNull);
      expect(cache2, isNot(cache1), reason: 'D6：影响编译图的参数变 → 独立缓存目录');
      expect(h2.lastSpawnArgs, containsAllInOrder(['-c', '512']));

      final sb = StringBuffer();
      await for (final tok in inf.completionWithMessages(
          prompt: '说"好"一个字即可', messagesJson: '[]', maxTokens: 16)) {
        sb.write(tok);
      }
      expect(sb.toString().trim(), isNotEmpty);
      await inf.unloadModel();
    },
    timeout: const Timeout(Duration(minutes: 10)),
    skip: skipReason,
  );

  test(
    '看门狗：外部杀进程（账本 pid）→ host 自动复活回 ready（M1-d DoD）',
    () async {
      final inf = LocalServerInference.instance;
      await inf.initialize();
      expect(await inf.loadModel(modelFile.path, nCtx: 1024), isTrue);
      final host = inf.debugHost()!;
      final ledger = ProcessLedger(WangCaiPaths.enginePaths());
      final entries = await ledger.readAll();
      final me = entries.where((e) => e.instanceId == host.instanceId).toList();
      expect(me, hasLength(1), reason: '运行中必须有账本（pid/port）');

      // 外部硬杀（模拟崩溃/OOM killer）：host 应吃重启预算自动复活。
      Process.killPid(me.single.pid);
      // 先等退出事件被消化（否则旧 ready 态会让 waitReady 立即为真 → 假通过）。
      final deadline = DateTime.now().add(const Duration(seconds: 30));
      while (host.status.phase == EnginePhase.ready &&
          DateTime.now().isBefore(deadline)) {
        await Future<void>.delayed(const Duration(milliseconds: 50));
      }
      expect(host.status.phase, isNot(EnginePhase.ready),
          reason: '杀进程后退出事件未被感知');
      final revived = await host.waitReady(const Duration(minutes: 3));
      expect(revived, isTrue, reason: '看门狗未复活：${host.status}');
      final sb = StringBuffer();
      await for (final tok in inf.completionWithMessages(
          prompt: '回一个字：在', messagesJson: '[]', maxTokens: 16)) {
        sb.write(tok);
      }
      expect(sb.toString().trim(), isNotEmpty);
      await inf.unloadModel();
    },
    timeout: const Timeout(Duration(minutes: 10)),
    skip: skipReason,
  );
}
