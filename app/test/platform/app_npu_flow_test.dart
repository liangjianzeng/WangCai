// M1-d DoD · 「App 内三问 + 设置页改配置生效」的 provider 层复验（真机门控）。
// 跑法（app/ 下，同 gateway_npu_test 的三件套 env + E2E 显式开关；用正斜杠防 MSYS 削路径）：
//   export WANGCAI_NPU_E2E=1
//   export WANGCAI_MODEL_DIR=E:/DTXY/WangCai/models
//   export WANGCAI_SERVER_EXE=E:/DTXY/WangCai/src/llama/build/bin/llama-server.exe
//   export WANGCAI_OV_LIBS=E:/DTXY/WangCai/ov/openvino/libs
//   flutter test test/platform/app_npu_flow_test.dart
//
// 与 gateway_npu_test（引擎层直连）的分工：这里走 **UI 按钮背后的同一批
// notifier**——模型管理页=ModelManagerNotifier.loadModel、聊天页=
// ChatNotifier.sendMessage（真实路由 planGenerationRoute→local）、
// 设置页=SettingsNotifier.setContextSize。证明「App 内」链路端到端可用。
import 'dart:async';
import 'dart:io';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';
import 'package:wangcai/models/chat_message.dart';
import 'package:wangcai/platform/local_server_inference.dart';
import 'package:wangcai/platform/wangcai_paths.dart';
import 'package:wangcai/providers/chat_provider.dart';
import 'package:wangcai/providers/model_provider.dart';
import 'package:wangcai/providers/settings_provider.dart';
import 'package:wangcai/providers/shared_providers.dart';
import 'package:wangcai/services/settings_service.dart';
import 'package:wangcai/services/storage_service.dart';
import 'package:wangcai/tts/edge_tts_service.dart';

/// 设置页真 notifier + 内存设置后端。
/// 原因：SettingsService 落盘走 getApplicationDocumentsDirectory → 依赖
/// ServicesBinding，而 binding 又会把 HttpClient mock 成 400（引擎全灭）。
/// load/save 换成内存字段后，setContextSize/setAgentEnabled 的 notifier
/// 语义与 UI 完全一致（ModelManagerNotifier 读的正是 service.load()）。
class _InMemSettingsService extends SettingsService {
  InferenceSettings _current = const InferenceSettings();
  @override
  Future<InferenceSettings> load() async => _current;
  @override
  Future<void> save(InferenceSettings s) async => _current = s;
}

