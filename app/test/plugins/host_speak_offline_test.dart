// 离线朗读（P7）的行为钉死。
//
// 这块要证明的不是"多了个引擎"，而是**能力可替换**这件事真的成立：
// 多出来那份 `app.speak` 以 priority -1 注册，它 unavailable 时注册表自动浮回 Edge 那份，
// 插件侧一行代码都不用改。测试必须覆盖"没模型 / 有模型 / 卸载后回退"三个时刻，
// 缺一个就可能变成"离线实现悄悄把在线那份饿死"或者"离线根本没生效"。
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:plugin_kernel/plugin_kernel.dart';
import 'package:tongyi_lite/plugins/host/host_speak.dart';
import 'package:tongyi_lite/plugins/host/host_speak_offline.dart';
import 'package:tongyi_lite/tts/offline_tts_service.dart';

/// 在线端口假件：负责播控 + 在线合成，所有调用留痕（"播放只有一份实现"就靠它验）。
class _OnlinePort implements TtsPlaybackPort {
  _OnlinePort({this.succeed = true});
  final bool succeed;
  final List<String> calls = [];
  int began = 0;
  int ended = 0;
  int stopped = 0;
  final Directory dir = Directory.systemTemp.createTempSync('online_clip');
  int _seq = 0;

  @override
  Future<int> begin(String key) async {
    began++;
    calls.add('begin');
    return ++_seq;
  }

  @override
  bool isCurrent(int seq) => true;

  @override
  void end(int seq) {
    ended++;
    calls.add('end');
  }

  @override
  Future<void> stop() async {
    stopped++;
    calls.add('stop');
  }

  @override
  Future<TtsClip?> synthesize(String text,
      {required String voice, required int rate, required int pitch, required int volume}) async {
    calls.add('synth:$text');
    if (!succeed) return null;
    final f = File('${dir.path}/online_${text.hashCode}.wav');
    if (!f.existsSync()) f.writeAsBytesSync([1, 2, 3]);
    return TtsClip(text, f);
  }

  @override
  Future<bool> play(int seq, TtsClip clip) async {
    calls.add('play:${clip.text}');
    return true;
  }

  @override
  String? get lastFailureMessage => succeed ? null : '在线合成没成';

  @override
  bool get ready => true;

  @override
  String? get notReadyReason => null;
}

class _FakeBackend implements OfflineTtsBackend {
  _FakeBackend({this.ready = true, this.succeed = true, this.reason});
  bool ready;
  bool succeed;
  String? reason;
  String? lastFail;
  final List<String> calls = [];
  final Directory dir = Directory.systemTemp.createTempSync('offline_clip');

  @override
  String? get notReadyReason => reason;

  @override
  bool supports(String text) => !RegExp(r'[一-鿿]').hasMatch(text) && RegExp(r'[A-Za-z]').hasMatch(text);

  @override
  Future<File?> synthesizeToFile(String text, {required String voice, required int rate}) async {
    calls.add('offline:$text');
    if (!succeed) {
      lastFail = '离线引擎坏了';
      return null;
    }
    final f = File('${dir.path}/offline_$text.wav');
    if (!f.existsSync()) f.writeAsBytesSync([4, 5, 6]);
    return f;
  }

  @override
  String? get lastFailureMessage => lastFail;
}

class _FakeEngine implements OfflineTtsEngine {
  _FakeEngine({this.throwOnLoad = false, this.throwOnSynth = false, this.sampleRate = 22050});
  final bool throwOnLoad;
  final bool throwOnSynth;
  final int sampleRate;
  int loads = 0;
  final List<String> synthesized = [];

  @override
  Future<void> load() async {
    loads++;
    if (throwOnLoad) throw Exception('模型文件坏了');
  }

  @override
  Future<OfflinePcm> pcm16(String text, {required int speakerId, required double speed}) async {
    synthesized.add('$text@$speed');
    if (throwOnSynth) throw Exception('引擎炸了');
    return OfflinePcm(Uint8List.fromList(List.filled(8, 7)), sampleRate);
  }

