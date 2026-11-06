/// 离线朗读（P7 → ASR&TTS 重构 T1.3）：sherpa-onnx `OfflineTts` 的 `app.speak` 第二套实现。
///
/// **为什么现在装得起来**：`sherpa_onnx` 早已是依赖（流式 ASR 在用），原生库已随包分发，
/// 所以这条轨道**零新依赖**；唯一的成本是模型本体 —— 因此**不打包、不自动下载**（T1.5
/// VoiceModelManager 接管线下载），只在 `ApplicationSupport/tts/<模型名>/` 里出现
/// "合格模型目录"时才启用（没模型 = 这个实现 `available == false`，能力注册表自动回落
/// 到 Edge TTS，听写一行代码都不用改）。
///
/// **T1.3：模型加载与合成全部跑常驻 worker isolate**（还掉旧版自注的主 isolate 债，
/// 模式对齐 `lib/asr/sherpa_streaming_asr.dart`）：
/// - `OfflineTts` 是重 FFI 对象（加载秒级、整句合成百毫秒~秒级），FFI 指针不能跨
///   isolate，所以引擎必须长在 worker 里；主 isolate 只发命令、收 PCM（TransferableTypedData
///   零拷贝转移），UI 不再可能被合成就近卡住；
/// - worker 常驻：首次加载完成后进程内复用；[OfflineTtsService.dispose] 只释放引擎
///   （`unload`），isolate 本身留着等下次 `load`，避免反复 spawn；
/// - worker 内所有异常就地捕获回传，朗读引擎炸了也杀不掉 App。
///
/// **多引擎（T1.3 就位、M2 转正）**：[OfflineTtsLayout] 自动识别 vits / matcha /
/// kokoro 三种模型目录形态（vits-zh-aishell3 兜底、matcha-icefall-zh-baker 首选、
/// Kokoro 备选，实测数据见 docs/M0-EVIDENCE-VOICE.md）。中文能力跟着布局走：
/// matcha/kokoro/带 lexicon 的中文 vits 才接汉字（`chineseCapable`），英文 piper
/// 模型喂中文"不报错但念不成形"的老规矩不变 —— **宁可少接，不许念错**。
///
/// 三条纪律（P7 原文保留）：
/// 1. **原生调用绝不许抛出去**：模型坏了 / 引擎初始化失败，一律变成 `lastFailureMessage` 让人看见，
///    平台侧靠"单条失败继续下一条"兜住，听写不许因为朗读引擎崩掉；
/// 2. **模型只装一次**：首次用到才加载（懒），`prewarm()` 把加载挪到听写开始之前；
/// 3. **它只管合成，不管播放**：播放复用 `EdgeTtsService` 已抽出的通用播控原语
///    （`beginPlayback/isCurrentPlayback/endPlayback/playCached`），保证"同时最多一个播报位"
///    与"取消当场放掉循环"这两条不变量只有一份实现。
library;

import 'dart:async';
import 'dart:io';
import 'dart:isolate';
import 'dart:math' as math;

import 'package:flutter/foundation.dart';
import 'package:path/path.dart' as p;
import 'package:sherpa_onnx/sherpa_onnx.dart' as sherpa;
import '../platform/sherpa_dll.dart';
import '../platform/wangcai_paths.dart';

/// 引擎抽象：真机用 [SherpaOfflineTtsEngine]，测试塞假的即可（原生跑不了测试）。
abstract interface class OfflineTtsEngine {
  /// 加载模型（幂等；失败抛异常，由 [OfflineTtsService] 就地吞掉并记账）。
  Future<void> load();

  /// 合成一段。**采样率跟着结果走**：不同模型（8k/16k/22.05k/24k）不一样，
  /// 拿引擎级的那个数字去拼 WAV 头，声音会变调 —— 那是最难听出来也最难查的错。
  Future<OfflinePcm> pcm16(String text, {required int speakerId, required double speed});

  Future<void> dispose();
}

