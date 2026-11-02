import 'package:flutter_test/flutter_test.dart';
import 'package:tongyi_lite/tts/edge_tts_service.dart';

TtsVoiceInfo v(String shortName, String locale, String gender) =>
    TtsVoiceInfo(shortName: shortName, localName: shortName, locale: locale,
        gender: gender);

void main() {
  test('groupTtsVoices 只保留 大陆/港/台/美/英，其余地区全部过滤', () {
    final groups = groupTtsVoices([
      v('ja-JP-NanamiNeural', 'ja-JP', 'Female'),
      v('en-AU-NatashaNeural', 'en-AU', 'Female'),
      v('fr-FR-DeniseNeural', 'fr-FR', 'Female'),
      v('zh-CN-XiaoxiaoNeural', 'zh-CN', 'Female'),
      v('en-GB-SoniaNeural', 'en-GB', 'Female'),
    ]);
    final names = [for (final g in groups) ...g.voices.map((e) => e.shortName)];
    expect(names, ['zh-CN-XiaoxiaoNeural', 'en-GB-SoniaNeural']);
  });

  test('地区顺序 = 大陆→香港→台湾→美国→英国；区内男先女后', () {
    final groups = groupTtsVoices([
      v('en-GB-RyanNeural', 'en-GB', 'Male'),
      v('en-US-GuyNeural', 'en-US', 'Male'),
      v('en-US-AriaNeural', 'en-US', 'Female'),
      v('zh-TW-HsiaoChenNeural', 'zh-TW', 'Female'),
      v('zh-HK-WanLungNeural', 'zh-HK', 'Male'),
      v('zh-CN-YunxiNeural', 'zh-CN', 'Male'),
      v('zh-CN-XiaoxiaoNeural', 'zh-CN', 'Female'),
    ]);
    expect([for (final g in groups) g.title], [
      '中国大陆 · 男',
      '中国大陆 · 女',
      '中国香港 · 男',
      '中国台湾 · 女',
      '英语（美国） · 男',
      '英语（美国） · 女',
      '英语（英国） · 男',
    ]);
  });

  test('zh-CN 方言变体（liaoning/shaanxi）同属大陆组', () {
    final groups = groupTtsVoices([
      v('zh-CN-liaoning-XiaobeiNeural', 'zh-CN-liaoning', 'Female'),
      v('zh-CN-XiaoxiaoNeural', 'zh-CN', 'Female'),
      v('zh-CN-shaanxi-XiaoniNeural', 'zh-CN-shaanxi', 'Female'),
    ]);
    expect(groups, hasLength(1));
    expect(groups.single.title, '中国大陆 · 女');
    expect(groups.single.voices, hasLength(3));
  });

  test('组内按 shortName 排序；空输入返回空分组', () {
    final groups = groupTtsVoices([
      v('zh-CN-XiaoyiNeural', 'zh-CN', 'Female'),
      v('zh-CN-XiaoxiaoNeural', 'zh-CN', 'Female'),
    ]);
    expect(
        [for (final x in groups.single.voices) x.shortName],
        ['zh-CN-XiaoxiaoNeural', 'zh-CN-XiaoyiNeural']);
    expect(groupTtsVoices(const []), isEmpty);
  });

  test('兜底清单（kFallbackVoices）也能正确分组且全部为大陆音色', () {
    final groups = groupTtsVoices(kFallbackVoices);
    for (final g in groups) {
      expect(g.title.startsWith('中国大陆'), isTrue);
    }
    expect([for (final g in groups) ...g.voices], hasLength(kFallbackVoices.length));
  });
}
