// T2.2/T2.4 WakeSession 单测（纯状态机，无浮层/无 widget pump——浮条层交给
// 人工验收，这里的三个口径必须钉死）：D2 自动发送（缓冲可取消）/手动确认/
// 空稿不交付/abort 不交稿/会话互斥。缓冲毫秒级注入 + 真时钟（几十 ms 级）。
import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:wangcai/asr/sherpa_streaming_asr.dart';
import 'package:wangcai/voice/voice_service.dart';
import 'package:wangcai/voice/wake_session.dart';

import 'voice_service_test.dart' show FakeCapture, FakeGate;

void main() {
  late VoiceService svc;
  late FakeCapture Function() engine;
  late FakeGate gate;
  late List<(String, bool)> delivered;
  int endedCount = 0;
  final buffer = const Duration(milliseconds: 30);
  String fakeFinalText = '终稿文本';

  setUp(() {
    final engines = <FakeCapture>[];
    gate = FakeGate();
    svc = VoiceService(
      captureFactory: (en, scene) async {
        final e = FakeCapture()..finalText = fakeFinalText;
        engines.add(e);
        return e;
      },
      gate: gate,
      enhancedLoader: () async => false,
      wakeIdleTimeout: const Duration(seconds: 60),
      maxUtterance: const Duration(seconds: 600),
    );
    engine = () => engines.last;
    delivered = [];
    endedCount = 0;
  });

  tearDown(() {
    VoiceService.instanceForTest = null;
    SherpaStreamingAsr.pcmTap = null;
  });

  WakeSession makeSession({bool autoSend = true, int noInputSec = 60}) =>
      WakeSession(
        onDeliver: (text, send) async => delivered.add((text, send)),
        onEnded: () => endedCount++,
        autoSend: autoSend,
        noInputSec: noInputSec,
        maxInputSec: 600,
        autoSendBuffer: buffer,
      );

  Future<WakeSession> startSession({bool autoSend = true}) async {
    final session = makeSession(autoSend: autoSend);
    final ok = await session.start(null); // 无浮条（纯状态机）
    expect(ok, isTrue);
    expect(session.active, isTrue);
    return session;
  }

  Future<void> waitBuffer() =>
      Future<void>.delayed(buffer + const Duration(milliseconds: 60));

  test('D2 自动发送：定稿 → 缓冲 → 交付 (text, send=true)', () async {
    VoiceService.instanceForTest = svc;
    final session = await startSession();
    engine().finalText = '帮我看下内存占用';
    await session.stop(); // 正常结束 → final 事件 → D2 缓冲
    // finalTexts 是 broadcast（非 sync）——事件微任务派发晚于 stop 恢复，
    // 断言前排空微任务队列。
    await pumpEventQueue();
    expect(session.finalized.value, '帮我看下内存占用');
    expect(delivered, isEmpty, reason: '缓冲期内不交付');
    await waitBuffer();
    expect(delivered, hasLength(1));
    expect(delivered.single.$1, '帮我看下内存占用');
    expect(delivered.single.$2, isTrue, reason: 'D2 自动发送');
    expect(endedCount, 1, reason: '收尾通知宿主');
    expect(session.active, isFalse);
  });

  test('D2 关闭：定稿直接进输入框（send=false），无缓冲', () async {
    VoiceService.instanceForTest = svc;
    final session = await startSession(autoSend: false);
    engine().finalText = '手动确认口径';
    await session.stop();
    await pumpEventQueue();
    expect(session.autoSendCountdown.value, 0);
    expect(delivered.single, ('手动确认口径', false));
    expect(endedCount, 1);
  });

  test('缓冲期点取消：不发送，定稿回输入框（send=false）', () async {
    VoiceService.instanceForTest = svc;
    final session = await startSession();
    engine().finalText = '差点发出去';
    await session.stop();
    await pumpEventQueue();
    session.cancelAutoSend();
    expect(delivered.single, ('差点发出去', false));
    await waitBuffer();
    expect(delivered, hasLength(1), reason: '取消后不再自动发');
    expect(endedCount, 1);
  });

  test('空稿二段式（T2.3）：首空稿自动重开一次麦，再空稿才收尾', () async {
    VoiceService.instanceForTest = svc;
    fakeFinalText = ''; // 两轮引擎都吐空稿
    final session = makeSession(noInputSec: 1); // 两轮都走 idle 自动收尾
    final ok = await session.start(null);
    expect(ok, isTrue);
    // 第一轮：无输入 → idle 1s 自动 endCapture → 空稿 → 自动重开。
    await Future<void>.delayed(const Duration(milliseconds: 1400));
    await pumpEventQueue();
    expect(session.autoSendCountdown.value, -2, reason: '「没听清」重试提示态');
    expect(session.active, isTrue, reason: '会话未结束，麦已重开');
    expect(session.finalized.value, isEmpty);
    expect(delivered, isEmpty);
    // 第二轮：仍无输入 → 空稿 → 「未识别到内容」收尾。
    await Future<void>.delayed(const Duration(milliseconds: 1400));
    await waitBuffer();
    expect(endedCount, 1, reason: '二段式走完才收尾');
    expect(session.active, isFalse);
    expect(delivered, isEmpty);
  });

  test('重试重开后 partial 到达 → 回聆听态，定稿照常走 D2', () async {
    VoiceService.instanceForTest = svc;
    fakeFinalText = ''; // 第一轮空稿触发重试
    final session = makeSession(noInputSec: 1);
    await session.start(null);
    await Future<void>.delayed(const Duration(milliseconds: 1400));
    await pumpEventQueue();
    expect(session.autoSendCountdown.value, -2);
    engine().emit('这次说出来了'); // 重开的那路麦
    await pumpEventQueue();
    expect(session.autoSendCountdown.value, 0, reason: 'partial 到达回聆听态');
    engine().finalText = '这次说出来了';
    await session.stop();
    await pumpEventQueue();
    await waitBuffer();
    expect(delivered.single, ('这次说出来了', true), reason: 'D2 语义不受重试影响');
    expect(endedCount, 1);
  });

  test('重试期用户喊停：立即收尾，不再重试也不再重开', () async {
    VoiceService.instanceForTest = svc;
    fakeFinalText = ''; // 空稿触发重试后喊停
    final session = makeSession(noInputSec: 1);
    await session.start(null);
    await Future<void>.delayed(const Duration(milliseconds: 1400));
    await pumpEventQueue();
    expect(session.autoSendCountdown.value, -2);
    await session.stop(); // 提示态 -2 下用户喊停
    await pumpEventQueue();
    expect(session.active, isFalse);
    expect(endedCount, 1);
    expect(delivered, isEmpty);
    await Future<void>.delayed(const Duration(milliseconds: 300));
    expect(session.active, isFalse, reason: '喊停后不得暗中复活');
  });

  test('D2 重说：丢稿再开一轮（麦重开），新稿照常自动发送', () async {
    VoiceService.instanceForTest = svc;
    final session = await startSession();
    engine().finalText = '第一版稿子';
    await session.stop();
    await pumpEventQueue();
    expect(delivered, isEmpty, reason: '缓冲期内不交付');
    expect(session.finalized.value, '第一版稿子');
    await session.retry(); // 重说（30ms 缓冲注入下倒计时显示为 0，不断言刻度）
    await pumpEventQueue();
    expect(session.active, isTrue, reason: '浮条留在聆听态');
    expect(session.autoSendCountdown.value, 0);
    expect(session.finalized.value, isEmpty, reason: '旧稿已丢');
    expect(delivered, isEmpty);
    expect(engine().starts, greaterThanOrEqualTo(1), reason: '麦已重开');
    engine().finalText = '重说的新稿';
    await session.stop();
    await pumpEventQueue();
    await waitBuffer();
    expect(delivered.single, ('重说的新稿', true));
    expect(endedCount, 1);
  });

  test('abort：会话取消、不交付任何文本', () async {
    VoiceService.instanceForTest = svc;
    final session = await startSession();
    engine().finalText = '不该出现';
    await session.abort();
    await waitBuffer();
    expect(delivered, isEmpty);
    expect(session.active, isFalse);
    expect(gate.active, isFalse);
  });

  test('会话互斥：进行中再 start 被拒（门面语义穿透到场景层）', () async {
    VoiceService.instanceForTest = svc;
    final first = await startSession();
    final second = makeSession();
    final ok = await second.start(null);
    expect(ok, isFalse, reason: '门面会话互斥');
    expect(second.active, isFalse);
    expect(first.active, isTrue);
    await first.abort();
  });
}
