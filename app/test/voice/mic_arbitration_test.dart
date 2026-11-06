// T1.2 mic 仲裁单测：PCM 单路分发（多消费者同帧）、播报期半双工门控。
// 麦克风在 SherpaStreamingAsr 一处（平台通道约束），VoiceService 是唯一分发者。
import 'dart:async';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:wangcai/asr/sherpa_streaming_asr.dart';
import 'package:wangcai/voice/voice_service.dart';

import 'voice_service_test.dart' show FakeCapture, FakeGate;

void main() {
  late VoiceService svc;
  late FakeCapture Function() engine;
  late FakeGate gate;

  setUp(() {
    final gate2 = FakeGate();
    gate = gate2;
    final engines = <FakeCapture>[];
    svc = VoiceService(
      captureFactory: (en, scene) async {
        final e = FakeCapture();
        engines.add(e);
        return e;
      },
      gate: gate,
      enhancedLoader: () async => false,
    );
    engine = () => engines.last;
  });

  tearDown(() {
    svc.disposeForTest();
    SherpaStreamingAsr.pcmTap = null;
  });

  group('PCM 单路分发', () {
    test('多消费者（KWS+VAD+探针）同帧各得一份', () async {
      final kws = <Uint8List>[];
      final vad = <Uint8List>[];
      final probe = <Uint8List>[];
      final s1 = svc.pcmFrames.listen(kws.add);
      final s2 = svc.pcmFrames.listen(vad.add);
      final s3 = svc.pcmFrames.listen(probe.add);
      SherpaStreamingAsr.pcmTap!(Uint8List.fromList(List.filled(320, 7))); // 10ms@16k
      await pumpEventQueue();
      expect(kws.length, 1);
      expect(vad.length, 1);
      expect(probe.length, 1);
      expect(vad.single, kws.single);
      await s1.cancel();
      await s2.cancel();
      await s3.cancel();
    });

    test('PCM 与录音会话解耦：录音停了 tap 仍在（M3 常驻前提）', () async {
      final frames = <Uint8List>[];
      final sub = svc.pcmFrames.listen(frames.add);
      await svc.beginCapture();
      SherpaStreamingAsr.pcmTap!(Uint8List.fromList([1]));
      await pumpEventQueue();
      await svc.endCapture();
      SherpaStreamingAsr.pcmTap!(Uint8List.fromList([2])); // 录音停后仍分发
      await pumpEventQueue();
      expect(frames.length, 2);
      await sub.cancel();
    });
  });

  group('播报期半双工门控', () {
    test('speaking 时开麦：自动停播报再开麦（半双工）', () async {
      gate.setSpeaking(true);
      expect(svc.speaking, isTrue);
      expect(await svc.beginCapture(), isTrue);
      expect(gate.stopped, 1, reason: '播报让路，不留双声');
      expect(svc.capturing, isTrue);
    });

    test('stopSpeak 无条件停（遗留直调 Edge 的播报位也停得掉）', () async {
      gate.setSpeaking(true); // 模拟不经 beginSpeak 的遗留播报位
      await svc.stopSpeak();
      expect(gate.stopped, 1);
      expect(svc.speaking, isFalse);
    });

    test('capture 中 beginSpeak：先停麦再占播报位（不双开）', () async {
      await svc.beginCapture();
      expect(engine().starts, 1);
      await svc.beginSpeak('auto-conv');
      expect(engine().stops, 1, reason: '播报前必须归还麦克风');
      expect(svc.capturing, isFalse);
      expect(svc.speaking, isTrue);
    });
  });
}
