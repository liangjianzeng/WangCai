// 引擎子进程环境（设计 §4.1 / run-npu.ps1 语义的程序化等价）：
// ① 清除全部 GGML_OPENVINO_*/NPUW_* 残留（run-npu.ps1 的同款纪律，防串环境）；
// ② PATH 前置 bin 与运行时 DLL 目录（OV libs）；
// ③ 注入 manifest envTemplate 渲染结果。
import 'dart:io';

Map<String, String> buildServerEnv({
  required Map<String, String> parentEnv,
  required List<String> pathPrefixes,
  required Map<String, String> engineEnv,
  bool? isWindows,
}) {
  final win = isWindows ?? Platform.isWindows;
  final env = Map<String, String>.from(parentEnv);
  env.removeWhere((k, _) {
    final u = k.toUpperCase();
    return u.startsWith('GGML_OPENVINO_') || u.startsWith('NPUW_');
  });
  final sep = win ? ';' : ':';
  final pathKey = env.keys.firstWhere(
    (k) => k.toUpperCase() == 'PATH',
    orElse: () => 'PATH',
  );
  env[pathKey] = [...pathPrefixes, env[pathKey] ?? '']
      .where((p) => p.isNotEmpty)
      .join(sep);
  env.addAll(engineEnv);
  return env;
}
