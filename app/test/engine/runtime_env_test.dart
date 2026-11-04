import 'package:flutter_test/flutter_test.dart';
import 'package:wangcai/engine/runtime_env.dart';

void main() {
  test('清除 GGML_OPENVINO_*/NPUW_* 残留；PATH 前置；注入引擎 env', () {
    final env = buildServerEnv(
      parentEnv: {
        'PATH': r'C:\Windows',
        'SystemRoot': r'C:\Windows',
        'GGML_OPENVINO_DEVICE': 'STALE', // run-npu.ps1 要清掉的残留
        'npuw_cache_dir': 'STALE', // 大小写不敏感
      },
      pathPrefixes: [r'E:\bin', r'E:\ov\libs'],
      engineEnv: {'GGML_OPENVINO_DEVICE': 'NPU'},
      isWindows: true,
    );
    expect(env.containsKey('npuw_cache_dir'), isFalse);
    expect(env['GGML_OPENVINO_DEVICE'], 'NPU');
    expect(env['PATH'], startsWith(r'E:\bin;E:\ov\libs;C:\Windows'));
    expect(env['SystemRoot'], r'C:\Windows', reason: '非引擎变量必须保留');
  });

  test('PATH 键名大小写不敏感', () {
    final env = buildServerEnv(
      parentEnv: {'Path': 'C:\\W'},
      pathPrefixes: ['X'],
      engineEnv: {},
      isWindows: true,
    );
    expect(env['Path'], 'X;C:\\W');
  });
}
