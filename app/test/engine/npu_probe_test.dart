// NPU 探测解析单测（世代自适应 2026-11-05）：--list-devices NPU 行的
// 型号/型号码/MiB 提取、世代表决、探测缓存纪律。fixture 用真机与
// 文档记录的枚举形态（本机 3720 行含 MiB 尾注 = 2026-11-05 便携包自检实锤）。
import 'package:flutter_test/flutter_test.dart';
import 'package:wangcai/engine/npu_profiles.dart';
import 'package:wangcai/engine/openvino_probe.dart';

const npu3720 = '''
Available devices:
  OPENVINO0: GGML_OPENVINO_DEVICE=CPU - Intel(R) Core(TM) Ultra 9 275HX (48511 MiB, 14991 MiB free)
  OPENVINO1: GGML_OPENVINO_DEVICE=GPU.0 - Intel(R) Graphics (iGPU) (25542 MiB, 14991 MiB free)
  OPENVINO3: GGML_OPENVINO_DEVICE=NPU - Intel(R) AI Boost (NPU 3720) (24576 MiB, 14991 MiB free)
''';

void main() {
  setUp(clearOpenvinoProbeCache);
  tearDown(() => probeRunnerForTest = null);

  group('parseNpuListDevices', () {
    test('本机实锤行：devArg/型号名/码/MiB 全提取，世代 = ultra1', () {
      final d = parseNpuListDevices(npu3720)!;
      expect(d.devArg, 'OPENVINO3');
      expect(d.deviceName, 'Intel(R) AI Boost (NPU 3720)');
      expect(d.npuCode, 3720);
      expect(d.totalMib, 24576);
      expect(d.freeMib, 14991);
      expect(d.generation, NpuGeneration.ultra1);
    });

    test('二代 3820（Lunar Lake 枚举形态）→ ultra2', () {
      final d = parseNpuListDevices(
          'OPENVINO2: GGML_OPENVINO_DEVICE=NPU - Intel(R) AI Boost (NPU 3820) (24576 MiB, 20000 MiB free)')!;
      expect(d.devArg, 'OPENVINO2');
      expect(d.npuCode, 3820);
      expect(d.generation, NpuGeneration.ultra2);
    });

    test('三代 4000 系（Panther Lake 可能枚举名）→ ultra3', () {
      final d = parseNpuListDevices(
          '  OPENVINO1: GGML_OPENVINO_DEVICE=NPU - Intel(R) NPU (NPU 4000) (32768 MiB, 30000 MiB free)')!;
      expect(d.npuCode, 4000);
      expect(d.generation, NpuGeneration.ultra3);
    });

    test('枚举名不带号码（旧驱动 AI Boost）→ code null · unknown 世代', () {
      final d = parseNpuListDevices(
          'OPENVINO2: GGML_OPENVINO_DEVICE=NPU - Intel(R) AI Boost')!;
      expect(d.npuCode, isNull);
      expect(d.generation, NpuGeneration.unknown);
      expect(d.deviceName, 'Intel(R) AI Boost');
    });

    test('`=NPU (selected) -` 变体：名称解析失败仍从整行提取型号码', () {
      final d = parseNpuListDevices(
          'OPENVINO1: GGML_OPENVINO_DEVICE=NPU (selected) - Intel(R) AI Boost (NPU 3820)')!;
      expect(d.deviceName, isNull); // 正则要求 `=NPU - ` 直连
      expect(d.npuCode, 3820); // 兜底从整行找
      expect(d.generation, NpuGeneration.ultra2);
    });

    test('长数字防误吃（NPU 37200 不匹配，宁缺勿错代）', () {
      final d = parseNpuListDevices(
          'OPENVINO0: GGML_OPENVINO_DEVICE=NPU - Weird Device (NPU 37200)')!;
      expect(d.npuCode, isNull);
      expect(d.generation, NpuGeneration.unknown);
    });

    test('无 NPU 行 → null', () {
      expect(parseNpuListDevices('OPENVINO0: GGML_OPENVINO_DEVICE=CPU - x'),
          isNull);
    });
  });

  group('npuGenerationFor（纯函数）', () {
    test('号码区间裁决', () {
      expect(npuGenerationFor(3720, null), NpuGeneration.ultra1);
      expect(npuGenerationFor(3820, null), NpuGeneration.ultra2);
      expect(npuGenerationFor(4000, null), NpuGeneration.ultra3);
      expect(npuGenerationFor(4399, null), NpuGeneration.ultra3);
      expect(npuGenerationFor(3500, null), NpuGeneration.unknown);
      expect(npuGenerationFor(null, null), NpuGeneration.unknown);
    });
    test('名称兜底（无号码时看名字）', () {
      expect(npuGenerationFor(null, 'Intel(R) AI Boost (NPU 3820)'),
          NpuGeneration.ultra2);
      expect(npuGenerationFor(null, 'Intel(R) AI Boost (NPU 3720)'),
          NpuGeneration.ultra1);
      expect(npuGenerationFor(null, 'Intel(R) NPU'), NpuGeneration.unknown);
    });
  });

  group('probeNpuDevice 缓存纪律', () {
    test('成功缓存：第二次探测不起子进程；cachedNpuInfo 读缓存', () async {
      var calls = 0;
      probeRunnerForTest = (_, __) async {
        calls++;
        return npu3720;
      };
      final a = await probeNpuDevice('E:\\fake\\llama-server.exe', const {});
      final b = await probeNpuDevice('E:\\fake\\llama-server.exe', const {});
      expect(calls, 1);
      expect(a!.devArg, 'OPENVINO3');
      expect(b!.generation, NpuGeneration.ultra1);
      expect(cachedNpuInfo('E:\\fake\\llama-server.exe')?.npuCode, 3720);
      expect(cachedNpuInfo('E:\\other\\llama-server.exe'), isNull);
    });

    test('失败不缓存：null 结果下次重试', () async {
      var calls = 0;
      probeRunnerForTest = (_, __) async {
        calls++;
        return calls == 1 ? null : npu3720;
      };
      expect(await probeNpuDevice('E:\\fake\\x.exe', const {}), isNull);
      expect(await probeNpuDevice('E:\\fake\\x.exe', const {}), isNotNull);
      expect(calls, 2);
    });

    test('无 NPU 行不算命中也不缓存（探测成功但枚举无 NPU 是合法状态）', () async {
      probeRunnerForTest = (_, __) async => 'OPENVINO0: CPU only';
      expect(await probeNpuDevice('E:\\fake\\y.exe', const {}), isNull);
      expect(cachedNpuInfo('E:\\fake\\y.exe'), isNull);
    });
  });
}
