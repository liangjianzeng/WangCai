import 'dart:async';
import 'dart:io';
import 'dart:isolate';

import 'package:flutter/foundation.dart';
import 'package:path/path.dart' as p;
import 'package:record/record.dart';
import 'package:sherpa_onnx/sherpa_onnx.dart' as sherpa;

import 'asr_settings.dart';
import 'asr_engine.dart';
import 'asr_model_manager.dart';
import 'hotword_corrector.dart';

/// 端侧流式识别引擎：sherpa-onnx 流式 Zipformer（zh int8，chunk-16）。
///
/// **全部 sherpa 工作跑在常驻 worker isolate**（2026-10-07 重构）：
/// - 识别器（模型 ~160MB）加载 + 解码 + 热词校正都是重 FFI/计算，曾在主
///   isolate 执行 → 首次按住说话整个 UI 冻结数秒（真机实测卡顿根因）；
/// - 现在识别器在 worker 进程内加载一次、全局复用；主 isolate 只负责
///   record 录音流（平台通道只能在主 isolate 消费）并经 SendPort 转发
///   PCM 块（TransferableTypedData 零拷贝转移）；
/// - worker 常驻：首次加载完成后，后续每次按住说话只建流，秒开；
/// - worker 内所有异常就地捕获回传为 error 事件，引擎层失败不再能杀死 App。
///
/// 录音用 record 的 16kHz mono PCM16 流，逐块喂入解码，partial 文本经
/// [partialText] 广播（endpoint 静音断句后自动定稿并继续监听）。输出无标点
/// （流式 transducer 特性），注入后可再编辑。
///
/// 识别增强档位（[enhanced]）与热词：
/// - sherpa-onnx 流式（Online）API 不支持 LM（LM 仅在离线 API 可用），
///   因此增强档位在同一模型上启用 beam search + blankPenalty；
/// - 热词两路（详见 [HotwordCorrector]）：词表内热词经 per-stream
///   ContextGraph 偏置（需 beam，故有词表内热词时标准档也自动切 beam）；
///   词表外生僻字热词在 worker 输出端做同音后校正。每次按住说话从设置读
///   最新热词表（主 isolate 读，改热词即时生效）。
class SherpaStreamingAsr implements StreamingAsrEngine {
  SherpaStreamingAsr._(this.modelDir, this.enhanced);

  final String modelDir;

  /// 当前会话是否增强档位（决定加载形态签名）。
  final bool enhanced;

  /// 常驻 worker（进程级单例；识别器跨会话复用）。
  static _AsrWorker? _worker;

  static Future<_AsrWorker> _requireWorker() async {
    var w = _worker;
    if (w == null) {
      w = _AsrWorker();
      _worker = w;
      await w.spawn();
    }
    return w;
  }

  /// 兼容入口：确保识别器已按档位加载（不建会话流）。注意热词对齐发生在
  /// [warmup] 或会话 [start]（按「enhanced+热词」最终形态加载）。
  static Future<void> ensureLoaded(String modelDir,
      {bool enhanced = false, bool hotwordsActive = false}) async {
    final w = await _requireWorker();
    await w.load(modelDir: modelDir, enhanced: enhanced, hotwords: const []);
  }

  /// 创建会话（每次按住说话一个实例）。
  static Future<SherpaStreamingAsr> create(String modelDir,
      {bool enhanced = false}) async {
    return SherpaStreamingAsr._(modelDir, enhanced);
  }

  /// 启动完成后预热：
  /// 1. **后台 isolate** 预读模型文件到 OS 页缓存（不阻塞 UI）；
  /// 2. 在 worker isolate 里**预加载识别器**——首次长按说话不再等数秒模型
  ///    加载，直接秒开。模型未下载（首次启动）跳过，待首次使用时走下载
  ///    引导。失败不阻塞启动。
  static Future<void> warmup() async {
    try {
      if (!await AsrModelManager.isReady()) return;
      final dir = await AsrModelManager.modelDir();
      await Isolate.run(() => _preloadFiles(dir));
      debugPrint('[DSH][asr] warmup: model files preloaded to page cache');
      final mode = await AsrSettings.loadAsrMode();
      final hotwords = _normalizeHotwords(await AsrSettings.loadHotwords());
      final w = await _requireWorker();
      await w.load(
          modelDir: dir,
          enhanced: mode == AsrMode.enhanced,
          hotwords: hotwords);
      debugPrint('[DSH][asr] warmup: recognizer preloaded in worker isolate');
    } catch (e) {
      debugPrint('[DSH][asr] warmup skipped: $e');
    }
  }

