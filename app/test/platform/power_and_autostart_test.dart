// 自启的真机只读冒烟（Windows 门控；不写注册表）。
// 电源感知（M3-b readPowerState）已随 2026-11-07 路由重设计退役：
// 「拔电 → NPU 加权」属于已废除的 auto 档语义，孤儿模块一并移除。
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:wangcai/platform/autostart_windows.dart';

void main() {
  test(
    'AutostartWindows.isEnabled 只读查询不抛',
    () async {
      final on = await AutostartWindows.isEnabled();
      // ignore: avoid_print
      print('autostart enabled=$on');
      expect(on, isA<bool>());
    },
    skip: !Platform.isWindows ? '需要 Windows（reg.exe）' : false,
  );
}
