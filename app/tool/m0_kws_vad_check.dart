// M0 T0.5：KWS 常驻 + silero-VAD 预验（M3 唤醒的前置扫雷）。
// 指标：加载时长、RSS、正/负样本检测、VAD 分段与处理 RTF。
// 跑法：cd app && dart run tool/m0_kws_vad_check.dart
import 'dart:io';

import 'package:sherpa_onnx/sherpa_onnx.dart' as sherpa;

import 'm0_common.dart';

void main() {
  initSherpaBindings();
  _kws();
  _vad();
  stdout.writeln('\nKWS_VAD_CHECK_DONE');
}

File? _pickModel(Directory dir, String prefix) {
  final hits = dir
      .listSync()
      .whereType<File>()
      .where((f) {
        final n = f.uri.pathSegments.last.toLowerCase();
        return n.startsWith(prefix) && n.endsWith('.onnx');
      })
      .toList()
    ..sort((a, b) => b.lengthSync().compareTo(a.lengthSync()));
  return hits.isEmpty ? null : hits.first;
}

void _kws() {
  final dir = Directory('$defaultModelsRoot\\kws');
  if (!dir.existsSync()) {
    stdout.writeln('KWS: 目录缺失，跳过');
    return;
  }
  final enc = _pickModel(dir, 'encoder');
  final dec = _pickModel(dir, 'decoder');
  final jn = _pickModel(dir, 'joiner');
  final tokens = File('${dir.path}\\tokens.txt');
  final kwFile = File('${dir.path}\\keywords.txt');
  if (enc == null || dec == null || jn == null || !tokens.existsSync()) {
    stdout.writeln('KWS: 模型不全 enc=${enc?.path} dec=${dec?.path} joiner=${jn?.path}');
    return;
  }
  section('KWS @ ${dir.path}');
  row(['metric', 'value']);
  final sw = Stopwatch()..start();
  final spotter = sherpa.KeywordSpotter(sherpa.KeywordSpotterConfig(
    model: sherpa.OnlineModelConfig(
      transducer: sherpa.OnlineTransducerModelConfig(
          encoder: enc.path, decoder: dec.path, joiner: jn.path),
      tokens: tokens.path,
      numThreads: 2,
      provider: 'cpu',
    ),
    keywordsFile: kwFile.existsSync() ? kwFile.path : '',
    keywordsScore: 1.5,
    keywordsThreshold: 0.25,
    numTrailingBlanks: 1,
  ));
  sw.stop();
  row(['load ms', sw.elapsedMilliseconds.toString()]);
  row(['rss MB(after load)',
        (ProcessInfo.currentRss / 1048576).toStringAsFixed(0)]);

  // 自带 test_waves：positive 应命中、negative 应沉默
  final dirs = dir
      .listSync()
      .whereType<Directory>()
      .where((d) => d.uri.pathSegments.last.toLowerCase().contains('wave'))
      .toList();
  row(['test_waves dirs', dirs.map((d) => d.uri.pathSegments.last).join(',')]);
  for (final d in dirs) {
    final positive = d.uri.pathSegments.last.toLowerCase().contains('posi');
    final wavs = d.listSync().whereType<File>()
        .where((f) => f.path.toLowerCase().endsWith('.wav')).toList()
          ..sort((a, b) => a.path.compareTo(b.path));
    var hit = 0;
    double decodeMs = 0, audioSec = 0;
    for (final w in wavs) {
      final audio = readWavPcm16(w.path);
      final stream = spotter.createStream();
      final t = Stopwatch()..start();
      const chunk = 1600; // 100ms @16k
      for (var i = 0; i < audio.samples.length; i += chunk) {
        final end = (i + chunk > audio.samples.length) ? audio.samples.length : i + chunk;
        stream.acceptWaveform(
            samples: audio.samples.sublist(i, end), sampleRate: audio.sampleRate);
        while (spotter.isReady(stream)) {
          spotter.decode(stream);
        }
      }
      t.stop();
      decodeMs += t.elapsedMilliseconds.toDouble();
      audioSec += audioSeconds(audio);
      final r = spotter.getResult(stream);
      final detected = (r.keyword ?? '').isNotEmpty;
      if (detected) hit++;
      stdout.writeln('  [${d.uri.pathSegments.last}] ${w.uri.pathSegments.last} '
          'keyword="${r.keyword}"');
      spotter.reset(stream);
      stream.free();
    }
    row([d.uri.pathSegments.last,
         '${wavs.length} wav',
         'hits=$hit',
         'decode_rt ${(audioSec == 0 ? 0 : decodeMs / 1000 / audioSec).toStringAsFixed(3)}']);
  }
  spotter.free();
}

