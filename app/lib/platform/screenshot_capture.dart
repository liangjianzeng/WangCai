// Windows 截屏捕获（2026-11-07 用户拍板：桌面「拍照」退役后的正确形态）。
// 方案：Win+Shift+S 交给系统 Snipping overlay（原生框选 / 多屏 / 延时，
// 零自研选区 UI），主窗口由调用方先隐藏避免挡住目标；框选产物从剪贴板
// 取回——优先 "PNG" 注册格式直得字节（Win10 1809+ 的 Snipping Tool 会写），
// 兜底 CF_DIB → BMP 文件头拼装 → image 包解码转 PNG。
// 纪律：判定「新图」用剪贴板序列号（GetClipboardSequenceNumber），防止把
// 用户剪贴板里的旧图误挂进聊天。
import 'dart:async';
import 'dart:ffi';
import 'dart:io';
import 'dart:typed_data';

import 'package:ffi/ffi.dart' as ffi;
import 'package:image/image.dart' as img;

final DynamicLibrary _user32 = DynamicLibrary.open('user32.dll');
final DynamicLibrary _kernel32 = DynamicLibrary.open('kernel32.dll');

// ── user32 ────────────────────────────────────────────────────────────────
// lookupFunction 纪律：FFI 类型（Uint8/Int32/IntPtr…）只出现在 Native 侧，
// Dart 侧签名与变量声明一律纯 int（IntPtr 在 Dart 侧的对应就是 int）。
// keybd_event(BYTE bVk, BYTE bScan, DWORD dwFlags, ULONG_PTR dwExtraInfo)
final int Function(int, int, int, int) _keybdEvent = _user32
    .lookupFunction<Uint8 Function(Uint8, Uint8, Uint32, IntPtr),
        int Function(int, int, int, int)>('keybd_event');
final int Function() _clipboardSequence = _user32
    .lookupFunction<Uint32 Function(), int Function()>(
        'GetClipboardSequenceNumber');
final int Function(int) _openClipboard = _user32
    .lookupFunction<Int32 Function(IntPtr), int Function(int)>(
        'OpenClipboard');
final int Function() _closeClipboard = _user32
    .lookupFunction<Int32 Function(), int Function()>('CloseClipboard');
final int Function(int) _formatAvailable = _user32
    .lookupFunction<Int32 Function(Uint32), int Function(int)>(
        'IsClipboardFormatAvailable');
final int Function(int) _getClipboardData = _user32
    .lookupFunction<IntPtr Function(Uint32), int Function(int)>(
        'GetClipboardData');
final int Function(Pointer<ffi.Utf8>) _registerClipboardFormat = _user32
    .lookupFunction<Uint32 Function(Pointer<ffi.Utf8>),
        int Function(Pointer<ffi.Utf8>)>('RegisterClipboardFormatA');

// ── kernel32 ──────────────────────────────────────────────────────────────
final Pointer<Void> Function(int) _globalLock = _kernel32
    .lookupFunction<Pointer<Void> Function(IntPtr), Pointer<Void> Function(
        int)>('GlobalLock');
final int Function(int) _globalUnlock = _kernel32
    .lookupFunction<Int32 Function(IntPtr), int Function(int)>(
        'GlobalUnlock');
// SIZE_T = 平台字宽（dart:ffi 无 SizeT 类型，x64 下 IntPtr 等价）
final int Function(int) _globalSize = _kernel32
    .lookupFunction<IntPtr Function(IntPtr), int Function(int)>('GlobalSize');

const int _kKeyUp = 0x0002; // KEYEVENTF_KEYUP
const int _vkLwin = 0x5B;
const int _vkShift = 0x10;
const int _vkS = 0x53;
const int _cfDib = 8; // CF_DIB

int? _pngFormat; // RegisterClipboardFormat("PNG") 缓存（系统常量，进程内不变）

int _pngClipboardFormat() =>
    _pngFormat ??= _registerClipboardFormat('PNG'.toNativeUtf8());

/// Win+Shift+S：唤起系统截图 overlay（原生框选，多屏/延时由系统管）。
/// keybd_event 进系统队列由其消化，连发可靠，无需键间 Sleep。
void _sendWinShiftS() {
  void tap(int vk, {bool up = false}) =>
      _keybdEvent(vk, 0, up ? _kKeyUp : 0, 0);
  tap(_vkLwin);
  tap(_vkShift);
  tap(_vkS);
  tap(_vkS, up: true);
  tap(_vkShift, up: true);
  tap(_vkLwin, up: true);
}

