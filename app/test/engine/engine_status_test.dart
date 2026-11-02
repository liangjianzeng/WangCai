// flutter_test 自带 EnginePhase（binding 内部用），hide 掉避免撞名。
import 'package:flutter_test/flutter_test.dart' hide EnginePhase;
import 'package:tongyi_lite/engine/engine_status.dart';

void main() {
  group('EngineStateMachine', () {
    test('start→日志推进→health 全链路', () {
      final m = EngineStateMachine();
      expect(m.handle(StartRequested()).phase, EnginePhase.launching);
      expect(
          m.handle(LogLineEvent('ggml-openvino: compiling static graph ...')).phase,
          EnginePhase.compiling);
      expect(m.handle(LogLineEvent('0.19 model loaded')).phase, EnginePhase.warming);
      expect(m.handle(HealthOkEvent()).phase, EnginePhase.ready);
    });

    test('错误词表命中 → error（status.md 实测词）', () {
      for (final line in [
        'ZE_RESULT_ERROR_OUT_OF_HOST_MEMORY at pfnAppendGraphExecute',
        'ov::Exception: something',
        'error loading model: bad gguf',
        'Compute error on node 42',
        'invalid argument: -st',
      ]) {
        final m = EngineStateMachine();
        m.handle(StartRequested());
        expect(m.handle(LogLineEvent(line)).phase, EnginePhase.error,
            reason: line);
      }
    });

    test('ready 之后的日志不回退状态（生成期 INFO 无害）', () {
      final m = EngineStateMachine();
      m.handle(StartRequested());
      m.handle(HealthOkEvent());
      final s = m.handle(LogLineEvent('ZE_RESULT ... late log'));
      expect(s.phase, EnginePhase.ready);
    });

    test('意外退出=error；主动停止=stopped', () {
      final crash = EngineStateMachine();
      crash.handle(StartRequested());
      expect(crash.handle(ProcessExitedEvent(1)).phase, EnginePhase.error);

      final stop = EngineStateMachine();
      stop.handle(StartRequested());
      stop.handle(StopRequested());
      expect(stop.handle(ProcessExitedEvent(0)).phase, EnginePhase.stopped);
    });

    test('stopped 态 health/日志均不动', () {
      final m = EngineStateMachine();
      expect(m.handle(HealthOkEvent()).phase, EnginePhase.stopped);
    });
  });
}