/// 一段合成结果（PCM16 小端 + 它自己的采样率）。
final class OfflinePcm {
  const OfflinePcm(this.bytes, this.sampleRate);
  final Uint8List bytes;
  final int sampleRate;
}

/// sherpa-onnx `OfflineTts` 支持的模型家族（由 [OfflineTtsLayout.detect] 目录形态判定）。
enum OfflineTtsKind { vits, matcha, kokoro }

/// 真机引擎：主 isolate 侧的 worker 代理（T1.3）。
///
/// 协议（main → worker）：`{'cmd':'load','seq','spec'}` / `{'cmd':'synth','seq','text','sid','speed'}`
/// / `{'cmd':'unload'}`；（worker → main）`{'seq','ok'}` / `{'seq','sampleRate','pcm':TransferableTypedData}`
/// / `{'seq','error'}`。命令全部带 seq，回包按 seq 认领。
final class SherpaOfflineTtsEngine implements OfflineTtsEngine {
  SherpaOfflineTtsEngine(this._layout, {this.numThreads = 2, this.dllDir});

  final OfflineTtsLayout _layout;
  final int numThreads;

  /// DLL 目录（Windows 开发机 System32 onnxruntime 劫持防护）；null = 用
  /// WANGCAI_SHERPA_DLL_DIR 环境变量 / 平台默认搜索。
  final String? dllDir;

  bool _loaded = false;

  Map<String, Object?> _spec() => {
        'kind': _layout.kind.name,
        'model': _layout.model,
        'tokens': _layout.tokens,
        'lexicon': _layout.lexicon,
        'dataDir': _layout.dataDir,
        'voices': _layout.voices,
        'vocoder': _layout.vocoder,
        'dictDir': _layout.dictDir,
        'ruleFsts': _layout.ruleFsts,
        'ruleFars': _layout.ruleFars,
        'numThreads': numThreads,
        if (dllDir != null) 'dllDir': dllDir,
      };

  @override
  Future<void> load() async {
    if (_loaded) return;
    if (!_layout.complete) throw StateError('离线朗读模型没就位：${_layout.dir}');
    final w = await _TtsWorker.require();
    // 120s：正常加载秒级（M0 实测 1.9–8s）；超时 = completer 挂死类异常，
    // 宁可报失败回落 Edge 也不许静默卡死合成链。
    await w.load(_spec()).timeout(const Duration(seconds: 120));
    _loaded = true;
  }

  @override
  Future<OfflinePcm> pcm16(String text, {required int speakerId, required double speed}) async {
    if (!_loaded) throw StateError('离线朗读引擎没加载');
    final w = _TtsWorker.current;
    if (w == null) throw StateError('tts worker 没在跑');
    return w.synth(text, speakerId: speakerId, speed: speed);
  }

  @override
  Future<void> dispose() async {
    // 释放引擎（几十~几百 MB），worker isolate 留着复用（下次 load 秒回）。
    _TtsWorker.current?.unload();
    _loaded = false;
  }
}

/// worker isolate 的主 isolate 侧代理（进程级常驻，参照 sherpa_streaming_asr 的 _AsrWorker）。
class _TtsWorker {
  static _TtsWorker? _instance;

  static _TtsWorker? get current => _instance;

  static Future<_TtsWorker> require() async {
    var w = _instance;
    if (w == null) {
      w = _TtsWorker();
      _instance = w;
      await w.spawn();
    }
    return w;
  }

  SendPort? _toWorker;
  Completer<void>? _spawnReady;
  Completer<void>? _loadCompleter;
  int _seq = 0;
  final Map<int, Completer<OfflinePcm>> _pending = {};

  Future<void> spawn() async {
    final ready = Completer<void>();
    final port = ReceivePort();
    _spawnReady = ready;
    port.listen(_handleMessage);
    await Isolate.spawn(_ttsWorkerMain, port.sendPort,
        debugName: 'sherpa-tts-worker', errorsAreFatal: false);
    await ready.future
        .timeout(const Duration(seconds: 10),
            onTimeout: () => throw StateError('tts worker spawn timeout'));
  }