  /// 后台 isolate：分块读取模型文件并丢弃，把文件页拉进 OS 页缓存。
  static void _preloadFiles(String dir) {
    for (final f in AsrModelManager.files) {
      final file = File(p.join(dir, f));
      if (!file.existsSync()) continue;
      try {
        final raf = file.openSync();
        try {
          // 每次读 1MB，读到 EOF（返回空）为止；不一次性整读，避免内存尖峰
          while (raf.readSync(1 << 20).isNotEmpty) {}
        } finally {
          raf.closeSync();
        }
      } catch (_) {}
    }
  }

  final AudioRecorder _recorder = AudioRecorder();
  StreamSubscription<Uint8List>? _pcmSub;
  bool _sessionActive = false;

  @override
  Stream<String> get partialText => _requireWorkerSync().partials;

  @override
  Future<void> start() async {
    // 热词在主 isolate 读取（shared_preferences 平台通道不进后台 isolate），
    // 词表本身交给 worker 配置。
    final hotwordList = _normalizeHotwords(await AsrSettings.loadHotwords());
    final worker = await _requireWorker();
    // 1) 对齐识别器形态（预 warmed 时这里幂等秒回）。
    await worker.load(
        modelDir: modelDir, enhanced: enhanced, hotwords: hotwordList);
    // 2) 建会话流（per-stream 热词偏置在 worker 侧组装）。
    await worker.beginSession();
    // 3) 录音（主 isolate）→ PCM 块转发 worker。
    final pcmStream = await _recorder.startStream(const RecordConfig(
      encoder: AudioEncoder.pcm16bits,
      sampleRate: 16000,
      numChannels: 1,
      autoGain: true,
      echoCancel: true,
      noiseSuppress: true,
    ));
    _sessionActive = true;
    _pcmSub = pcmStream.listen(
      (bytes) => worker.feedAudio(bytes),
      onError: (Object e) {
        debugPrint('[DSH][asr] pcm stream error: $e');
      },
      cancelOnError: false,
    );
    debugPrint('[DSH][asr] session start');
  }

  @override
  Future<String> stop() async {
    await _pcmSub?.cancel();
    _pcmSub = null;
    try {
      await _recorder.stop();
    } catch (e) {
      debugPrint('[DSH][asr] recorder stop error: $e');
    }
    _sessionActive = false;
    // worker：结束输入 → 收尾解码 → 回传终稿 → 释放会话流。
    // start 失败路径上 worker 可能尚未创建——按空终稿处理，不抛。
    if (_worker == null) return '';
    final text = await _requireWorkerSync().endSession();
    final corrected = text.trim();
    debugPrint('[DSH][asr] session stop, final=${corrected.length} chars');
    return corrected;
  }

  /// stop 路径上 worker 必然已存在（start 创建过）；防御空指针。
  _AsrWorker _requireWorkerSync() {
    final w = _worker;
    if (w == null) {
      throw StateError('asr worker not running');
    }
    return w;
  }

  @override
  Future<void> dispose() async {
    // 会话流若还在（异常路径未 stop），让 worker 丢弃；识别器保留复用。
    if (_sessionActive) {
      try {
        await _worker?.discardSession();
      } catch (_) {}
      _sessionActive = false;
    }
    await _recorder.dispose();
  }

  /// 把热词表归一化为逐词列表：兼容用户以逗号/斜杠/换行/全角逗号混填的词表，
  /// 去掉空串与重复项——sherpa 按换行（含 '/'，CreateStream 会把斜杠转义成
  /// 换行）切分每个热词，逗号连写会被当成一个整体热词导致不生效。
  static List<String> _normalizeHotwords(String raw) {
    final seen = <String>{};
    final out = <String>[];
    for (final w in raw.split(RegExp(r'[,，/\n\r]'))) {
      final t = w.trim();
      if (t.isNotEmpty && seen.add(t)) out.add(t);
    }
    return out;
  }
}

/// worker isolate 的主 isolate 侧代理：命令通道 + partial 广播。
///
/// 协议（main → worker）：
/// - `{'cmd':'load', 'modelDir', 'enhanced', 'hotwords'}` 对齐识别器签名 +
///   配置热词校正 → 回 `{'ok':true}` / `{'error':msg}`；
/// - `{'cmd':'session'}` 建会话流 → 回 ok/error；
/// - `{'cmd':'audio', 'data':TransferableTypedData}` 喂 PCM 块；
/// - `{'cmd':'stop'}` 结束输入 → 回 `{'final':text}`；
/// - `{'cmd':'discard'}` 丢弃当前会话流（异常清理，无回包）。
/// （worker → main）`{'partial':text}` / `{'final':text}` / `{'ok':...}` /
/// `{'error':msg}`。
class _AsrWorker {
  SendPort? _toWorker;
  ReceivePort? _fromWorker;
  Completer<void>? _loadCompleter;
  Completer<void>? _sessionCompleter;
  Completer<String>? _stopCompleter;

