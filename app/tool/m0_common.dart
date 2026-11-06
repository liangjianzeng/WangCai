// M0 实测工具共享件（ASR&TTS 重构专项 T0.2–T0.5）：wav 读、PCM 转 float、
// 计时表、sherpa 绑定初始化。纯 Dart + package:sherpa_onnx（与 app 同一 pub
// 解析），跑法：cd app && dart run tool/<name>.dart
import 'dart:ffi';
import 'dart:io';
import 'dart:typed_data';

import 'package:sherpa_onnx/sherpa_onnx.dart' as sherpa;

const defaultModelsRoot = r'C:\dev-tools\voice-models';

/// M0 工具显式指定 sherpa DLL 目录（绕开 pub 镜像分发的那份坏 DLL）。
const sherpaDllDir = r'C:\dev-tools\voice-models\bin';

/// 初始化 sherpa 绑定。
///
/// 必须先用绝对路径预热 onnxruntime：本机 `C:\Windows\System32\onnxruntime.dll`
/// （系统自带、版本不兼容）会在 c-api 隐式依赖解析时抢在 PATH 之前被加载，
/// 导致 `ERROR_BAD_EXE_FORMAT (193)`。预加载后按模块名命中已载实例即绕开。
/// app 侧（M1 worker isolate 的 initBindings 处）要做同样的预热——见台账。
void initSherpaBindings() {
  DynamicLibrary.open('$sherpaDllDir\\onnxruntime.dll');
  DynamicLibrary.open('$sherpaDllDir\\onnxruntime_providers_shared.dll');
  sherpa.initBindings(sherpaDllDir);
}

/// 极简 RIFF/PCM16 wav 读取（M0 工具够用；app 正式代码不用它）。
({Float32List samples, int sampleRate}) readWavPcm16(String path) {
  final bytes = File(path).readAsBytesSync();
  final bd = ByteData.sublistView(bytes);
  int off = 12; // 跳过 RIFF/fmt 头（测试 wav 均为标准 44 字节头，宽松扫描 fmt/data）
  int sampleRate = 16000;
  int bits = 16;
  int channels = 1;
  int dataOff = -1, dataLen = 0;
  while (off + 8 <= bytes.length) {
    final id = String.fromCharCodes(bytes.sublist(off, off + 4));
    final size = bd.getUint32(off + 4, Endian.little);
    if (id == 'fmt ') {
      channels = bd.getUint16(off + 10, Endian.little);
      sampleRate = bd.getUint32(off + 12, Endian.little);
      bits = bd.getUint16(off + 22, Endian.little);
    } else if (id == 'data') {
      dataOff = off + 8;
      dataLen = size;
      if (dataOff + dataLen > bytes.length) dataLen = bytes.length - dataOff;
      break;
    }
    off += 8 + size + (size & 1);
  }
  if (dataOff < 0) throw FormatException('not a wav: $path');
  if (bits != 16) throw FormatException('only pcm16 supported: $path');
  final n = dataLen ~/ 2 ~/ channels; // 取首声道
  final out = Float32List(n);
  for (var i = 0; i < n; i++) {
    final v = bd.getInt16(dataOff + i * channels * 2, Endian.little);
    out[i] = v / 32768.0;
  }
  return (samples: out, sampleRate: sampleRate);
}

double audioSeconds(({Float32List samples, int sampleRate}) w) =>
    w.samples.length / w.sampleRate;

/// 表格行输出（台账直接抄）。
void row(List<String> cols) =>
    stdout.writeln(cols.map((c) => c.padRight(18)).join('| '));

void section(String t) => stdout.writeln('\n=== $t ===');
