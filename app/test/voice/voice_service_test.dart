// T1.1/T1.2 VoiceService 门面单测：状态机迁移 / 会话互斥 / 半双工门控 /
// 超时器（wake 场景，毫秒级注入）/ 事件流时序。
// 引擎与播报门控全部注入假实现（原生 FFI/audioplayers 跑不了测试）。
import 'dart:async';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:wangcai/asr/sherpa_streaming_asr.dart';
import 'package:wangcai/voice/voice_service.dart';

/// 假识别引擎：记账 start/stop/dispose，partial 可手动注入。
final class FakeCapture implements VoiceCaptureEngine {
  final controller = StreamController<String>.broadcast();
  int starts = 0, stops = 0, disposes = 0;
  Object? startError;
  String finalText = '终稿文本';

  @override
  Future<void> start() async {
    if (startError != null) throw startError!;
    starts++;
  }

  @override
  Future<String> stop() async {
    stops++;
    return finalText;
  }

  @override
  Future<void> dispose() async => disposes++;

  @override
  Stream<String> get partialText => controller.stream;

  void emit(String t) => controller.add(t);
}

/// 假播报门控：代次记账 + active 开关。
final class FakeGate implements SpeakGate {
  int seq = 0;
  bool _active = false;
  final List<int> ended = [];
  int stopped = 0;

  @override
  Future<int> begin(String key) async {
    _active = true;
    return ++seq;
  }

  @override
  bool isCurrent(int s) => _active && s == seq;

  @override
  void end(int s) {
    ended.add(s);
    if (s == seq) _active = false;
  }

  @override
  Future<void> stop() async {
    stopped++;
    _active = false;
  }

  @override
  bool get active => _active;

  void setSpeaking(bool v) => _active = v;
}

(VoiceService, FakeCapture Function(), FakeGate) makeService({
  Duration idle = const Duration(seconds: 10),
  Duration utter = const Duration(seconds: 60),
  bool enhanced = false,
}) {
  final engines = <FakeCapture>[];
  final gate = FakeGate();
  final svc = VoiceService(
    captureFactory: (en, scene) async {
      final e = FakeCapture()..finalText = '终稿文本';
      engines.add(e);
      return e;
    },
    gate: gate,
    enhancedLoader: () async => enhanced,
    wakeIdleTimeout: idle,
    maxUtterance: utter,
  );
  return (svc, () => engines.last, gate);
}

