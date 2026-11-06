// M3 KWS 真 FFI 冒烟：常驻 worker 完整链（load → 流式解码 → 关键字命中）。
// 本机开发模型在才跑（C:\dev-tools\voice-models\kws，与 tool/m3_kws_check 同源）；
// 缺席即 skip——注册表用户目录另行验收（设置页引导下载路径）。
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:wangcai/asr/kws_engine.dart';

const _kwsDir = r'C:\dev-tools\voice-models\kws';
const _binDir = r'C:\dev-tools\voice-models\bin';

bool get _modelsHere =>
    Directory(_kwsDir).existsSync() &&
    File('$_kwsDir\\encoder-epoch-99-avg-1-chunk-16-left-64.onnx').existsSync() &&
    File('$_kwsDir\\test_3.wav').existsSync();

/// 取 wav 的 PCM16 data 段原始字节（KWS worker 吃的就是这个，16k mono）。
Uint8List _pcmBytesFromWav(String path) {
  final bytes = File(path).readAsBytesSync();
  final bd = ByteData.sublistView(bytes);
  var off = 12;
  var dataOff = -1;
  var dataLen = 0;
  while (off + 8 <= bytes.length) {
    final id = String.fromCharCodes(bytes.sublist(off, off + 4));
    final size = bd.getUint32(off + 4, Endian.little);
    if (id == 'data') {
      dataOff = off + 8;
      dataLen = size.clamp(0, bytes.length - off - 8);
      break;
    }
    off += 8 + size + (size & 1);
  }
      expect(dataOff, greaterThan(0), reason: 'no data chunk: $path');
      return Uint8List.sublistView(bytes, dataOff, dataOff + dataLen);
}

void main() {
  group('KWS 真 FFI 冒烟（本机模型在才跑）', () {
    test('官方 test_3.wav + 拼音关键字 → 命中「文森特卡索」', () async {
      final speech = _pcmBytesFromWav('$_kwsDir\\test_3.wav');
      // numTrailingBlanks=2：关键字后要跟 2 帧静音才吐命中（实测口径，
      // tool/m3_kws_check 同款尾静音步骤）。生产麦克风自然有停顿，无需补。
      final pcm = Uint8List(speech.length + 16000) // +0.5s 静音
        ..setRange(0, speech.length, speech);

      final hit = await KwsEngine.spotPcmForTest(
        pcm,
        modelDir: _kwsDir,
        keywords: 'w én s ēn t è k ǎ s uǒ @文森特卡索',
        threshold: 0.25,
        dllDir: _binDir,
      );
      expect(hit, contains('文森特卡索'));
    },
        skip: _modelsHere ? false : '本机无 KWS 开发模型（$_kwsDir）',
        timeout: const Timeout(Duration(minutes: 10)));
  });
}
