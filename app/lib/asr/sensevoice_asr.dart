/// 唤醒对话识别引擎（T2.1）：SenseVoice-Small int8 离线整段识别，常驻 worker
/// isolate；VAD 分段 + 假流式回显（T2.2）。
///
/// 与按住说话（SherpaStreamingAsr 流式 Zipformer）的分场景调度见母方案 §4.1：
/// - 流式 = 真 partial、用户自己控制端点（按住说话）；
/// - SenseVoice = 精度/标点/ITN 强，免提场景说话短，**每段（停顿）增量上屏**
///   ——「假流式」：silero-VAD 滑窗分段（段尾静音 800ms 定稿，§4.2），段
///   送 SenseVoice，段文本经 [AsrPostProcessor]（剥富转写标签 + 同音热词 +
///   指令归一）后作为 partial 增量广播。
///
/// 全部 FFI（OfflineRecognizer + VoiceActivityDetector）在常驻 worker 内：
/// 引擎跨会话复用（模型 ~495MB RSS），VAD/会话缓冲按会话建；PCM 经
/// TransferableTypedData 零拷贝转移。录音机（record 平台通道）在主 isolate
/// 本类持有——与 SherpaStreamingAsr 同构；VoiceService 互斥保证同一时刻
/// 只有一路在录。
///
/// SenseVoice 单段上限 ~15s（母方案 §4.1）→ VAD maxSpeechDuration=15s 强制分段。
library;

import 'dart:async';
import 'dart:isolate';

import 'package:flutter/foundation.dart';
import 'package:path/path.dart' as p;
import 'package:record/record.dart';
import 'package:sherpa_onnx/sherpa_onnx.dart' as sherpa;

import '../platform/sherpa_dll.dart';
import '../voice/voice_model_manager.dart';
import '../voice/voice_ports.dart';
import 'asr_post_processor.dart';
import 'asr_settings.dart';

/// 唤醒对话会话（每次会话一个实例；引擎与模型在 worker 常驻）。
class SenseVoiceAsr implements VoiceCaptureEngine {
  SenseVoiceAsr._({this.modelDir, this.vadModelPath});

  /// 开发机/测试注入点；null = 走 VoiceModelManager 注册表目录。
  final String? modelDir;
  final String? vadModelPath;

  final AudioRecorder _recorder = AudioRecorder();
  StreamSubscription<Uint8List>? _sub;
  bool _sessionActive = false;

  /// 创建会话。模型未就位时 [start] 会失败（VoiceService 记账回 idle）。
  static Future<SenseVoiceAsr> create(
          {String? modelDir, String? vadModelPath}) async =>
      SenseVoiceAsr._(modelDir: modelDir, vadModelPath: vadModelPath);

  @override
  Stream<String> get partialText {
    final w = _SenseVoiceWorker.current;
    if (w == null) return const Stream<String>.empty();
    return w.partials;
  }

  @override
  Future<void> start() async {
    // 热词主 isolate 读（平台通道），配置在 worker 侧生效。
    final hotwords =
        AsrSettings.normalizeHotwords(await AsrSettings.loadHotwords());
    final dir =
        modelDir ?? await VoiceModelManager.modelDir(VoiceModels.sensevoice);
    final vad = vadModelPath ??
        p.join(await VoiceModelManager.modelDir(VoiceModels.vad),
            'silero_vad.onnx');
    final w = await _SenseVoiceWorker.require();
    await w.beginSession(modelDir: dir, vadModel: vad, hotwords: hotwords);
    // 录音（主 isolate）→ PCM16 块转发 worker（worker 内 VAD 分段 + 识别）。
    final pcmStream = await _recorder.startStream(const RecordConfig(
      encoder: AudioEncoder.pcm16bits,
      sampleRate: 16000,
      numChannels: 1,
      autoGain: true,
      echoCancel: true,
      noiseSuppress: true,
    ));
    _sessionActive = true;
    _sub = pcmStream.listen(
      (bytes) => w.feed(bytes),
      onError: (Object e) {
        debugPrint('[DSH][sensevoice] pcm stream error: $e');
      },
      cancelOnError: false,
    );
    debugPrint('[DSH][sensevoice] session start');
  }