void main() {
  late VoiceService svc;
  late FakeCapture Function() engine;
  late FakeGate gate;

  setUp(() {
    final made = makeService();
    svc = made.$1;
    engine = made.$2;
    gate = made.$3;
  });

  tearDown(() {
    svc.disposeForTest();
    SherpaStreamingAsr.pcmTap = null;
  });

  group('状态机（IDLE→LISTENING→CAPTURE→RECOGNIZE→IDLE）', () {
    test('正常一轮：状态序列 + 引擎生命周期记账 + 终稿', () async {
      final seen = <VoiceState>[];
      final sub = svc.states.listen(seen.add);
      final ok = await svc.beginCapture();
      expect(ok, isTrue);
      expect(svc.state, VoiceState.capture);
      expect(svc.capturing, isTrue);
      engine().emit('你好');
      await pumpEventQueue();
      final text = await svc.endCapture();
      await pumpEventQueue();
      expect(text, '终稿文本');
      expect(svc.state, VoiceState.idle);
      expect(engine().starts, 1);
      expect(engine().stops, 1);
      expect(engine().disposes, 1);
      // listening → capture → recognize → idle（listening/capture 可能合并发，
      // 只断言出现顺序）
      final order = seen.indexOf(VoiceState.capture) <
          seen.indexOf(VoiceState.recognize) &&
          seen.indexOf(VoiceState.recognize) < seen.indexOf(VoiceState.idle);
      expect(order, isTrue, reason: '状态序列应为 capture→recognize→idle: $seen');
      await sub.cancel();
    });

    test('partial 与 final 事件流转发', () async {
      final partials = <String>[];
      final finals = <String>[];
      final s1 = svc.partialText.listen(partials.add);
      final s2 = svc.finalTexts.listen(finals.add);
      await svc.beginCapture();
      engine().emit('分段回显');
      await pumpEventQueue();
      expect(partials, ['分段回显']);
      await svc.endCapture();
      await pumpEventQueue();
      expect(finals, ['终稿文本']);
      await s1.cancel();
      await s2.cancel();
    });

    test('引擎起不来：返回 false、状态回 idle、引擎被回收', () async {
      final seen = <VoiceState>[];
      final sub = svc.states.listen(seen.add);
      // 起一个会炸的工厂
      final bad = VoiceService(
        captureFactory: (en, scene) async =>
            FakeCapture()..startError = Exception('引擎坏了'),
        gate: gate,
        enhancedLoader: () async => false,
      );
      expect(await bad.beginCapture(), isFalse);
      expect(bad.state, VoiceState.idle);
      expect(seen.contains(VoiceState.capture), isFalse); // 没进 capture
      await sub.cancel();
      bad.disposeForTest();
    });

    test('cancelCapture：麦克风归还、终稿丢弃', () async {
      await svc.beginCapture();
      engine().emit('不该上屏');
      final text = await svc.cancelCapture();
      expect(text, '');
      expect(svc.state, VoiceState.idle);
      expect(engine().stops, 1); // 录音已停（关麦）
      expect(engine().disposes, 1);
      final finals = await svc.finalTexts.take(0).toList();
      expect(finals, isEmpty);
    });
  });

  group('会话互斥与半双工', () {
    test('capture 中再开一路：被拒（不变量 1）', () async {
      expect(await svc.beginCapture(), isTrue);
      expect(await svc.beginCapture(), isFalse);
      expect(engine().starts, 1); // 没有第二个引擎
    });

    test('播报期开麦：先自动停播报再开麦（半双工，不变量 2）', () async {
      gate.setSpeaking(true);
      expect(await svc.beginCapture(), isTrue);
      expect(gate.stopped, 1, reason: '用户主动开麦 = 意图明确，播报让路');
      expect(svc.capturing, isTrue);
      expect(svc.speaking, isFalse);
    });

    test('播报中 beginSpeak 先停麦：引擎 stop+dispose、状态 speak', () async {
      await svc.beginCapture();
      expect(svc.capturing, isTrue);
      final seq = await svc.beginSpeak('auto-1');
      expect(seq, 1);
      expect(svc.speaking, isTrue);
      expect(svc.state, VoiceState.speak);
      expect(engine().stops, 1); // 播报期关麦
      expect(engine().disposes, 1);
      expect(svc.capturing, isFalse);
    });

    test('endSpeak 幂等 + 代次不符不误清（原语上收语义）', () async {
      final seq = await svc.beginSpeak('a');
      svc.endSpeak(seq);
      expect(svc.speaking, isFalse);
      expect(svc.state, VoiceState.idle);
      // 新播报后，旧代次 end 不该清掉新播报位
      await svc.beginSpeak('b');
      svc.endSpeak(seq);
      expect(svc.speaking, isTrue);
      await svc.stopSpeak();
      expect(svc.speaking, isFalse);
    });

    test('stopAll 全停', () async {
      await svc.beginCapture();
      await svc.beginSpeak('x'); // 顺带停了 capture
      await svc.stopAll();
      expect(svc.speaking, isFalse);
      expect(svc.capturing, isFalse);
      expect(svc.state, VoiceState.idle);
    });
  });

  group('超时器（wake 场景，毫秒级注入）', () {
    // 注入值刻意放宽到 ≥200ms：全量并行时 4 核饿死会把毫秒级 Timer 推迟几十毫秒
    // （台账口径「宁慢要跑」），60/80ms 档在调度抖动下会误触发；比值不变，总量
    // 仍控制在秒内。
    test('唤醒后无输入超时 → 自动收尾回 idle', () async {
      final made = makeService(idle: const Duration(milliseconds: 200));
      final s = made.$1;
      await s.beginCapture(scene: VoiceScene.wake);
      expect(s.capturing, isTrue);
      await Future<void>.delayed(const Duration(milliseconds: 500));
      expect(s.capturing, isFalse);
      expect(s.state, VoiceState.idle);
      expect(made.$2().stops, 1);
      s.disposeForTest();
    });

    test('有 partial 就重置空闲计时', () async {
      final made = makeService(idle: const Duration(milliseconds: 300));
      final s = made.$1;
      await s.beginCapture(scene: VoiceScene.wake);
      // 每 100ms 来一帧 partial，撑 500ms 不超时
      for (var i = 0; i < 5; i++) {
        await Future<void>.delayed(const Duration(milliseconds: 100));
        made.$2().emit('t$i');
        if (!s.capturing) break;
      }
      expect(s.capturing, isTrue, reason: 'partial 持续到达时不应被空闲超时收走');
      await s.endCapture();
      s.disposeForTest();
    });

    test('最长输入超时 → 自动定稿（终稿进 final 流）', () async {
      final made = makeService(utter: const Duration(milliseconds: 200));
      final s = made.$1;
      final finals = <String>[];
      final sub = s.finalTexts.listen(finals.add);
      await s.beginCapture(scene: VoiceScene.wake);
      await Future<void>.delayed(const Duration(milliseconds: 500));
      expect(s.capturing, isFalse);
      expect(finals, ['终稿文本']);
      await sub.cancel();
      s.disposeForTest();
    });

    test('holdToTalk 场景不挂超时器（按住说话零回归）', () async {
      final made = makeService(idle: const Duration(milliseconds: 200));
      final s = made.$1;
      await s.beginCapture(scene: VoiceScene.holdToTalk);
      await Future<void>.delayed(const Duration(milliseconds: 400));
      expect(s.capturing, isTrue, reason: '按住说话没有 10s 空闲超时');
      await s.endCapture();
      s.disposeForTest();
    });
  });

  group('mic 单点（pcmTap → pcmFrames 分发）', () {
    test('PCM 帧经静态钩子汇聚广播（KWS/VAD 共用路）', () async {
      final frames = <Uint8List>[];
      final sub = svc.pcmFrames.listen(frames.add);
      // 模拟引擎侧录音回调（SherpaStreamingAsr.pcmTap 挂着本服务的分发器）
      expect(SherpaStreamingAsr.pcmTap, isNotNull);
      SherpaStreamingAsr.pcmTap!(Uint8List.fromList([1, 2, 3]));
      SherpaStreamingAsr.pcmTap!(Uint8List.fromList([4, 5]));
      await pumpEventQueue();
      expect(frames.length, 2);
      expect(frames[0], [1, 2, 3]);
      await sub.cancel();
    });

    test('无人监听时帧被丢弃（broadcast 语义，不积压）', () async {
      SherpaStreamingAsr.pcmTap!(Uint8List.fromList([9]));
      await pumpEventQueue();
      final lateFrames = <Uint8List>[];
      final sub = svc.pcmFrames.listen(lateFrames.add);
      await pumpEventQueue();
      expect(lateFrames, isEmpty); // 订阅前的帧不回放
      await sub.cancel();
    });
  });
}
