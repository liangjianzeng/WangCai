// M0 T0.3：离线 TTS 本机实测（ASR&TTS 重构专项）。
// 自动识别引擎：目录里有 vocoder*.onnx 走 matcha；否则找 vits*.onnx 走 vits
// （matcha-icefall-zh-baker 官方包缺 vocoder，按母方案 §8 走 vits-zh-aishell3 兜底）。
// 指标：模型加载、逐句「合成一句播一句」链的**首句合成时长**（=首声代理）、
// RTF（合成/音频时长）、输出采样率、wav 落盘供人工听感验收（三档评级）。
// 跑法：cd app && dart run tool/m0_matcha_check.dart [modelDir]
import 'dart:io';
import 'dart:typed_data';

import 'package:sherpa_onnx/sherpa_onnx.dart' as sherpa;

import '../lib/tts/tts_text.dart' show segmentForTts;
import 'm0_common.dart';

const _sentences = [
  '今天天气不错，我们下午去公园散步吧。',
  '好的，已经为您找到三个相关方案，请看下面列表。',
  '汪柴是运行在本地电脑上的智能助理，断网也能听懂你说的话。',
  '会议纪要已生成，共十二条待办，其中三条需要今天确认。',
  '请把下面这段文字的语速调到一点五倍，再朗读一遍。',
];

String? _find(String dir, String name) {
  final f = File('$dir\\$name');
  return f.existsSync() ? f.path : null;
}

String? _findAny(String dir, String ext, String mustContain) {
  final hits = Directory(dir)
      .listSync()
      .whereType<File>()
      .where((f) => f.path.toLowerCase().endsWith(ext) &&
          f.path.toLowerCase().contains(mustContain))
      .toList();
  return hits.isEmpty ? null : hits.first.path;
}

String? _findVits(String dir) {
  final hits = Directory(dir)
      .listSync()
      .whereType<File>()
      .where((f) {
        final n = f.uri.pathSegments.last.toLowerCase();
        return n.endsWith('.onnx') && n.contains('vits');
      })
      .toList()
    ..sort((a, b) => b.lengthSync().compareTo(a.lengthSync()));
  return hits.isEmpty ? null : hits.first.path;
}

