// M4 DoD · Agent --jinja 工具链真机回归（skip 门控）：
// settings.agentEnabled=true（等价聊天页开「智能体」）→ ChatNotifier 真实
// agent 路径（ReactLoopAgent → OpenAiAdapter → /v1/chat/completions + tools
// schema）→ c4096 容量下正常回合。
//
// 2026-11-03 实测定案：M1-d 首跑的 http=400 是 **ctx 超限**（agent 系统
// 提示 + tools schema 超过 c1024），协议层（tools/tool_calls/tool 结果）
// 在 LFM3 --jinja 下全部正常（tools 探针 R1/R2/R3 均 200）。
// 跑法（app/ 下，引擎三件套 env 同 gateway_npu_test）：
//   flutter test test/platform/agent_npu_test.dart
import 'dart:async';
import 'dart:io';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';
import 'package:tongyi_lite/engine/bindings_store.dart';
import 'package:tongyi_lite/models/chat_message.dart';
import 'package:tongyi_lite/platform/local_server_inference.dart';
import 'package:tongyi_lite/platform/wangcai_paths.dart';
import 'package:tongyi_lite/providers/chat_provider.dart';
import 'package:tongyi_lite/providers/model_provider.dart';
import 'package:tongyi_lite/providers/settings_provider.dart';
import 'package:tongyi_lite/providers/shared_providers.dart';
import 'package:tongyi_lite/services/settings_service.dart';
import 'package:tongyi_lite/services/storage_service.dart';
import 'package:tongyi_lite/tts/edge_tts_service.dart';

class _InMemSettingsService extends SettingsService {
  InferenceSettings _current = const InferenceSettings();
  @override
  Future<InferenceSettings> load() async => _current;
  @override
  Future<void> save(InferenceSettings s) async => _current = s;
}

void main() {
  final sep = Platform.pathSeparator;
  final dir = WangCaiPaths.modelsRoot();
  final lfm = File('${dir.path}${sep}LFM3-1.7B-Q4_K_M.gguf');
  final skipReason = (!Platform.isWindows || !lfm.existsSync())
      ? '需要 Windows + LFM3-1.7B-Q4_K_M.gguf（WANGCAI_MODEL_DIR）'
      : false;

  setUpAll(() {
    sqfliteFfiInit();
    databaseFactory = databaseFactoryFfi;
    BindingsStore.databaseFactoryFfiForTest = databaseFactoryFfi;
    // EdgeTtsService 单例的 AudioPlayer 要 ServicesBinding（M1-d 同款）：
    // 预触发吞错让它成型（不可用环境 stop() 自 catch）。
    runZonedGuarded(() {
      try {
        EdgeTtsService.instance;
      } catch (_) {}
    }, (e, _) {});
  });

  test(
    'Agent 链路真机回合：开智能体 → sendMessage → 正常完成（tools schema 在场）',
    () async {
      final inf = LocalServerInference.instance;
      inf.onLoadingLog = (m) {
        if (m != null) print('[engine] $m');
      };
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
      final mgr = container.read(modelManagerProvider.notifier);
      final settings = container.read(settingsProvider.notifier);

      // agent 系统提示 + tools schema 体量大：ctx 给 4096（NPU 1.7B 无上限约束）。
      expect(await mgr.loadModel('LFM3-1.7B-Q4_K_M'), isTrue,
          reason: '加载失败：${mgr.loadingLogs.join('\n')}');
      expect(inf.debugHost()!.lastSpawnArgs, containsAllInOrder(['-c', '4096']));

      await settings.setAgentEnabled(true); // 聊天页「智能体」开关
      await container.read(conversationsProvider.notifier).create(title: 'M4 agent');
      final conv = container.read(conversationsProvider).first;
      final chat = container.read(chatNotifierProvider.notifier);

      final resp = await chat.sendMessage(conv.id, '2+2 等于几？只报数字');
      print('AGENT A: ${resp.length > 140 ? '${resp.substring(0, 140)}…' : resp}');
      expect(resp.trim(), isNotEmpty, reason: 'agent 回合无产出');
      expect(resp, isNot(contains('执行失败')), reason: 'agent 回合失败');

      final msgs = await StorageService().getMessages(conv.id);
      expect(
        msgs.any((m) => m.role == MessageRole.assistant && m.content.trim().isNotEmpty),
        isTrue,
      );
      await settings.setAgentEnabled(false);
      await mgr.unloadModel();
      await container.read(conversationsProvider.notifier).delete(conv.id);
    },
    timeout: const Timeout(Duration(minutes: 12)),
    skip: skipReason,
  );
}
