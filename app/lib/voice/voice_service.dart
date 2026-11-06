/// VoiceService：语音交互统一门面（ASR&TTS 重构 T1.1/T1.2）。
///
/// 母方案 §3 目标架构的门面层：四方消费者（按住说话 / 唤醒对话 / 插件听写 /
/// 自动朗读）**只准走这个门面**，门面之下是端口化的引擎——测试塞假端口，
/// 生产塞 SherpaStreamingAsr / EdgeTtsService（后续 matcha）。
///
/// 三条不变量（全部可单测，见 test/voice/）：
/// 1. **会话互斥**：同一时刻至多一路识别器在跑（母方案 §3「SenseVoice 与
///    流式并存不冲突」的落点），第二路 beginCapture 直接被拒；
/// 2. **半双工门控**：TTS 播报期关麦（beginCapture 被拒）、开新播报先停麦
///    （beginSpeak 内自动 endCapture）——「自己念自己醒」类事故的结构化防线；
///    播报位代次原语（beginPlayback/isCurrentPlayback/endPlayback，原
///    EdgeTtsService :371/:380/:383）**上收**到这里，播放器实现仍只有一份；
/// 3. **mic 单点**：录音机只在 SherpaStreamingAsr 一处（record 平台通道只能
///    在主 isolate 消费），PCM 帧经 [SherpaStreamingAsr.pcmTap] 汇聚到
///    [pcmFrames] 广播——M3 的 KWS/VAD 常驻共用这一路，不再各开各的麦。
///
/// 状态机：IDLE→LISTENING（加载引擎）→CAPTURE（录音中）→RECOGNIZE（收尾定稿）
/// →SPEAK（播报）→IDLE；事件流 [states]/[partialText]/[finalTexts]。
/// 超时器（唤醒后无输入 [wakeIdleTimeout]=10s、单次输入 [maxUtterance]=60s，
/// 母方案 §4.2）已就位，M1 只在 wake 场景启用（按住说话行为零回归）。
library;

import 'dart:async';
import 'dart:io';

import 'package:flutter/foundation.dart';

import '../asr/asr_settings.dart';
import '../asr/kws_engine.dart';
import '../asr/sensevoice_asr.dart';
import '../asr/sherpa_streaming_asr.dart';
import '../tts/edge_tts_service.dart';
import '../tts/offline_tts_service.dart';
import '../tts/tts_text.dart';
import 'wake_cue.dart';
import 'voice_model_manager.dart';
import 'voice_ports.dart';

export 'voice_ports.dart' show VoiceCaptureEngine, SpeakGate, KwsHandle;

/// KWS 工厂注入点（测试塞假句柄）：null = 生产 [_productionKws]。
/// 返回 null = 不就位（模型缺 / 唤醒词不支持），门面静默留痕。
typedef KwsHandleFactory = Future<KwsHandle?> Function(double threshold);

/// 会话状态（母方案 §3 状态机；post-process 不单列状态，挂在 RECOGNIZE 内）。
enum VoiceState { idle, listening, capture, recognize, speak }

/// 识别场景（决定超时器口径与引擎路由；见 [_productionCapture]）。
enum VoiceScene { holdToTalk, wake, plugin }

/// 引擎工厂注入点（测试塞假引擎）。[scene] 决定引擎路由（母方案 §4.1）。
typedef VoiceCaptureFactory = Future<VoiceCaptureEngine> Function(
    bool enhanced, VoiceScene scene);

/// 生产播报门控：薄薄一层转发 EdgeTtsService（唯一播放器实现所在）。
final class EdgeTtsSpeakGate implements SpeakGate {
  const EdgeTtsSpeakGate();
  @override
  Future<int> begin(String key) => EdgeTtsService.instance.beginPlayback(key);
  @override
  bool isCurrent(int seq) => EdgeTtsService.instance.isCurrentPlayback(seq);
  @override
  void end(int seq) => EdgeTtsService.instance.endPlayback(seq);
  @override
  Future<void> stop() => EdgeTtsService.instance.stop();
  @override
  bool get active => EdgeTtsService.instance.isPlaying;
}