  /// 实时转写广播（按住说话同一时刻最多一个会话，广播流安全）。
  final StreamController<String> _partialCtrl =
      StreamController<String>.broadcast();

  Stream<String> get partials => _partialCtrl.stream;

  Future<void> spawn() async {
    final ready = Completer<void>();
    final port = ReceivePort();
    _fromWorker = port;
    _spawnReady = ready;
    port.listen(_handleMessage);
    await Isolate.spawn(_workerMain, port.sendPort,
        debugName: 'sherpa-asr-worker');
    // worker 启动后第一件事是把自己的 SendPort 发回来（_handleMessage 里
    // 完成 _spawnReady）。
    await ready.future.timeout(const Duration(seconds: 10),
        onTimeout: () => throw StateError('asr worker spawn timeout'));
  }

  Completer<void>? _spawnReady;

  void _handleMessage(dynamic msg) {
    if (msg is SendPort) {
      _toWorker = msg;
      _spawnReady?.complete();
      _spawnReady = null;
      return;
    }
    if (msg is Map) _handleEvent(msg);
  }

  void _handleEvent(Map msg) {
    if (msg.containsKey('error')) {
      final err = msg['error'].toString();
      debugPrint('[DSH][asr] worker error: $err');
      _loadCompleter?.completeError(StateError(err));
      _sessionCompleter?.completeError(StateError(err));
      _stopCompleter?.complete('');
      _loadCompleter = null;
      _sessionCompleter = null;
      _stopCompleter = null;
      return;
    }
    if (msg.containsKey('ok')) {
      _loadCompleter?.complete();
      _sessionCompleter?.complete();
      _loadCompleter = null;
      _sessionCompleter = null;
      return;
    }
    if (msg['partial'] is String) {
      if (!_partialCtrl.isClosed) _partialCtrl.add(msg['partial'] as String);
      return;
    }
    if (msg.containsKey('final')) {
      final text = msg['final']?.toString() ?? '';
      _stopCompleter?.complete(text);
      _stopCompleter = null;
      return;
    }
  }

  Future<void> load(
      {required String modelDir,
      required bool enhanced,
      required List<String> hotwords}) async {
    final c = Completer<void>();
    _loadCompleter = c;
    _toWorker!.send({
      'cmd': 'load',
      'modelDir': modelDir,
      'enhanced': enhanced,
      'hotwords': hotwords,
    });
    return c.future;
  }

  Future<void> beginSession() async {
    final c = Completer<void>();
    _sessionCompleter = c;
    _toWorker!.send({'cmd': 'session'});
    return c.future;
  }

  void feedAudio(Uint8List bytes) {
    _toWorker?.send({
      'cmd': 'audio',
      'data': TransferableTypedData.fromList([bytes]),
    });
  }

  Future<String> endSession() async {
    final c = Completer<String>();
    _stopCompleter = c;
    _toWorker!.send({'cmd': 'stop'});
    return c.future;
  }

  Future<void> discardSession() async {
    _toWorker?.send({'cmd': 'discard'});
  }
}

