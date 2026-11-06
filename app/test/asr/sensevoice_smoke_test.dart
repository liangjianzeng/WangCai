// T2.1/T2.2 真 FFI 冒烟：SenseVoice worker（VAD 分段 → 识别 → 后处理 → 终稿）
// 本机模型在才跑（CI/其他机器自动 skip）。样本 = M0 台账同款 zh 测试 wav。
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:wangcai/asr/sensevoice_asr.dart';

/// 极简 WAV 解析：跳到 data 块取 PCM16（样本均为 16k mono）。
Uint8List pcm16FromWav(String path) {
  final b = File(path).readAsBytesSync();
  var off = 12;
  while (off + 8 <= b.length) {
    final id = String.fromCharCodes(b.sublist(off, off + 4));
    final size = ByteData.sublistView(b, off + 4, off + 8)
        .getUint32(0, Endian.little);
    if (id == 'data') {
      return Uint8List.fromList(b.sublist(off + 8, off + 8 + size));
    }
    off += 8 + size + (size & 1);
  }
  throw StateError('wav 无 data 块: $path');
}

void main() {
  const modelDir = r'C:\dev-tools\voice-models\sensevoice';
  const vadModel = r'C:\dev-tools\voice-models\vad\silero_vad.onnx';
  final ready =
      Directory(modelDir).existsSync() && File(vadModel).existsSync();

  test('SenseVoice worker 全链：PCM 喂入 → VAD 分段 → 识别 → 终稿', () async {
    final wavs = Directory(r'C:\dev-tools\voice-models\sensevoice\test_wavs')
        .listSync()
        .whereType<File>()
        .where((f) => f.path.toLowerCase().endsWith('.wav'))
        .toList()
      ..sort((a, b) => a.path.compareTo(b.path));
    expect(wavs, isNotEmpty, reason: '模型目录自带 test_wavs');
    // 锁中文样本（en/yue 等样本断「含汉字」会误红）。
    final zh = wavs.firstWhere(
      (f) => f.uri.pathSegments.last.toLowerCase().contains('zh'),
      orElse: () => wavs.first,
    );
    final pcm = pcm16FromWav(zh.path);
    expect(pcm.length, greaterThan(16000), reason: '样本至少 1s');

    final text = await SenseVoiceAsr.recognizePcmForTest(
      pcm,
      modelDir: modelDir,
      vadModel: vadModel,
      dllDir: r'C:\dev-tools\voice-models\bin',
    );
    // M0 实测 zh 样本解码 ~250ms；断言出字且是中文（富转写标签已被剥离）。
    expect(text, isNotEmpty);
    expect(RegExp(r'[一-鿿]').hasMatch(text), isTrue, reason: '终稿: $text');
    expect(text.contains('|'), isFalse, reason: '富转写标签必须被剥离: $text');
  },
      timeout: const Timeout(Duration(minutes: 10)),
      skip: ready ? null : '本机无 sensevoice/vad 模型，跳过真 FFI 冒烟');
}
