import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

// ---------------------------------------------------------------------------
// 编码守护（2026-09-30 健康审查 P0）：
// settings 双文件曾发生「UTF-8 注释被当 GBK 再存回」的双重编码事故，
// 注释大面积变乱码且部分字节永久丢失。此测试锁死：这两个文件里
// 不允许再出现双重编码特征字符（它们不在任何正常中文词汇里出现）。
// ---------------------------------------------------------------------------

/// 双重编码的高频特征字（GBK 误读 UTF-8 字节的典型产物）。
const String _mojibakeMarkers = '锛鎸鏄鍦鍚鐨鏂鍏鐘鍒鐮鎴鍔瀛銆鎬敓浠嶅紝鈥';

void _assertNoMojibake(String path) {
  final file = File(path);
  if (!file.existsSync()) return; // 允许文件被重命名后同步更新本测试
  final lines = file.readAsLinesSync();
  final bad = <String>[];
  for (var i = 0; i < lines.length; i++) {
    final line = lines[i];
    for (var j = 0; j < line.length; j++) {
      if (_mojibakeMarkers.contains(line[j])) {
        bad.add('L${i + 1}: ${line.trim()}');
        break;
      }
    }
  }
  expect(bad, isEmpty,
      reason: '$path 存在双重编码乱码注释（先按行做 GBK→UTF-8 round-trip 恢复）：\n'
          '${bad.take(10).join('\n')}');
}

void main() {
  test('settings_provider.dart 无双重编码乱码注释', () {
    _assertNoMojibake('lib/providers/settings_provider.dart');
  });

  test('settings_service.dart 无双重编码乱码注释', () {
    _assertNoMojibake('lib/services/settings_service.dart');
  });
}
