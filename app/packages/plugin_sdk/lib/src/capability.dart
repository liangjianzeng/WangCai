/// 能力契约（L3）：任何人（含插件）都能注册，消费者只认 [ServiceKey] 不认实现。
///
/// 设计来源：Cordis `Service` + `Impl.check`（"Optional availability predicate consulted before
/// dependents may load"）+ `Context.isolate(name, label)`（同名服务在子域换实现）。
/// 本仓收益：离线 TTS / OCR 都以"再注册一个实现"接入，宿主不需要 `if`。
library;

import 'hook.dart';
import 'manifest.dart';
import 'outcome.dart';

/// 强类型服务键。用 `Type` + 契约版本做键，**不用裸字符串**（DSH 用字符串服务名是 JS 生态的妥协）。
///
/// [id] 是稳定标识（写进 `plugin.json` 的 `inject`，一经发布不可改）；
/// [contractVersion] 变化表示行为破坏（`v1` → `v2`），内核据此做协商与双实现共存。
final class ServiceKey<T extends Capability> {
  const ServiceKey(this.id, {this.contractVersion = 'v1'});

  final String id;
  final String contractVersion;

  @override
  bool operator ==(Object other) =>
      identical(this, other) || (other is ServiceKey<T> && other.id == id && other.contractVersion == contractVersion);

  @override
  int get hashCode => Object.hash(id, contractVersion);

  @override
  String toString() => '$id@$contractVersion';
}

/// 平台契约承认的能力 id 全集（校验器据此抓拼写错误）。
///
/// 与"本机当前装了哪几个"是两件事：后者决定 **门控（gated）**，前者决定 **是不是拼错了（rejected）**。
/// 混淆这两件事会让"等离线 TTS 上线"的插件被当成拼错直接拒掉。
const Set<String> kKnownCapabilityIds = {
  'llm.complete',
  'llm.vision',
  'app.speak',
  'app.capture',
  'app.store',
  'app.interact',
  'asr.transcribe',
  'net.search',
};

/// 能力 → 所需权限（**唯一真相**：校验器、Fake 夹具、内核三处共用，防三方漂移）。
PluginPermission? impliedPermissionFor(String capabilityId) => switch (capabilityId) {
      'llm.complete' => PluginPermission.llmChat,
      'llm.vision' => PluginPermission.llmVision,
      'app.speak' => PluginPermission.speechSynthesis,
      'app.capture' => PluginPermission.camera,
      'app.store' => PluginPermission.pluginStorage,
      'asr.transcribe' => PluginPermission.speechRecognition,
      'net.search' => PluginPermission.webSearch,
      _ => null,
    };

/// 能力实现必须满足的契约。
///
/// 规约（conformance「契约」组机检）：
/// - [available] 必须**同步且便宜**：只读本地状态，不得发网络请求、不得加载模型。
///   网络健康度走 `readiness` 可观察量，不进 `available`（否则门控会自己制造卡顿）。
/// - [available] 返回 true 但实际用不了 = **谎报**，是平台级 bug；套件的 `assertNoLyingCapability` 专抓它。
/// - [unavailableReason] 在 `available == false` 时**必须非空**，且要给出路。
abstract interface class Capability {
  ServiceKey get key;

  bool get available;

  /// 不可用时的人话原因 + 出路（面板直接显示）。
  String? get unavailableReason;

  /// 可选预热（拉音色列表、加载模型）。内核在空闲时调用，不在 build 路径。
  Future<void> warmUp() async {}

  /// 能力自检（比 [available] 深，可 IO）；用于插件面板"测试一下"按钮。
  Future<Outcome<void>> probe() async {
    if (!available) {
      return Err<void>.of(
        PluginFailureKind.missingCapability,
        unavailableReason ?? '${key.id} 当前不可用',
        hint: '见「设置」页对应开关',
      );
    }
    return const Ok<void>(null);
  }
}

/// 能力实现默认件：作者 `implements Xxx` 时混入它就少写两份样板。
mixin CapabilityBase implements Capability {
  @override
  Future<void> warmUp() async {}

  @override
  Future<Outcome<void>> probe() async {
    if (!available) {
      return Err<void>.of(
        PluginFailureKind.missingCapability,
        unavailableReason ?? '${key.id} 当前不可用',
        hint: '见「设置」页对应开关',
      );
    }
    return const Ok<void>(null);
  }
}