/// worker isolate 入口：常驻，顺序处理命令。所有异常就地捕获回传。
Future<void> _workerMain(SendPort toMain) async {
  final port = ReceivePort();
  toMain.send(port.sendPort);

  sherpa.OnlineRecognizer? recognizer;
  String? loadedSignature;
  sherpa.OnlineStream? stream;
  final corrector = HotwordCorrector();
  final segments = StringBuffer();
  String modelDir = '';

  void drain(sherpa.OnlineRecognizer rec, sherpa.OnlineStream st) {
    var guard = 0;
    while (rec.isReady(st)) {
      rec.decode(st);
      if (++guard > 10000) break; // 防御：异常时避免死循环
    }
  }

  Future<void> alignRecognizer(
      {required bool enhanced, required List<String> hotwords}) async {
    await corrector.configure(modelDir, hotwords);
    // 加载形态签名：仅增强 / 仅热词（也需 beam）/ 纯贪心。任一变化重载，
    // 相同签名幂等——会话 start() 每次可放心调用做档位对齐。
    final signature = enhanced
        ? 'enhanced'
        : (corrector.decoderHotwords.isNotEmpty ? 'hotwords' : 'greedy');
    if (recognizer != null && loadedSignature == signature) return;
    // FFI 绑定必须先初始化（worker isolate 内同样指向 process 库），
    // 否则 OnlineRecognizer 抛 "Please initialize sherpa-onnx first"。
    sherpa.initBindings();
    final sw = Stopwatch()..start();
    final beam = enhanced || corrector.decoderHotwords.isNotEmpty;
    final rec = sherpa.OnlineRecognizer(sherpa.OnlineRecognizerConfig(
      model: sherpa.OnlineModelConfig(
        transducer: sherpa.OnlineTransducerModelConfig(
          encoder: '$modelDir/encoder.int8.onnx',
          decoder: '$modelDir/decoder.onnx',
          joiner: '$modelDir/joiner.int8.onnx',
        ),
        tokens: '$modelDir/tokens.txt',
        // 热词编码单元：本模型词表为字符级（含 byte fallback），cjkchar 让
        // EncodeHotwords 把热词逐字切分成 token；缺省空串会让热词编码直接
        // 失败（1.13.8 EncodeHotwords 实测）。
        modelingUnit: 'cjkchar',
        numThreads: 2,
        provider: 'cpu',
        debug: false,
      ),
      // 热词（ContextGraph 偏置）只在 modified_beam_search 下生效（1.13.8
      // 源码 InitOnlineStream 实测，greedy 静默忽略）——因此"有词表内热词"
      // 的标准档位同样切 beam（8 路，开销可控）。
      decodingMethod: beam ? 'modified_beam_search' : 'greedy_search',
      maxActivePaths: enhanced ? 16 : 8,
      hotwordsScore: 3.0,
      blankPenalty: enhanced ? 0.5 : 0.0,
      enableEndpoint: true,
      // 按住说话场景：静音 1.2s 判定断句（句间停顿即定稿），长句 20s 兜底
      rule1MinTrailingSilence: 2.4,
      rule2MinTrailingSilence: 1.2,
      rule3MinUtteranceLength: 20,
    ));
    recognizer?.free();
    recognizer = rec;
    loadedSignature = signature;
    debugPrint('[DSH][asr] recognizer loaded ($signature) '
        'in ${sw.elapsedMilliseconds}ms (worker isolate)');
  }

  await for (final msg in port) {
    if (msg is! Map) continue;
    try {
      switch (msg['cmd'] as String?) {
        case 'load':
          modelDir = msg['modelDir'] as String;
          await alignRecognizer(
            enhanced: msg['enhanced'] as bool? ?? false,
            hotwords: (msg['hotwords'] as List?)?.cast<String>() ?? const [],
          );
          toMain.send({'ok': true});
        case 'session':
          final rec = recognizer;
          if (rec == null) {
            toMain.send({'error': 'recognizer not loaded'});
            break;
          }
          stream?.free();
          segments.clear();
          stream = rec.createStream(
              hotwords: corrector.decoderHotwords.join('\n'));
          toMain.send({'ok': true});
        case 'audio':
          final st = stream;
          final rec = recognizer;
          if (st == null || rec == null) break;
          final bytes = (msg['data'] as TransferableTypedData)
              .materialize()
              .asUint8List();
          if (bytes.isEmpty) break;
          st.acceptWaveform(
              samples: _pcm16ToFloat32(bytes), sampleRate: 16000);
          drain(rec, st);
          final text = segments.toString() + rec.getResult(st).text;
          toMain.send({'partial': corrector.apply(text).trim()});
          if (rec.isEndpoint(st)) {
            // 静音断句：当前句定稿、拼接，识别器状态复位后继续听下一句
            final segment = rec.getResult(st).text.trim();
            if (segment.isNotEmpty) segments.write(segment);
            rec.reset(st);
            toMain.send(
                {'partial': corrector.apply(segments.toString()).trim()});
            debugPrint('[DSH][asr] endpoint, segment=$segment');
          }
        case 'stop':
          final st = stream;
          final rec = recognizer;
          var finalText = segments.toString();
          if (st != null && rec != null) {
            st.inputFinished();
            drain(rec, st);
            finalText += rec.getResult(st).text;
            st.free();
          }
          stream = null;
          segments.clear();
          toMain.send({'final': corrector.apply(finalText).trim()});
        case 'discard':
          stream?.free();
          stream = null;
          segments.clear();
        case 'exit':
          return;
      }
    } catch (e, st) {
      debugPrint('[DSH][asr] worker exception: $e\n$st');
      toMain.send({'error': e.toString()});
    }
  }
}

/// worker isolate 内的 PCM16LE → Float32。
Float32List _pcm16ToFloat32(Uint8List bytes) {
  final sampleCount = bytes.length ~/ 2;
  final data = ByteData.sublistView(bytes);
  final samples = Float32List(sampleCount);
  for (var i = 0; i < sampleCount; i++) {
    samples[i] = data.getInt16(i * 2, Endian.little) / 32768.0;
  }
  return samples;
}
