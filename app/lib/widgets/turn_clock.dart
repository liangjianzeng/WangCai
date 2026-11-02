// ============================================================
// 回合秒级时钟（2026-10-25 阶段 4 计时器收敛）。
//
// 此前每张执行中的工具卡/思考卡各自开一个 Ticker（N 卡 N 个、每帧回调、
// 组件重建计时清零）。收敛为全 app **一个** 1s Timer + ValueNotifier<int>
// 广播：卡片只在 mounted 时监听，秒数变化才 setState。
// ============================================================

import 'dart:async';

import 'package:flutter/foundation.dart';

class TurnClock {
  TurnClock._();
  static final TurnClock instance = TurnClock._();

  /// 每秒自增的 tick（监听方用它触发 setState，实际耗时用 DateTime 差值）。
  final ValueNotifier<int> tick = ValueNotifier<int>(0);
  Timer? _timer;
  int _refs = 0;

  /// 卡片 mount 时调用；引用计数归零自动停表（空闲零开销）。
  void acquire() {
    _refs++;
    _timer ??= Timer.periodic(const Duration(seconds: 1), (_) {
      tick.value = tick.value + 1;
    });
  }

  void release() {
    _refs = (_refs - 1).clamp(0, _refs);
    if (_refs == 0) {
      _timer?.cancel();
      _timer = null;
    }
  }
}
