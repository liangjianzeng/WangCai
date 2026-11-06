/// ARMED 短提示音（voice-wakeup-min-spec §2：KWS 命中后 <100ms 本地提示）。
///
/// 资源 assets/wake_cue.wav（880Hz 90ms 淡入淡出，tool/gen_voice_assets.dart
/// 生成）；播放失败/资源缺席（测试环境）**静默跳过并短路**——提示音是增强，
/// 浮条即时可见才是硬反馈。独立 AudioPlayer，不占门面播报位（播报位是回复朗读的）。
library;

import 'package:audioplayers/audioplayers.dart';
import 'package:flutter/foundation.dart';

class WakeCue {
  WakeCue._();

  static AudioPlayer? _player;
  static bool _skipped = false;

  static Future<void> play() async {
    if (_skipped) return;
    try {
      final p = _player ??= AudioPlayer();
      await p.stop(); // 连点不叠音
      await p.play(AssetSource('wake_cue.wav'), volume: 0.6);
    } catch (e) {
      _skipped = true; // 资源缺失/无音频设备：不再重试
      debugPrint('[DSH][cue] wake cue skipped: $e');
    }
  }

  @visibleForTesting
  static void resetForTest() => _skipped = false;
}