void _vad() {
  final vadOnnx = File('$defaultModelsRoot\\vad\\silero_vad.onnx');
  if (!vadOnnx.existsSync()) {
    stdout.writeln('VAD: silero_vad.onnx 缺失，跳过');
    return;
  }
  section('silero-VAD v5 @ ${vadOnnx.path}');
  final sw = Stopwatch()..start();
  final vad = sherpa.VoiceActivityDetector(
    config: sherpa.VadModelConfig(
      sileroVad: sherpa.SileroVadModelConfig(
        model: vadOnnx.path,
        threshold: 0.5,
        minSilenceDuration: 0.8, // 专项 §4.2 段尾定稿 800ms
        minSpeechDuration: 0.25,
        windowSize: 512,
        maxSpeechDuration: 15.0, // SenseVoice 单段上限
      ),
      sampleRate: 16000,
    ),
    bufferSizeInSeconds: 60,
  );
  sw.stop();
  row(['load ms', sw.elapsedMilliseconds.toString()]);
  row(['rss MB(after load)',
        (ProcessInfo.currentRss / 1048576).toStringAsFixed(0)]);

  // 样本：kws positive 优先，缺失则用 sensevoice test_wavs
  var posDir = Directory('$defaultModelsRoot\\kws\\test_waves\\positive');
  if (!posDir.existsSync()) {
    posDir = Directory('$defaultModelsRoot\\sensevoice\\test_wavs');
  }
  if (!posDir.existsSync()) {
    stdout.writeln('VAD: 无样本（kws positive / sensevoice test_wavs 均缺失），跳过');
    vad.free();
    return;
  }
  final wavs = posDir.listSync().whereType<File>()
      .where((f) => f.path.toLowerCase().endsWith('.wav')).toList()
        ..sort((a, b) => a.path.compareTo(b.path));
  double procMs = 0, audioSec = 0;
  var segs = 0;
  for (final w in wavs) {
    final audio = readWavPcm16(w.path);
    vad.reset();
    final t = Stopwatch()..start();
    const win = 512;
    for (var i = 0; i < audio.samples.length; i += win) {
      final end = (i + win > audio.samples.length) ? audio.samples.length : i + win;
      vad.acceptWaveform(audio.samples.sublist(i, end));
      while (!vad.isEmpty()) {
        final seg = vad.front();
        stdout.writeln('  [seg] start=${seg.start} len=${seg.samples.length} '
            '(${(seg.samples.length / 16000).toStringAsFixed(2)}s)');
        segs++;
        vad.pop();
      }
    }
    vad.flush();
    while (!vad.isEmpty()) {
      final seg = vad.front();
      segs++;
      vad.pop();
    }
    t.stop();
    procMs += t.elapsedMilliseconds.toDouble();
    audioSec += audioSeconds(audio);
  }
  row(['files', wavs.length.toString(), 'segments', segs.toString()]);
  row(['process_rt ${(audioSec == 0 ? 0 : procMs / 1000 / audioSec).toStringAsFixed(4)}',
       'budget', '0.05']);
  vad.free();
}
