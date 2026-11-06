// M0 T0.2b：流式 Zipformer（按住说话现役引擎）本机基线（ASR&TTS 重构专项）。
// 指标：加载、逐 chunk 解码 RTF、尾点延迟。样本用 sensevoice test_wavs。
// 跑法：cd app && dart run tool/m0_streaming_check.dart [modelDir]
import 'dart:io';

import 'package:sherpa_onnx/sherpa_onnx.dart' as sherpa;

import 'm0_common.dart';

void main(List<String> args) {
  final dir = args.isNotEmpty
      ? args[0]
      : '$defaultModelsRoot\\streaming-zipformer';
  final enc = _pick(dir, 'encoder');
  final dec = _pick(dir, 'decoder');
  final jn = _pick(dir, 'joiner');
  final tokens = '$dir\\tokens.txt';
  if (enc == null || dec == null || jn == null || !File(tokens).existsSync()) {
    stderr.writeln('模型不全 enc=$enc dec=$dec joiner=$jn');
    exit(2);
  }
  initSherpaBindings();

  section('streaming-zipformer @ $dir');
  row(['metric', 'value']);
  final sw = Stopwatch()..start();
  final rec = sherpa.OnlineRecognizer(sherpa.OnlineRecognizerConfig(
    model: sherpa.OnlineModelConfig(
      transducer:
          sherpa.OnlineTransducerModelConfig(encoder: enc, decoder: dec, joiner: jn),
      tokens: tokens,
      numThreads: 4,
      provider: 'cpu',
    ),
  ));
  sw.stop();
  row(['load ms', sw.elapsedMilliseconds.toString()]);
  row(['rss MB(after load)',
        (ProcessInfo.currentRss / 1048576).toStringAsFixed(0)]);

  final wavsDir = Directory('$defaultModelsRoot\\sensevoice\\test_wavs');
  final wavs = wavsDir
      .listSync()
      .whereType<File>()
      .where((f) => f.path.toLowerCase().endsWith('.wav'))
      .toList()
    ..sort((a, b) => a.path.compareTo(b.path));
  if (wavs.isEmpty) {
    stderr.writeln('无测试 wav');
    exit(3);
  }

  section('流式解码（100ms chunk 喂入）');
  row(['file', 'sec', 'decode ms', 'rtf', 'final text']);
  for (final w in wavs) {
    final audio = readWavPcm16(w.path);
    final stream = rec.createStream();
    final t = Stopwatch()..start();
    const chunk = 1600; // 100ms @16k
    for (var i = 0; i < audio.samples.length; i += chunk) {
      final end = (i + chunk > audio.samples.length)
          ? audio.samples.length
          : i + chunk;
      stream.acceptWaveform(
          samples: audio.samples.sublist(i, end), sampleRate: audio.sampleRate);
      while (rec.isReady(stream)) {
        rec.decode(stream);
      }
    }
    // 尾点：输入结束后的最终解码（模拟松手出字）
    stream.inputFinished();
    while (rec.isReady(stream)) {
      rec.decode(stream);
    }
    t.stop();
    final r = rec.getResult(stream);
    final sec = audioSeconds(audio);
    row([w.uri.pathSegments.last, sec.toStringAsFixed(2),
         t.elapsedMilliseconds.toString(),
         (t.elapsedMilliseconds / 1000 / sec).toStringAsFixed(3),
         r.text]);
    stream.free();
  }
  rec.free();
  stdout.writeln('\nSTREAMING_CHECK_DONE');
}

String? _pick(String dir, String prefix) {
  final hits = Directory(dir)
      .listSync()
      .whereType<File>()
      .where((f) {
        final n = f.uri.pathSegments.last.toLowerCase();
        return n.startsWith(prefix) && n.endsWith('.onnx');
      })
      .toList()
    ..sort((a, b) => b.lengthSync().compareTo(a.lengthSync()));
  return hits.isEmpty ? null : hits.first.path;
}
