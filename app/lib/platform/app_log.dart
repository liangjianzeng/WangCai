/// 全局落盘日志（2026-11-07）：引擎装配/路由/退出等关键链路的黑匣子。
///
/// 动机：装机现场「NPU 引擎不可用」排查时发现推理日志几乎为零（_log 只进
/// 内存回调，弹层关闭即丢），排障只能靠猜。本文件提供进程级追加日志：
/// `{dataRoot}/logs/app.log`，1MB 自动轮转（app.log.1），任何一步失败静默
/// （日志器自己绝不能把业务打死）。
library;

import 'dart:io';

import 'package:flutter/foundation.dart';

import 'wangcai_paths.dart';

class AppLog {
  AppLog._();

  static bool _failed = false; // 写失败后本进程不再尝试（防每次 IO 空转）

  /// 追加一行（自带时间戳）。多行消息按行拆开，日志好读。
  static void write(String message) {
    if (_failed) return;
    try {
      final f = _file();
      if (f == null) return;
      final now = DateTime.now();
      final ts =
          '${now.year.toString().padLeft(4, '0')}-${now.month.toString().padLeft(2, '0')}-${now.day.toString().padLeft(2, '0')} '
          '${now.hour.toString().padLeft(2, '0')}:${now.minute.toString().padLeft(2, '0')}:${now.second.toString().padLeft(2, '0')}.${now.millisecond.toString().padLeft(3, '0')}';
      final sb = StringBuffer();
      for (final line in message.split('\n')) {
        sb.writeln('[$ts] $line');
      }
      f.writeAsStringSync(sb.toString(), mode: FileMode.append, flush: false);
    } catch (e) {
      debugPrint('[AppLog] 写日志失败（本进程停写）: $e');
      _failed = true;
    }
  }

  /// 日志文件：`{dataRoot}/logs/app.log`，>1MB 轮转为 .1。
  static File? _file() {
    try {
      final dir =
          Directory('${WangCaiPaths.dataRoot().path}${Platform.pathSeparator}logs');
      if (!dir.existsSync()) dir.createSync(recursive: true);
      final f = File('${dir.path}${Platform.pathSeparator}app.log');
      try {
        if (f.existsSync() && f.lengthSync() > 1024 * 1024) {
          final old = File('${dir.path}${Platform.pathSeparator}app.log.1');
          if (old.existsSync()) old.deleteSync();
          f.renameSync(old.path);
        }
      } catch (_) {/* 轮转失败不影响追加 */}
      return f;
    } catch (_) {
      return null;
    }
  }
}
