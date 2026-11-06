// M2 调试：zh.wav → VAD 分段（段边界打印）→ SenseVoice 逐段识别。
// 跑法：cd app && dart run tool/m2_sensevoice_vad_debug.dart
import 'dart:io';
import 'dart:typed_data';

import 'package:sherpa_onnx/sherpa_onnx.dart' as sherpa;

import 'm0_common.dart';

void main() {
  initSherpaBindings();
  const dir = r'C:\dev-tools\voice-models\sensevoice';
  const vadModel = r'C:\dev-tools\voice-models\vad\silero_vad.onnx';

  final pcm = pcm16FromWav('$dir\\test_wavs\\zh.wav');
  stdout.writeln('pcm bytes=${pcm.length} samples=${pcm.length ~/ 2} '
      'sec=${(pcm.length ~/ 2) / 16000}');

  final vad = sherpa.VoiceActivityDetector(
    config: sherpa.VadModelConfig(
      sileroVad: sherpa.SileroVadModelConfig(
        model: vadModel,
        threshold: 0.5,
        minSilenceDuration: 0.8,
        minSpeechDuration: 0.25,
        maxSpeechDuration: 15.0,
      ),
      sampleRate: 16000,
      numThreads: 1,
      debug: false,
    ),
    bufferSizeInSeconds: 60,
  );

  final rec = sherpa.OfflineRecognizer(sherpa.OfflineRecognizerConfig(
    model: sherpa.OfflineModelConfig(
      senseVoice: sherpa.OfflineSenseVoiceModelConfig(
        model: '$dir\\model.int8.onnx',
        language: 'zh',
        useInverseTextNormalization: true,
      ),
      tokens: '$dir\\tokens.txt',
      numThreads: 2,
      provider: 'cpu',
      debug: false,
    ),
  ));

  vad.acceptWaveform(_f32(pcm));
  stdout.writeln('after feed: empty=${vad.isEmpty()} detected=${vad.isDetected()}');
  while (!vad.isEmpty()) {
    final seg = vad.front();
    vad.pop();
    stdout.writeln('segment start=${seg.start} samples=${seg.samples.length} '
        'sec=${seg.samples.length / 16000}');
    final st = rec.createStream();
    st.acceptWaveform(samples: seg.samples, sampleRate: 16000);
    rec.decode(st);
    stdout.writeln('  text=[${rec.getResult(st).text}]');
    st.free();
  }
  stdout.writeln('before flush: empty=${vad.isEmpty()} detected=${vad.isDetected()}');
  vad.flush();
  stdout.writeln('after flush: empty=${vad.isEmpty()}');
  while (!vad.isEmpty()) {
    final seg = vad.front();
    vad.pop();
    stdout.writeln('flush segment samples=${seg.samples.length} '
        'sec=${seg.samples.length / 16000}');
    final st = rec.createStream();
    st.acceptWaveform(samples: seg.samples, sampleRate: 16000);
    rec.decode(st);
    stdout.writeln('  text=[${rec.getResult(st).text}]');
    st.free();
  }
  vad.free();
  rec.free();
  stdout.writeln('VAD_DEBUG_DONE');
}

Float32List _f32(Uint8List bytes) {
  final n = bytes.length ~/ 2;
  final bd = ByteData.sublistView(bytes);
  final out = Float32List(n);
  for (var i = 0; i < n; i++) {
    out[i] = bd.getInt16(i * 2, Endian.little) / 32768.0;
  }
  return out;
}

Uint8List pcm16FromWav(String path) {
  final b = File(path).readAsBytesSync();
  var off = 12;
  while (off + 8 <= b.length) {
    final id = String.fromCharCodes(b.sublist(off, off + 4));
    final size =
        ByteData.sublistView(b, off + 4, off + 8).getUint32(0, Endian.little);
    if (id == 'data') return Uint8List.fromList(b.sublist(off + 8, off + 8 + size));
    off += 8 + size + (size & 1);
  }
  throw StateError('no data chunk');
}
