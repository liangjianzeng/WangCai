/// 原生开发环境桥（Dev Agent L1/L2）—— MethodChannel 通道服务。
///
/// 通道 `com.dgxspark.tongyilite/devenv`：
/// - `nativeInfo`：nativeLibraryDir / filesDir / Termux 外部交换目录；
/// - `runTermux`：向 Termux 发 RUN_COMMAND intent（免 SSH 官方通道）；
/// - `installApk`：FileProvider 拉起安装器（Termux 伴侣应用自动装）；
/// - `canRequestInstall`：REQUEST_INSTALL_PACKAGES 是否已授权。
///
/// 通道调用经 [invoker] 收口（测试注入桩；null = 真实通道）。
library;

import 'package:flutter/services.dart';

const MethodChannel _kDevEnvChannel =
    MethodChannel('com.dgxspark.tongyilite/devenv');

/// 通道调用器签名（测试注入点）。
typedef DevEnvInvoker = Future<Object?> Function(
    String method, Map<String, dynamic> args);

/// 原生环境信息（nativeInfo 返回）。
final class DevNativeInfo {
  /// 应用 native 库目录（jniLibs 的 lib*.so 落地处，唯一可 exec 白名单位置）。
  final String nativeLibraryDir;

  /// 应用私有文件目录。
  final String filesDir;

  const DevNativeInfo({required this.nativeLibraryDir, required this.filesDir});

  static DevNativeInfo fromMap(Object? raw) {
    final map = raw is Map ? raw.cast<String, dynamic>() : <String, dynamic>{};
    return DevNativeInfo(
      nativeLibraryDir: (map['nativeLibraryDir'] as String?) ?? '',
      filesDir: (map['filesDir'] as String?) ?? '',
    );
  }
}

/// 原生环境桥（静态收口；invoker 仅供测试注入）。
class DevNativeEnv {
  DevNativeEnv._();

  /// 测试注入：null = 真实 MethodChannel。
  static DevEnvInvoker? invoker;

  static Future<Object?> _invoke(String method, Map<String, dynamic> args) {
    final f = invoker;
    if (f != null) return f(method, args);
    return _kDevEnvChannel.invokeMethod(method, args);
  }

  /// 读取原生环境信息；失败返回 null（调用方按"环境不可用"降级）。
  static Future<DevNativeInfo?> nativeInfo() async {
    try {
      return DevNativeInfo.fromMap(await _invoke('nativeInfo', const {}));
    } catch (_) {
      return null;
    }
  }

  /// 向 Termux 发 RUN_COMMAND intent。
  /// 返回错误信息（null = 已成功交由系统投递；执行结果走文件交换）。
  static Future<String?> runTermux({
    required String executablePath,
    required List<String> arguments,
    String? workDir,
  }) async {
    try {
      final err = await _invoke('runTermux', {
        'path': executablePath,
        'args': arguments,
        if (workDir != null && workDir.isNotEmpty) 'workDir': workDir,
      });
      return err is String && err.isNotEmpty ? err : null;
    } on PlatformException catch (e) {
      return e.message ?? e.code;
    } catch (e) {
      return '$e';
    }
  }

  /// 是否已声明并取得「安装未知应用」授权（Android 8+ 需用户逐应用开启）。
  static Future<bool> canRequestInstall() async {
    try {
      return await _invoke('canRequestInstall', const {}) == true;
    } catch (_) {
      return false;
    }
  }

  /// 拉起 APK 安装器（FileProvider）。返回错误信息（null = 已发起）。
  static Future<String?> installApk(String apkPath) async {
    try {
      final err = await _invoke('installApk', {'path': apkPath});
      return err is String && err.isNotEmpty ? err : null;
    } on PlatformException catch (e) {
      return e.message ?? e.code;
    } catch (e) {
      return '$e';
    }
  }

  /// 用系统 DownloadManager 后台下载 APK 到 `Download/TongYi-Lite/`。
  /// 返回错误信息（null = 已入队；完成后的安装需再调 installApk）。
  static Future<String?> downloadTermuxApk(String url) async {
    try {
      final err = await _invoke('downloadTermuxApk', {'url': url});
      return err is String && err.isNotEmpty ? err : null;
    } on PlatformException catch (e) {
      return e.message ?? e.code;
    } catch (e) {
      return '$e';
    }
  }
}
