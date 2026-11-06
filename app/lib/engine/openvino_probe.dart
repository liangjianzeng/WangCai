// OpenVINO 设备索引探测（v0.0.3 Phase 3，设计 §12 / 计划「OPENVINO 探测」；
// 世代自适应〔2026-11-05，Unreleased〕升级为返回完整 NPU 设备信息，npu_profiles.dart）。
//
// 背景：wangcai-npu manifest 的 argsTemplate 硬编码 `-dev {devArg=OPENVINO3}`，
// 那是**开发机**（带 Arc iGPU）的枚举实测；OpenVINO 插件枚举顺序决定索引 ——
// 纯 285H 笔记本实测 `OPENVINO2` 才是 NPU（本机 --list-devices 实锤：
// 0=CPU / 1=Arc iGPU / 2=NPU）。装机用户拿到 OPENVINO3 = 加载必败。
//
// 纪律：探测以 `llama-server --list-devices` 的输出命中为准（解析
// `OPENVINO{n}: ... GGML_OPENVINO_DEVICE=NPU` 行）；探测失败/无 NPU 行
// **回退 OPENVINO2**（比 OPENVINO3 命中率高：它是无 dGPU 机型的通解，
// 也是本机验证过的档位），不抛错、不阻塞加载。
//
// 世代自适应追加（2026-11-05）：命中行的设备名/型号码/MiB 一并保留（NpuDeviceInfo），
// 供世代档案（npu_profiles.dart）与引擎管理页取证；MiB 仅诊断，不做预算。
import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'npu_profiles.dart';

/// 命中行形态：`  OPENVINO2: GGML_OPENVINO_DEVICE=NPU - Intel(R) AI Boost …`
final _npuLine = RegExp(r'(OPENVINO\d+)\s*:.*GGML_OPENVINO_DEVICE\s*=\s*NPU\b',
    caseSensitive: false);

/// 设备名：`=NPU - ` 之后到行尾（含型号后缀），如 `Intel(R) AI Boost (NPU 3720)`。
final _deviceName =
    RegExp(r'GGML_OPENVINO_DEVICE\s*=\s*NPU\s*-\s*(.+)$', caseSensitive: false);

/// 真机行尾还挂内存标注：`… (NPU 3720) (24576 MiB, 14991 MiB free)` → 名字
/// 剥掉尾部 MiB 括注（对齐 engine_store.parseListDevices 的同类处理）。
final _mibTail = RegExp(r'\s*\([^)]*MiB[^)]*\)\s*$', caseSensitive: false);

/// 型号码：`… (NPU 3720)`；枚举名不带号码时无命中（→ 世代按名称兜底/unknown）。
/// `\b` 收尾防误吃长数字（NPU 37200 不匹配，宁缺勿错代）。
final _npuCode = RegExp(r'NPU\s*(\d{3,4})\b', caseSensitive: false);

/// 内存对：`(24576 MiB, 14991 MiB free)`（仅诊断）。
final _mibPair = RegExp(r'(\d+)\s*MiB\s*,\s*(\d+)\s*MiB\s*free',
    caseSensitive: false);

/// exe 路径 → 探测结果。同进程缓存：驱动不变则
/// 枚举不变，加载不必每次重探；失败不缓存（下次加载再试）。
final _cache = <String, NpuDeviceInfo>{};

/// 测试注入：(exe, env) → --list-devices 的合并输出（null = 模拟探测失败）。
Future<String?> Function(String exe, Map<String, String> env)?
    probeRunnerForTest;

/// 探测失败时的兜底档位（计划定案：回退 OPENVINO2）。
const String kOpenvinoNpuFallbackDevArg = 'OPENVINO2';

/// 探测 [exe] 的 NPU 设备信息；返回 null = 探测失败（调用方保守兜底）。
/// [env] 是给子进程的完整环境（PATH 必须含 ovlibs，与真启动同一份）。
Future<NpuDeviceInfo?> probeNpuDevice(String exe, Map<String, String> env) async {
  final cached = _cache[exe];
  if (cached != null) return cached;
  String? out;
  try {
    final runner = probeRunnerForTest;
    if (runner != null) {
      out = await runner(exe, env).timeout(const Duration(seconds: 20));
    } else {
      final r = await Process.run(exe, ['--list-devices'],
              environment: env, runInShell: false)
          .timeout(const Duration(seconds: 20));
      out = '${r.stdout}\n${r.stderr}';
    }
  } catch (_) {
    return null; // 超时/无法执行 = 探测失败，不缓存
  }
  if (out == null) return null;
  final info = parseNpuListDevices(out);
  if (info != null) _cache[exe] = info;
  return info;
}

/// `--list-devices` 输出的 NPU 行解析（纯函数，可测）。无 NPU 行 → null。
NpuDeviceInfo? parseNpuListDevices(String out) {
  for (final line in const LineSplitter().convert(out)) {
    final m = _npuLine.firstMatch(line);
    if (m == null) continue;
    final devArg = m.group(1)!.toUpperCase();
    var name = _deviceName.firstMatch(line)?.group(1)?.trim();
    if (name != null) name = name.replaceAll(_mibTail, '').trim();
    // 名里没有（如 `=NPU (selected) - …` 变体导致 name 取不到）→ 从整行找号码。
    final code =
        int.tryParse(_npuCode.firstMatch(name ?? line)?.group(1) ?? '');
    final mib = _mibPair.firstMatch(line);
    return NpuDeviceInfo(
      devArg: devArg,
      deviceName: (name == null || name.isEmpty) ? null : name,
      npuCode: code,
      totalMib: int.tryParse(mib?.group(1) ?? ''),
      freeMib: int.tryParse(mib?.group(2) ?? ''),
    );
  }
  return null;
}

/// 已缓存的探测结果（不触发子进程）：loadModel 的 clamp 链读世代信息用。
NpuDeviceInfo? cachedNpuInfo(String exe) => _cache[exe];

/// 清缓存（测试/引擎升级后重探）。
void clearOpenvinoProbeCache() => _cache.clear();
