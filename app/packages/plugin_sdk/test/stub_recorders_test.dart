import 'package:plugin_sdk/testing.dart';
import 'package:test/test.dart';

/// 「桩会记」这件事本身要有测试。
///
/// `FakeCapability` 一族替作者记了三样东西：LLM 收到的 `userText`、ASR 收到的音频路径、
/// 以及带 tick 的调用流水（`callsSince` 是阶段化断言的唯一分段口）。
/// 以前**没有一条测试引用过它们** —— 于是"记了"只是承诺：真到听写实例出问题
/// （抽词 prompt 被聊天历史污染、一段音频被重复递给 ASR），断言根本写不出来。
void main() {
  group('假实现真的在记（桩会记不能只是承诺）', () {
    test('FakeLlmComplete 记下收到的 userText / systemPrompt', () async {
      final h = FakeCapabilityHarness();
      final llm = h.register(FakeLlmComplete(response: '{"items":[]}'));
      await llm.complete(systemPrompt: '你是教材识别器', userText: '课本原文：apple 苹果');
      expect(llm.lastUserText, '课本原文：apple 苹果',
          reason: '抽词 prompt 被聊天历史污染时，只有这个凭据能让测试红');
      expect(llm.lastSystemPrompt, contains('教材识别器'));

      final fresh = FakeLlmComplete();
      expect(fresh.lastUserText, isNull,
          reason: '没调用过却留着上一次的文本 —— 阶段化断言会指着上一条调用说事');
    });

    test('FakeTranscribe 记下 ASR 收到的是哪个文件', () async {
      final h = FakeCapabilityHarness();
      final asr = h.register(FakeTranscribe(text: 'apple'));
      final r = await asr.transcribe('/storage/emulated/0/TongYiLite/plugin_exports/en-dictation/seg-2.wav');
      expect(r.valueOrNull, 'apple');
      expect(asr.lastAudioPath, endsWith('en-dictation/seg-2.wav'),
          reason: '把上一段的音频路径递给这一条，是听写流程最容易犯的错，只有这个凭据能发现');
    });

    test('callsSince 按 tick 分段：只回这一段之后的调用', () async {
      final h = FakeCapabilityHarness();
      final llm = h.register(FakeLlmComplete());
      await llm.complete(systemPrompt: 's', userText: 'u1');
      h.tickForward(); // 作者推进时钟：下面这些调用属于"下一阶段"
      final mark = h.tick;
      await llm.complete(systemPrompt: 's', userText: 'u2');
      await llm.complete(systemPrompt: 's', userText: 'u3');

      expect(h.calls, hasLength(3), reason: '流水本身要全');
      final since = h.callsSince(mark);
      expect(since.map((c) => c.args['user']), ['u2', 'u3'],
          reason: '分段断言把"这一步到底调了什么"说清楚；把上一阶段的也算进来就等于没分段');
      expect(since.map((c) => c.tick).toSet(), {mark});
      expect(h.callsSince(mark).map((c) => c.method).toSet(), {'complete'});
    });
  });
}
