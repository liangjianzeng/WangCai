// T1.7 TtsLevels 与 settings 默认值单口径锁定（施工计划 §5 test 清单）。
// 2026-11-05 专项 §2 裁决：HostSpeak 兜底 volume:100 与设置默认 volume:0
// 双口径事故 —— 修复后两处必须由本测试钉死，谁改一边就红。
import 'package:flutter_test/flutter_test.dart';
import 'package:wangcai/plugins/host/host_speak.dart';
import 'package:wangcai/services/settings_service.dart';

void main() {
  test('TtsLevels 兜底口径 = Edge 设置默认口径（0/0/0）', () {
    // HostSpeak 的兜底 levels（levels 注入为 null 时生效的那份）
    final host = HostSpeak(_NullPort(), resolveVoice: (_) => 'x');
    final l = host.levelsForTest();
    expect(l.rate, 0);
    expect(l.pitch, 0);
    expect(l.volume, 0);
  });

  test('InferenceSettings 默认值：Edge TTS 关 + 自动朗读关 + 参数 0/0/0（D1 口径）', () {
    const s = InferenceSettings();
    expect(s.edgeTtsEnabled, isFalse, reason: 'D1：Edge 保留但默认关');
    expect(s.edgeTtsAutoSpeak, isFalse);
    expect(s.edgeTtsVoice, 'zh-CN-XiaoxiaoNeural');
    expect(s.edgeTtsRate, 0);
    expect(s.edgeTtsPitch, 0);
    expect(s.edgeTtsVolume, 0);
  });
}

/// HostSpeak 只需要端口在构造期可用；本测试不触发播放。
class _NullPort implements TtsPlaybackPort {
  @override
  bool get ready => false;
  @override
  String? get notReadyReason => 'unused';
  @override
  Future<int> begin(String key) async => 0;
  @override
  bool isCurrent(int seq) => false;
  @override
  void end(int seq) {}
  @override
  Future<void> stop() async {}
  @override
  Future<bool> play(int seq, TtsClip clip) async => false;
  @override
  String? get lastFailureMessage => null;
  @override
  Future<TtsClip?> synthesize(String text,
          {required String voice, required int rate, required int pitch, required int volume}) async =>
      null;
}