void main(List<String> args) {
  final dir = args.isNotEmpty ? args[0] : '$defaultModelsRoot\\tts-offline-zh';
  final vocoder = _findAny(dir, '.onnx', 'voc'); // vocoder*/vocos* 都匹配
  final acoustic = _find(dir, 'model.onnx') ?? _find(dir, 'model-steps-3.onnx');
  final vits = _findVits(dir);
  final tokens = _find(dir, 'tokens.txt');
  final voices = _find(dir, 'voices.bin');
  final isKokoro =
      voices != null && vits == null && vocoder == null && tokens != null;
  final isVits =
      !isKokoro && vocoder == null && vits != null; // 无 vocoder + 有 vits*.onnx → vits
  if (tokens == null ||
      (!isKokoro && !isVits && (acoustic == null || vocoder == null))) {
    stderr.writeln(
        '模型文件不全: kokoro=$voices vits=$vits acoustic=$acoustic vocoder=$vocoder tokens=$tokens');
    exit(2);
  }
  final dictDir = Directory('$dir\\dict');
  final lexicon = _find(dir, 'lexicon.txt');
  final fst = ['date.fst', 'number.fst', 'phone.fst', 'new_heteronym.fst']
      .map((f) => '$dir\\$f')
      .where((f) => File(f).existsSync())
      .join(',');

  initSherpaBindings();
  section('${isKokoro ? "kokoro" : isVits ? "vits" : "matcha"} @ $dir');
  row(['metric', 'value']);
  if (isKokoro) {
    final model = _find(dir, 'model.int8.onnx') ??
        _findAny(dir, '.onnx', 'model');
    row(['model MB', (File(model!).lengthSync() / 1048576).toStringAsFixed(1)]);
    row(['voices MB', (File(voices!).lengthSync() / 1048576).toStringAsFixed(1)]);
  } else if (isVits) {
    row(['vits MB', (File(vits!).lengthSync() / 1048576).toStringAsFixed(1)]);
  } else {
    row(['acoustic MB', (File(acoustic!).lengthSync() / 1048576).toStringAsFixed(1)]);
    row(['vocoder MB', (File(vocoder!).lengthSync() / 1048576).toStringAsFixed(1)]);
  }
  row(['ruleFsts', fst.isEmpty ? '(none)' : fst.split(',').length.toString()]);

  final sw = Stopwatch()..start();
  final kokoroModel =
      isKokoro ? (_find(dir, 'model.int8.onnx') ?? _findAny(dir, '.onnx', 'model')) : null;
  final espeakDir = Directory('$dir\\espeak-ng-data');
  final tts = sherpa.OfflineTts(sherpa.OfflineTtsConfig(
    model: sherpa.OfflineTtsModelConfig(
      matcha: isKokoro || isVits
          ? const sherpa.OfflineTtsMatchaModelConfig()
          : sherpa.OfflineTtsMatchaModelConfig(
              acousticModel: acoustic!,
              vocoder: vocoder!,
              lexicon: lexicon ?? '',
              tokens: tokens,
              dictDir: dictDir.existsSync() ? dictDir.path : '',
            ),
      vits: isVits
          ? sherpa.OfflineTtsVitsModelConfig(
              model: vits!,
              tokens: tokens,
              lexicon: lexicon ?? '',
            )
          : const sherpa.OfflineTtsVitsModelConfig(),
      kokoro: isKokoro
          ? sherpa.OfflineTtsKokoroModelConfig(
              model: kokoroModel!,
              voices: voices,
              tokens: tokens,
              dataDir: espeakDir.existsSync() ? espeakDir.path : '',
              lexicon: _find(dir, 'lexicon-zh.txt') ?? '',
              lang: 'zh',
            )
          : const sherpa.OfflineTtsKokoroModelConfig(),
      numThreads: 4,
      provider: 'cpu',
      debug: false,
    ),
    ruleFsts: fst,
  ));
  sw.stop();
  final loadMs = sw.elapsedMilliseconds;
  row(['load ms', loadMs.toString()]);
  row(['rss MB(after load)',
        (ProcessInfo.currentRss / 1048576).toStringAsFixed(0)]);
  row(['tts sampleRate', tts.sampleRate.toString()]);

  final outDir = Directory('$defaultModelsRoot\\out');
  if (!outDir.existsSync()) outDir.createSync(recursive: true);

  section('whole-sentence synthesis (5 sentences)');
  row(['sentence', 'chars', 'audio s', 'synth ms', 'RTF']);
  double firstSentenceMs = 0;
  for (var i = 0; i < _sentences.length; i++) {
    final s = _sentences[i];
    // 「合成一句播一句」链：每句独立合成计时（首句 = 首声代理）
    final t = Stopwatch()..start();
    final audio = tts.generate(text: s, sid: 0, speed: 1.0);
    t.stop();
    final ms = t.elapsedMilliseconds.toDouble();
    if (i == 0) firstSentenceMs = ms;
    final audioSec = audio.samples.length / (audio.sampleRate > 0 ? audio.sampleRate : 22050);
    // 落盘（人工听感验收）
    final wav = _wavFromPcm(audio.samples, audio.sampleRate);
    File('${outDir.path}\\tts_sent_$i.wav').writeAsBytesSync(wav);
    row(['sent$i', s.length.toString(),
         audioSec.toStringAsFixed(2), ms.toStringAsFixed(0),
         (ms / 1000 / audioSec).toStringAsFixed(3)]);
    audio.samples.toString(); // keep alive
  }

  section('long-text segment chain (auto-speak, <=600 chars)');
  final long = List.generate(3, (_) => _sentences.join()).join();
  final segs = segmentForTts(long);
  double firstMs = 0, totalMs = 0, audioAll = 0;
  for (var i = 0; i < segs.length; i++) {
    final t = Stopwatch()..start();
    final audio = tts.generate(text: segs[i], sid: 0, speed: 1.0);
    t.stop();
    if (i == 0) firstMs = t.elapsedMilliseconds.toDouble();
    totalMs += t.elapsedMilliseconds.toDouble();
    audioAll += audio.samples.length / (audio.sampleRate > 0 ? audio.sampleRate : 22050);
    if (i == 0) {
      File('${outDir.path}\\tts_seg0.wav')
          .writeAsBytesSync(_wavFromPcm(audio.samples, audio.sampleRate));
    }
  }
  row(['segments', segs.length.toString(), 'first seg ms', firstMs.toStringAsFixed(0)]);
  row(['total synth ms', totalMs.toStringAsFixed(0),
       'total audio s', audioAll.toStringAsFixed(2)]);
  row(['first-audio proxy ms', firstSentenceMs.toStringAsFixed(0),
       'budget', '1000']);

  tts.free();
  stdout.writeln('\nTTS_CHECK_DONE  wavs -> ${outDir.path}');
}

List<int> _wavFromPcm(List<double> samples, int sampleRate) {
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