/// 平台预置的能力键（宿主提供实现；插件可**覆盖**同名键，也可自定义新键）。
///
/// 命名规范：`<域>.<动词>`，全小写点分。**新增键必须同时提供：默认实现、面板说明、conformance 用法样例**。
abstract final class ServiceKeys {
  /// 一次性文本/对话补全（**不进会话 KV**，见 §5.4：抽词绝不该污染聊天上下文）。
  static const llmComplete = ServiceKey<LlmComplete>('llm.complete');

  /// 带图一次性补全（抽词主路径）。available 必须真查 `visionCapable` / `visionEnabled` + mmproj 有效性。
  static const llmVision = ServiceKey<LlmVision>('llm.vision');

  /// 通用"按序朗读"能力（听写只是它的一个消费者，**不许做成 speakWords 后门**）。
  static const speak = ServiceKey<Speak>('app.speak');

  /// 取景/相册取图（复用 `_pickImage`，但由能力暴露，插件不 import screens）。
  static const capture = ServiceKey<Capture>('app.capture');

  /// 插件分域存储（键空间前缀 `plugin:<id>:`，卸载即清）。
  static const store = ServiceKey<Store>('app.store');

  /// 与用户交互（底部表单/询问），复用既有 `ask_user_question` 的文化。
  static const interact = ServiceKey<Interact>('app.interact');

  /// 语音识别（可选能力，跟读评测类插件用）。
  static const transcribe = ServiceKey<Transcribe>('asr.transcribe');

  /// 联网搜索（可选能力）。
  static const search = ServiceKey<Search>('net.search');
}

// ——— 以下为各能力的**接口形状**（不实现；实现由内核/宿主提供，插件只消费）———

/// 一次性补全：独立 `maxTokens`（绝不复用 `maxTokensPerRound=512`，本仓 `toolCallTruncated` 血泪教训）。
abstract interface class LlmComplete implements Capability {
  Future<Outcome<String>> complete({
    required String systemPrompt,
    required String userText,
    int? maxTokens,
    double temperature = 0,
    PluginCancelToken? cancelToken,
  });
}

abstract interface class LlmVision implements Capability {
  Future<Outcome<String>> completeWithImage({
    required String systemPrompt,
    required String userText,
    required List<String> imagePaths,
    int? maxTokens,
    double temperature = 0,
    PluginCancelToken? cancelToken,
  });
}

/// 朗读请求。`sequence` 语义由能力实现负责（单代次、可取消、可缓存）。
final class SpeakRequest {
  const SpeakRequest({
    required this.items,
    required this.voice,
    this.gap = const Duration(seconds: 5),
    this.repeatPerItem = 1,
  });
  final List<String> items;
  final String voice;
  final Duration gap;
  final int repeatPerItem;
}

final class SpeakProgress {
  const SpeakProgress({required this.index, required this.text, required this.phase, this.error});
  final int index;
  final String text;
  final SpeakPhase phase;
  final String? error;
}

enum SpeakPhase { synthesizing, playing, gap, skipped }

abstract interface class Speak implements Capability {
  /// 单代次按序朗读：内部必须"每个 await 复查代次 + `stop()` 即时 complete"。
  Stream<SpeakProgress> speak(SpeakRequest request, PluginCancelToken cancelToken);
  Future<void> stop();
  Future<bool> prewarm(List<String> texts, String voice);
}

abstract interface class Capture implements Capability {
  Future<Outcome<List<String>>> pickImages({required int maxCount, required bool preferCamera});
}

abstract interface class Store implements Capability {
  Future<Outcome<String?>> read(String key);
  Future<Outcome<void>> write(String key, String value);
  Future<Outcome<void>> remove(String key);
  Future<Outcome<List<String>>> keys();
}

abstract interface class Interact implements Capability {
  /// 向用户要一个数（听写的"间隔几秒"就走这里，复用既有 ask_user_question，不造第二套提问机制）。
  /// **实现侧契约**：返回值必须落在 `[min, max]` 内，或 `null` 表示用户不表态。
  /// `flow` 引擎会复查（越界即失败并指名是实现违约），但复查只是兜底 —— 实现自己钳制/拒收才是本分，
  /// 因为插件参数走的不止 flow 这一条路（面板、代码级插件直接调也一样）。
  Future<Outcome<double?>> askNumber({required String question, required double defaultValue, required double min, required double max});
  Future<Outcome<String?>> askChoice({required String question, required List<String> options, String? defaultValue});
}

abstract interface class Transcribe implements Capability {
  Future<Outcome<String>> transcribe(String audioPath, {PluginCancelToken? cancelToken});
}

abstract interface class Search implements Capability {
  Future<Outcome<String>> search(String query, {int maxResults = 8});
}
