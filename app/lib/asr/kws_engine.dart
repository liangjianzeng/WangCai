/// 常驻关键词唤醒 KWS（M3，docs/voice-wakeup-min-spec.md）。
///
/// wenetspeech-3.3M zipformer2（注册表 [VoiceModels.kws]，~12MB）常驻 worker
/// isolate；主 isolate 只留录音机（record 平台通道约束，与 SherpaStreamingAsr /
/// SenseVoiceAsr 同构——**KWS 待命期这条录音机是唯一的麦主**，命中/开会话/播报
/// 时让麦，仲裁在 VoiceService）。
///
/// 实测锚（tool/m3_kws_check.dart，i5-7400T）：加载 1.3s / RSS +约 60MB /
/// RTF 0.033（预算 ≤5% 单核）；matcha 合成「汪柴」th=0.25 命中，th≥0.3 不命中
/// —— 灵敏度上限封 0.45（见 VoiceService 侧映射）。
///
/// 唤醒词表刻意写死：tokens 是**带调拼音初/终音**（无汉字），新唤醒词要过
/// pypinyin 级分词，超出最小规格（spec §5「明确不做多唤醒词」）。
library;

import 'dart:async';
import 'dart:convert';
import 'dart:isolate';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:record/record.dart';
import 'package:sherpa_onnx/sherpa_onnx.dart' as sherpa;

import '../platform/sherpa_dll.dart';
import '../voice/voice_ports.dart';

/// 唤醒词 → sherpa 关键字行（`<空格分隔拼音 token> @汉字`，test_keywords 同款
/// 形态；token 对齐 kws tokens.txt：w=38 āng=46 ch=34 ái=99）。
const _kWakeWordLines = {'汪柴': 'w āng ch ái @汪柴'};

/// 唤醒词的关键字行；null = 不支持（worker 加载前就拦，不烧模型）。
String? buildKwsKeywordLine(String wakeWord) => _kWakeWordLines[wakeWord.trim()];

/// 灵敏度滑条（UI 口径 0.3–0.9，默认 0.75）→ sherpa keywordsThreshold。
/// 实测锚（tool/m3_kws_check）：合成「汪柴」0.25 稳命中、≥0.3 必漏（干净人声
/// 到 0.5 且有高阈值误配倾向）→ 上限封 0.45 杜绝必漏区，下限 0.1 防疯醒。
double kwsThresholdFromSensitivity(double sensitivity) =>
    (1.0 - sensitivity).clamp(0.1, 0.45);

class KwsEngine implements KwsHandle {
  KwsEngine._(this._worker);

  final _KwsWorker _worker;
  final AudioRecorder _recorder = AudioRecorder();
  StreamSubscription<Uint8List>? _sub;
  final StreamController<String> _hits = StreamController<String>.broadcast();
  bool _micOn = false;
  bool _disposed = false;

  @override
  bool get micOn => _micOn;

  @override
  Stream<String> get hits => _hits.stream;

  /// 加载模型 + 开麦。模型/绑定失败**抛**（调用方 VoiceService 记账，UI 提示）。
  static Future<KwsEngine> start({
    required String modelDir,
    double threshold = 0.25,
    String wakeWord = '汪柴',
    String? dllDir,
  }) async {
    final kwLine = buildKwsKeywordLine(wakeWord);
    if (kwLine == null) {
      throw ArgumentError('唤醒词「$wakeWord」无 pinyin token 表（M3 只支持「汪柴」）');
    }
    _writeKeywordsFile(modelDir, kwLine);
    final w = await _KwsWorker.require();
    await w.load(
        modelDir: modelDir, keywords: kwLine, threshold: threshold, dllDir: dllDir);
    final e = KwsEngine._(w);
    w.bindHits(e._hits);
    await e._startMic();
    debugPrint('[DSH][kws] armed (th=$threshold, "$wakeWord")');
    return e;
  }

  Future<void> _startMic() async {
    final pcm = await _recorder.startStream(const RecordConfig(
      encoder: AudioEncoder.pcm16bits,
      sampleRate: 16000,
      numChannels: 1,
      autoGain: true,
      echoCancel: true,
      noiseSuppress: true,
    ));
    _sub = pcm.listen(
      (bytes) => _worker.feed(bytes),
      onError: (Object e) => debugPrint('[DSH][kws] pcm error: $e'),
      cancelOnError: false,
    );
    _micOn = true;
  }

  @override
  Future<void> pause() async {
    await _sub?.cancel();
    _sub = null;
    if (!_micOn) return;
    try {
      await _recorder.stop();
    } catch (e) {
      debugPrint('[DSH][kws] recorder stop error: $e');
    }
    _micOn = false;
  }

