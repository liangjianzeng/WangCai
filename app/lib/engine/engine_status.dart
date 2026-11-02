// 引擎状态机（设计 §4.2）：纯 Dart 可测；输入事件 → 输出 EngineStatus。
// M0-3 实测约束：server 侧无 -st；参数集 -fa 1 -np 1 -dev OPENVINO{n} --jinja。
enum EnginePhase {
  stopped,
  launching, // 进程已拉起，等 health
  compiling, // 日志出现图编译迹象（NPU 冷编 ~36s）
  warming, // 日志 model loaded，即将 listening
  ready, // /health 200
  draining, // 正在停止
  error, // 崩溃/编译失败/预算耗尽，需人工
}

class EngineStatus {
  const EngineStatus(this.phase, {this.detail, this.error});

  final EnginePhase phase;
  final String? detail;
  final String? error;

  bool get isUsable => phase == EnginePhase.ready;
  bool get isStarting =>
      phase == EnginePhase.launching ||
      phase == EnginePhase.compiling ||
      phase == EnginePhase.warming;

  @override
  String toString() => 'EngineStatus($phase${error != null ? ', error=$error' : ''})';

  @override
  bool operator ==(Object other) =>
      other is EngineStatus &&
      other.phase == phase &&
      other.detail == detail &&
      other.error == error;

  @override
  int get hashCode => Object.hash(phase, detail, error);
}

sealed class EngineEvent {}

class StartRequested extends EngineEvent {}

class StopRequested extends EngineEvent {}

class LogLineEvent extends EngineEvent {
  LogLineEvent(this.line);
  final String line;
}

class ProcessExitedEvent extends EngineEvent {
  ProcessExitedEvent(this.code);
  final int code;
}

class HealthOkEvent extends EngineEvent {}

class CrashDetectedEvent extends EngineEvent {
  CrashDetectedEvent(this.reason);
  final String reason;
}

/// 纯状态机。重启/退避策略在 host 层（可测性：host 拿 machine 的快照做决策）。
class EngineStateMachine {
  EngineStatus _state = const EngineStatus(EnginePhase.stopped);
  EngineStatus get state => _state;

  /// 当前是否处于"我们主动要求它跑"的意图下（决定意外退出算崩溃还是算停止）。
  bool _wantRunning = false;
  bool get wantRunning => _wantRunning;

  /// 编译期日志标记（大小写不敏感）。NPU 静态图编译、blob 缓存。
  static final RegExp _compileRe =
      RegExp(r'compil|blob|npuw', caseSensitive: false);
  static final RegExp _warmingRe =
      RegExp(r'model loaded|listening|server_?listening', caseSensitive: false);
  /// M0-3 / status.md 实测错误词表。命中即 error（崩溃类由 host 走重启预算）。
  static final List<RegExp> _errorRes = [
    RegExp(r'ZE_RESULT', caseSensitive: false),
    RegExp(r'ov::Exception'),
    RegExp(r'OUT_OF_HOST_MEMORY', caseSensitive: false),
    RegExp(r'error loading model', caseSensitive: false),
    RegExp(r'Compute error', caseSensitive: false),
    RegExp(r'invalid argument', caseSensitive: false),
  ];

  EngineStatus handle(EngineEvent event) {
    switch (event) {
      case StartRequested():
        _wantRunning = true;
        _state = const EngineStatus(EnginePhase.launching);
      case StopRequested():
        _wantRunning = false;
        _state = const EngineStatus(EnginePhase.draining);
      case LogLineEvent(:final line):
        _state = _onLog(line);
      case ProcessExitedEvent(:final code):
        if (!_wantRunning) {
          _state = const EngineStatus(EnginePhase.stopped);
        } else {
          _state = EngineStatus(EnginePhase.error, error: '进程意外退出 code=$code');
        }
      case HealthOkEvent():
        if (_state.phase == EnginePhase.launching ||
            _state.phase == EnginePhase.compiling ||
            _state.phase == EnginePhase.warming) {
          _state = const EngineStatus(EnginePhase.ready);
        }
      case CrashDetectedEvent(:final reason):
        _state = EngineStatus(EnginePhase.error, error: reason);
    }
    return _state;
  }

  EngineStatus _onLog(String line) {
    // ready 之后日志不再回退状态（生成期也有各种 INFO 行）。
    if (_state.phase == EnginePhase.ready || _state.phase == EnginePhase.stopped) {
      return _state;
    }
    for (final re in _errorRes) {
      if (re.hasMatch(line)) {
        return EngineStatus(EnginePhase.error, error: line.trim());
      }
    }
    if (_compileRe.hasMatch(line)) {
      return const EngineStatus(EnginePhase.compiling);
    }
    if (_warmingRe.hasMatch(line)) {
      return const EngineStatus(EnginePhase.warming);
    }
    return _state;
  }
}

/// 引擎日志行（host 转发 UI，设计 §4.2 日志驱动进度）。
class EngineLogLine {
  EngineLogLine(this.ts, this.text);
  final DateTime ts;
  final String text;

  factory EngineLogLine.now(String text) => EngineLogLine(DateTime.now(), text);
}

DateTime nowUtc() => DateTime.now().toUtc();
