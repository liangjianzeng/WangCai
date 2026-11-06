// M3 一次性资源生成（docs/voice-wakeup-min-spec.md §2）：
//  - assets/wake_cue.wav：ARMED 提示音（880Hz 90ms，淡入淡出，pcm16 mono 22050）
//  - assets/tray/voice_{armed,capture,speak}.ico：托盘状态三色（16x16 32bpp 实心圆）
// 生成后随仓提交（固定字节 = 固定 sha256，重跑无害）。
// 跑法：cd app && dart run tool/gen_voice_assets.dart
import 'dart:io';
import 'dart:math' as math;
import 'dart:typed_data';

void main() {
  final out = Directory('assets');
  if (!out.existsSync()) out.createSync(recursive: true);
  File('${out.path}\\wake_cue.wav').writeAsBytesSync(_wakeCueWav());
  final tray = Directory('${out.path}\\tray')..createSync(recursive: true);
  File('${tray.path}\\voice_armed.ico').writeAsBytesSync(_ico([255, 193, 7]));
  File('${tray.path}\\voice_capture.ico').writeAsBytesSync(_ico([76, 175, 80]));
  File('${tray.path}\\voice_speak.ico').writeAsBytesSync(_ico([33, 150, 243]));
  stdout.writeln('voice assets generated -> assets\\wake_cue.wav, assets\\tray\\*.ico');
}

List<int> _wakeCueWav() {
  const rate = 22050;
  final n = (rate * 0.09).round(); // 90ms
  final bytes = Uint8List(44 + n * 2);
  final bd = ByteData.sublistView(bytes);
  void ascii(int off, String s) {
    for (var i = 0; i < s.length; i++) {
      bytes[off + i] = s.codeUnitAt(i);
    }
  }

  ascii(0, 'RIFF');
  bd.setUint32(4, 36 + n * 2, Endian.little);
  ascii(8, 'WAVE');
  ascii(12, 'fmt ');
  bd.setUint32(16, 16, Endian.little);
  bd.setUint16(20, 1, Endian.little);
  bd.setUint16(22, 1, Endian.little);
  bd.setUint32(24, rate, Endian.little);
  bd.setUint32(28, rate * 2, Endian.little);
  bd.setUint16(32, 2, Endian.little);
  bd.setUint16(34, 16, Endian.little);
  ascii(36, 'data');
  bd.setUint32(40, n * 2, Endian.little);
  final fade = (rate * 0.01).round(); // 10ms 淡入淡出（防爆音）
  for (var i = 0; i < n; i++) {
    var env = 0.55;
    if (i < fade) env *= i / fade;
    if (i > n - fade) env *= (n - i) / fade;
    final v = (math.sin(2 * math.pi * 880 * i / rate) * env * 32767).round();
    bd.setInt16(44 + i * 2, v, Endian.little);
  }
  return bytes;
}

/// 16x16 32bpp 单图标 ICO（BGRA 自底向上 + 全 0 AND 掩膜，透明度走 alpha）。
List<int> _ico(List<int> rgb) {
  const size = 16;
  const xorBytes = size * size * 4;
  const andBytes = size * 8; // 1bpp 行 pad 到 32bit
  final bytes = Uint8List(6 + 16 + 40 + xorBytes + andBytes);
  final bd = ByteData.sublistView(bytes);
  // ICONDIR
  bd.setUint16(0, 0, Endian.little); // reserved
  bd.setUint16(2, 1, Endian.little); // type = icon
  bd.setUint16(4, 1, Endian.little); // count
  // ICONDIRENTRY
  bytes[6] = size;
  bytes[7] = size;
  bytes[8] = 0; // palette
  bytes[9] = 0; // reserved
  bd.setUint16(10, 1, Endian.little); // planes
  bd.setUint16(12, 32, Endian.little); // bpp
  bd.setUint32(14, 40 + xorBytes + andBytes, Endian.little); // bytesInRes
  bd.setUint32(18, 22, Endian.little); // imageOffset
  // BITMAPINFOHEADER（height = 2*size：XOR + AND）
  bd.setUint32(22, 40, Endian.little);
  bd.setUint32(26, size, Endian.little);
  bd.setUint32(30, size * 2, Endian.little);
  bd.setUint16(34, 1, Endian.little);
  bd.setUint16(36, 32, Endian.little);
  bd.setUint32(38, 0, Endian.little); // BI_RGB
  bd.setUint32(42, xorBytes + andBytes, Endian.little);
  // XOR：实心圆盘（半径 7.4），BGRA
  final cx = (size - 1) / 2.0;
  for (var y = 0; y < size; y++) {
    for (var x = 0; x < size; x++) {
      final dx = x - cx, dy = y - cx;
      final inside = (dx * dx + dy * dy) <= 7.4 * 7.4;
      final off = 62 + ((size - 1 - y) * size + x) * 4; // 自底向上
      bytes[off] = rgb[2];
      bytes[off + 1] = rgb[1];
      bytes[off + 2] = rgb[0];
      bytes[off + 3] = inside ? 255 : 0;
    }
  }
  // AND 掩膜保持全 0（透明由 alpha 决定）
  return bytes;
}
