// T1.6/T2.4 语音设置默认值单测（母方案 §6 总表 + D1/D2 裁决）。
// Edge TTS 参数口径在 test/tts/tts_levels_default_test.dart 已锁，本文件锁
// 总开关/唤醒对话/引擎选择口径。
import 'package:flutter_test/flutter_test.dart';
import 'package:wangcai/services/settings_service.dart';

void main() {
  test('§6 ASR 默认值：增强模式关、热词全启用（空集语义）、自定义热词空', () {
    const s = InferenceSettings();
    expect(s.asrEnhancedMode, isFalse,
        reason: '§6：增强识别模式默认标准档（greedy 流式）');
    expect(s.asrHotwordCategories, isEmpty,
        reason: '空集 = 全部分类启用（设置页语义）');
    expect(s.asrHotwordCustom, '');
    expect(s.asrHotwordAdded, isEmpty);
    expect(s.asrHotwordRemoved, isEmpty);
  });

  test('§6 总开关：语音交互默认关（零 footprint）；唤醒对话默认关', () {
    const s = InferenceSettings();
    expect(s.voiceEnabled, isFalse,
        reason: '§6：总开关关 = 不占麦不加载模型');
    expect(s.voiceWakeEnabled, isFalse);
    expect(s.voiceQuickResponse, isTrue, reason: '§6：快速响应模式默认开');
  });

  test('D2 裁决：唤醒对话自动发送默认开；超时口径 10s/60s/800ms', () {
    const s = InferenceSettings();
    expect(s.voiceWakeAutoSend, isTrue,
        reason: 'D2：自动发送为用户设置项，默认自动（3s 缓冲可取消）');
    expect(s.voiceWakeNoInputSec, 10, reason: '§4.2：唤醒后无输入 10s 结束');
    expect(s.voiceWakeMaxInputSec, 60, reason: '§4.2：单次输入最长 60s');
    expect(s.voiceVadTailSilenceMs, 800, reason: '§4.3：段尾静音 800ms 定稿');
  });

  test('§6 引擎选择：离线默认；自动朗读默认关（D1：Edge 保留可选）', () {
    const s = InferenceSettings();
    expect(s.voiceTtsEngine, 'offline',
        reason: 'T2.5：matcha/vits 离线转正为默认，Edge 是可选');
    expect(s.voiceAutoSpeak, isFalse);
    // 旧值迁移：voiceAutoSpeak 缺失时承接旧 edgeTtsAutoSpeak=true 的存量。
    final migrated = InferenceSettings.fromJson(const {
      'edgeTtsAutoSpeak': true,
    });
    expect(migrated.voiceAutoSpeak, isTrue,
        reason: '§5.2：旧「自动朗读」语义并入新键，存量不丢');
  });

  test('§6 TTS 默认值（D1）：Edge 保留、默认关、参数 0/0/0', () {
    const s = InferenceSettings();
    expect(s.edgeTtsEnabled, isFalse);
    expect(s.edgeTtsRate, 0);
    expect(s.edgeTtsPitch, 0);
    expect(s.edgeTtsVolume, 0);
  });

  test('M3 常驻唤醒：默认关（绝不暗中留麦）；灵敏度默认 0.75 → 阈值 0.25 实测档', () {
    const s = InferenceSettings();
    expect(s.voiceWakeKws, isFalse,
        reason: '常驻唤醒 = opt-in：要下模型 + 待命麦，默认必须关');
    expect(s.voiceWakeSensitivity, 0.75,
        reason: '映射 clamp(1−v,0.1,0.45) → 0.25（m3_kws_check 实测安全档）');
    final loaded = InferenceSettings.fromJson(const {});
    expect(loaded.voiceWakeKws, isFalse);
    expect(loaded.voiceWakeSensitivity, 0.75, reason: '存量配置无键走默认');
    final json = s.toJson();
    expect(json['voiceWakeKws'], isFalse);
    expect(json['voiceWakeSensitivity'], 0.75);
  });
}
