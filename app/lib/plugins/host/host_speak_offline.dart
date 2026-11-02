/// `app.speak` 的**第二套实现**：离线英文朗读优先，其余仍走 Edge TTS。
///
/// 这一层存在的意义不是"多一个朗读引擎"，而是**验证能力可替换这件事**（方案 §5.0 第 5 条）：
/// 插件侧一行代码都不改，听写在断网时照样能念 —— 因为多出来的实现是以
/// `priority: -1` 注册进 `CapabilityRegistry` 的，它 `available == false`（没放模型）时
/// 注册表自动浮回 Edge TTS 那份。**"能不能用离线"变成运行时事实，而不是分支代码。**
///
/// 三条设计约束：
/// 1. **播放只有一份实现**：`begin/isCurrent/end/stop/play` 全部委托在线端口
///    （即 `EdgeTtsService` 的通用播控原语）。两条链路各自维护一套播放器，
///    "同时最多一个播报位"与"取消当场放掉间隔等待"就会各说一套 —— 那类 bug 最难查。
/// 2. **合成可以两条路**：离线模型是英文 VITS，中文/整句它接不了（更糟的是它不报错，
///    只是念不成形）—— 于是逐条问后端 `supports(text)`，不接的立刻交给在线端口，
///    后端合成失败也照样回落（"单条失败不掀桌"）。
/// 3. **`available` 只说离线自己的可用性**：模型没就位就说 false，让注册表去选另一份；
///    不许为了"看起来能用"而谎报 ready。
library;

import 'dart:io';

import 'package:flutter/foundation.dart';
import '../../tts/offline_tts_service.dart';
import 'host_speak.dart';

/// 离线后端的窄接口（`OfflineTtsService` 的实现见 [OfflineTtsBackendFromService]）。
///
/// 抽接口是为了能在 widget test 里跑：原生 FFI 在测试环境起不来，
/// 而"该走离线还是该回落在在线"这条决策逻辑恰恰是最需要钉住的部分。
abstract interface class OfflineTtsBackend {
  /// 模型就位且引擎可用 —— 决定这份实现要不要参与竞争。
  bool get ready;

  /// 不能说谎：不 ready 就要给出用户照着做的出路。
  String? get notReadyReason;

  /// 这段文本离线模型接不接（英文单词才接）。
  bool supports(String text);

  /// 合成一条到文件；失败返回 null（原因看 [lastFailureMessage]）。
  Future<File?> synthesizeToFile(String text, {required String voice, required int rate});

  String? get lastFailureMessage;
}

/// 真后端：直接包 [OfflineTtsService]。
final class OfflineTtsBackendFromService implements OfflineTtsBackend {
  OfflineTtsBackendFromService(this._service);
  final OfflineTtsService _service;

  @override
  bool get ready => _service.modelPresent && _service.lastFailureMessage == null;

  @override
  String? get notReadyReason => _service.notReadyReason;

  @override
  bool supports(String text) => _service.supports(text);

  @override
  Future<File?> synthesizeToFile(String text, {required String voice, required int rate}) =>
      _service.synthesizeToFile(text, voice: voice, rate: rate);

  @override
  String? get lastFailureMessage => _service.lastFailureMessage;
}

/// 离线优先端口：合成能离线就离线，播放永远只有一条路。
final class OfflineTtsPort implements TtsPlaybackPort {
  OfflineTtsPort({required OfflineTtsBackend backend, required TtsPlaybackPort fallback})
      : _backend = backend,
        _fallback = fallback;

  final OfflineTtsBackend _backend;
  final TtsPlaybackPort _fallback;

  String? _lastFailure;

  @override
  bool get ready => _backend.ready;

  @override
  String? get notReadyReason => _backend.notReadyReason;

  @override
  Future<int> begin(String key) => _fallback.begin(key);

  @override
  bool isCurrent(int seq) => _fallback.isCurrent(seq);

  @override
  void end(int seq) => _fallback.end(seq);

  @override
  Future<void> stop() => _fallback.stop();

  @override
  Future<bool> play(int seq, TtsClip clip) => _fallback.play(seq, clip);

  @override
  String? get lastFailureMessage => _lastFailure ?? _fallback.lastFailureMessage;

  @override
  Future<TtsClip?> synthesize(String text,
      {required String voice, required int rate, required int pitch, required int volume}) async {
    if (_backend.ready && _backend.supports(text)) {
      final file = await _backend.synthesizeToFile(text, voice: voice, rate: rate);
      if (file != null) {
        _lastFailure = null;
        return TtsClip(text, file);
      }
      // 离线没念成 **不是终局**：接着试在线。断网时这条会一起失败，
      // 那时才由 HostSpeak 发 skipped 事件（整场不许中断）。
      _lastFailure = _backend.lastFailureMessage ?? '离线朗读没念成，改走在线';
      debugPrint('[offline-tts] "$text" 回落在线：$_lastFailure');
    }
    final clip = await _fallback.synthesize(text, voice: voice, rate: rate, pitch: pitch, volume: volume);
    if (clip == null) _lastFailure = _fallback.lastFailureMessage ?? _lastFailure;
    return clip;
  }
}