  void _handleMessage(dynamic msg) {
    if (msg is SendPort) {
      _toWorker = msg;
      _spawnReady?.complete();
      _spawnReady = null;
      return;
    }
    if (msg is! Map) return;
    final seq = msg['seq'];
    if (msg.containsKey('error')) {
      final err = msg['error'].toString();
      debugPrint('[DSH][offline-tts] worker error: $err');
      // 命令全部带 seq，error 回包也带 —— 认领顺序：先对 _pending（synth），
      // 对不上才是 load 的失败（否则 load 失败永远挂起，真踩过）。
      if (seq is int && _pending.containsKey(seq)) {
        _pending.remove(seq)!.completeError(StateError(err));
      } else {
        _loadCompleter?.completeError(StateError(err));
        _loadCompleter = null;
      }
      return;
    }
    if (msg.containsKey('ok')) {
      _loadCompleter?.complete();
      _loadCompleter = null;
      return;
    }
    if (seq is int) {
      final c = _pending.remove(seq);
      if (c == null) return;
      if (msg['error'] != null) {
        c.completeError(StateError(msg['error'].toString()));
      } else {
        final pcm = (msg['pcm'] as TransferableTypedData).materialize().asUint8List();
        c.complete(OfflinePcm(pcm, (msg['sampleRate'] as num).toInt()));
      }
    }
  }

  Future<void> load(Map<String, Object?> spec) {
    final c = Completer<void>();
    _loadCompleter = c;
    _toWorker!.send({'cmd': 'load', 'seq': ++_seq, 'spec': spec});
    return c.future;
  }

  Future<OfflinePcm> synth(String text, {required int speakerId, required double speed}) {
    final c = Completer<OfflinePcm>();
    final seq = ++_seq;
    _pending[seq] = c;
    _toWorker!.send({
      'cmd': 'synth',
      'seq': seq,
      'text': text,
      'sid': speakerId,
      'speed': speed,
    });
    return c.future;
  }

  void unload() => _toWorker?.send({'cmd': 'unload'});
}

/// worker isolate 入口：常驻，顺序处理命令，所有异常就地捕获回传。
Future<void> _ttsWorkerMain(SendPort toMain) async {
  final port = ReceivePort();
  toMain.send(port.sendPort);

  sherpa.OfflineTts? tts;
  String? loadedSignature;

  await for (final msg in port) {
    if (msg is! Map) continue;
    final seq = msg['seq'];
    try {
      switch (msg['cmd'] as String?) {
        case 'load':
          final spec = Map<String, Object?>.from(msg['spec'] as Map);
          final signature = spec.toString(); // 字段序固定（_spec()），串比对可靠
          if (tts == null || loadedSignature != signature) {
            try {
              tts?.free();
            } catch (_) {}
            tts = null;
            bindSherpa(spec['dllDir'] as String?);
            final sw = Stopwatch()..start();
            tts = _buildTts(spec);
            loadedSignature = signature;
            debugPrint('[DSH][offline-tts] engine loaded in '
                '${sw.elapsedMilliseconds}ms (worker isolate)');
          }
          toMain.send({'seq': seq, 'ok': true});
        case 'synth':
          final t = tts;
          if (t == null) {
            toMain.send({'seq': seq, 'error': '离线朗读引擎没加载'});
            break;
          }
          final audio = t.generate(
            text: msg['text'] as String,
            sid: (msg['sid'] as num).toInt(),
            speed: (msg['speed'] as num).toDouble(),
          );
          toMain.send({
            'seq': seq,
            'sampleRate': audio.sampleRate,
            'pcm': TransferableTypedData.fromList([_pcm16Bytes(audio.samples)]),
          });
        case 'unload':
          try {
            tts?.free();
          } catch (_) {}
          tts = null;
          loadedSignature = null;
        case 'exit':
          try {
            tts?.free();
          } catch (_) {}
          return;
      }
    } catch (e, s) {
      debugPrint('[DSH][offline-tts] worker exception: $e\n$s');
      toMain.send({'seq': seq, 'error': e.toString()});
    }
  }
}

