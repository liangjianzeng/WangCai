// NPU 世代档案（世代自适应，2026-11-05）：从 `llama-server --list-devices`
// 的 NPU 行识别 Core Ultra 一/二/三代，提供 clamp 与准入的世代数据源。
//
// 背景：全仓实测调优值（4B ctx512/chunk128、admission「4B@c>512 →
// OUT_OF_HOST_MEMORY」、冷编 600s…）都来自**一台** 275HX + Intel AI Boost
// NPU 3720 机器（docs/status.md）。装机用户换到 Lunar Lake（NPU 3820）或
// Panther Lake（NPU 4000 系）时，这些值只是「保守的先验」，不是该机实测。
//
// 纪律（与 routing_policy「不写死阈值、约束全是数据」一脉）：
//   · 世代识别 = npuGenerationFor（型号码优先，枚举名兜底）；
//   · 各世代对 preset 上限的覆盖是 NpuProfile 的**数据位**：当前仅一代有
//     实测（= manifest preset 本身，故覆盖表为空），二/三代**不预填乐观
//     数字**（无实测不赌，2026-11-05 定案）——拿到别台实测后往表里加行即可；
//   · 未知/未识别世代 → 一代保守基线兜底 = 与今天逐位一致的行为；
//   · 「实测上探」不走档案表：每次成功推理由 BindingsStore.maxStableCtx
//     单调回写、clamp 时取用（local_server_inference）；驱动报
//     OUT_OF_HOST_MEMORY 由 demoteCtx 收回（失败回退）。
import 'package:flutter/foundation.dart';

/// Intel Core Ultra 的 NPU 世代（VPU 型号码为锚）。
enum NpuGeneration {
  ultra1('Ultra 一代（NPU 3720 · Meteor Lake / Arrow Lake-HX）'),
  ultra2('Ultra 二代（NPU 3820 · Lunar Lake / Arrow Lake-H）'),
  ultra3('Ultra 三代（NPU 4000 系 · Panther Lake）'),
  unknown('未识别 NPU · 按一代保守基线');

  const NpuGeneration(this.label);
  final String label;
}

/// `--list-devices` NPU 行的结构化解析结果（探测缓存 / engines.json 共用）。
class NpuDeviceInfo {
  const NpuDeviceInfo({
    required this.devArg,
    this.deviceName,
    this.npuCode,
    this.totalMib,
    this.freeMib,
    this.driverVersion,
  });

  /// NPU 在 OpenVINO 插件枚举中的档位（`OPENVINO{n}`，探测命中值）。
  final String devArg;

  /// 冒号行 `=NPU - ` 之后的设备名，如 `Intel(R) AI Boost (NPU 3720)`。
  final String? deviceName;

  /// 型号码（3720/3820/4000 系）；枚举名不带号码时 null。
  final int? npuCode;

  /// 设备上报的总/空闲内存（MiB）。**仅诊断展示**：NPU 的
  /// OUT_OF_HOST_MEMORY 是驱动 per-process 预算而非系统内存
  /// （HANDOFF 2026-11-02 深夜定案），不得用作预算依据。
  final int? totalMib;
  final int? freeMib;

  /// Intel NPU 驱动版本（best-effort，EngineStore.npuDriverVersion）。
  final String? driverVersion;

  NpuGeneration get generation => npuGenerationFor(npuCode, deviceName);

  /// engines.json `lastNpuInfo` 摘要（可选字段，旧文件无此键 → null 容错）。
  Map<String, dynamic> toSummary() => {
        'devArg': devArg,
        if (deviceName != null) 'name': deviceName,
        if (npuCode != null) 'code': npuCode,
        'generation': generation.name,
        if (driverVersion != null) 'driver': driverVersion,
      };
}

/// 型号码提取（对枚举名兜底同样用它）：`\b` 收尾防误吃长数字
/// （`NPU 37200` 里的子串 `3720` 不得命中 —— contains 会犯的错）。
final _codeInName = RegExp(r'NPU\s*(\d{3,4})\b', caseSensitive: false);

/// 世代表决：型号码优先（3720→一代、3820→二代、4000–4999→三代），
/// 枚举名兜底（旧驱动只报 `Intel(R) AI Boost` 无号码；Panther Lake 枚举
/// 形态未实机核证，识别不了就 unknown → 保守基线，绝不猜成高档）。
/// 名称兜底必须走 `_codeInName`（带 `\b`），禁止 contains 松匹配。
NpuGeneration npuGenerationFor(int? code, String? name) {
  var c = code;
  if (c == null && name != null) {
    c = int.tryParse(_codeInName.firstMatch(name)?.group(1) ?? '');
  }
  if (c != null) {
    if (c >= 4000 && c < 5000) return NpuGeneration.ultra3;
    if (c >= 3800 && c < 3900) return NpuGeneration.ultra2;
    if (c >= 3700 && c < 3800) return NpuGeneration.ultra1;
  }
  return NpuGeneration.unknown;
}

/// 世代档案：clamp/UI/驱动提示的世代侧数据。字段全可空 —— 缺省 = 让位
/// manifest preset（= 一代实测基线）。
class NpuProfile {
  const NpuProfile({
    required this.generation,
    this.minDriverVersion,
    this.driverNote,
    this.ctxOverrides = const {},
  });

  final NpuGeneration generation;

  /// 驱动最低版本（warning-only；比对到 EngineStore.npuDriverVersion）。
  /// 暂无实测口径不预填 —— 版本线是编的会误导用户升错驱动，留实测回填。
  final String? minDriverVersion;

  /// 驱动提示语（低于 minDriverVersion 或三代首装排障时随 UI 展示）。
  final String? driverNote;

  /// preset 名 → ctx 上限覆盖（数据位：拿到该机世代实测才填；覆盖只**抬高**
  /// 预设先验，收紧请改 manifest preset 本身——出厂实测的权威在那边）。
  final Map<String, int> ctxOverrides;

  /// 档案对某 preset 的 ctx 覆盖（null = 沿用 preset.ctx）。
  int? ctxOverrideFor(String? presetName) =>
      presetName == null ? null : ctxOverrides[presetName];
}

const _kProfiles = <NpuGeneration, NpuProfile>{
  NpuGeneration.ultra1: NpuProfile(generation: NpuGeneration.ultra1),
  NpuGeneration.ultra2: NpuProfile(generation: NpuGeneration.ultra2),
  // 三代（Panther Lake / NPU 4000 系）：新硬件对新驱动敏感 —— 无实测数字，
  // 只挂排障提示（数字不赌，见文件头纪律）。
  NpuGeneration.ultra3: NpuProfile(
    generation: NpuGeneration.ultra3,
    driverNote: 'NPU 4000 系需较新的 Intel NPU 驱动与 OpenVINO 运行时；'
        '加载反复失败请先升级 NPU 驱动（设备管理器 → 神经处理单元）',
  ),
  NpuGeneration.unknown: NpuProfile(generation: NpuGeneration.unknown),
};

/// 测试注入：整表替换（clamp 链用例注入 gen2 覆盖数字验证数据位接线）。
@visibleForTesting
Map<NpuGeneration, NpuProfile>? profileOverrideForTest;

/// 世代档案查询：null/unknown → 一代保守基线（兜底 = 今天的行为）。
NpuProfile profileFor(NpuGeneration? g) {
  final ov = profileOverrideForTest;
  final key = g ?? NpuGeneration.unknown;
  return ov?[key] ?? _kProfiles[key]!;
}
