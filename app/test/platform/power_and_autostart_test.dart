// M3-b 电源感知/自启的真机只读冒烟（Windows 门控；不写注册表）。
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:wangcai/platform/autostart_windows.dart';
import 'package:wangcai/platform/power_monitor.dart';

void main() {
  test(
    'readPowerState：不抛且字段自洽',
    () {
      final p = readPowerState();
      // ignore: avoid_print
      print('power: onBattery=${p.onBattery} pct=${p.batteryPercent} '
          'unknown=${p.unknown}');
      final pct = p.batteryPercent;
      expect(pct == null || (pct >= 0 && pct <= 100), isTrue);
    },
    skip: !Platform.isWindows ? '需要 Windows（FFI kernel32）' : false,
  );

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