/// 绑定原生库（T1.5 抽到 lib/platform/sherpa_dll.dart，ASR/VAD worker 共用）。

/// worker 侧按 spec 建引擎（三种模型家族各走各的 config；命名参数与
/// tool/m0_matcha_check.dart 实测通过的形态一致）。
sherpa.OfflineTts _buildTts(Map<String, Object?> spec) {
  final kind = OfflineTtsKind.values.byName(spec['kind'] as String? ?? 'vits');
  final numThreads = (spec['numThreads'] as num?)?.toInt() ?? 2;
  String s(String k) => spec[k] as String? ?? '';
  final modelCfg = sherpa.OfflineTtsModelConfig(
    vits: kind == OfflineTtsKind.vits
        ? sherpa.OfflineTtsVitsModelConfig(
            model: s('model'),
            tokens: s('tokens'),
            lexicon: s('lexicon'),
            dataDir: s('dataDir'),
          )
        : const sherpa.OfflineTtsVitsModelConfig(),
    matcha: kind == OfflineTtsKind.matcha
        ? sherpa.OfflineTtsMatchaModelConfig(
            acousticModel: s('model'),
            vocoder: s('vocoder'),
            lexicon: s('lexicon'),
            tokens: s('tokens'),
            dictDir: s('dictDir'),
          )
        : const sherpa.OfflineTtsMatchaModelConfig(),
    kokoro: kind == OfflineTtsKind.kokoro
        ? sherpa.OfflineTtsKokoroModelConfig(
            model: s('model'),
            voices: s('voices'),
            tokens: s('tokens'),
            dataDir: s('dataDir'),
            lexicon: s('lexicon'),
            lang: 'zh',
          )
        : const sherpa.OfflineTtsKokoroModelConfig(),
    numThreads: numThreads,
    provider: 'cpu',
    debug: false, // 别把引擎的日志刷进用户看得见的推理日志里
  );
  return sherpa.OfflineTts(sherpa.OfflineTtsConfig(
    model: modelCfg,
    ruleFsts: s('ruleFsts'),
    ruleFars: s('ruleFars'),
  ));
}

/// Float32 [-1,1] → PCM16 小端字节（在 worker 侧转，主 isolate 零计算）。
Uint8List _pcm16Bytes(List<double> samples) {
  final out = Uint8List(samples.length * 2);
  final bd = ByteData.sublistView(out);
  for (var i = 0; i < samples.length; i++) {
    final v = (math.max(-1.0, math.min(1.0, samples[i])) * 32767).round();
    bd.setInt16(i * 2, v, Endian.little);
  }
  return out;
}

/// 一个离线朗读引擎（含它的模型位置、失败记账与 WAV 落盘缓存）。
///
/// 注意 `available` 的含义很窄也很关键：**"这个引擎现在能不能替我合成它支持的语种"**。
/// 语种边界由布局决定（[OfflineTtsService.supports]），不接的交给在线 Edge TTS，
/// 由 `OfflineTtsPort` 逐条决定走哪条路。
final class OfflineTtsService {
  OfflineTtsService({
    required this.modelDir,
    required OfflineTtsEngine Function(OfflineTtsLayout layout) engineFactory,
  }) : _layout = OfflineTtsLayout.detect(modelDir),
       _engineFactory = engineFactory;

  /// 模型目录（`ApplicationSupport/tts/<模型名>/`）。
  final String modelDir;
  final OfflineTtsEngine Function(OfflineTtsLayout layout) _engineFactory;
  final OfflineTtsLayout _layout;

  OfflineTtsEngine? _engine;
  String? _failure;
  final Map<String, File> _cache = {};
  Directory? _cacheDir;

  /// 模型文件齐不齐 —— **不加载模型就能回答**，能力注册表靠这个决定要不要用离线实现。
  bool get modelPresent => _layout.complete;

  /// 识别出的模型家族（vits/matcha/kokoro）—— 日志与 M2 回落链排障用。
  OfflineTtsKind get kind => _layout.kind;

