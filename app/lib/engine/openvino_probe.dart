// OpenVINO 设备索引探测（v0.0.3 Phase 3，设计 §12 / 计划「OPENVINO 探测」）。
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
import 'dart:async';
import 'dart:io';

/// 命中行形态：`  OPENVINO2: GGML_OPENVINO_DEVICE=NPU - Intel(R) AI Boost …`
final _npuLine = RegExp(r'(OPENVINO\d+)\s*:.*GGML_OPENVINO_DEVICE\s*=\s*NPU\b',
    caseSensitive: false);

/// exe 路径 → 探测结果（NPU 的 OPENVINO{n}）。同进程缓存：驱动不变则
/// 枚举不变，加载不必每次重探；失败不缓存（下次加载再试）。
final _cache = <String, String>{};

/// 测试注入：(exe, env) → --list-devices 的合并输出（null = 模拟探测失败）。
Future<String?> Function(String exe, Map<String, String> env)?
    probeRunnerForTest;

/// 探测失败时的兜底档位（计划定案：回退 OPENVINO2）。
const String kOpenvinoNpuFallbackDevArg = 'OPENVINO2';

/// 探测 [exe] 的 NPU 设备索引；返回 `OPENVINO{n}` 或 null（探测失败）。
/// [env] 是给子进程的完整环境（PATH 必须含 ovlibs，与真启动同一份）。
Future<String?> probeNpuDevArg(String exe, Map<String, String> env) async {
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
  final m = _npuLine.firstMatch(out);
  final hit = m?.group(1)?.toUpperCase();
  if (hit != null) _cache[exe] = hit;
  return hit;
}

/// 清缓存（测试/引擎升级后重探）。
void clearOpenvinoProbeCache() => _cache.clear();
