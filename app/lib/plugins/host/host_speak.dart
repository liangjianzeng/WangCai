/// 宿主接缝：把 `EdgeTtsService` 适配成平台的 `app.speak` 能力。
///
/// 为什么放 `lib/plugins/host/`（而不是 `lib/plugins/adapters/`）：这层天生要同时够到
/// 平台契约与宿主内部，架构门 B/C 只对 `host/**` 开了这个口子；`builtin/` 里的插件代码
/// 一律不许 import 宿主内部（见 `packages/plugin_kernel/test/architecture_test.dart`）。
///
/// 三条硬要求（听写场景全踩在上面）：
/// 1. **间隔由能力内部控制**（"播完再等 N 秒"），插件不许自己 sleep —— 否则双倍间隔；
/// 2. **取消要真停**：每个 await 复查令牌，且 `stop()` 当场把等待播放结束的循环放掉
///    （EdgeTtsService.stop 已补：audioplayers 被 stop 后不再回 onPlayerComplete）；
/// 3. **单条失败不掀桌**：某个词合成失败发 `skipped` 事件继续下一条，整场不中断。
library;

import 'dart:io';

import 'package:plugin_kernel/plugin_kernel.dart';

import '../../tts/edge_tts_service.dart';

/// 一条已合成好的音频（[handle] 对能力层不透明，端口自己认得）。
final class TtsClip {
  const TtsClip(this.text, this.handle);
  final String text;
  final Object handle;
}

/// 播报参数（取自设置，调用时现取，改设置立刻生效）。
final class TtsLevels {
  const TtsLevels({required this.rate, required this.pitch, required this.volume});
  final int rate;
  final int pitch;
  final int volume;
}

/// 窄播控端口：`HostSpeak` 只认这几件事，测试用假端口即可跑（不必起 audioplayers）。
abstract interface class TtsPlaybackPort {
  /// 开一场播报（内部保证"同时最多一个播报位"），返回本场代次。
  Future<int> begin(String key);
  bool isCurrent(int seq);
  void end(int seq);
  Future<void> stop();

  /// 合成一条（**必须命中缓存优先**）；失败返回 null，原因看 [lastFailureMessage]。
  Future<TtsClip?> synthesize(String text,
      {required String voice, required int rate, required int pitch, required int volume});

  /// 播一条到结束；被顶掉/停止 → false。
  Future<bool> play(int seq, TtsClip clip);

  String? get lastFailureMessage;

  /// 本机此刻能不能播（离线时给个准话，别等第一条失败才说）。
  bool get ready;
  String? get notReadyReason => null;
}

/// 真机端口：直连 `EdgeTtsService` 的通用播放原语。
final class EdgeTtsPort implements TtsPlaybackPort {
  EdgeTtsPort([EdgeTtsService? service]) : _injected = service;

  final EdgeTtsService? _injected;

  /// **构造时不碰单例**：`EdgeTtsService.instance` 会顺手建 `AudioPlayer`（订阅平台事件通道）。
  /// 能力实现在插件平台启动那一刻就被装配根构造，那时候不该有播放器、也不该有通道订阅；
  /// 等真要念第一条时再建 —— 顺带让"这份能力能不能用"这类判断保持零副作用（能力体检才能安全地跑）。
  late final EdgeTtsService _tts = _injected ?? EdgeTtsService.instance;

  @override
  Future<int> begin(String key) => _tts.beginPlayback(key);

  @override
  bool isCurrent(int seq) => _tts.isCurrentPlayback(seq);

  @override
  void end(int seq) => _tts.endPlayback(seq);

  @override
  Future<void> stop() => _tts.stop();

  @override
  Future<TtsClip?> synthesize(String text,
      {required String voice, required int rate, required int pitch, required int volume}) async {
    final file = await _tts.synthesizeCached(text,
        voice: voice, rate: rate, pitch: pitch, volume: volume);
    if (file == null) return null;
    return TtsClip(text, file);
  }

  @override
  Future<bool> play(int seq, TtsClip clip) => _tts.playCached(seq, clip.handle as File);

  @override
  String? get lastFailureMessage => _tts.lastFailure?.message;

  @override
  bool get ready => true; // Edge TTS 的可用性只能试出来；失败按条报（见上面第 3 条）。

  @override
  String? get notReadyReason => null;
}

/// `app.speak` 的宿主实现。
final class HostSpeak with CapabilityBase implements Speak {
  HostSpeak(
    this._port, {
    required String Function(String sample) resolveVoice,
    TtsLevels Function()? levels,
  })  : _resolveVoice = resolveVoice,
        _levels = levels ?? (() => const TtsLevels(rate: 0, pitch: 0, volume: 100));

  final TtsPlaybackPort _port;
  final String Function(String sample) _resolveVoice;
  final TtsLevels Function() _levels;

  @override
  final ServiceKey<Speak> key = ServiceKeys.speak;

  @override
  bool get available => _port.ready;

  @override
  String? get unavailableReason => _port.notReadyReason;

  @override
  Stream<SpeakProgress> speak(SpeakRequest request, PluginCancelToken cancelToken) async* {
    final levels = _levels();
    final items = [for (final t in request.items) t.trim()].where((t) => t.isNotEmpty).toList();
    if (items.isEmpty) return;
    final seq = await _port.begin('plugin:speak');
    try {
      for (var i = 0; i < items.length; i++) {
        if (cancelToken.isCancelled || !_port.isCurrent(seq)) return;
        final text = items[i];
        // 音色按**这一条**的文本决定：中英混排的听写里，英文条走英文音色，
        // 否则中文音色念 apple 会念成"阿婆"（听写场景不可接受）。
        final voice = request.voice.isNotEmpty ? request.voice : _resolveVoice(text);
        yield SpeakProgress(index: i, text: text, phase: SpeakPhase.synthesizing);
        final clip = await _port.synthesize(text,
            voice: voice, rate: levels.rate, pitch: levels.pitch, volume: levels.volume);
        if (cancelToken.isCancelled || !_port.isCurrent(seq)) return;
        if (clip == null) {
          // 单条失败继续下一条：听写读到第 8 个词网络抖一下，不该让整场作废。
          yield SpeakProgress(
            index: i,
            text: text,
            phase: SpeakPhase.skipped,
            error: _port.lastFailureMessage ?? '没能播报',
          );
          continue;
        }
        yield SpeakProgress(index: i, text: text, phase: SpeakPhase.playing);
        if (!await _port.play(seq, clip)) return;
        if (cancelToken.isCancelled || !_port.isCurrent(seq)) return;
        if (i < items.length - 1 && request.gap > Duration.zero) {
          yield SpeakProgress(index: i, text: text, phase: SpeakPhase.gap);
          // "播完再等 N 秒"就发生在这里：等的是间隔，不是合成时间。
          if (!await cancelToken.delay(request.gap)) return;
        }
      }
    } finally {
      _port.end(seq);
    }
  }

  @override
  Future<void> stop() => _port.stop();

  @override
  Future<bool> prewarm(List<String> texts, String voice) async {
    // 提前把音频落到缓存：听写开始前预热心生词，念的时候就不卡在网络上了。
    final levels = _levels();
    var allOk = true;
    for (final raw in texts.take(200)) {
      final text = raw.trim();
      if (text.isEmpty) continue;
      final clip = await _port.synthesize(text,
          voice: voice.isNotEmpty ? voice : _resolveVoice(text),
          rate: levels.rate,
          pitch: levels.pitch,
          volume: levels.volume);
      if (clip == null) allOk = false;
    }
    return allOk;
  }
}