  String? get notReadyReason {
    if (!_layout.complete) {
      // 出路要照着想：用户只会去"设置里能看到的目录"放文件，所以两个路径都给 ——
      // 绝对路径便于 adb 推，`ApplicationSupport/tts/<模型名>/` 是它在 app 里的名字。
      final need = <String>['model.onnx（或任意 *.onnx 主模型）', 'tokens.txt'];
      if (_layout.kind == OfflineTtsKind.matcha && _layout.vocoder == null) {
        need.add('vocoder*.onnx（matcha 必须带声码器，官方包不含，需另取）');
      } else if (_layout.kind == OfflineTtsKind.kokoro && _layout.voices == null) {
        need.add('voices.bin（Kokoro 必需）');
      } else if (_layout.kind == OfflineTtsKind.vits &&
          !_layout.chineseCapable &&
          _layout.dataDir == null) {
        need.add('espeak-ng-data/（英文模型必须有，否则会念错或崩）');
      }
      return '离线朗读的模型没就位：把 ${need.join(' + ')} 放进 '
          'ApplicationSupport/tts/<模型名>/（本机：${_layout.dir}）就能离线播';
    }
    if (_layout.kind == OfflineTtsKind.vits &&
        !_layout.chineseCapable &&
        _layout.dataDir == null) {
      // 齐了但英文模型缺 espeak 数据：加载多半失败，提前把出路说清楚。
      return '离线朗读的模型没就位：把 espeak-ng-data/（英文模型必须有，否则会念错或崩）放进 '
          'ApplicationSupport/tts/<模型名>/（本机：${_layout.dir}）就能离线播';
    }
    return _failure;
  }

  String? get lastFailureMessage => _failure;

  /// 找模型目录：`ApplicationSupport/tts/*/` 里第一个文件齐的。找不到返回 null（= 不启用离线）。
  static Future<String?> locateModelDir() async {
    try {
      final root = await _rootDir();
      if (!root.existsSync()) return null;
      for (final d in root.listSync().whereType<Directory>().toList()..sort((a, b) => a.path.compareTo(b.path))) {
        if (OfflineTtsLayout.detect(d.path).complete) return d.path;
      }
    } catch (e) {
      debugPrint('[offline-tts] 扫模型目录失败：$e');
    }
    return null;
  }

  static Future<Directory> _rootDir() async =>
      Directory(WangCaiPaths.dataDir('tts').path);

  /// 这个引擎接不接这段文本。**宁可少接，不许念错**：英文 VITS 模型喂中文不会报错、
  /// 只会吐出念不成形的声音 —— 那比不念还糟（听写场景直接误导孩子）。
  /// 中文引擎（matcha/kokoro/带 lexicon 的中文 vits，见 [OfflineTtsLayout.chineseCapable]）
  /// 反过来接汉字；两边都要求至少有一个可念的实义字符。
  bool supports(String text) {
    if (!_layout.complete) return false;
    final t = text.trim();
    if (t.isEmpty) return false;
    if (!RegExp(r'[A-Za-z0-9一-鿿]').hasMatch(t)) return false; // 纯符号没意义
    if (_layout.chineseCapable) return true;
    if (RegExp(r'[一-鿿]').hasMatch(t)) return false; // 含汉字一律交给在线
    return RegExp(r'[A-Za-z]').hasMatch(t);
  }

  /// 把模型加载挪到听写开始之前（纪律 2：别让用户点"开始"之后才卡那 1–2 秒）。
  /// 失败不抛，只记账（能力注册表/黄条会看到）。
  Future<void> prewarm() async {
    if (!_layout.complete) return;
    try {
      await _ensureEngine();
    } catch (e) {
      _failure = '离线朗读预热失败：$e';
      debugPrint('[offline-tts] $lastFailureMessage');
    }
  }

