// M0-4 运行时验证：从 shell 侧真实加载 sherpa-onnx-c-api.dll 并调版本函数。
// 用法（cwd=app/，PATH 含 Release 目录）：dart run tool/sherpa_check.dart
// 纯 FFI，不依赖 Flutter binding——Windows 宿主 VM 可直跑。
import 'dart:ffi';

import 'package:ffi/ffi.dart';

void main() {
  // 显式 open 给出清晰错误；真实 App 内由 sherpa_onnx 包 bindings 懒加载同一 DLL。
  final lib = DynamicLibrary.open('sherpa-onnx-c-api.dll');
  print('dll loaded: $lib');
  final fn = lib.lookupFunction<Pointer<Utf8> Function(),
      Pointer<Utf8> Function()>('SherpaOnnxGetVersionStr');
  print('sherpa-onnx version: ${fn().toDartString()}');
}
