// M3 T3.0：KWS 本机实测验证（ASR&TTS 重构专项，唤醒词「汪柴」闭环）。
// Part A：wenetspeech-3.3M 官方 7 条 test wav + 自带拼音关键词表 → 阈值矩阵求命中
//         （模型完整性 + 灵敏度基线）。
// Part B：matcha 合成「汪柴，汪柴！」→ 重采样 16k + 尾静音 → 自定义唤醒词关键字
//         "w āng ch ái @汪柴" 必须命中（「合成→检测」与真实唤醒链同源）。
// 指标：加载时长、RSS、RTF（解码墙钟/音频时长；常驻预算 ≤5% 单核 → RTF 需远小于 1）。
// 跑法：cd app && dart run tool/m3_kws_check.dart
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:sherpa_onnx/sherpa_onnx.dart' as sherpa;

import 'm0_common.dart';

const _kwsDir = '$defaultModelsRoot\\kws';
const _matchaDir = '$defaultModelsRoot\\matcha-zh-baker';

/// 阈值档位矩阵（母方案灵敏度滑条 0.3–0.8 是 UI 口径，底层就是这个数）。
/// 可用环境变量 KWS_TH=0.5,0.4,0.3 覆盖（灵敏度默认值标定用）。
const _thresholds = [0.25, 0.15, 0.1];

List<double> _thresholdList() {
  final env = Platform.environment['KWS_TH'];
  if (env == null || env.trim().isEmpty) return _thresholds;
  return env
      .split(',')
      .map((s) => double.tryParse(s.trim()))
      .whereType<double>()
      .toList();
}

sherpa.KeywordSpotter _makeSpotter(String keywordsFile, double threshold) =>
    sherpa.KeywordSpotter(sherpa.KeywordSpotterConfig(
      model: const sherpa.OnlineModelConfig(
        transducer: sherpa.OnlineTransducerModelConfig(
          encoder:
              r'C:\dev-tools\voice-models\kws\encoder-epoch-99-avg-1-chunk-16-left-64.onnx',
          decoder:
              r'C:\dev-tools\voice-models\kws\decoder-epoch-99-avg-1-chunk-16-left-64.onnx',
          joiner:
              r'C:\dev-tools\voice-models\kws\joiner-epoch-99-avg-1-chunk-16-left-64.onnx',
        ),
        tokens: r'C:\dev-tools\voice-models\kws\tokens.txt',
        numThreads: 2,
        provider: 'cpu',
      ),
      keywordsFile: keywordsFile,
      keywordsThreshold: threshold,
      keywordsScore: 1.5,
      numTrailingBlanks: 2,
    ));

/// 单条音频跑一遍流式 KWS（spotter 复用，流新建）。返回 (命中词, 解码 ms)。
(String, double) _feed(sherpa.KeywordSpotter spotter, Float32List samples,
    int sampleRate) {
  final sw = Stopwatch()..start();
  String hit = '';
  final stream = spotter.createStream();
  const chunk = 1600; // 100ms @16k
  for (var off = 0; off < samples.length; off += chunk) {
    final end = (off + chunk) > samples.length ? samples.length : off + chunk;
    stream.acceptWaveform(
        samples: samples.sublist(off, end), sampleRate: 16000);
    while (spotter.isReady(stream)) {
      spotter.decode(stream);
    }
    final kw = spotter.getResult(stream).keyword;
    if (kw.isNotEmpty && hit.isEmpty) hit = kw;
  }
  // 尾静音推 trailing blanks 出终点
  stream.acceptWaveform(samples: Float32List(3200), sampleRate: 16000);
  while (spotter.isReady(stream)) {
    spotter.decode(stream);
  }
  final kw = spotter.getResult(stream).keyword;
  if (kw.isNotEmpty && hit.isEmpty) hit = kw;
  stream.free();
  sw.stop();
  return (hit, sw.elapsedMilliseconds.toDouble());
}

/// 最近邻重采样（KWS 特征对走样不敏感，验证用途够用）。
Float32List _resample(Float32List src, int srcRate, int dstRate) {
  if (srcRate == dstRate) return src;
  final n = (src.length * dstRate / srcRate).floor();
  final out = Float32List(n);
  for (var i = 0; i < n; i++) {
    out[i] = src[(i * srcRate / dstRate).floor().clamp(0, src.length - 1)];
  }
  return out;
}

