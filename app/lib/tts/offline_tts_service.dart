/// 离线英文朗读（P7）：sherpa-onnx `OfflineTts` 的第二套 `app.speak` 实现。
///
/// **为什么现在装得起来**：`sherpa_onnx` 早已是依赖（流式 ASR 在用），原生 `.so` 已在 APK 里，
/// 所以这条轨道**零新依赖**；唯一的成本是那个 ~40 MB 的 VITS 模型 —— 因此**不打包、不自动下载**，
/// 只在 `ApplicationSupport/tts/<模型名>/` 里出现"合格模型目录"时才启用（没模型 = 这个实现
/// `available == false`，能力注册表自动回落到 Edge TTS，听写一行代码都不用改）。
///
/// 三条纪律：
/// 1. **原生调用绝不许抛出去**：模型坏了 / 引擎初始化失败，一律变成 `lastFailureMessage` 让人看见，
///    平台侧靠"单条失败继续下一条"兜住，听写不许因为朗读引擎崩掉；
/// 2. **模型只装一次**：首次用到才加载（懒），`prewarm()` 把加载挪到听写开始之前，
///    别让用户点"开始"之后才卡那 1–2 秒；
/// 3. **它只管合成，不管播放**：播放复用 `EdgeTtsService` 已抽出的通用播控原语
///    （`beginPlayback/isCurrentPlayback/endPlayback/playCached`），保证"同时最多一个播报位"
///    与"取消当场放掉循环"这两条不变量只有一份实现。
///
/// 已知取舍（真机要盯的）：模型加载与合成跑在**主 isolate**。单词级合成很快（百毫秒级），
/// 但首次加载是秒级 —— 所以务必走 `prewarm`。若真机仍卡，照 `lib/asr/sherpa_streaming_asr.dart`
/// 的常驻 worker isolate 模式搬过来（FFI 指针不能跨 isolate，引擎必须长在 worker 里）。
library;

import 'dart:io';
import 'dart:math' as math;

import 'package:flutter/foundation.dart';
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';
import 'package:sherpa_onnx/sherpa_onnx.dart' as sherpa;

/// 引擎抽象：真机用 [SherpaOfflineTtsEngine]，测试塞假的即可（原生跑不了测试）。
abstract interface class OfflineTtsEngine {
  /// 加载模型（幂等；失败抛异常，由 [OfflineTtsService] 就地吞掉并记账）。
  Future<void> load();

  /// 合成一段。**采样率跟着结果走**：不同模型（16k/22.05k）不一样，
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

/// 真机引擎：薄薄一层 sherpa-onnx `OfflineTts`。
final class SherpaOfflineTtsEngine implements OfflineTtsEngine {
  SherpaOfflineTtsEngine(this.modelPath, this.tokensPath, {this.dataDir, this.numThreads = 2});

  final String modelPath;
  final String tokensPath;
  final String? dataDir;
  final int numThreads;

  sherpa.OfflineTts? _tts;
  bool _initialized = false;

  @override
  Future<void> load() async {
    if (_tts != null) return;
    if (!_initialized) {
      // 与 ASR 同一套：先绑原生符号，再建引擎。
      sherpa.initBindings();
      _initialized = true;
    }
    final config = sherpa.OfflineTtsConfig(
      model: sherpa.OfflineTtsModelConfig(
        vits: sherpa.OfflineTtsVitsModelConfig(
          model: modelPath,
          tokens: tokensPath,
          dataDir: dataDir ?? '',
        ),
        numThreads: numThreads,
        debug: false, // 别把引擎的日志刷进用户看得见的推理日志里
        provider: 'cpu',
      ),
    );
    _tts = sherpa.OfflineTts(config);
  }

  @override
  Future<OfflinePcm> pcm16(String text, {required int speakerId, required double speed}) async {
    final tts = _tts;
    if (tts == null) throw StateError('离线朗读引擎没加载');
    final audio = tts.generate(text: text, sid: speakerId, speed: speed);
    final samples = audio.samples; // Float32List，范围约 [-1,1]
    final out = Uint8List(samples.length * 2);
    final bd = ByteData.sublistView(out);
    for (var i = 0; i < samples.length; i++) {
      final v = (math.max(-1.0, math.min(1.0, samples[i])) * 32767).round();
      bd.setInt16(i * 2, v, Endian.little);
    }
    return OfflinePcm(out, audio.sampleRate);
  }

