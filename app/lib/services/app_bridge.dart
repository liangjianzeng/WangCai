/// 外部应用桥（MethodChannel：com.dgxspark.tongyilite/app）。
///
/// Termux SSH 向导用：检测 Termux 是否安装、一键拉起 Termux App——
/// sshd 未启动时用户不用回桌面找图标。
library;

import 'package:flutter/services.dart';

class AppBridge {
  static const MethodChannel _ch =
      MethodChannel('com.dgxspark.tongyilite/app');

  /// Termux 官方包名（F-Droid/GitHub 版；Play 商店变体同 id）。
  static const String termuxPackage = 'com.termux';

  /// 应用是否已安装。异常按未安装处理。
  static Future<bool> isAppInstalled(String package) async {
    try {
      return await _ch.invokeMethod<bool>('isAppInstalled',
              <String, dynamic>{'package': package}) ==
          true;
    } catch (_) {
      return false;
    }
  }

  /// Termux 零粘贴：经 RUN_COMMAND intent 让 Termux 执行 [command]。
  /// 返回是否成功派发 intent；Termux 未装 / 未开 allow-external-apps 时
  /// 返回 false 或 Termux 侧静默忽略（调用方需引导用户检查开关）。
  static Future<bool> runInTermux(String command,
      {bool background = false}) async {
    try {
      return await _ch.invokeMethod<bool>('runInTermux',
              <String, dynamic>{'command': command, 'background': background}) ==
          true;
    } catch (_) {
      return false;
    }
  }

  /// 拉起应用主界面。失败（未安装/被禁）返回 false。
  static Future<bool> launchApp(String package) async {
    try {
      return await _ch.invokeMethod<bool>('launchApp',
              <String, dynamic>{'package': package}) ==
          true;
    } catch (_) {
      return false;
    }
  }

  /// GPU 推理防闪纹：把窗口刷新率锁到最接近 [fps] 的支持模式（60 = DPU
  /// 供帧带宽减半，prefill/加载不再挤占显示）。[fps] <= 0 = 恢复跟随系统。
  /// 静默失败（老设备不支持 preferredDisplayModeId 时）返回 false。
  static Future<bool> setPreferredRefreshRate(double fps) async {
    try {
      return await _ch.invokeMethod<bool>('setPreferredRefreshRate',
              <String, dynamic>{'fps': fps}) ==
          true;
    } catch (_) {
      return false;
    }
  }
}