  @override
  Future<void> resume() async {
    if (_disposed || _micOn) return;
    await _worker.reset(); // 丢弃抑制期积压的流状态
    await _startMic();
    debugPrint('[DSH][kws] rearmed');
  }

  @override
  Future<void> dispose() async {
    _disposed = true;
    await pause();
    await _worker.reset();
    await _recorder.dispose();
    await _hits.close();
    // worker isolate 与模型保留（常驻复用，dispose 语义 = 释放麦而非模型）。
  }

  /// 真 FFI 冒烟入口（test/asr/kws_smoke_test.dart）：绕开麦，把一段
  /// PCM16(16k mono) 直接喂进 worker，返回命中关键字（无命中 = ''）。
  @visibleForTesting
  static Future<String> spotPcmForTest(
    Uint8List pcm16, {
    required String modelDir,
    required String keywords,
    double threshold = 0.25,
    String? dllDir,
  }) async {
    _writeKeywordsFile(modelDir, keywords);
    final w = await _KwsWorker.require();
    await w.load(
        modelDir: modelDir, keywords: keywords, threshold: threshold, dllDir: dllDir);
    final probe = StreamController<String>.broadcast();
    w.bindHits(probe);
    // 30s：全量测试并行时 4 核饿死，RTF 0.033 的解码也会被拖到秒级（台账口径
    // 「宁慢要跑」）；单跑实测 <1s。
    final first = probe.stream.first.timeout(
      const Duration(seconds: 30),
      onTimeout: () => '',
    );
    w.feed(pcm16);
    final hit = await first;
    await probe.close();
    await w.reset();
    return hit;
  }
}

/// worker isolate 的主 isolate 侧代理（协议同 _SenseVoiceWorker，命令更短：
/// load/reset/audio/exit；命中回包 `{'hit': kw}`）。
class _KwsWorker {
  static _KwsWorker? _instance;

  static _KwsWorker? get current => _instance;

  static Future<_KwsWorker> require() async {
    var w = _instance;
    if (w == null) {
      w = _KwsWorker();
      _instance = w;
      await w.spawn();
    }
    return w;
  }

  SendPort? _toWorker;
  Completer<void>? _spawnReady;
  Completer<void>? _loadCompleter;
  StreamController<String>? _boundHits;

  void bindHits(StreamController<String> c) => _boundHits = c;

  Future<void> spawn() async {
    final ready = Completer<void>();
    final port = ReceivePort();
    _spawnReady = ready;
    port.listen(_handleMessage);
    await Isolate.spawn(_kwsWorkerMain, port.sendPort,
        debugName: 'sherpa-kws-worker', errorsAreFatal: false);
    await ready.future.timeout(const Duration(seconds: 10),
        onTimeout: () => throw StateError('kws worker spawn timeout'));
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
      debugPrint('[DSH][kws] worker error: ${msg['error']}');
      // 教训（M1 worker 挂死）：error 只认领在等的 completer，绝不广播。
      _loadCompleter?.completeError(err);
      _loadCompleter = null;
      return;
    }
    if (msg.containsKey('ok')) {
      _loadCompleter?.complete();
      _loadCompleter = null;
      return;
    }
    if (msg['hit'] is String) {
      final c = _boundHits;
      if (c != null && !c.isClosed) c.add(msg['hit'] as String);
      return;
    }
  }

  Future<void> load({
    required String modelDir,
    required String keywords,
    required double threshold,
    String? dllDir,
  }) async {
    final c = Completer<void>();
    _loadCompleter = c;
    _toWorker!.send({
      'cmd': 'load',
      'modelDir': modelDir,
      'keywords': keywords,
      'threshold': threshold,
      if (dllDir != null) 'dllDir': dllDir,
    });
    // 120s：模型冷加载实测 1.3s；超时 = completer 挂死类异常（同 sensevoice）。
    return c.future.timeout(const Duration(seconds: 120));
  }

  void feed(Uint8List bytes) {
    _toWorker?.send({
      'cmd': 'audio',
      'data': TransferableTypedData.fromList([bytes]),
    });
  }

  Future<void> reset() async {
    _toWorker?.send({'cmd': 'reset'});
  }
}

