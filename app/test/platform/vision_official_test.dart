// M3-c/M4 DoD · 识图（官方引擎线）：SmolVLM2-500M + 官方 llama.cpp（CUDA/Vulkan）
// → 壳网关 loadModel(mmproj) → image_url base64 → 出文字描述。
// 背景：wangcai fork 的 OV 后端 mtmd 不可用（docs/defect-npu-mtmd.md），
// 识图 DoD 按设计落到官方引擎（M2 商店装好的 b12034）。
// 模型（hf-mirror.com/ggml-org/SmolVLM2-500M-Video-Instruct-GGUF，2026-11-03）：
//   SmolVLM2-500M-Video-Instruct-Q8_0.gguf + mmproj-...-Q8_0.gguf → models\
// 跑法（app/ 下，env 三件套同 gateway_npu_test）：
//   flutter test test/platform/vision_official_test.dart
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:tongyi_lite/platform/local_server_inference.dart';
import 'package:tongyi_lite/platform/wangcai_paths.dart';

void main() {
  final sep = Platform.pathSeparator;
  final dir = WangCaiPaths.modelsRoot();
  final main_ = File('${dir.path}${sep}SmolVLM2-500M-Video-Instruct-Q8_0.gguf');
  final mmproj = File('${dir.path}${sep}mmproj-SmolVLM2-500M-Video-Instruct-Q8_0.gguf');
  final wallpaper = File(r'C:\Windows\Web\Wallpaper\Windows\img0.jpg');
  final skipReason = (!Platform.isWindows ||
          !main_.existsSync() ||
          !mmproj.existsSync() ||
          !wallpaper.existsSync())
      ? '需要 Windows + SmolVLM2-500M GGUF/mmproj（models\） + 系统壁纸'
      : false;

  test(
    '识图：官方引擎 + SmolVLM2 → 描述出非空文字（含可判读内容）',
    () async {
      final inf = LocalServerInference.instance;
      inf.onLoadingLog = (m) {
        if (m != null) print('[engine] $m');
      };
      await inf.initialize();
      expect(await inf.loadModel(main_.path, mmprojPath: mmproj.path, nCtx: 4096),
          isTrue, reason: 'SmolVLM2 加载失败');

      final inst = inf.debugHost()!.instanceId;
      print('ROUTED=$inst');
      expect(inst, anyOf('llamacpp-cuda', 'llamacpp-vulkan'),
          reason: '识图必须走官方引擎（NPU mtmd 缺陷，见 defect-npu-mtmd.md）');

      final sb = StringBuffer();
      await for (final tok in inf.completionWithMessages(
        prompt: 'Describe this image in one sentence.',
        messagesJson: '[]',
        maxTokens: 64,
        imagePaths: [wallpaper.path],
      )) {
        sb.write(tok);
      }
      final text = sb.toString().trim();
      print('VISION A: ${text.length > 160 ? '${text.substring(0, 160)}…' : text}');
      expect(text, isNotEmpty, reason: '识图必须出文字');
      // Windows 10/11 默认壁纸 img0 以蓝色为主调——断言模型读到了色彩/图形语义
      // （弱模型允许长尾，只验证非幻觉性可判读输出，不锁具体措辞）。
      expect(text.toLowerCase(), anyOf(
        contains('blue'),
        contains('color'),
        contains('abstract'),
        contains('wave'),
        contains('fluid'),
      ), reason: '描述应含图像语义（蓝色/抽象/波浪类）');
      await inf.unloadModel();
    },
    timeout: const Timeout(Duration(minutes: 8)),
    skip: skipReason,
  );
}
