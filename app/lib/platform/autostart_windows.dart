// Windows 开机自启（M3-b / 设计 §3）：HKCU\...\Run 注册表项，reg.exe 实现
// （不引入 win32 依赖；HKCU 不需要管理员权限）。幂等：重复 enable 覆盖。
import 'dart:io';

class AutostartWindows {
  AutostartWindows._();
  static const _runKey =
      r'HKCU\Software\Microsoft\Windows\CurrentVersion\Run';
  static const _valueName = 'WangCai';

  /// 当前 exe 路径（flutter_tester/调试也可写，但仅 release 语义有意义）。
  static String get exePath {
    final exe = Platform.resolvedExecutable;
    // dart VM 调试运行时（dart.exe/flutter_tester）不注册——由调用方守门。
    return exe;
  }

  static Future<bool> isEnabled() async {
    final r = await Process.run('reg', ['query', _runKey, '/v', _valueName]);
    return r.exitCode == 0;
  }

  /// 失败返回 false（如 reg.exe 不可用）；成功写 exe 路径。
  static Future<bool> enable({String? exeOverride}) async {
    final exe = exeOverride ?? exePath;
    final r = await Process.run('reg', [
      'add', _runKey, '/v', _valueName, '/t', 'REG_SZ', '/d', '"$exe"', '/f',
    ]);
    return r.exitCode == 0;
  }

  static Future<bool> disable() async {
    final r =
        await Process.run('reg', ['delete', _runKey, '/v', _valueName, '/f']);
    // 不存在也算成功（幂等）。
    return r.exitCode == 0 || '${r.stderr}'.contains('unable to find');
  }
}