class VoiceService {
  VoiceService({
    required VoiceCaptureFactory captureFactory,
    SpeakGate? gate,
    Future<bool> Function()? enhancedLoader,
    KwsHandleFactory? kwsFactory,
    Future<void> Function()? wakeCue,
    // 母方案 §4.2 默认口径（测试注入毫秒级驱动）
    this.wakeIdleTimeout = const Duration(seconds: 10),
    this.maxUtterance = const Duration(seconds: 60),
  })  : _captureFactory = captureFactory,
        _gateOverride = gate,
        _enhancedLoader = enhancedLoader ?? _defaultEnhancedLoader,
        _kwsFactory = kwsFactory,
        _wakeCue = wakeCue ?? WakeCue.play {
    // mic 单点：录音机留在引擎里，PCM 帧在此汇聚分发。
    SherpaStreamingAsr.pcmTap = _onFrame;
  }

  final VoiceCaptureFactory _captureFactory;
  SpeakGate? _gateOverride;
  final Future<bool> Function() _enhancedLoader;
  final KwsHandleFactory? _kwsFactory;

  /// ARMED 提示音钩子（生产 = [WakeCue.play]；测试注入 no-op——audioplayers
  /// 构造器会发**异步**平台通道异常，try/catch 拦不住，必须端口化隔离）。
  final Future<void> Function() _wakeCue;

  final Duration wakeIdleTimeout;
  final Duration maxUtterance;

  SpeakGate get _gate => _gateOverride ??= const EdgeTtsSpeakGate();

  // ---- 进程级单例（消费方走 [VoiceService.instance]）----

  static VoiceService? _instance;
  static VoiceService get instance => _instance ??= VoiceService(
        captureFactory: _productionCapture,
      );

  @visibleForTesting
  static set instanceForTest(VoiceService? s) {
    _instance = s;
    if (s == null) SherpaStreamingAsr.pcmTap = null;
  }

  // ---- 状态机与事件流 ----

  final ValueNotifier<VoiceState> _state = ValueNotifier(VoiceState.idle);
  VoiceState get state => _state.value;

  final StreamController<VoiceState> _stateCtrl =
      StreamController<VoiceState>.broadcast();
  Stream<VoiceState> get states => _stateCtrl.stream;

  final StreamController<String> _partialCtrl =
      StreamController<String>.broadcast();
  Stream<String> get partialText => _partialCtrl.stream;

  final StreamController<String> _finalCtrl =
      StreamController<String>.broadcast();
  Stream<String> get finalTexts => _finalCtrl.stream;

  void _setState(VoiceState s) {
    if (_state.value == s) return;
    _state.value = s;
    if (!_stateCtrl.isClosed) _stateCtrl.add(s);
  }

  // ---- mic 单点（PCM 分发）----

  final StreamController<Uint8List> _pcmCtrl =
      StreamController<Uint8List>.broadcast();

  /// 常驻 PCM 分发（16k mono PCM16）：KWS/VAD/测试探针共用；无人监听时
  /// broadcast 流直接丢弃帧（tap 照常挂，M3 常驻才有真订阅者）。
  Stream<Uint8List> get pcmFrames => _pcmCtrl.stream;

  void _onFrame(Uint8List bytes) {
    if (!_pcmCtrl.isClosed) _pcmCtrl.add(bytes);
  }

  // ---- M3 常驻唤醒 KWS（docs/voice-wakeup-min-spec.md）----

  KwsHandle? _kws;
  bool _wakeWanted = false;

  final StreamController<void> _wakeDetectedCtrl =
      StreamController<void>.broadcast();

  /// KWS 命中事件（宿主据此起 WakeSession；命中时麦已让出、提示音已放）。
  Stream<void> get wakeDetected => _wakeDetectedCtrl.stream;

  /// 唤醒待命麦是否在跑（托盘四色：ARMED=黄 的数据源）。
  final ValueNotifier<bool> wakeMicOn = ValueNotifier(false);