  @override
  Future<void> dispose() async {}
}

/// 取成功值；失败就把失败内容原样报出来（测试里"悄悄吞掉失败"是最坏的一种假通过）。
T _must<T>(Outcome<T> o) {
  expect(o.isOk, isTrue, reason: o.toString());
  return (o as Ok<T>).value;
}

HostSpeak speakOf(TtsPlaybackPort port) => HostSpeak(
      port,
      resolveVoice: (s) => RegExp(r'[一-鿿]').hasMatch(s) ? 'zh-CN-XiaoxiaoNeural' : 'en-US-AriaNeural',
      levels: () => const TtsLevels(rate: 0, pitch: 0, volume: 100),
    );

void main() {
  late Directory tmp;
  setUp(() => tmp = Directory.systemTemp.createTempSync('offline_tts'));
  tearDown(() {
    if (tmp.existsSync()) tmp.deleteSync(recursive: true);
  });

  String modelDir({bool complete = true}) {
    final d = '${tmp.path}/vits-en';
    Directory(d).createSync(recursive: true);
    if (complete) {
      File('$d/model.onnx').writeAsBytesSync([0]);
      File('$d/tokens.txt').writeAsStringSync('a\nb\n');
      Directory('$d/espeak-ng-data').createSync();
    } else {
      File('$d/model.onnx').writeAsBytesSync([0]); // 缺 tokens.txt
    }
    return d;
  }

  group('能力可替换（注册表这一层）', () {
    test('没放模型：离线那份 available=false，注册表自动用回 Edge（插件零改动）', () {
      final registry = CapabilityRegistry();
      final edge = speakOf(_OnlinePort());
      final offline = speakOf(OfflineTtsPort(
        backend: OfflineTtsBackendFromService(
            OfflineTtsService(modelDir: modelDir(complete: false), engineFactory: (_) => _FakeEngine())),
        fallback: _OnlinePort(),
      ));
      registry.register(edge, ownerPluginId: 'app');
      final disposer = _must(registry.register(offline, ownerPluginId: 'app', priority: -1));

      expect(offline.available, isFalse, reason: '模型没就位就必须说false，不许谎报ready');
      expect(offline.unavailableReason, contains('ApplicationSupport/tts'), reason: '不ready要给出路');
      expect(_must(registry.resolve(ServiceKeys.speak)), same(edge), reason: '注册表自己会浮回在线那份');
      disposer();
    });

    test('放了模型：离线那份赢；把它卸掉又自动浮回 Edge（完整闭环）', () async {
      final registry = CapabilityRegistry();
      final edge = speakOf(_OnlinePort());
      final offline = speakOf(OfflineTtsPort(
        backend: OfflineTtsBackendFromService(
            OfflineTtsService(modelDir: modelDir(), engineFactory: (_) => _FakeEngine())),
        fallback: _OnlinePort(),
      ));
      registry.register(edge, ownerPluginId: 'app');
      final disposer = _must(registry.register(offline, ownerPluginId: 'app', priority: -1));

      expect(_must(registry.resolve(ServiceKeys.speak)), same(offline), reason: 'priority 更小的赢');
      await disposer();
      expect(_must(registry.resolve(ServiceKeys.speak)), same(edge), reason: '卸载后被遮蔽者自动浮回，不是"没有能力了"');
    });
  });

  group('逐条选路（端口这一层）', () {
    test('英文单词走离线，一次都不碰在线', () async {
      final online = _OnlinePort();
      final backend = _FakeBackend();
      final port = OfflineTtsPort(backend: backend, fallback: online);

      final clip = await port.synthesize('apple', voice: 'v', rate: 0, pitch: 0, volume: 100);
      expect(clip, isNotNull);
      expect(backend.calls, ['offline:apple']);
      expect(online.calls, isEmpty, reason: '断网也能念 —— 这条路径压根没上网络');
    });

    test('中文条目交给在线（英文模型念中文不报错、只是念不成形，比不念更糟）', () async {
      final online = _OnlinePort();
      final backend = _FakeBackend();
      final port = OfflineTtsPort(backend: backend, fallback: online);

      await port.synthesize('生字表', voice: 'v', rate: 0, pitch: 0, volume: 100);
      expect(backend.calls, isEmpty);
      expect(online.calls, ['synth:生字表']);
    });

    test('离线没念成 → 继续试在线；两条都不成才报失败', () async {
      final online = _OnlinePort();
      final backend = _FakeBackend(succeed: false);
      final port = OfflineTtsPort(backend: backend, fallback: online);

      final clip = await port.synthesize('apple', voice: 'v', rate: 0, pitch: 0, volume: 100);
      expect(clip, isNotNull, reason: '离线坏了不许让这一条消失，得回落到在线');
      expect(port.lastFailureMessage, contains('离线'));

      final deadOnline = _OnlinePort(succeed: false);
      final dead = OfflineTtsPort(backend: _FakeBackend(succeed: false), fallback: deadOnline);
      expect(await dead.synthesize('apple', voice: 'v', rate: 0, pitch: 0, volume: 100), isNull);
      expect(dead.lastFailureMessage, '在线合成没成');
    });

    test('后端说自己不 ready：逐条一律走在线，离线一次都不问', () async {
      final online = _OnlinePort();
      final backend = _FakeBackend(ready: false, reason: '模型没就位');
      final port = OfflineTtsPort(backend: backend, fallback: online);
      expect(port.ready, isFalse, reason: '可用性只说离线自己，好让注册表去选另一份');
      final clip = await port.synthesize('apple', voice: 'v', rate: 0, pitch: 0, volume: 100);
      expect(clip, isNotNull, reason: '不 ready 不等于念不出来，回落在线照样有声音');
      expect(backend.calls, isEmpty);
      expect(port.notReadyReason, '模型没就位');
    });

    test('播控只有一份实现：begin/end/stop/play 全落在线端口', () async {
      final online = _OnlinePort();
      final port = OfflineTtsPort(backend: _FakeBackend(), fallback: online);
      final seq = await port.begin('plugin:speak');
      await port.play(seq, const TtsClip('apple', 'handle'));
      await port.stop();
      port.end(seq);
      expect(online.began, 1);
      expect(online.ended, 1);
      expect(online.stopped, 1);
      expect(online.calls, contains('play:apple'));
    });

    test('HostSpeak 配离线端口：整场听写事件齐、间隔照走、取消当场停', () async {
      final online = _OnlinePort();
      final cap = speakOf(OfflineTtsPort(backend: _FakeBackend(), fallback: online));
      final token = PluginCancelToken();
      final events = <SpeakProgress>[];
      await for (final e in cap.speak(
        const SpeakRequest(items: ['apple', '香蕉'], voice: '', gap: Duration(milliseconds: 5)),
        token,
      )) {
        events.add(e);
      }
      expect(events.map((e) => e.phase).toSet(), {
        SpeakPhase.synthesizing,
        SpeakPhase.playing,
        SpeakPhase.gap,
      });
      expect(online.calls, containsAllInOrder(['synth:香蕉', 'play:香蕉']));
      expect(online.ended, 1, reason: '播报位必须释放');
    });
  });

  group('服务层（模型 / 引擎 / WAV）', () {
    test('模型齐不齐只靠文件判断，不加载原生；缺 tokens 就不启用', () {
      final bad = OfflineTtsService(modelDir: modelDir(complete: false), engineFactory: (_) => _FakeEngine());
      expect(bad.modelPresent, isFalse);
      expect(bad.notReadyReason, contains('tokens.txt'));
      expect(bad.notReadyReason, contains('espeak-ng-data'), reason: '英文模型缺这个要提前说，别等崩');

      final good = OfflineTtsService(modelDir: modelDir(), engineFactory: (_) => _FakeEngine());
      expect(good.modelPresent, isTrue);
      expect(good.notReadyReason, isNull);
    });

    test('引擎抛异常绝不外抛：记账 + 返回 null，让"单条失败不掀桌"接得住', () async {
      final svc = OfflineTtsService(
          modelDir: modelDir(), engineFactory: (_) => _FakeEngine(throwOnSynth: true));
      expect(await svc.synthesizeToFile('apple', voice: 'v', rate: 0), isNull);
      expect(svc.lastFailureMessage, contains('离线朗读没念成'));

      final brokenLoad = OfflineTtsService(
          modelDir: modelDir(), engineFactory: (_) => _FakeEngine(throwOnLoad: true));
      expect(await brokenLoad.synthesizeToFile('apple', voice: 'v', rate: 0), isNull);
      expect(brokenLoad.lastFailureMessage, contains('模型文件坏了'));
    });

    test('同一条只合成一次（缓存命中不再进引擎）；语速不同算两条', () async {
      final engine = _FakeEngine();
      final svc = OfflineTtsService(modelDir: modelDir(), engineFactory: (_) => engine);
      await svc.synthesizeToFile('apple', voice: 'v', rate: 0);
      await svc.synthesizeToFile('apple', voice: 'v', rate: 0);
      expect(engine.synthesized.length, 1);
      await svc.synthesizeToFile('apple', voice: 'v', rate: 60);
      expect(engine.synthesized.length, 2, reason: '语速变了必须重合成，否则用户调语速没反应');
      expect(engine.synthesized.last, endsWith('@1.6'));
    });

    test('WAV 用的是**这段音频自己的**采样率（模型有 16k 有 22.05k，写错就是变调）', () async {
      final svc = OfflineTtsService(
          modelDir: modelDir(), engineFactory: (_) => _FakeEngine(sampleRate: 16000));
      final f = await svc.synthesizeToFile('apple', voice: 'v', rate: 0);
      final bytes = await f!.readAsBytes();
      expect(ByteData.sublistView(bytes).getUint32(24, Endian.little), 16000);
    });

    test('WAV 头写对（裸 PCM 播不出来，采样率写错就是变调）', () {
      final wav = wavFromPcm16(Uint8List.fromList(List.filled(4, 9)), sampleRate: 22050);
      expect(String.fromCharCodes(wav.sublist(0, 4)), 'RIFF');
      expect(String.fromCharCodes(wav.sublist(8, 12)), 'WAVE');
      expect(String.fromCharCodes(wav.sublist(36, 40)), 'data');
      expect(wav.length, 48);
      final bd = ByteData.sublistView(wav);
      expect(bd.getUint32(24, Endian.little), 22050);
      expect(bd.getUint32(4, Endian.little), 36 + 4);
      expect(bd.getUint16(34, Endian.little), 16);
    });

    test('语速换算单调且夹在 0.5–2.0（Edge 的 -100..100 与引擎倍率对齐）', () {
      expect(speedFromRate(0), 1.0);
      expect(speedFromRate(-100), lessThan(speedFromRate(0)));
      expect(speedFromRate(100), greaterThan(speedFromRate(0)));
      expect(speedFromRate(-9999), 0.5);
      expect(speedFromRate(9999), 2.0);
    });

    test('哪些文本离线接：只接含字母且不含汉字的', () {
      final svc = OfflineTtsService(modelDir: modelDir(), engineFactory: (_) => _FakeEngine());
      expect(svc.supports('apple'), isTrue);
      expect(svc.supports('Apple banana'), isTrue);
      expect(svc.supports('苹果'), isFalse);
      expect(svc.supports('apple 苹果'), isFalse, reason: '混排里离线念整条会念错，整条交给在线');
      expect(svc.supports('123'), isFalse);
      expect(svc.supports('   '), isFalse);
    });
  });
}