/// worker isolate 入口：spotter 跨引擎实例常驻（目录/阈值/关键字不变即复用）。
Future<void> _kwsWorkerMain(SendPort toMain) async {
  final port = ReceivePort();
  toMain.send(port.sendPort);

  sherpa.KeywordSpotter? spotter;
  String? loadedSignature;
  String? boundDllDir;
  sherpa.OnlineStream? stream;
  String lastHit = '';

  void makeStream() {
    try {
      stream?.free();
    } catch (_) {}
    stream = spotter!.createStream();
    lastHit = '';
  }

  await for (final msg in port) {
    if (msg is! Map) continue;
    try {
      switch (msg['cmd'] as String?) {
        case 'load':
          final modelDir = msg['modelDir'] as String;
          final keywords = msg['keywords'] as String;
          final threshold = (msg['threshold'] as num).toDouble();
          final dllDir = msg['dllDir'] as String?;
          final sig = '$modelDir|$keywords|$threshold';
          if (spotter == null || loadedSignature != sig) {
            if (dllDir != boundDllDir) {
              bindSherpa(dllDir);
              boundDllDir = dllDir;
            }
            final sw = Stopwatch()..start();
            final s = sherpa.KeywordSpotter(sherpa.KeywordSpotterConfig(
              model: sherpa.OnlineModelConfig(
                transducer: sherpa.OnlineTransducerModelConfig(
                  encoder: _joinKws(modelDir, 'encoder-epoch-99-avg-1-chunk-16-left-64.onnx'),
                  decoder: _joinKws(modelDir, 'decoder-epoch-99-avg-1-chunk-16-left-64.onnx'),
                  joiner: _joinKws(modelDir, 'joiner-epoch-99-avg-1-chunk-16-left-64.onnx'),
                ),
                tokens: _joinKws(modelDir, 'tokens.txt'),
                numThreads: 2,
                provider: 'cpu',
              ),
              keywordsFile: _joinKws(modelDir, 'keywords.txt'),
              keywordsThreshold: threshold,
              keywordsScore: 1.5,
              numTrailingBlanks: 2,
            ));
            spotter?.free();
            spotter = s;
            loadedSignature = sig;
            debugPrint('[DSH][kws] spotter loaded in ${sw.elapsedMilliseconds}ms '
                '(worker isolate)');
          }
          // keywordsFile = 模型目录下 keywords.txt（主 isolate 加载前落盘，见
          // _writeKeywordsFile；注册表 ready 判定只看声明文件，多一个无害）。
          makeStream();
          toMain.send({'ok': true});
        case 'audio':
          final s = spotter;
          final st = stream;
          if (s == null || st == null) break;
          final bytes = (msg['data'] as TransferableTypedData)
              .materialize()
              .asUint8List();
          if (bytes.isEmpty) break;
          // 与生产麦克风同节奏：按 100ms 块喂入并逐块 decode/getResult——
          // 实测（m3_kws_check）KWS 的命中判定走「块间解码」路径；8s 一次性
          // acceptWaveform 后集中解码不吐命中（语义未背书，不赌）。
          final f32 = _pcm16ToFloat32(bytes);
          var hit = false;
          for (var off = 0; off < f32.length && !hit; off += 1600) {
            final end = (off + 1600) > f32.length ? f32.length : off + 1600;
            st.acceptWaveform(
                samples: f32.sublist(off, end), sampleRate: 16000);
            while (s.isReady(st)) {
              s.decode(st);
            }
            final kw = s.getResult(st).keyword;
            if (kw.isNotEmpty && kw != lastHit) {
              lastHit = kw;
              toMain.send({'hit': kw});
              makeStream(); // 命中即复位：等待宿主 pause/resume 周期
              hit = true;
            }
          }
        case 'reset':
          if (spotter != null) makeStream();
        case 'exit':
          return;
      }
    } catch (e, st) {
      debugPrint('[DSH][kws] worker exception: $e\n$st');
      toMain.send({'error': e.toString()});
    }
  }
}

String _joinKws(String dir, String name) {
  final sep = dir.contains('\\') ? '\\' : '/';
  return '$dir$sep$name';
}

/// 关键字行落盘 `模型目录\keywords.txt`（sherpa keywordsFile 路线；内容不变则
/// 不重写，UTF-8 无 BOM——PS 5.1 禁碰，写入只走这里）。
void _writeKeywordsFile(String dir, String line) {
  final f = File(_joinKws(dir, 'keywords.txt'));
  final want = '$line\n';
  if (!f.existsSync() || f.readAsStringSync(encoding: utf8) != want) {
    f.writeAsStringSync(want, encoding: utf8);
  }
}

/// PCM16LE → Float32（与 sensevoice_asr / sherpa_streaming_asr 同源实现）。
Float32List _pcm16ToFloat32(Uint8List bytes) {
  final sampleCount = bytes.length ~/ 2;
  final data = ByteData.sublistView(bytes);
  final samples = Float32List(sampleCount);
  for (var i = 0; i < sampleCount; i++) {
    samples[i] = data.getInt16(i * 2, Endian.little) / 32768.0;
  }
  return samples;
}
