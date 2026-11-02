/// 宿主接缝：把 app 真能力接到平台能力注册表上（**唯一允许 import 宿主内部的目录**）。
///
/// 拆在这里而不是写在 `plugin_host.dart` 里，是为了让架构门 B/C 保持锋利：
/// `plugin_host.dart` 只做装配（读自己的子树），伸手拿 TTS/设置这类动作被关在本文件里，
/// 一眼能看出"平台到底依赖宿主的哪几处"。
library;

import 'package:flutter/foundation.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:plugin_kernel/plugin_kernel.dart';

import '../../providers/settings_provider.dart';
import 'host_capture.dart';
import 'host_llm.dart';
import '../../tts/edge_tts_service.dart';
import '../../tts/offline_tts_service.dart';
import 'host_speak.dart';
import 'host_speak_offline.dart';

/// 宿主注册能力的**唯一入口**。
///
/// `CapabilityRegistry.register` 返回 `Outcome`：同 id 同 priority 的第二次注册会被**拒**
/// （先到先得，后来者必须用更小的 priority 压上去）。以前各处直接丢弃这个返回值 ——
/// 于是"我明明注册了离线实现，怎么还是走在线"这种问题在日志里一个字都没有（受理了但没干活）。
/// 被拒必须留下声音；返回值给调用方决定是否降级。
bool registerHostCapability(
  CapabilityRegistry capabilities,
  Capability impl, {
  required String ownerPluginId,
  int priority = 0,
  void Function(String line)? log,
}) {
  final r = capabilities.register(impl, ownerPluginId: ownerPluginId, priority: priority);
  if (r.isErr) {
    final f = r.failureOrNull!;
    (log ?? debugPrint)('[plugin-cap] 能力 ${impl.key.id} 注册被拒（来自 $ownerPluginId）：'
        '${f.message}${f.hint == null ? '' : ' —— ${f.hint}'}');
    return false;
  }
  return true;
}

/// 注册 `llm.complete` 与 `llm.vision`（复用聊天同一套路由，一次性补全不进 KV）。
void registerHostLlm(CapabilityRegistry capabilities, Ref ref) {
  final port = AppLlmPort(ref);
  registerHostCapability(capabilities, HostLlmComplete(port), ownerPluginId: 'app');
  registerHostCapability(capabilities, HostLlmVision(port), ownerPluginId: 'app');
}

/// 注册 `app.capture`（拍照 / 相册选图）。
void registerHostCapture(CapabilityRegistry capabilities) {
  registerHostCapability(capabilities, HostCapture(ImagePickerPort()), ownerPluginId: 'app');
}

/// 注册 `app.speak`（Edge-TTS 实现）。
///
/// 参数在**调用时**现读设置：用户改了语速/音色，下一场播报立刻跟上，不必重启插件。
void registerHostSpeak(CapabilityRegistry capabilities, Ref ref) {
  registerHostCapability(
    capabilities,
    HostSpeak(EdgeTtsPort(), resolveVoice: (sample) => _voiceFor(ref, sample), levels: () => hostTtsLevels(ref)),
    ownerPluginId: 'app',
  );
}

/// 播报参数（调用时现读设置，改语速/音色不必重启插件）。两份 `app.speak` 实现共用同一份口径。
TtsLevels hostTtsLevels(Ref ref) {
  final s = ref.read(settingsProvider);
  return TtsLevels(rate: s.edgeTtsRate, pitch: s.edgeTtsPitch, volume: s.edgeTtsVolume);
}

/// 注册 `app.speak` 的**离线实现**（P7：能力可替换的最硬验收）。
///
/// 只在**找到模型**时注册，且以 `priority: -1` 压在 Edge 那份上面：
/// 没放模型 → 压根不注册；放了模型但引擎坏了 → 它 `available == false`，注册表自动浮回 Edge。
/// **两种情况插件侧都是零改动**，"能不能离线"是运行时事实，不是 if 分支。
///
/// 返回是否注册成功（面板/日志要说清楚为什么现在是离线还是在线）。
Future<bool> registerHostSpeakOffline(CapabilityRegistry capabilities, Ref ref) async {
  final dir = await OfflineTtsService.locateModelDir();
  if (dir == null) {
    debugPrint('[plugin-host] 没找到离线朗读模型，app.speak 只走 Edge TTS'
        '（把 VITS 模型放进 ApplicationSupport/tts/<模型名>/ 即可启用离线）');
    return false;
  }
  final service = OfflineTtsService(
    modelDir: dir,
    // 懒加载：这里只记账，真原生调用推迟到第一次合成 / prewarm（别在 boot 路径上卡 1–2 秒）。
    engineFactory: (layout) =>
        SherpaOfflineTtsEngine(layout.model!, layout.tokens!, dataDir: layout.dataDir),
  );
  final r = capabilities.register(
    HostSpeak(
      OfflineTtsPort(backend: OfflineTtsBackendFromService(service), fallback: EdgeTtsPort()),
      resolveVoice: (sample) => _voiceFor(ref, sample),
      levels: () => hostTtsLevels(ref),
    ),
    ownerPluginId: 'app',
    priority: -1, // 更小的 priority 更大：它能盖住 Edge 那份，卸掉后自动回退
  );
  if (r case Err(:final failure)) {
    debugPrint('[plugin-host] 离线朗读没注册上：${failure.message}');
    return false;
  }
  debugPrint('[plugin-host] 离线朗读已启用：$dir');
  return true;
}

/// 音色兜底：中文音色念英文单词会念成拼音、甚至返回空音频（`TtsFailureKind.empty`
/// 的常见成因），所以**按这一条文本的语言**挑音色。
///
/// 用户在设置里明确选了非中文音色时不改他的选择；只有"中文音色 + 纯英文条目"这种
/// 明显念不成形的组合才换（听写场景就是这条）。
String _voiceFor(Ref ref, String sample) {
  final configured = ref.read(settingsProvider).edgeTtsVoice;
  final latinOnly = !RegExp(r'[一-鿿]').hasMatch(sample) && RegExp(r'[A-Za-z]').hasMatch(sample);
  if (configured.isEmpty) {
    return latinOnly ? kEnglishFallbackVoice : kFallbackVoices.first.shortName;
  }
  if (latinOnly && configured.startsWith('zh-')) return kEnglishFallbackVoice;
  return configured;
}

/// 英文兜底音色（`kFallbackVoices` 里只留了中文，英文条目必须另给一个，
/// 否则离线拉到音色列表失败时英文听写全哑）。
const String kEnglishFallbackVoice = 'en-US-AriaNeural';