  bool get wakeListening => _kws?.micOn ?? false;

  /// 起常驻唤醒（spec §2 待命态）。false = 不就位（模型缺/加载失败/唤醒词
  /// 不支持——留痕不抛，UI 侧走模型下载引导）。[threshold] 由设置项映射：
  /// `clamp(1 - sensitivity, 0.1, 0.45)`（≥0.5 实测「汪柴」必漏，上限封死）。
  Future<bool> startWakeListening({double threshold = 0.25}) async {
    await stopWakeListening(); // 幂等重启（灵敏度变更也走这里）
    _wakeWanted = true;
    try {
      final kws = await (_kwsFactory ?? _productionKws)(threshold);
      if (kws == null) {
        debugPrint('[DSH][voice] wake listening: engine not available');
        _wakeWanted = false;
        return false;
      }
      _kws = kws;
      wakeMicOn.value = kws.micOn;
      kws.hits.listen((kw) {
        debugPrint('[DSH][voice] kws hit "$kw" → wake arm');
        _suspendKws('hit'); // 让麦：WakeSession 会开 SenseVoice 自己的麦
        unawaited(_wakeCue()); // spec §2 ARMED 短提示音
        if (!_wakeDetectedCtrl.isClosed) _wakeDetectedCtrl.add(null);
      });
      return true;
    } catch (e) {
      debugPrint('[DSH][voice] wake listening start failed: $e');
      _kws = null;
      _wakeWanted = false;
      wakeMicOn.value = false;
      return false;
    }
  }

  Future<void> stopWakeListening() async {
    _wakeWanted = false;
    final k = _kws;
    _kws = null;
    wakeMicOn.value = false;
    if (k != null) {
      try {
        await k.dispose();
      } catch (_) {}
    }
  }

  /// 会话/播报结束后重开待命麦（自检条件：唤醒仍开 && 无识别 && 无播报）。
  Future<void> resumeWakeListening() async {
    final k = _kws;
    if (!_wakeWanted || k == null || speaking || capturing) return;
    await k.resume();
    wakeMicOn.value = k.micOn;
  }

  /// 抑制窗（spec §2 KWS 抑制窗 + 麦仲裁统一入口，幂等）。
  void _suspendKws(String why) {
    final k = _kws;
    if (k == null || !k.micOn) return;
    debugPrint('[DSH][voice] kws suppressed ($why)');
    unawaited(k.pause().then((_) => wakeMicOn.value = k.micOn));
  }

  // ---- 识别会话 ----

  VoiceCaptureEngine? _engine;
  StreamSubscription<String>? _sub;
  VoiceScene _scene = VoiceScene.holdToTalk;
  Timer? _idleTimer;
  Timer? _utterTimer;

  /// 是否有一路识别在跑（含加载中/收尾中）。
  bool get capturing =>
      _state.value == VoiceState.listening ||
      _state.value == VoiceState.capture ||
      _state.value == VoiceState.recognize;

