/// sherpa-onnx FFI 绑定引导（ASR/TTS/VAD 各 worker isolate 共用）。
///
/// Windows 坑（docs/M0-EVIDENCE-VOICE.md 环境坑 1）：System32 里别的软件留下的
/// `onnxruntime.dll` 会劫持 c-api 的隐式依赖解析（error 193，报错还不指名文件）。
/// 缓解：知道自家 DLL 目录时先用**绝对路径**把自家 onnxruntime 打开（先进先赢）
/// 再 initBindings。打包态 DLL 在 exe 旁边，默认搜索序已正确——不传 dir 即平台默认。
///
/// dir 优先级：显式参数 > 环境变量 `WANGCAI_SHERPA_DLL_DIR` > 平台默认。
library;

import 'dart:ffi';
import 'dart:io';

import 'package:path/path.dart' as p;
import 'package:sherpa_onnx/sherpa_onnx.dart' as sherpa;

void bindSherpa([String? dllDir]) {
  final dir = dllDir ?? Platform.environment['WANGCAI_SHERPA_DLL_DIR'];
  if (Platform.isWindows && dir != null && dir.isNotEmpty) {
    for (final dll in const ['onnxruntime.dll', 'onnxruntime_providers_shared.dll']) {
      final f = File(p.join(dir, dll));
      if (f.existsSync()) {
        try {
          DynamicLibrary.open(f.absolute.path);
        } catch (_) {}
      }
    }
    sherpa.initBindings(dir);
    return;
  }
  sherpa.initBindings();
}