void main() {
  initSherpaBindings();
  var pass = 0, fail = 0;
  final swLoad = Stopwatch()..start();
  final probe = _makeSpotter('$_kwsDir\\test_keywords.txt', 0.25);
  swLoad.stop();

  section('A. 官方 test wavs × 阈值矩阵');
  final ths = _thresholdList();
  row(['wav', ...[for (final t in ths) 'th=${t.toStringAsFixed(2)}'],
        'audio s', 'RTF']);
  final wavs = [for (var i = 0; i < 7; i++) '$_kwsDir\\test_$i.wav']
      .where((p) => File(p).existsSync())
      .toList();
  var aHits = 0;
  for (final w in wavs) {
    final wav = readWavPcm16(w);
    final cells = <String>[];
    var decodeMs = 0.0;
    var anyHit = false;
    for (final th in ths) {
      final spotter = _makeSpotter('$_kwsDir\\test_keywords.txt', th);
      final (kw, ms) = _feed(spotter, wav.samples, wav.sampleRate);
      spotter.free();
      cells.add(kw.isEmpty ? '-' : kw);
      decodeMs = ms;
      if (kw.isNotEmpty) anyHit = true;
    }
    final audioSec = wav.samples.length / wav.sampleRate;
    row([
      w.split('\\').last, ...cells, audioSec.toStringAsFixed(2),
      (decodeMs / 1000 / audioSec).toStringAsFixed(4)
    ]);
    if (anyHit) aHits++;
  }
  // 完整性口径：官方 7 条并非都与 test_keywords 配对（有 3 条对 keywords_raw），
  // 只要 ≥3 条命中即证明模型+解码链完好；逐条成败不计。
  row(['A 命中数', '$aHits/${wavs.length}', '要求', '>=3']);
  if (aHits >= 3) {
    pass++;
  } else {
    fail++;
  }
  probe.free();
  row(['load ms(首个 spotter)', swLoad.elapsedMilliseconds.toString(), 'rss MB',
        (ProcessInfo.currentRss / 1048576).toStringAsFixed(0)]);

  section('B. matcha 合成「汪柴」→ KWS 自定义唤醒词（E2E）');
  final lexicon = File('$_matchaDir\\lexicon.txt');
  final dictDir = Directory('$_matchaDir\\dict');
  final tts = sherpa.OfflineTts(sherpa.OfflineTtsConfig(
    model: sherpa.OfflineTtsModelConfig(
      matcha: sherpa.OfflineTtsMatchaModelConfig(
        acousticModel: '$_matchaDir\\model-steps-3.onnx',
        vocoder: '$_matchaDir\\vocos-22khz-univ.onnx',
        lexicon: lexicon.existsSync() ? lexicon.path : '',
        tokens: '$_matchaDir\\tokens.txt',
        dictDir: dictDir.existsSync() ? dictDir.path : '',
      ),
      numThreads: 4,
      provider: 'cpu',
    ),
  ));
  final audio = tts.generate(text: '汪柴，汪柴！', sid: 0, speed: 0.9);
  tts.free();
  final outDir = Directory('$defaultModelsRoot\\out');
  if (!outDir.existsSync()) outDir.createSync(recursive: true);
  final pcm16k = _resample(audio.samples, audio.sampleRate, 16000);
  File('${outDir.path}\\kws_wangchai_16k.wav')
      .writeAsBytesSync(_wav16(pcm16k, 16000)); // 人工复听留证
  // 唤醒词关键字行：tokens.txt 里的拼音初/终音 token + @汉字注释
  final kwFile = File('${outDir.path}\\keywords_wangchai.txt');
  kwFile.writeAsStringSync('w āng ch ái @汪柴\n', encoding: utf8);
  row(['keyword line', 'w āng ch ái @汪柴', 'audio s',
        (pcm16k.length / 16000).toStringAsFixed(2)]);
  var wangchaiHit = false;
  for (final th in ths) {
    final spotter = _makeSpotter(kwFile.path, th);
    final (kw, ms) = _feed(spotter, pcm16k, 16000);
    spotter.free();
    row(['th=${th.toStringAsFixed(2)}', kw.isEmpty ? '(无命中)' : kw, 'decode ms',
          ms.toStringAsFixed(0)]);
    if (kw.isNotEmpty) wangchaiHit = true;
  }
  if (wangchaiHit) {
    pass++;
  } else {
    fail++;
  }

  stdout.writeln('\nKWS_CHECK_DONE PASS=$pass FAIL=$fail');
  if (fail > 0) exit(1);
}

List<int> _wav16(List<double> samples, int sampleRate) {
  final bytes = Uint8List(44 + samples.length * 2);
  final bd = ByteData.sublistView(bytes);
  void ascii(int off, String s) {
    for (var i = 0; i < s.length; i++) {
      bytes[off + i] = s.codeUnitAt(i);
    }
  }

  ascii(0, 'RIFF');
  bd.setUint32(4, 36 + samples.length * 2, Endian.little);
  ascii(8, 'WAVE');
  ascii(12, 'fmt ');
  bd.setUint32(16, 16, Endian.little);
  bd.setUint16(20, 1, Endian.little);
  bd.setUint16(22, 1, Endian.little);
  bd.setUint32(24, sampleRate, Endian.little);
  bd.setUint32(28, sampleRate * 2, Endian.little);
  bd.setUint16(32, 2, Endian.little);
  bd.setUint16(34, 16, Endian.little);
  ascii(36, 'data');
  bd.setUint32(40, samples.length * 2, Endian.little);
  for (var i = 0; i < samples.length; i++) {
    final v = (samples[i].clamp(-1.0, 1.0) * 32767).round();
    bd.setInt16(44 + i * 2, v, Endian.little);
  }
  return bytes;
}