  /// 开启一路识别。返回 false = 被拒（会话互斥 / 引擎起不来）。
  ///
  /// [idleTimeout]/[maxUtterance]：per-session 超时覆盖（null = 构造默认）——
  /// 唤醒对话按设置项（voiceWakeNoInputSec/voiceWakeMaxInputSec）传入。
  ///
  /// 半双工（不变量 2）：播报期先**自动停播报**再开麦——用户长按说话的意图
  /// 明确，硬拒会让 UI 报「启动失败」引人困惑；「关麦防自念自醒」由门控语义保证
  /// （KWS 抑制窗在 M3 接）。
  Future<bool> beginCapture({
    VoiceScene scene = VoiceScene.holdToTalk,
    Duration? idleTimeout,
    Duration? maxUtterance,
  }) async {
    if (_engine != null || capturing) {
      debugPrint('[DSH][voice] capture rejected: session busy');
      return false; // 会话互斥（不变量 1）
    }
    if (_gate.active) {
      debugPrint('[DSH][voice] capture: stopping playback first (half-duplex)');
      await stopSpeak();
    }
    _suspendKws('capture:${scene.name}'); // 让麦 + KWS 抑制窗
    final idle = idleTimeout ?? wakeIdleTimeout;
    final utter = maxUtterance ?? this.maxUtterance;
    _setState(VoiceState.listening);
    VoiceCaptureEngine? eng;
    try {
      eng = await _captureFactory(await _enhancedLoader(), scene);
      await eng.start();
    } catch (e) {
      debugPrint('[DSH][voice] capture start failed: $e');
      try {
        await eng?.dispose();
      } catch (_) {}
      _setState(VoiceState.idle);
      return false;
    }
    if (_state.value != VoiceState.listening) {
      // beginCapture 期间门面被外部复位（stopAll/测试清理）：就地回收。
      try {
        await eng.dispose();
      } catch (_) {}
      return false;
    }
    _engine = eng;
    _scene = scene;
    _sub = eng.partialText.listen((t) {
      if (!_partialCtrl.isClosed) _partialCtrl.add(t);
      // 唤醒场景：有声音进来就重置「无输入超时」（只认 partial 到达为活跃）。
      if (_scene == VoiceScene.wake && _idleTimer != null) _armIdleTimer(idle);
    });
    _setState(VoiceState.capture);
    if (scene == VoiceScene.wake) {
      _armIdleTimer(idle);
      _utterTimer = Timer(utter, () {
        debugPrint('[DSH][voice] max utterance ${utter}s, auto-finalize');
        unawaited(endCapture());
      });
    }
    return true;
  }

  /// 收尾一路识别，返回终稿（cancelled = 丢弃内容但仍归还麦克风）。
  Future<String> endCapture({bool cancelled = false}) async {
    _cancelTimers();
    final eng = _engine;
    if (eng == null) return '';
    _engine = null;
    final sub = _sub;
    _sub = null;
    await sub?.cancel();
    _setState(VoiceState.recognize);
    String text = '';
    try {
      text = await eng.stop();
    } catch (e) {
      debugPrint('[DSH][voice] capture stop error: $e');
    }
    try {
      await eng.dispose();
    } catch (_) {}
    _setState(VoiceState.idle);
    final finalText = cancelled ? '' : text.trim();
    if (!cancelled && !_finalCtrl.isClosed) _finalCtrl.add(finalText);
    unawaited(resumeWakeListening()); // 麦归还待命 KWS（条件自检在内部）
    return finalText;
  }

  /// 中止一路识别（丢弃终稿，归还麦克风）。
  Future<String> cancelCapture() => endCapture(cancelled: true);

  void _armIdleTimer(Duration idle) {
    _idleTimer?.cancel();
    _idleTimer = Timer(idle, () {
      debugPrint('[DSH][voice] wake idle ${idle}s with no input, end session');
      unawaited(endCapture());
    });
  }

  void _cancelTimers() {
    _idleTimer?.cancel();
    _idleTimer = null;
    _utterTimer?.cancel();
    _utterTimer = null;
  }

  // ---- 播报门控（原语上收，播放器实现仍一份）----

  bool _speakActive = false;

  /// 是否在播报期（半双工门控的另一半）。
  bool get speaking => _speakActive || _gate.active;

  /// 开始一场播报：先停掉进行中的识别（播报期关麦），再占播报位，返回代次。
  Future<int> beginSpeak(String key) async {
    if (capturing) {
      debugPrint('[DSH][voice] beginSpeak: stopping active capture (half-duplex)');
      await endCapture(cancelled: true);
    }
    _suspendKws('speak'); // spec §2：播报期关 KWS（防自念自醒）
    _speakActive = true;
    _setState(VoiceState.speak);
    final seq = await _gate.begin(key);
    return seq;
  }

  /// 本场是否仍是当前播报位（被顶掉 → false，调用方立即收工）。
  bool isSpeakCurrent(int seq) => _speakActive && _gate.isCurrent(seq);