  /// 合成一条并落到缓存文件；失败返回 null（原因看 [lastFailureMessage]），**绝不抛**。
  Future<File?> synthesizeToFile(String text, {required String voice, required int rate}) async {
    if (!_layout.complete) {
      _failure = notReadyReason;
      return null;
    }
    final speed = speedFromRate(rate);
    final key = '${text.trim()}|$speed';
    final hit = _cache[key];
    if (hit != null && await hit.exists()) return hit;
    try {
      final engine = await _ensureEngine();
      final pcm = await engine.pcm16(text.trim(), speakerId: 0, speed: speed);
      final wav = wavFromPcm16(pcm.bytes, sampleRate: pcm.sampleRate);
      final dir = await _ensureCacheDir();
      final file = File(p.join(dir.path, 'off_${key.hashCode.toRadixString(16)}_${key.length}.wav'));
      if (!await file.exists()) await file.writeAsBytes(wav, flush: true);
      _cache[key] = file;
      _failure = null;
      return file;
    } catch (e) {
      // 记账而不是抛出：调用方（HostSpeak）要的是"这条没成，下一条继续"。
      _failure = '离线朗读没念成：$e';
      debugPrint('[offline-tts] $_failure');
      return null;
    }
  }

  Future<OfflineTtsEngine> _ensureEngine() async {
    final e = _engine;
    if (e != null) return e;
    final created = _engineFactory(_layout);
    await created.load();
    _engine = created;
    return created;
  }

  Future<Directory> _ensureCacheDir() async {
    final d = _cacheDir;
    if (d != null) return d;
    final dir = Directory(p.join(modelDir, '.cache'));
    if (!await dir.exists()) await dir.create(recursive: true);
    _cacheDir = dir;
    return dir;
  }

  Future<void> dispose() async {
    await _engine?.dispose();
    _engine = null;
  }
}

/// 模型文件布局（T1.3 多引擎）：
/// - **vits / piper**：`model.onnx + tokens.txt`；英文 piper 还要 `espeak-ng-data/`
///   （没有它 piper 会念错或崩，所以按"需要"报给用户）；中文 vits（vits-zh-aishell3）
///   带 `lexicon.txt`、不需要 espeak。
/// - **matcha**：`model-steps-3.onnx（或 model.onnx）+ vocoder*.onnx + tokens.txt +
///   dict/（jieba）`（matcha-icefall-zh-baker；官方包不含 vocoder，见台账）。
/// - **kokoro**：`model*.onnx + voices.bin + tokens.txt + espeak-ng-data/`。
final class OfflineTtsLayout {
  OfflineTtsLayout._(
    this.dir,
    this.model,
    this.tokens,
    this.dataDir,
    this.lexicon,
    this.voices,
    this.vocoder,
    this.dictDir,
    this.ruleFsts,
    this.ruleFars,
  );

  final String dir;
  final String? model;
  final String? tokens;
  final String? dataDir;
  final String? lexicon;
  final String? voices;
  final String? vocoder;
  final String? dictDir;

  /// 逗号分隔的 TextNormalisation fst（date/number/phone/…），没有则 null。
  final String? ruleFsts;

  /// rule.far（vits-zh-aishell3 带），没有则 null。
  final String? ruleFars;

  OfflineTtsKind get kind {
    if (voices != null) return OfflineTtsKind.kokoro;
    if (vocoder != null) return OfflineTtsKind.matcha;
    return OfflineTtsKind.vits;
  }

  /// 这个布局的模型接不接中文（英文 piper = false，见 [OfflineTtsService.supports]）。
  bool get chineseCapable => switch (kind) {
        OfflineTtsKind.matcha => true,
        OfflineTtsKind.kokoro => true,
        OfflineTtsKind.vits => lexicon != null,
      };

  bool get complete =>
      model != null &&
      tokens != null &&
      (kind != OfflineTtsKind.matcha || vocoder != null) &&
      (kind != OfflineTtsKind.kokoro || voices != null);