  @override
  Future<String> stop() async {
    await _sub?.cancel();
    _sub = null;
    try {
      await _recorder.stop();
    } catch (e) {
      debugPrint('[DSH][sensevoice] recorder stop error: $e');
    }
    _sessionActive = false;
    // worker：flush VAD 尾段 → 识别 → 回传终稿。
    final w = _SenseVoiceWorker.current;
    if (w == null) return '';
    final text = await w.endSession();
    debugPrint('[DSH][sensevoice] session stop, final=${text.length} chars');
    return text;
  }

  @override
  Future<void> dispose() async {
    // 异常路径未 stop：让 worker 丢弃会话缓冲（引擎/模型保留复用）。
    if (_sessionActive) {
      try {
        await _SenseVoiceWorker.current?.discardSession();
      } catch (_) {}
      _sessionActive = false;
    }
    await _recorder.dispose();
  }

  /// 真 FFI 冒烟入口（test/asr/sensevoice_smoke_test.dart）：绕开 record
  /// 平台通道，直接把一段 PCM16(16k mono) 喂进 worker 走完整链
  /// （session → VAD 分段 → SenseVoice 识别 → 后处理 → flush 终稿）。
  @visibleForTesting
  static Future<String> recognizePcmForTest(
    Uint8List pcm16, {
    required String modelDir,
    required String vadModel,
    List<String> hotwords = const [],
    String? dllDir,
  }) async {
    final w = await _SenseVoiceWorker.require();
    await w.beginSession(
        modelDir: modelDir,
        vadModel: vadModel,
        hotwords: hotwords,
        dllDir: dllDir);
    w.feed(pcm16);
    // 段尾静音 800ms 定稿 → VAD 出段 → 识别；给足等待。
    await Future<void>.delayed(const Duration(milliseconds: 1500));
    return w.endSession();
  }
}

/// worker isolate 的主 isolate 侧代理（协议与 _AsrWorker 同形）：
/// `session`(modelDir/vadModel/hotwords) → ok；`audio`(TransferableTypedData)
/// → {partial}；`stop` → {final}；`discard` 无回包。
class _SenseVoiceWorker {
  static _SenseVoiceWorker? _instance;

  static _SenseVoiceWorker? get current => _instance;

  static Future<_SenseVoiceWorker> require() async {
    var w = _instance;
    if (w == null) {
      w = _SenseVoiceWorker();
      _instance = w;
      await w.spawn();
    }
    return w;
  }

  SendPort? _toWorker;
  Completer<void>? _spawnReady;
  Completer<void>? _sessionCompleter;
  Completer<String>? _stopCompleter;

  final StreamController<String> _partialCtrl =
      StreamController<String>.broadcast();

  Stream<String> get partials => _partialCtrl.stream;

  Future<void> spawn() async {
    final ready = Completer<void>();
    final port = ReceivePort();
    _spawnReady = ready;
    port.listen(_handleMessage);
    await Isolate.spawn(_workerMain, port.sendPort,
        debugName: 'sherpa-sensevoice-worker', errorsAreFatal: false);
    await ready.future.timeout(const Duration(seconds: 10),
        onTimeout: () => throw StateError('sensevoice worker spawn timeout'));
  }

  void _handleMessage(dynamic msg) {
    if (msg is SendPort) {
      _toWorker = msg;
      _spawnReady?.complete();
      _spawnReady = null;
      return;
    }
    if (msg is! Map) return;
    if (msg.containsKey('error')) {
      final err = StateError(msg['error'].toString());
      debugPrint('[DSH][sensevoice] worker error: ${msg['error']}');
      _sessionCompleter?.completeError(err);
      _sessionCompleter = null;
      _stopCompleter?.complete('');
      _stopCompleter = null;
      return;
    }
    if (msg.containsKey('ok')) {
      _sessionCompleter?.complete();
      _sessionCompleter = null;
      return;
    }
    if (msg['partial'] is String) {
      if (!_partialCtrl.isClosed) _partialCtrl.add(msg['partial'] as String);
      return;
    }
    if (msg.containsKey('final')) {
      _stopCompleter?.complete(msg['final']?.toString() ?? '');
      _stopCompleter = null;
      return;
    }
  }

