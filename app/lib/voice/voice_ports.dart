/// VoiceService 的端口契约（T2.1 从 voice_service.dart 拆出）：
/// 引擎实现（SherpaStreamingAsr / SenseVoiceAsr / 测试假引擎）只 import 本文件，
/// 避免「接口在门面、门面引用引擎」的循环 import。
library;

import 'dart:async';

/// 识别引擎端口：生产 = SherpaStreamingAsr（按住说话）/ SenseVoiceAsr（唤醒对话），
/// 测试 = 假引擎。方法面刻意收窄到 start/stop/dispose/partialText 四件。
abstract interface class VoiceCaptureEngine {
  Stream<String> get partialText;
  Future<void> start();

  /// 收尾并取终稿（引擎自己保证幂等/不抛）。
  Future<String> stop();

  Future<void> dispose();
}

/// 播报门控端口：生产 = EdgeTtsService 的播控原语（实现仍只有一份），
/// 测试 = 假门控。代次语义与 beginPlayback/isCurrentPlayback/endPlayback 一致。
abstract interface class SpeakGate {
  Future<int> begin(String key);
  bool isCurrent(int seq);
  void end(int seq);
  Future<void> stop();
  bool get active;
}

/// 常驻关键词唤醒（KWS）端口（M3，voice-wakeup-min-spec）：
/// 生产 = KwsEngine（worker + 自有录音机）；测试 = 假句柄（手动投 hit）。
///
/// 麦克风仲裁约定（VoiceService 落实）：
/// - 识别会话 / 播报期 → [pause]（KWS 抑制窗，防自念自醒 + 让麦）；
/// - 会话与播报都结束且唤醒仍开 → [resume]；
/// - 命中 = KWS 自己停麦（让位给 SenseVoice 唤醒会话）并广播 [hits] 一次。
abstract interface class KwsHandle {
  /// 命中关键字流（每次命中后引擎已自动停麦+复位，等待宿主 resume）。
  Stream<String> get hits;

  /// 录音机是否在跑（托盘四色口径之一）。
  bool get micOn;

  Future<void> pause();
  Future<void> resume();
  Future<void> dispose();
}