  /// 结束一场播报（幂等；代次不符什么都不做，避免误清新播报位）。
  void endSpeak(int seq) {
    if (!_speakActive || !_gate.isCurrent(seq)) return;
    _gate.end(seq);
    _speakActive = false;
    _setState(VoiceState.idle);
    unawaited(resumeWakeListening()); // 播报停 → KWS 抑制窗解除
  }

  /// 停掉当前播报（用户喊停）。**无条件**：即使播报位不是本门面开的
  /// （遗留路径直调 EdgeTtsService.speak），也把播放器停掉——stopGeneration
  /// 的「用户明确喊停不应继续出声」不能因为没人调过 beginSpeak 而失效。
  /// 等待者当场放掉的原语在 gate 实现内。
  Future<void> stopSpeak() async {
    await _gate.stop();
    _speakActive = false;
    if (_state.value == VoiceState.speak) _setState(VoiceState.idle);
    unawaited(resumeWakeListening());
  }

  /// 全停（识别 + 播报）；页面销毁 / 总开关关掉时调。
  Future<void> stopAll() async {
    await cancelCapture();
    await stopSpeak();
  }

  // ---- 回复朗读链（T2.5/T2.6/T2.7）----

  OfflineTtsService? _offlineTts;
  bool _offlineTtsTried = false;

  /// 离线 TTS（T2.5 matcha 转正 + vits 兜底 + kokoro 候选）：从
  /// VoiceModelManager 注册表目录里找第一个布局完整的（matcha > vits > kokoro，
  /// 对齐 M0 台账选型）。找不到 = null（离线不参与，全走 Edge）。失败不重试
  /// （isReady 是文件事实，重试无意义）；懒建（构造不碰 FFI）。
  Future<OfflineTtsService?> get offlineTts async {
    if (_offlineTtsTried) return _offlineTts;
    _offlineTtsTried = true;
    try {
      for (final id in const [
        VoiceModels.matcha,
        VoiceModels.vits,
        VoiceModels.kokoro,
      ]) {
        if (!await VoiceModelManager.isReady(id)) continue;
        final dir = await VoiceModelManager.modelDir(id);
        final layout = OfflineTtsLayout.detect(dir);
        if (!layout.complete) continue;
        _offlineTts = OfflineTtsService(
          modelDir: dir,
          engineFactory: (l) => SherpaOfflineTtsEngine(l),
        );
        break;
      }
    } catch (e) {
      debugPrint('[DSH][voice] offline tts locate failed: $e');
    }
    return _offlineTts;
  }

  /// 最近一次朗读失败（T2.6 黄条数据源；成功/被停后清空）。
  final ValueNotifier<String?> lastSpeakFailure = ValueNotifier(null);

