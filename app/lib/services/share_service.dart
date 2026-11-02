// ============================================================
// Share Service — 系统分享桥
//
// 把文本经 Android ACTION_SEND 分享（系统分享面板里选微信/QQ 等）。
// 走既有 files MethodChannel（MainActivity 侧 shareText），不引新插件。
// ============================================================

import 'package:flutter/services.dart';

/// 系统分享服务（单例）。
class ShareService {
  ShareService._internal();
  static final ShareService instance = ShareService._internal();

  static const MethodChannel _channel =
      MethodChannel('com.dgxspark.tongyilite/files');

  /// 分享纯文本。返回是否成功唤起系统分享面板。
  /// 平台不支持（如桌面调试）时静默返回 false，不抛异常。
  Future<bool> shareText(String text, {String? title}) async {
    if (text.isEmpty) return false;
    try {
      final ok = await _channel.invokeMethod<bool>('shareText', {
        'text': text,
        'title': title ?? '分享',
      });
      return ok ?? false;
    } on MissingPluginException {
      return false;
    } on PlatformException {
      return false;
    }
  }
}
