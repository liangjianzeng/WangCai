// M0 T0.2：SenseVoice-Small int8 本机实测（ASR&TTS 重构专项）。
// 指标：模型加载时长、5s 级中文段解码延迟（热 3 次取中位）、RTF、字面文本
// （富转写标签原样打印——T1.4 剥离规则样本）、ITN 形态。台账进
// docs（M0-EVIDENCE-VOICE.md，注明本机=i5-7400T 口径，非 285H）。
// 跑法：cd app && dart run tool/m0_sensevoice_check.dart [modelDir]
import 'dart:io';

import 'package:sherpa_onnx/sherpa_onnx.dart' as sherpa;

import 'm0_common.dart';

void main(List<String> args) {
  final dir = args.isNotEmpty ? args[0] : '$defaultModelsRoot\\sensevoice';
  final modelFile = '$dir\\model.int8.onnx';
  if (!File(modelFile).existsSync()) {
    stderr.writeln('模型缺失: $modelFile');
    exit(2);
  }
  initSherpaBindings();

  section('SenseVoice-Small int8 @ $dir');
  row(['metric', 'value']);
  row(['model MB',
        (File(modelFile).lengthSync() / 1048576).toStringAsFixed(1)]);

  final sw = Stopwatch()..start();
  final rec = sherpa.OfflineRecognizer(sherpa.OfflineRecognizerConfig(
    model: sherpa.OfflineModelConfig(
      senseVoice: sherpa.OfflineSenseVoiceModelConfig(
        model: modelFile,
        language: 'zh',
        useInverseTextNormalization: true,
      ),
      tokens: '$dir\\tokens.txt',
      numThreads: 4,
      provider: 'cpu',
      debug: false,
    ),
  ));
  sw.stop();
  row(['load ms', sw.elapsedMilliseconds.toString()]);
  row(['rss MB(after load)',
        (ProcessInfo.currentRss / 1048576).toStringAsFixed(0)]);

  // 测试 wav：模型包自带 test_wavs；没有就找任意 *.wav
  var wavs = <File>[];
  for (final cand in ['test_wavs', 'Test-Wave', 'test_wav']) {
    final d = Directory('$dir\\$cand');
    if (d.existsSync()) {
      wavs = d.listSync().whereType<File>()
          .where((f) => f.path.toLowerCase().endsWith('.wav')).toList()
            ..sort((a, b) => a.path.compareTo(b.path));
      break;
    }
  }
  if (wavs.isEmpty) {
    stderr.writeln('找不到测试 wav（test_wavs）——请放样本再跑');
    exit(3);
  }

  section('逐条解码（冷 1 + 热 3 取中位）');
  row(['file', 'sec', 'cold ms', 'warm ms', 'rtf']);
  for (final w in wavs) {
    final audio = readWavPcm16(w.path);
    double decodeOnce() {
      final t = Stopwatch()..start();
      final st = rec.createStream();
      st.acceptWaveform(samples: audio.samples, sampleRate: audio.sampleRate);
      rec.decode(st);
      final r = rec.getResult(st);
      t.stop();
      stdout.writeln('  text[${w.uri.pathSegments.last}] raw="${r.text}"');
      return t.elapsedMilliseconds.toDouble();
    }

    final cold = decodeOnce();
    final warm = [decodeOnce(), decodeOnce(), decodeOnce()]..sort();
    final med = warm[1];
    final sec = audioSeconds(audio);
    row([w.uri.pathSegments.last, sec.toStringAsFixed(2), cold.toStringAsFixed(0),
         med.toStringAsFixed(0), (med / 1000 / sec).toStringAsFixed(3)]);
  }
  rec.free();
  stdout.writeln('\nSENSEVOICE_CHECK_DONE');
}
