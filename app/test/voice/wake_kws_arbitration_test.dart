// M3 常驻唤醒仲裁单测（docs/voice-wakeup-min-spec.md §2）：
// KWS 命中→让麦+广播；识别/播报→抑制窗；结束→自动回待命；开关语义闭环。
// KWS 用假句柄（不碰 FFI/麦），仲裁逻辑全在 VoiceService，可全速跑。
import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:wangcai/asr/sherpa_streaming_asr.dart';
import 'package:wangcai/voice/voice_service.dart';

import 'voice_service_test.dart' show FakeCapture, FakeGate;

final class FakeKws implements KwsHandle {
  final StreamController<String> hitsCtrl = StreamController<String>.broadcast();
  bool mic = true;
  int pauses = 0;
  int resumes = 0;
  bool disposed = false;

  @override
  Stream<String> get hits => hitsCtrl.stream;
  @override
  bool get micOn => mic && !disposed;
  @override
  Future<void> pause() async {
    pauses++;
    mic = false;
  }

  @override
  Future<void> resume() async {
    if (disposed) return;
    resumes++;
    mic = true;
  }

  @override
  Future<void> dispose() async {
    disposed = true;
    mic = false;
  }

  void fire(String kw) => hitsCtrl.add(kw);
}

void main() {
  late FakeKws kws;
  late VoiceService svc;
  late FakeGate gate;

  // 工厂读**当前** kws 变量（用例中途替换句柄后，重新 start 拿新实例）。
  VoiceService buildService({bool factoryNull = false}) {
    final g = FakeGate();
    gate = g;
    return VoiceService(
      captureFactory: (en, scene) async => FakeCapture(),
      gate: g,
      enhancedLoader: () async => false,
      kwsFactory: factoryNull ? (_) async => null : (_) async => kws,
      wakeCue: () async {}, // 提示音钩子隔离（audioplayers 平台通道不进测试区）
    );
  }

  setUp(() {
    kws = FakeKws();
    svc = buildService();
  });

  tearDown(() {
    svc.disposeForTest();
    SherpaStreamingAsr.pcmTap = null;
  });

  group('起停与不就位', () {
    test('工厂返回 null（模型缺）→ false，wakeListening false', () async {
      final s2 = buildService(factoryNull: true);
      expect(await s2.startWakeListening(), isFalse);
      expect(s2.wakeListening, isFalse);
      s2.disposeForTest();
    });

    test('重复 start 幂等：旧句柄 dispose、新句柄接管', () async {
      expect(await svc.startWakeListening(), isTrue);
      final old = kws;
      kws = FakeKws();
      expect(await svc.startWakeListening(), isTrue);
      expect(old.disposed, isTrue);
      expect(svc.wakeListening, isTrue);
    });

    test('stopWakeListening：句柄 dispose、不再 wakeListening', () async {
      await svc.startWakeListening();
      await svc.stopWakeListening();
      expect(kws.disposed, isTrue);
      expect(svc.wakeListening, isFalse);
    });
  });

  group('命中路由（ARMED → 宿主）', () {
    test('命中 → wakeDetected 广播一次 + KWS 让麦', () async {
      await svc.startWakeListening();
      var detected = 0;
      final sub = svc.wakeDetected.listen((_) => detected++);
      kws.fire('汪柴');
      await pumpEventQueue();
      expect(detected, 1);
      expect(kws.micOn, isFalse, reason: '命中后让麦给唤醒会话');
      expect(kws.pauses, greaterThanOrEqualTo(1));
      await sub.cancel();
    });

    test('未 start 时 fire 无副作用', () async {
      var detected = 0;
      final sub = svc.wakeDetected.listen((_) => detected++);
      kws.fire('汪柴'); // 无订阅者绑定（句柄未接管）
      await pumpEventQueue();
      expect(detected, 0);
      await sub.cancel();
    });
  });

  group('抑制窗与麦仲裁（spec §2）', () {
    test('beginCapture → KWS 暂停；endCapture → 自动回待命', () async {
      await svc.startWakeListening();
      await svc.beginCapture(scene: VoiceScene.wake);
      expect(kws.micOn, isFalse);
      await svc.endCapture();
      await pumpEventQueue();
      expect(kws.micOn, isTrue, reason: '会话结束麦归还待命 KWS');
      expect(kws.resumes, greaterThanOrEqualTo(1));
    });

    test('beginSpeak → 播报期关 KWS；endSpeak → 回待命', () async {
      await svc.startWakeListening();
      final seq = await svc.beginSpeak('c1');
      expect(kws.micOn, isFalse, reason: 'KWS 抑制窗防自念自醒');
      svc.endSpeak(seq);
      await pumpEventQueue();
      expect(kws.micOn, isTrue);
    });

    test('stopSpeak → 回待命（无条件停也解除抑制）', () async {
      await svc.startWakeListening();
      await svc.beginSpeak('c1');
      await svc.stopSpeak();
      await pumpEventQueue();
      expect(kws.micOn, isTrue);
    });

    test('播报优先：会话收尾撞上播报期，KWS 不得回待命', () async {
      await svc.startWakeListening();
      await svc.beginSpeak('c1'); // 半双工自动停麦（无活动会话，no-op）
      final seq2 = await svc.beginSpeak('c2');
      await svc.endCapture(); // 无活动识别；resume 自检被播报挡下
      await pumpEventQueue();
      expect(kws.micOn, isFalse, reason: '播报期 KWS 必须保持关闭');
      svc.endSpeak(seq2);
      await pumpEventQueue();
      expect(kws.micOn, isTrue, reason: '播报真正结束才解除抑制');
    });

    test('stopWakeListening 后 endCapture 不再复活 KWS', () async {
      await svc.startWakeListening();
      await svc.beginCapture();
      await svc.stopWakeListening(); // 用户中途关掉常驻唤醒
      await svc.endCapture();
      await pumpEventQueue();
      expect(kws.micOn, isFalse);
      expect(svc.wakeListening, isFalse);
    });
  });
}