  static OfflineTtsLayout detect(String dir) {
    try {
      final d = Directory(dir);
      if (!d.existsSync()) {
        return OfflineTtsLayout._(dir, null, null, null, null, null, null, null, null, null);
      }
      String? model;
      String? tokens;
      String? data;
      String? lexicon;
      String? voices;
      String? vocoder;
      String? dictDir;
      String? ruleFars;
      final fsts = <String>[];
      for (final e in d.listSync()) {
        final name = p.basename(e.path).toLowerCase();
        if (e is File && name.endsWith('.onnx')) {
          if (name.contains('vocoder')) {
            vocoder ??= e.path; // 多个声码器取第一个（通常只有一个）
          } else {
            // 多个 onnx 时挑个"像主模型"的：优先名字里带 model 的，否则取最大的那个。
            if (model == null ||
                (name.contains('model') && !p.basename(model).toLowerCase().contains('model'))) {
              model = e.path;
            } else if (!name.contains('model')) {
              final a = File(model).statSync().size;
              final b = e.statSync().size;
              if (b > a) model = e.path;
            }
          }
        } else if (e is File && name == 'tokens.txt') {
          tokens = e.path;
        } else if (e is File && (name == 'lexicon.txt' || name == 'lexicon-zh.txt')) {
          lexicon ??= e.path;
        } else if (e is File && name == 'voices.bin') {
          voices = e.path;
        } else if (e is File && name.endsWith('.fst')) {
          fsts.add(e.path);
        } else if (e is File && name == 'rule.far') {
          ruleFars = e.path;
        } else if (e is Directory && (name == 'espeak-ng-data' || name == 'espeak_data')) {
          data = e.path;
        } else if (e is Directory && name == 'dict') {
          dictDir = e.path;
        }
      }
      fsts.sort((a, b) => a.compareTo(b));
      return OfflineTtsLayout._(
        dir,
        model,
        tokens,
        data,
        lexicon,
        voices,
        vocoder,
        dictDir,
        fsts.isEmpty ? null : fsts.join(','),
        ruleFars,
      );
    } catch (e) {
      debugPrint('[offline-tts] 探模型布局失败（$dir）：$e');
      return OfflineTtsLayout._(dir, null, null, null, null, null, null, null, null, null);
    }
  }
}

/// Edge TTS 的 rate（-100..100）→ 离线引擎的 speed 倍率。两条链路的"快慢"要能对齐，
/// 否则用户把语速调慢，离线那条没反应 —— 同一个设置项必须管住两条实现。
double speedFromRate(int rate) {
  final r = rate.clamp(-100, 100) / 100.0; // -1..1
  // 满量程正好对上 0.5×–2.0×：用户在设置里把语速拉满，离线那条也必须真的快一倍，
  // 否则同一个设置项管不住两条实现（"我调了语速怎么没反应"就是这种）。
  return (1.0 + r).clamp(0.5, 2.0).toDouble();
}

/// PCM16 → WAV（audioplayers 只认带容器的文件，裸 PCM 播不出来）。
Uint8List wavFromPcm16(Uint8List pcm, {required int sampleRate, int channels = 1, int bitsPerSample = 16}) {
  final byteRate = sampleRate * channels * bitsPerSample ~/ 8;
  final out = Uint8List(44 + pcm.length);
  final bd = ByteData.sublistView(out);
  void ascii(int off, String s) {
    for (var i = 0; i < s.length; i++) {
      out[off + i] = s.codeUnitAt(i);
    }
  }

  ascii(0, 'RIFF');
  bd.setUint32(4, 36 + pcm.length, Endian.little);
  ascii(8, 'WAVE');
  ascii(12, 'fmt ');
  bd.setUint32(16, 16, Endian.little);
  bd.setUint16(20, 1, Endian.little); // PCM
  bd.setUint16(22, channels, Endian.little);
  bd.setUint32(24, sampleRate, Endian.little);
  bd.setUint32(28, byteRate, Endian.little);
  bd.setUint16(32, channels * bitsPerSample ~/ 8, Endian.little);
  bd.setUint16(34, bitsPerSample, Endian.little);
  ascii(36, 'data');
  bd.setUint32(40, pcm.length, Endian.little);
  out.setRange(44, 44 + pcm.length, pcm);
  return out;
}
