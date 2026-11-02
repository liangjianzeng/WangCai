// 电源感知（设计 §7.3「电池机型拔电 → NPU 加权」/ M3-b）：
// dart:ffi 直调 kernel32!GetSystemPowerStatus（无新依赖）。
// 路由消费方：LocalServerInference._route 组装 RoutingRequest 时读 onBattery。
import 'dart:ffi';
import 'dart:io';

import 'package:ffi/ffi.dart';

final class _SystemPowerStatus extends Struct {
  @Uint8()
  external int acLineStatus; // 0=离线(电池) 1=在线(AC) 255=未知
  @Uint8()
  external int batteryFlag;
  @Uint8()
  external int batteryLifePercent; // 0-100，255=未知
  @Uint32()
  external int batteryLifeTime; // 秒，-1=未知
  @Uint32()
  external int batteryFullLifeTime;
}

typedef _GetPowerStatusC = Int32 Function(Pointer<_SystemPowerStatus>);
typedef _GetPowerStatusDart = int Function(Pointer<_SystemPowerStatus>);

_GetPowerStatusDart? _fn;

bool _available() {
  if (!Platform.isWindows) return false;
  try {
    _fn ??= DynamicLibrary.open('kernel32.dll')
        .lookupFunction<_GetPowerStatusC, _GetPowerStatusDart>(
            'GetSystemPowerStatus');
    return true;
  } catch (_) {
    return false;
  }
}

class PowerState {
  const PowerState({
    required this.onBattery,
    this.batteryPercent,
    this.unknown = false,
  });

  /// true = 用电池（路由按拔电加权 NPU）。
  final bool onBattery;

  /// 0-100；台式机/未知为 null。
  final int? batteryPercent;
  final bool unknown;
}

/// 读系统电源状态；API 不可用/台式机（无电池）→ onBattery=false。
PowerState readPowerState() {
  if (!_available()) {
    return const PowerState(onBattery: false, unknown: true);
  }
  final st = calloc<_SystemPowerStatus>();
  try {
    final ok = _fn!(st);
    if (ok == 0) return const PowerState(onBattery: false, unknown: true);
    final ac = st.ref.acLineStatus;
    final pct = st.ref.batteryLifePercent;
    final noBattery =
        st.ref.batteryFlag == 128; // BATTERY_FLAG_NO_BATTERY（台式机）
    return PowerState(
      onBattery: ac == 0 && !noBattery,
      batteryPercent: (pct >= 0 && pct <= 100) ? pct : null,
      unknown: ac == 255,
    );
  } catch (_) {
    return const PowerState(onBattery: false, unknown: true);
  } finally {
    calloc.free(st);
  }
}
