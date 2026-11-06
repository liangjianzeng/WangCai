// M3 KWS 纯函数单测：唤醒词关键字行 + 灵敏度阈值映射（不碰 FFI）。
import 'package:flutter_test/flutter_test.dart';
import 'package:wangcai/asr/kws_engine.dart';

void main() {
  group('唤醒词关键字行', () {
    test('「汪柴」→ 带调拼音 token 行（对齐 kws tokens.txt 实测形态）', () {
      expect(buildKwsKeywordLine('汪柴'), 'w āng ch ái @汪柴');
    });

    test('首尾空白容忍；未知词 = null（加载前拦截）', () {
      expect(buildKwsKeywordLine(' 汪柴 '), 'w āng ch ái @汪柴');
      expect(buildKwsKeywordLine('小汪'), isNull);
      expect(buildKwsKeywordLine(''), isNull);
    });
  });

  group('灵敏度 → 阈值映射（实测锚：0.25 稳命中 / ≥0.3 合成音必漏）', () {
    test('默认 0.75 → 0.25（实测安全档）', () {
      expect(kwsThresholdFromSensitivity(0.75), closeTo(0.25, 1e-9));
    });

    test('上限封 0.45（低灵敏度也不进必漏区）', () {
      expect(kwsThresholdFromSensitivity(0.3), closeTo(0.45, 1e-9));
      expect(kwsThresholdFromSensitivity(0.5), closeTo(0.45, 1e-9));
    });

    test('下限 0.1（拉满灵敏度也不疯醒）', () {
      expect(kwsThresholdFromSensitivity(0.9), closeTo(0.1, 1e-9));
      expect(kwsThresholdFromSensitivity(1.5), closeTo(0.1, 1e-9));
    });

    test('单调不增', () {
      double? prev;
      for (var v = 0.3; v <= 0.9001; v += 0.05) {
        final t = kwsThresholdFromSensitivity(v);
        if (prev != null) expect(t, lessThanOrEqualTo(prev + 1e-9));
        prev = t;
      }
    });
  });
}
