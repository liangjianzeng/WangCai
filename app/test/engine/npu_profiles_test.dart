// 世代档案数据位单测（世代自适应 2026-11-05）：保守起步口径的守门测试 ——
// 二/三代**不得**有预填的乐观 ctx 覆盖（无实测不赌）；档案覆盖位经注入
// 生效（future 实测回填的接线证明）。
import 'package:flutter_test/flutter_test.dart';
import 'package:wangcai/engine/npu_profiles.dart';

void main() {
  tearDown(() => profileOverrideForTest = null);

  test('一代/二代/未知：无任何 ctx 覆盖（保守基线 = manifest preset 原值）', () {
    for (final g in [
      NpuGeneration.ultra1,
      NpuGeneration.ultra2,
      NpuGeneration.unknown,
    ]) {
      final p = profileFor(g);
      expect(p.ctxOverrideFor('qwen3-4b'), isNull,
          reason: '$g 不应有预填乐观上限（无实测不赌）');
      expect(p.ctxOverrideFor('lfm3-1.7b'), isNull);
    }
  });

  test('三代：无乐观上限，只挂驱动提示', () {
    final p = profileFor(NpuGeneration.ultra3);
    expect(p.ctxOverrideFor('qwen3-4b'), isNull);
    expect(p.driverNote, isNotNull);
    // 驱动最低版本暂无实测口径 —— 编版本号会误导用户升错驱动。
    expect(p.minDriverVersion, isNull);
  });

  test('null 世代 → unknown 档案（兜底 = 今天的行为）', () {
    expect(profileFor(null).generation, NpuGeneration.unknown);
    expect(profileFor(NpuGeneration.unknown).ctxOverrideFor('qwen3-4b'), isNull);
  });

  test('档案注入：世代覆盖位驱动 clamp（future 实测回填的接线）', () {
    profileOverrideForTest = {
      NpuGeneration.ultra2: const NpuProfile(
        generation: NpuGeneration.ultra2,
        ctxOverrides: {'qwen3-4b': 2048},
      ),
    };
    expect(profileFor(NpuGeneration.ultra2).ctxOverrideFor('qwen3-4b'), 2048);
    // 未注入的世代与 preset 名不受影响。
    expect(profileFor(NpuGeneration.ultra2).ctxOverrideFor('other'), isNull);
    expect(profileFor(NpuGeneration.ultra1).ctxOverrideFor('qwen3-4b'), isNull);
  });
}
