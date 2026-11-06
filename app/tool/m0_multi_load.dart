// M0 T0.4：三引擎共存（流式 + SenseVoice + 离线 TTS）RAM 增量与 dll 冲突验证。
// 模拟「快速响应模式」全预热常驻。跑法：cd app && dart run tool/m0_multi_load.dart
import 'dart:io';
import 'dart:typed_data';

import 'package:sherpa_onnx/sherpa_onnx.dart' as sherpa;

import 'm0_common.dart';

void main() {
  final baseline = ProcessInfo.currentRss;
  initSherpaBindings();
  final afterBind = ProcessInfo.currentRss;
  row(['rss after bindings MB', mb(afterBind)]);

  // 1) 流式
  final sd = '$defaultModelsRoot\\streaming-zipformer';
  final sw1 = Stopwatch()..start();
  final rec1 = sherpa.OnlineRecognizer(sherpa.OnlineRecognizerConfig(
    model: sherpa.OnlineModelConfig(
      transducer: sherpa.OnlineTransducerModelConfig(
        encoder: '$sd\\encoder.int8.onnx',
        decoder: '$sd\\decoder.onnx',
        joiner: '$sd\\joiner.int8.onnx',
      ),
      tokens: '$sd\\tokens.txt',
      numThreads: 2,
      provider: 'cpu',
      debug: false,
    ),
  ));
  sw1.stop();
  row(['streaming loaded ms', sw1.elapsedMilliseconds.toString(),
       'rss MB', mb(ProcessInfo.currentRss)]);

  // 2) SenseVoice
  final vd = '$defaultModelsRoot\\sensevoice';
  final sw2 = Stopwatch()..start();
  final rec2 = sherpa.OfflineRecognizer(sherpa.OfflineRecognizerConfig(
    model: sherpa.OfflineModelConfig(
      senseVoice: sherpa.OfflineSenseVoiceModelConfig(
        model: '$vd\\model.int8.onnx',
        language: 'zh',
        useInverseTextNormalization: true,
      ),
      tokens: '$vd\\tokens.txt',
      numThreads: 2,
      provider: 'cpu',
      debug: false,
    ),
  ));
  sw2.stop();
  row(['sensevoice loaded ms', sw2.elapsedMilliseconds.toString(),
       'rss MB', mb(ProcessInfo.currentRss)]);

  // 3) 离线 TTS（vits 兜底档）
  final td = '$defaultModelsRoot\\tts-offline-zh';
  final sw3 = Stopwatch()..start();
  final tts = sherpa.OfflineTts(sherpa.OfflineTtsConfig(
    model: sherpa.OfflineTtsModelConfig(
      vits: sherpa.OfflineTtsVitsModelConfig(
        model: '$td\\vits-aishell3.int8.onnx',
        tokens: '$td\\tokens.txt',
        lexicon: '$td\\lexicon.txt',
      ),
      numThreads: 2,
      provider: 'cpu',
      debug: false,
    ),
  ));
  sw3.stop();
  row(['tts loaded ms', sw3.elapsedMilliseconds.toString(),
       'rss MB', mb(ProcessInfo.currentRss)]);

  // 三引擎同载下各跑一发，确认 dll 单实例无符号冲突
  final st = rec1.createStream();
  st.acceptWaveform(
      samples: Float32List(16000), sampleRate: 16000); // 1s 静音
  while (rec1.isReady(st)) {
    rec1.decode(st);
  }
  rec1.getResult(st);
  st.free();
  final ost = rec2.createStream();
  ost.acceptWaveform(samples: Float32List(16000), sampleRate: 16000);
  rec2.decode(ost);
  rec2.getResult(ost);
  ost.free();
  final audio = tts.generate(text: '共存测试。', sid: 0, speed: 1.0);
  row(['coexist smoke', 'ok', 'tts samples', audio.samples.length.toString()]);

  row(['total peak RSS MB', mb(ProcessInfo.currentRss),
       'delta vs baseline MB', mb(ProcessInfo.currentRss - baseline)]);
  rec1.free();
  rec2.free();
  tts.free();
  stdout.writeln('\nMULTI_LOAD_DONE');
}

String mb(int bytes) => (bytes / 1048576).toStringAsFixed(0);