  Future<void> beginSession({
    required String modelDir,
    required String vadModel,
    required List<String> hotwords,
    String? dllDir,
  }) async {
    final c = Completer<void>();
    _sessionCompleter = c;
    _toWorker!.send({
      'cmd': 'session',
      'modelDir': modelDir,
      'vadModel': vadModel,
      'hotwords': hotwords,
      if (dllDir != null) 'dllDir': dllDir,
    });
    // 120s：模型冷加载秒级（M0 实测 ~2.1s）；超时 = completer 挂死类异常。
    return c.future.timeout(const Duration(seconds: 120));
  }

  void feed(Uint8List bytes) {
    _toWorker?.send({
      'cmd': 'audio',
      'data': TransferableTypedData.fromList([bytes]),
    });
  }

  Future<String> endSession() async {
    final c = Completer<String>();
    _stopCompleter = c;
    _toWorker!.send({'cmd': 'stop'});
    return c.future.timeout(const Duration(seconds: 60), onTimeout: () => '');
  }

  Future<void> discardSession() async {
    _toWorker?.send({'cmd': 'discard'});
  }
}

/// worker isolate 入口：recognizer/后处理器常驻，VAD 按会话建。
/// 所有异常就地捕获回传（识别永不杀死 App）。
Future<void> _workerMain(SendPort toMain) async {
  final port = ReceivePort();
  toMain.send(port.sendPort);

  sherpa.OfflineRecognizer? recognizer;
  String? loadedModelDir;
  String? boundDllDir;
  sherpa.VoiceActivityDetector? vad;
  final post = AsrPostProcessor();
  final segments = StringBuffer();

  // 会话流坐标：VAD 出段（seg.start 绝对样本偏移）后裁掉已消费音频；
  // 会话结束时剩余（未等到 800ms 尾静音的说话尾段）直接送识别——
  // 实测 sherpa VAD 的 flush() 只推出最后 ~0.3s 窗口（丢正文），禁用。
  final pendingBlocks = <Float32List>[];
  int pendingBase = 0; // pendingBlocks 首块的绝对样本坐标
  int fedTotal = 0;
  int consumed = 0;

  void dropConsumed() {
    while (pendingBlocks.isNotEmpty) {
      final first = pendingBlocks.first;
      final firstEnd = pendingBase + first.length;
      if (firstEnd <= consumed) {
        pendingBlocks.removeAt(0);
        pendingBase = firstEnd;
        continue;
      }
      break;
    }
  }

  /// 建/对齐 recognizer（模型目录不变即复用）。
  void ensureRecognizer(String modelDir, String? dllDir) {
    if (recognizer != null && loadedModelDir == modelDir) return;
    bindSherpa(dllDir);
    final sw = Stopwatch()..start();
    final rec = sherpa.OfflineRecognizer(sherpa.OfflineRecognizerConfig(
      model: sherpa.OfflineModelConfig(
        senseVoice: sherpa.OfflineSenseVoiceModelConfig(
          model: p.join(modelDir, 'model.int8.onnx'),
          language: 'zh',
          useInverseTextNormalization: true,
        ),
        tokens: p.join(modelDir, 'tokens.txt'),
        numThreads: 2,
        provider: 'cpu',
        debug: false,
      ),
    ));
    recognizer?.free();
    recognizer = rec;
    loadedModelDir = modelDir;
    debugPrint('[DSH][sensevoice] recognizer loaded in '
        '${sw.elapsedMilliseconds}ms (worker isolate)');
  }

  /// 段识别（Float32 [-1,1]）→ 后处理 → 追加累计文本。
  String recognizeSegment(sherpa.OfflineRecognizer rec, Float32List samples) {
    final st = rec.createStream();
    try {
      st.acceptWaveform(samples: samples, sampleRate: 16000);
      rec.decode(st);
      final raw = rec.getResult(st).text;
      return post.apply(raw);
    } finally {
      st.free();
    }
  }

  /// VAD 已积压的段全部吃掉；每段识别后回传累计 partial（假流式增量上屏），
  /// 并按段绝对坐标裁掉已消费音频。
  void drainSegments() {
    final rec = recognizer;
    final v = vad;
    if (rec == null || v == null) return;
    var guard = 0;
    while (!v.isEmpty()) {
      final seg = v.front();
      v.pop();
      if (seg.samples.isNotEmpty) {
        final absEnd = seg.start + seg.samples.length;
        if (absEnd > consumed) consumed = absEnd;
        segments.write(recognizeSegment(rec, seg.samples));
        toMain.send({'partial': segments.toString()});
      }
      if (++guard > 500) break; // 防御：异常时避免死循环
    }
    dropConsumed();
  }

  await for (final msg in port) {
    if (msg is! Map) continue;
    try {
      switch (msg['cmd'] as String?) {
        case 'session':
          final modelDir = msg['modelDir'] as String;
          final dllDir = msg['dllDir'] as String?;
          if (dllDir != boundDllDir) {
            bindSherpa(dllDir); // VAD 也走 c-api，绑定要对齐
            boundDllDir = dllDir;
          }
          ensureRecognizer(modelDir, dllDir);
          await post.configure(modelDir,
              (msg['hotwords'] as List?)?.cast<String>() ?? const []);
          // VAD 按会话重建（段尾静音 800ms 定稿；单段最长 15s 强制分段）。
          try {
            vad?.free();
          } catch (_) {}
          vad = sherpa.VoiceActivityDetector(
            config: sherpa.VadModelConfig(
              sileroVad: sherpa.SileroVadModelConfig(
                model: msg['vadModel'] as String,
                threshold: 0.5,
                minSilenceDuration: 0.8, // §4.2：段尾静音 800ms 定稿
                minSpeechDuration: 0.25,
                maxSpeechDuration: 15.0, // SenseVoice 单段上限
              ),
              sampleRate: 16000,
              numThreads: 1,
              debug: false,
            ),
            bufferSizeInSeconds: 60,
          );
          segments.clear();
          pendingBlocks.clear();
          pendingBase = 0;
          fedTotal = 0;
          consumed = 0;
          toMain.send({'ok': true});
        case 'audio':
          final v = vad;
          if (v == null) break;
          final bytes = (msg['data'] as TransferableTypedData)
              .materialize()
              .asUint8List();
          if (bytes.isEmpty) break;
          final f32 = _pcm16ToFloat32(bytes);
          pendingBlocks.add(f32);
          fedTotal += f32.length;
          v.acceptWaveform(f32);
          drainSegments();
        case 'stop':
          final v = vad;
          final rec = recognizer;
          if (v != null) {
            drainSegments(); // 已定稿段（尾静音 ≥800ms 的）先吃掉
            try {
              v.free();
            } catch (_) {}
          }
          vad = null;
          // 尾段（未等到 800ms 静音、VAD 不出段）：直接识别剩余音频。
          // sherpa 的 flush() 实测只推出最后 ~0.3s（正文丢失），禁用。
          if (rec != null && fedTotal > consumed) {
            final tail = <double>[];
            var blockStart = pendingBase;
            for (final b in pendingBlocks) {
              final lo = (consumed - blockStart).clamp(0, b.length);
              if (lo < b.length) tail.addAll(b.sublist(lo));
              blockStart += b.length;
            }
            if (tail.length >= 3200) { // ≥0.2s 才识别（再短是噪声）
              final t = recognizeSegment(rec, Float32List.fromList(tail));
              if (t.isNotEmpty) segments.write(t);
            }
          }
          pendingBlocks.clear();
          pendingBase = consumed;
          final text = segments.toString().trim();
          segments.clear();
          toMain.send({'final': text});
        case 'discard':
          try {
            vad?.free();
          } catch (_) {}
          vad = null;
          segments.clear();
          pendingBlocks.clear();
          pendingBase = 0;
          fedTotal = 0;
          consumed = 0;
        case 'exit':
          return;
      }
    } catch (e, s) {
      debugPrint('[DSH][sensevoice] worker exception: $e\n$s');
      toMain.send({'error': e.toString()});
    }
  }
}

/// PCM16LE → Float32（与 sherpa_streaming_asr 同源实现）。
Float32List _pcm16ToFloat32(Uint8List bytes) {
  final sampleCount = bytes.length ~/ 2;
  final data = ByteData.sublistView(bytes);
  final samples = Float32List(sampleCount);
  for (var i = 0; i < sampleCount; i++) {
    samples[i] = data.getInt16(i * 2, Endian.little) / 32768.0;
  }
  return samples;
}
