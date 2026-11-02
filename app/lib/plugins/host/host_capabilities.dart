/// 宿主真实提供的能力清单（**纯 Dart 文件**：`tool/plugins.dart` 也要 import 它，
/// 而 CLI 跑在 `dart run` 上，一旦被 Flutter 污染就跑不起来了）。
///
/// 这里列的是"本机今天装了哪几个"，决定**门控**（gated）；
/// "平台契约承认哪些能力 id"是另一件事，见 SDK 的 `kKnownCapabilityIds`（决定拼写校验）。
library;

/// 已由宿主提供实现的能力 id。
///
/// P2：存储与提问；P4：`app.speak`（Edge-TTS 适配器 + 通用播放原语）已接上；
/// P4：`llm.complete` / `llm.vision` 也已接上（与聊天同源路由，一次性补全、用完归零 KV）；
/// P7 补离线 TTS（作为 `app.speak` 的第二个实现，不是新 id）。
const Set<String> kHostCapabilityIds = {
  'app.store',
  'app.interact',
  'app.speak',
  'app.capture',
  'llm.complete',
  'llm.vision',
};

/// 与 `settings_screen._appVersion` 对齐；`engines.app` 用它判定。
const String kPluginHostAppVersion = '0.2.8';