  /// 朗读一段回复（逐句「合成一句播一句」，≤600 字分句复用）。
  ///
  /// 引擎链（T2.5，方向由 [preferEdge] 决定）：
  /// - offline（默认）：matcha/vits/kokoro → Edge（若 [edgeAllowed]）→ 留痕静默；
  /// - edge：Edge → 离线兜底 → 留痕静默。
  ///
  /// 播放复用 EdgeTtsService 的通用播控原语（代次 = 本门面播报位）——
  /// 「同时最多一个播报位」仍只有一份实现。失败**绝不抛**（自动朗读
  /// 不打断聊天），原因写 [lastSpeakFailure]。
  Future<void> speakReply(
    String key,
    String text, {
    required String voice,
    required int rate,
    required int pitch,
    required int volume,
    required bool preferEdge,
    required bool edgeAllowed,
  }) async {
    final clean = cleanTextForTts(text);
    if (clean.isEmpty) return;
    final seq = await beginSpeak(key);
    final edge = EdgeTtsService.instance;
    final offline = await offlineTts;
    try {
      for (final seg in segmentForTts(clean)) {
        if (!isSpeakCurrent(seq)) return;
        File? file;
        String? failure;
        if (preferEdge) {
          // 用户选在线优先：直接试 Edge（voiceTtsEngine='edge' 本身就是选择，
          // 不再问 edgeTtsEnabled），失败回落离线。
          file = await edge.synthesizeCached(seg,
              voice: voice, rate: rate, pitch: pitch, volume: volume);
          if (file == null) failure = edge.lastError;
          file ??= await offline?.synthesizeToFile(seg,
              voice: voice, rate: rate);
          failure ??= offline?.lastFailureMessage;
        } else {
          if (offline != null) {
            file = await offline.synthesizeToFile(seg, voice: voice, rate: rate);
            failure = offline.lastFailureMessage;
          }
          // 离线没念成：Edge 开着才回落（D1：Edge 保留可选）。
          if (file == null && edgeAllowed) {
            file = await edge.synthesizeCached(seg,
                voice: voice, rate: rate, pitch: pitch, volume: volume);
            if (file != null) failure = null;
          }
        }
        if (!isSpeakCurrent(seq)) return;
        if (file == null) {
          lastSpeakFailure.value =
              failure ?? '语音合成失败（离线与在线均未出声）';
          debugPrint('[DSH][voice] speakReply failed: ${lastSpeakFailure.value}');
          return;
        }
        lastSpeakFailure.value = null;
        if (!await edge.playCached(seq, file)) return;
      }
    } catch (e) {
      lastSpeakFailure.value = '朗读异常：$e';
      debugPrint('[DSH][voice] speakReply error: $e');
    } finally {
      endSpeak(seq);
    }
  }

  @visibleForTesting
  void disposeForTest() {
    _cancelTimers();
    unawaited(_sub?.cancel() ?? Future<void>.value());
    _sub = null;
    _engine = null;
    _speakActive = false;
    _kws = null; // 假句柄由用例自己清；真句柄不经这条路径（测试不启 FFI 麦）
    _wakeWanted = false;
    wakeMicOn.value = false;
  }
}

/// 生产 KWS 工厂：注册表 KWS 条目就位才起；一切异常留痕返回 null
/// （常驻唤醒是增强项，起不来绝不拖垮门面其它能力）。
Future<KwsHandle?> _productionKws(double threshold) async {
  try {
    if (!await VoiceModelManager.isReady(VoiceModels.kws)) {
      debugPrint('[DSH][voice] kws model not ready — wake listening skipped');
      return null;
    }
    final dir = await VoiceModelManager.modelDir(VoiceModels.kws);
    return KwsEngine.start(modelDir: dir, threshold: threshold);
  } catch (e) {
    debugPrint('[DSH][voice] kws engine start failed: $e');
    return null;
  }
}

/// 生产引擎适配：SherpaStreamingAsr → [VoiceCaptureEngine] 窄端口
/// （领域类不实现门面接口，端口收窄由适配层承担）。
final class _StreamingAsrCapture implements VoiceCaptureEngine {
  _StreamingAsrCapture(this._e);
  final SherpaStreamingAsr _e;

  @override
  Stream<String> get partialText => _e.partialText;
  @override
  Future<void> start() => _e.start();
  @override
  Future<String> stop() => _e.stop();
  @override
  Future<void> dispose() => _e.dispose();
}

/// 生产引擎工厂（母方案 §4.1 分场景调度）：
/// - holdToTalk / plugin = 现役流式 Zipformer（真 partial，用户控制端点）；
/// - wake = SenseVoice int8（精度/标点/ITN 强，VAD 假流式）。
Future<VoiceCaptureEngine> _productionCapture(
    bool enhanced, VoiceScene scene) async {
  switch (scene) {
    case VoiceScene.wake:
      return SenseVoiceAsr.create();
    case VoiceScene.holdToTalk:
    case VoiceScene.plugin:
      final dir = await VoiceModelManager.modelDir(VoiceModels.streaming);
      return _StreamingAsrCapture(
          await SherpaStreamingAsr.create(dir, enhanced: enhanced));
  }
}

Future<bool> _defaultEnhancedLoader() async =>
    await AsrSettings.loadAsrMode() == AsrMode.enhanced;