  @override
  Future<void> dispose() async {
    // sherpa 的 OfflineTts 要手动 free（用户负责回收），漏了就是几十 MB 常驻。
    try {
      _tts?.free();
    } catch (e) {
      debugPrint('[offline-tts] 释放引擎失败：$e');
    }
    _tts = null;
  }
}

/// 一个离线朗读引擎（含它的模型位置、失败记账与 WAV 落盘缓存）。
///
/// 注意 `available` 的含义很窄也很关键：**"这个引擎现在能不能替我合成英文"**。
/// 它不覆盖中文、不覆盖整句 —— 那些交给在线 Edge TTS，由 `OfflineTtsPort` 逐条决定走哪条路。
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

  String? get notReadyReason {
    if (!_layout.complete || _layout.dataDir == null) {
      // 出路要照着想：用户只会去"设置里能看到的目录"放文件，所以两个路径都给 ——
      // 绝对路径便于 adb 推，`ApplicationSupport/tts/<模型名>/` 是它在 app 里的名字。
      final need = <String>['model.onnx（或任意 *.onnx 主模型）', 'tokens.txt'];
      if (_layout.dataDir == null) need.add('espeak-ng-data/（英文模型必须有，否则会念错或崩）');
      return '离线朗读的模型没就位：把 ${need.join(' + ')} 放进 '
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
      Directory(p.join((await getApplicationSupportDirectory()).path, 'tts'));

  /// 这个引擎接不接这段文本。**宁可少接，不许念错**：模型是英文 VITS，
  /// 喂中文它不会报错、只会吐出念不成形的声音 —— 那比不念还糟（听写场景直接误导孩子）。
  bool supports(String text) {
    if (!_layout.complete) return false;
    final t = text.trim();
    if (t.isEmpty) return false;
    if (RegExp(r'[一-鿿]').hasMatch(t)) return false; // 含汉字一律交给在线
    return RegExp(r'[A-Za-z]').hasMatch(t); // 纯符号/数字也没意义
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

/// 模型文件布局。VITS/piper 类模型需要 `model.onnx` + `tokens.txt`；
/// 英文模型还要 `espeak-ng-data/`（没有它 piper 会念错或崩，所以按"需要"报给用户）。
final class OfflineTtsLayout {
  OfflineTtsLayout._(this.dir, this.model, this.tokens, this.dataDir);

  final String dir;
  final String? model;
  final String? tokens;
  final String? dataDir;

  bool get complete => model != null && tokens != null;

  static OfflineTtsLayout detect(String dir) {
    try {
      final d = Directory(dir);
      if (!d.existsSync()) return OfflineTtsLayout._(dir, null, null, null);
      String? model;
      String? tokens;
      String? data;
      for (final e in d.listSync()) {
        final name = p.basename(e.path).toLowerCase();
        if (e is File && name.endsWith('.onnx') && !name.contains('vocoder')) {
          // 多个 onnx 时挑个"像主模型"的：优先名字里带 model 的，否则取最大的那个。
          if (model == null || (name.contains('model') && !p.basename(model).toLowerCase().contains('model'))) {
            model = e.path;
          } else if (!name.contains('model')) {
            final a = File(model).statSync().size;
            final b = e.statSync().size;
            if (b > a) model = e.path;
          }
        } else if (e is File && name == 'tokens.txt') {
          tokens = e.path;
        } else if (e is Directory && (name == 'espeak-ng-data' || name == 'espeak_data')) {
          data = e.path;
        }
      }
      return OfflineTtsLayout._(dir, model, tokens, data);
    } catch (e) {
      debugPrint('[offline-tts] 探模型布局失败（$dir）：$e');
      return OfflineTtsLayout._(dir, null, null, null);
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