/// 从剪贴板读图（调用方已确认序列号变化）。null = 无图/读取失败。
Uint8List? _readClipboardImage() {
  if (_openClipboard(0) == 0) return null;
  try {
    // 1) 直取 PNG（Win10 1809+ Snipping Tool 提供）
    final pngFmt = _pngClipboardFormat();
    if (pngFmt != 0 && _formatAvailable(pngFmt) != 0) {
      final h = _getClipboardData(pngFmt);
      if (h != 0) {
        final size = _globalSize(h);
        final p = _globalLock(h);
        if (p != Pointer.fromAddress(0) && size > 0) {
          final bytes =
              Uint8List.fromList(p.cast<Uint8>().asTypedList(size));
          _globalUnlock(h);
          return bytes;
        }
        if (p != Pointer.fromAddress(0)) _globalUnlock(h);
      }
    }
    // 2) 兜底 CF_DIB → 完整 BMP 文件字节（14 字节 BITMAPFILEHEADER +
    //    CF_DIB 的 BITMAPINFOHEADER+调色板+像素 即 BMP 本体）。
    if (_formatAvailable(_cfDib) != 0) {
      final h = _getClipboardData(_cfDib);
      if (h != 0) {
        final size = _globalSize(h);
        final p = _globalLock(h);
        if (p != Pointer.fromAddress(0) && size > 14) {
          final dib = Uint8List.fromList(p.cast<Uint8>().asTypedList(size));
          _globalUnlock(h);
          final headerSize =
              ByteData.sublistView(dib, 0, 4).getUint32(0, Endian.little);
          final bmp = BytesBuilder();
          bmp.add('BM'.codeUnits);
          final bd = ByteData(12);
          bd.setUint32(0, 14 + dib.length, Endian.little); // 文件大小
          bd.setUint32(4, 0, Endian.little); // 保留
          bd.setUint32(8, 14 + headerSize, Endian.little); // 像素数据偏移
          bmp.add(bd.buffer.asUint8List());
          bmp.add(dib);
          return bmp.toBytes();
        }
        if (p != Pointer.fromAddress(0)) _globalUnlock(h);
      }
    }
    return null;
  } finally {
    _closeClipboard();
  }
}

/// 截屏全流程：发 Win+Shift+S → 轮询剪贴板等用户框选完成（最长 [timeout]）→
/// 存 PNG 到临时目录，返回文件路径；null = 超时/取消/无图。
Future<String?> captureScreenToImageFile({
  Duration timeout = const Duration(seconds: 90),
  Directory? saveDir,
}) async {
  if (!Platform.isWindows) return null;
  final seq0 = _clipboardSequence();
  _sendWinShiftS();
  final deadline = DateTime.now().add(timeout);
  Uint8List? bytes;
  while (DateTime.now().isBefore(deadline)) {
    await Future<void>.delayed(const Duration(milliseconds: 400));
    if (_clipboardSequence() == seq0) continue; // 还没框完 / 用户已取消
    bytes = _readClipboardImage();
    if (bytes != null) break;
  }
  if (bytes == null || bytes.isEmpty) return null;

  // PNG 魔数直存；否则（BMP 兜底路径）用 image 包转 PNG。
  Uint8List pngBytes;
  if (bytes.length > 8 &&
      bytes[0] == 0x89 &&
      bytes[1] == 0x50 &&
      bytes[2] == 0x4E &&
      bytes[3] == 0x47) {
    pngBytes = bytes;
  } else {
    final decoded = img.decodeBmp(bytes);
    if (decoded == null) return null;
    pngBytes = Uint8List.fromList(img.encodePng(decoded));
  }

  final dir = (saveDir ??
          Directory('${Directory.systemTemp.path}'
              '${Platform.pathSeparator}wangcai_screenshots'))
    ..createSync(recursive: true);
  final file = File('${dir.path}${Platform.pathSeparator}'
      'shot_${DateTime.now().millisecondsSinceEpoch}.png');
  await file.writeAsBytes(pngBytes, flush: true);
  return file.path;
}
