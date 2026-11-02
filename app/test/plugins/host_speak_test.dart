// app.speak 宿主适配器的行为钉死（听写插件的命根子都在这几条上）。
//
// 用 `flutter test test/plugins` 跑。端口是假的（不起 audioplayers），
// 钉的是**编排语义**：间隔只在条与条之间、单条失败不掀桌、取消真停、
// 中英混排各走各的音色。
import 'package:flutter_test/flutter_test.dart';
import 'package:plugin_sdk/plugin_sdk.dart';
import 'package:tongyi_lite/plugins/host/host_speak.dart';

class _FakePort implements TtsPlaybackPort {
  _FakePort({this.failOn = const {}, this.dieAfter = -1});

  final Set<String> failOn;

  /// 播了这么多次之后，判定"被新播报顶掉"（模拟用户切走）。
  final int dieAfter;

  final List<String> synthesized = [];
  final List<String> played = [];
  final List<String> began = [];
  int ended = 0;
  bool stopped = false;
  int _seq = 0;

  @override
  Future<int> begin(String key) async {
    began.add(key);
    return ++_seq;
  }

  @override
  bool isCurrent(int seq) =>
      seq == _seq && (dieAfter < 0 ? true : played.length < dieAfter);

  @override
  void end(int seq) => ended++;

  @override
  Future<void> stop() async => stopped = true;

  @override
  Future<TtsClip?> synthesize(String text,
      {required String voice, required int rate, required int pitch, required int volume}) async {
    synthesized.add('$text@$voice');
    if (failOn.contains(text)) return null;
    return TtsClip(text, text);
  }

  @override
  Future<bool> play(int seq, TtsClip clip) async {
    played.add(clip.text);
    return isCurrent(seq);
  }

  @override
  String? get lastFailureMessage => '该音色对这段文本没有返回音频';

  @override
  bool get ready => true;

  @override
  String? get notReadyReason => null;
}

void main() {
  final token = PluginCancelToken();

  HostSpeak speakWith(_FakePort port, {String Function(String)? voice}) => HostSpeak(
        port,
        resolveVoice: voice ??
            ((sample) => RegExp(r'[一-鿿]').hasMatch(sample) ? 'zh-CN-XiaoxiaoNeural' : 'en-US-AriaNeural'),
        levels: () => const TtsLevels(rate: 0, pitch: 0, volume: 100),
      );

  Future<List<SpeakProgress>> collect(HostSpeak cap, List<String> items,
      {Duration gap = const Duration(milliseconds: 15), String voice = '', PluginCancelToken? tok}) async {
    final out = <SpeakProgress>[];
    await for (final p in cap.speak(
      SpeakRequest(items: items, voice: voice, gap: gap),
      tok ?? token,
    )) {
      out.add(p);
    }
    return out;
  }

  group('逐条朗读', () {
    test('间隔只发生在条与条之间：3 条只等 2 次，最后一条不空等', () async {
      final port = _FakePort();
      final events = await collect(speakWith(port), ['apple', 'banana', 'cherry']);
      expect(port.played, ['apple', 'banana', 'cherry']);
      expect(events.where((e) => e.phase == SpeakPhase.gap), hasLength(2),
          reason: '最后一条播完还等 5 秒 = 听写结束的多余等待');
      expect(events.where((e) => e.phase == SpeakPhase.playing), hasLength(3));
      expect(port.ended, 1, reason: '播报位必须收干净，否则输入区永远显示"正在播"');
    });

    test('单条合成失败只发 skipped，整场继续（读到第 8 个词网络抖一下不该作废）', () async {
      final port = _FakePort(failOn: {'banana'});
      final events = await collect(speakWith(port), ['apple', 'banana', 'cherry']);
      final skipped = events.where((e) => e.phase == SpeakPhase.skipped).toList();
      expect(skipped, hasLength(1));
      expect(skipped.single.text, 'banana');
      expect(skipped.single.error, isNotNull);
      expect(port.played, ['apple', 'cherry']);
    });

    test('条目按文本语言挑音色：英文词走英文音色，中文释义走中文音色', () async {
      final port = _FakePort();
      await collect(speakWith(port), ['apple', '苹果']);
      expect(port.synthesized, containsAll(<String>[
        'apple@en-US-AriaNeural',
        '苹果@zh-CN-XiaoxiaoNeural',
      ]));
    });

    test('插件显式给了音色就照办（宿主不越权）', () async {
      final port = _FakePort();
      await collect(speakWith(port), ['apple'], voice: 'en-GB-SoniaNeural');
      expect(port.synthesized, ['apple@en-GB-SoniaNeural']);
    });

    test('空条目被丢掉，不为空串联网合成', () async {
      final port = _FakePort();
      await collect(speakWith(port), ['  ', 'apple', '']);
      expect(port.synthesized, ['apple@en-US-AriaNeural']);
    });
  });

  group('取消与抢占', () {
    test('已取消的令牌：一条都不播（用户按了停止就不能再出声）', () async {
      final port = _FakePort();
      final tok = PluginCancelToken()..cancel('用户按了停止');
      final events = await collect(speakWith(port), ['apple', 'banana'], tok: tok);
      expect(events, isEmpty);
      expect(port.played, isEmpty);
      expect(port.ended, 1, reason: '即使一开局就被取消，播报位也要释放');
    });

    test('播到一半被新播报顶掉 → 当场收工，不再念下一条', () async {
      final port = _FakePort(dieAfter: 1); // 第一条播完就算"被顶掉"
      final events = await collect(speakWith(port), ['apple', 'banana', 'cherry']);
      expect(port.played, ['apple']);
      expect(events.where((e) => e.phase == SpeakPhase.playing), hasLength(1));
      expect(port.ended, 1);
    });

    test('stop() 透传到端口（输入区的停止按钮要能真的停住）', () async {
      final port = _FakePort();
      await speakWith(port).stop();
      expect(port.stopped, isTrue);
    });
  });

  group('预热', () {
    test('prewarm 把整批词预合成（听写开始前把音频落到缓存）', () async {
      final port = _FakePort();
      final ok = await speakWith(port).prewarm(['apple', 'banana'], 'en-US-AriaNeural');
      expect(ok, isTrue);
      expect(port.synthesized, ['apple@en-US-AriaNeural', 'banana@en-US-AriaNeural']);
    });

    test('预热有失败就返回 false（让 UI 说"部分词没预热上"，而不是假装成功）', () async {
      final port = _FakePort(failOn: {'banana'});
      expect(await speakWith(port).prewarm(['apple', 'banana'], ''), isFalse);
    });
  });

  test('能力自述：id 与可用性来自端口', () {
    final cap = speakWith(_FakePort());
    expect(cap.key.id, 'app.speak');
    expect(cap.available, isTrue);
    expect(cap.unavailableReason, isNull);
  });
}
