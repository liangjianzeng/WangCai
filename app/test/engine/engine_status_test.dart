// flutter_test 自带 EnginePhase（binding 内部用），hide 掉避免撞名。
import 'package:flutter_test/flutter_test.dart' hide EnginePhase;
import 'package:wangcai/engine/engine_status.dart';

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

    test('预热挂档：health 200 先进 prewarming，PrewarmDone 才 ready', () {
      final m = EngineStateMachine();
      m.handle(StartRequested());
      m.handle(PrewarmArmedEvent());
      m.handle(LogLineEvent('0.19 model loaded'));
      expect(m.handle(HealthOkEvent()).phase, EnginePhase.prewarming);
      // 预热期自家 completion 会刷编译行——不得把阶段倒拨回 compiling。
      expect(
          m.handle(LogLineEvent('ggml-openvino: compiling decode graph ...'))
              .phase,
          EnginePhase.prewarming);
      expect(m.handle(PrewarmDoneEvent()).phase, EnginePhase.ready);
    });

    test('未挂档 health 直达 ready（旧口径不回归）；prewarming 期错误词仍把关', () {
      final m = EngineStateMachine();
      m.handle(StartRequested());
      expect(m.handle(HealthOkEvent()).phase, EnginePhase.ready);

      final m2 = EngineStateMachine();
      m2.handle(StartRequested());
      m2.handle(PrewarmArmedEvent());
      m2.handle(HealthOkEvent());
      expect(
          m2.handle(LogLineEvent('ZE_RESULT_ERROR_OUT_OF_HOST_MEMORY warm崩'))
              .phase,
          EnginePhase.error);
    });

    test('StartRequested 重置挂档（同机复用时不串档）', () {
      final m = EngineStateMachine();
      m.handle(StartRequested());
      m.handle(PrewarmArmedEvent());
      m.handle(StartRequested());
      expect(m.prewarmArmed, isFalse);
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