void main() {
  // 刻意**不** ensureInitialized：TestWidgetsFlutterBinding 会把 HttpClient
  // 全 mock 成 400（真机 health/SSE 全灭）。metrics/goal 驱动的 binding 异常
  // 在 chat_provider 内部已 try/catch，只打日志不致败（真机首跑实证）。
  setUpAll(() {
    sqfliteFfiInit();
    databaseFactory = databaseFactoryFfi;
    // EdgeTtsService 单例的 AudioPlayer 字段初始化要 ServicesBinding（懒汉式
    // 首触在 sendMessage 里会抛穿）。这里 onboarding 式预触发：吞错让它成型，
    // 之后 stop() 对半初始化 player 无害空转。
    runZonedGuarded(() {
      try {
        EdgeTtsService.instance;
      } catch (_) {/* 半初始化即可用：stop() 内部自 catch */}
    }, (e, _) {});
  });
  final sep = Platform.pathSeparator;
  final dir = WangCaiPaths.modelsRoot();
  final lfm = File('${dir.path}${sep}LFM3-1.7B-Q4_K_M.gguf');
  final qwen = File('${dir.path}${sep}Qwen3-4B-Q4_K_M.gguf');
  // 真机 E2E 显式开启（WANGCAI_NPU_E2E=1）：与 gateway_npu/agent_npu 同纪律——
  // flutter test 全量会并行跑多套件，真 spawn 引擎互抢端口/设备，默认必须跳过。
  final skipReason = (!Platform.isWindows ||
          Platform.environment['WANGCAI_NPU_E2E'] != '1' ||
          !lfm.existsSync() ||
          !qwen.existsSync())
      ? '需要 Windows + WANGCAI_NPU_E2E=1 + LFM3-1.7B-Q4_K_M.gguf + Qwen3-4B-Q4_K_M.gguf（WANGCAI_MODEL_DIR，真机 E2E）'
      : false;

  test(
    'App 流程：模型管理加载→聊天三问→设置页 ctx 生效→换 4B 再答',
    () async {
      final inf = LocalServerInference.instance;
      final container = ProviderContainer(overrides: [
        inferenceServiceProvider.overrideWithValue(inf),
        settingsServiceProvider.overrideWithValue(_InMemSettingsService()),
      ]);
      addTearDown(container.dispose);
      addTearDown(() async {
        try {
          await inf.unloadModel();
        } catch (_) {}
      });
      final storage = StorageService();
      final mgr = container.read(modelManagerProvider.notifier);
      final chat = container.read(chatNotifierProvider.notifier);
      final settings = container.read(settingsProvider.notifier);

      // 1) 模型管理页加载 1.7B。设置页 contextSize 出厂默认 4096，
      //    必须被 preset 实测上限收敛到 1024（否则 NPU 顶穿）。
      expect(await mgr.loadModel('LFM3-1.7B-Q4_K_M'), isTrue,
          reason: '加载失败：${mgr.loadingLogs.join('\n')}');
      expect(inf.debugHost()!.lastSpawnArgs, containsAllInOrder(['-c', '1024']),
          reason: '设置默认 4096 应收敛到 preset 上限 1024');
      expect(mgr.state.isLoaded, isTrue);

      // 2) 聊天页三问：等价于聊天页关掉「智能体」开关（settings.agentEnabled）
      //    ——普通聊天直通 completionWithMessages；agent 工具链属 M4 DoD。
      //    真实路由（本地已加载 → local）→ 每条落库非空 assistant。
      await settings.setAgentEnabled(false);
      await container.read(conversationsProvider.notifier).create(title: 'M1-d 真机');
      final conv = container.read(conversationsProvider).first;
      const prompts = [
        '介绍你自己，一句话',
        '比较大小：9.11 和 9.9 哪个大？直接给答案',
        '2+2 等于几？只报数字',
      ];
      for (final p in prompts) {
        final t0 = DateTime.now();
        final resp = await chat.sendMessage(conv.id, p);
        // ignore: avoid_print
        print('Q: $p\nA: ${resp.length > 140 ? '${resp.substring(0, 140)}…' : resp}'
            '（${DateTime.now().difference(t0).inMilliseconds}ms）');
        expect(resp.trim(), isNotEmpty, reason: '"$p" 无产出');
        expect(resp, isNot(contains('执行失败')), reason: '"$p" 回合失败');
      }
      final msgs = await storage.getMessages(conv.id);
      final assts = msgs.where((m) => m.role == MessageRole.assistant).toList();
      // agent 关闭后每轮一条 assistant；对活动消息留冗余，故 ≥ 而非 ==。
      expect(assts.length, greaterThanOrEqualTo(prompts.length));
      for (final m in assts) {
        expect(m.content.trim(), isNotEmpty, reason: 'assistant 消息为空：${m.id}');
        expect(m.content, isNot(startsWith('⚠️')), reason: '落库失败消息：${m.content}');
      }

      // 3) 设置页把全局 ctx 改成 6144 → 重载 → 启动命令必须 -c 6144
      //（生效证据；2026-11-06 全局 ctx 口径：滑杆 4096..16384 每档 512）。
      await settings.setContextSize(6144);
      await mgr.unloadModel();
      expect(await mgr.loadModel('LFM3-1.7B-Q4_K_M'), isTrue,
          reason: '重载失败：${mgr.loadingLogs.join('\n')}');
      expect(inf.debugHost()!.lastSpawnArgs, containsAllInOrder(['-c', '6144']),
          reason: '设置页 contextSize 未生效');
      final r2 = await chat.sendMessage(conv.id, '回一个字：好');
      expect(r2.trim(), isNotEmpty);

      // 4) 全局 ctx 回到 4096 → 模型管理页换 4B 再答一问。兜底准入
      //（2026-11-09 用户拍板「先兜底定制 ctx，确保先能用」）：4B@4096 被
      // 网关收敛到实测安全档 512 加载（此前 2026-11-07 admission 收紧后这个
      // 臂在真机必被前置拦——旧锚「-c 4096 放行」已失实，随兜底口径改写）。
      await settings.setContextSize(4096);
      expect(await mgr.loadModel('Qwen3-4B-Q4_K_M'), isTrue,
          reason: '4B 加载失败：${mgr.loadingLogs.join('\n')}');
      final args4b = inf.debugHost()!.lastSpawnArgs!;
      expect(args4b[0], '-m');
      expect(args4b[1], contains('Qwen3-4B'));
      expect(args4b, containsAllInOrder(['-c', '512']),
          reason: '兜底准入：4B@4096 收敛到实测包线 512 先保可用');
      expect(mgr.loadingLogs.join(), contains('兜底准入'),
          reason: '兜底动作必须对用户可见（为什么 4096 变 512）');
      final r3 = await chat.sendMessage(conv.id, '打个招呼，十个字以内');
      expect(r3.trim(), isNotEmpty);

      // 清理：卸载模型、还原设置、删测试会话（库是测试进程私有目录，仍还原）。
      await mgr.unloadModel();
      await settings.setContextSize(4096);
      await container.read(conversationsProvider.notifier).delete(conv.id);
    },
    timeout: const Timeout(Duration(minutes: 15)),
    skip: skipReason,
  );
}
