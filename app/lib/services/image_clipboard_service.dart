/// 图片复制到系统剪贴板（聊天气泡「复制图片」动作的后端）。
///
/// 平台路径：
/// - Windows：PowerShell(-STA) + System.Windows.Forms.Clipboard.SetImage
///   （进程内 ffi 写 CF_DIB 需要 PNG→DIB 重排，交给 .NET 一次成型；
///   spawn 开销 ~1s，复制动作无感）。文件经字节流喂给 Image，不锁原文件。
/// - Linux：xclip（X11）/ wl-copy（Wayland）按序探测，都没有 → false。
/// 返回 bool 由 UI 决定成功/失败提示，本服务不弹任何 UI。
library;

import 'dart:async';
import 'dart:convert' show utf8;
import 'dart:io';

class ImageClipboardService {
  const ImageClipboardService._();

  /// 把 [path] 指向的 PNG/JPG 写入系统剪贴板（作为图像内容，非文件引用）。
  /// 失败（工具缺失/命令报错）返回 false，不抛。
  static Future<bool> copyImageFile(String path) async {
    if (Platform.isWindows) return _copyWindows(path);
    if (Platform.isLinux) return _copyLinux(path);
    return false;
  }

  static Future<bool> _copyWindows(String path) async {
    try {
      // PS 单引号字符串里单引号翻倍转义；FromFile 的文件锁随 PS 退出即释放。
      final escaped = path.replaceAll("'", "''");
      final result = await Process.run(
        'powershell',
        [
          '-NoProfile',
          '-NonInteractive',
          '-STA',
          '-Command',
          'Add-Type -AssemblyName System.Windows.Forms; '
              'Add-Type -AssemblyName System.Drawing; '
              "\$img = [System.Drawing.Image]::FromFile('$escaped'); "
              '[System.Windows.Forms.Clipboard]::SetImage(\$img); '
              '\$img.Dispose()',
        ],
        stdoutEncoding: utf8,
        stderrEncoding: utf8,
      ).timeout(const Duration(seconds: 10));
      return result.exitCode == 0;
    } catch (_) {
      return false;
    }
  }

  static Future<bool> _copyLinux(String path) async {
    // X11 → xclip；Wayland → wl-copy（stdin 语义走 sh 重定向）。
    try {
      if (await _canRun('xclip')) {
        final r = await Process.run(
                'xclip',
                ['-selection', 'clipboard', '-t', 'image/png', '-i', path],
                stdoutEncoding: utf8)
            .timeout(const Duration(seconds: 5));
        if (r.exitCode == 0) return true;
      }
      if (await _canRun('wl-copy')) {
        final r = await Process.run(
                'sh', ['-c', 'wl-copy --type image/png < ${_shq(path)}'],
                stdoutEncoding: utf8)
            .timeout(const Duration(seconds: 5));
        if (r.exitCode == 0) return true;
      }
    } catch (_) {
      // 落到 false。
    }
    return false;
  }

  /// shell 单引号安全包裹。
  static String _shq(String s) => "'" + s.replaceAll("'", "'\\''") + "'";

  static Future<bool> _canRun(String exe) async {
    try {
      final r = await Process.run('sh', ['-c', 'command -v $exe'])
          .timeout(const Duration(seconds: 3));
      return r.exitCode == 0;
    } catch (_) {
      return false;
    }
  }
}
