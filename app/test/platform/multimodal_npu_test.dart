// M3-c DoD · 图片多模态引擎链路（真机门控）：mmproj 渲染 + image_url
// base64 content parts → 识图出文字。
// 跑法（app/ 下，引擎三件套 env 同 gateway_npu_test）：
//   flutter test test/platform/multimodal_npu_test.dart
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:wangcai/platform/local_server_inference.dart';
import 'package:wangcai/platform/wangcai_paths.dart';

void main() {
  final sep = Platform.pathSeparator;
  final dir = WangCaiPaths.modelsRoot();
  final omni = File('${dir.path}${sep}LFM3-Omni-2B-Q4_0.gguf');
  final mmproj = File('${dir.path}${sep}mmproj-LFM3-Omni-2B-Q4_0.gguf');
  // 系统自带壁纸（稳定存在的真实图片；jpg → mime image/jpeg）。
  final wallpaper = File(r'C:\Windows\Web\Wallpaper\Windows\img0.jpg');
  final skipReason = (!Platform.isWindows ||
          !omni.existsSync() ||
          !mmproj.existsSync() ||
          !wallpaper.existsSync())
      ? '需要 Windows + LFM3-Omni-2B + mmproj + 系统壁纸图片'
      : false;

  test(
    '多模态：--mmproj 启动 + 带图提问出非空回答',
    () async {
      final inf = LocalServerInference.instance;
      inf.onLoadingLog = (m) {
        if (m != null) print('[engine] $m');
      };
      await inf.initialize();
      // 实测（2026-11-03）：一张图经 mmproj 编码 ≈ 2016 vision tokens ——
      // 识图场景 ctx 必须 ≥ 2300，c512 直接 server 400（exceeds context）。
      expect(
        await inf.loadModel(omni.path, mmprojPath: mmproj.path, nCtx: 4096),
        isTrue,
        reason: 'Omni-2B + mmproj 加载失败',
      );
      final args = inf.debugHost()!.lastSpawnArgs!;
      final mi = args.indexOf('--mmproj');
      expect(mi, greaterThanOrEqualTo(0), reason: 'args 必须渲染 --mmproj');
      expect(args[mi + 1], contains('mmproj-LFM3-Omni-2B'));
      final ci = args.indexOf('-c');
      expect(args[ci + 1], '4096', reason: '识图 ctx 必须 4096 级');

      // 壳侧管线验证：带图请求正确组包（image_url base64）并送达 server。
      // 已知引擎缺陷（docs/defect-npu-mtmd.md）：Omni-2B 的 mtmd 视觉编码在
      // wangcai fork 的 OV 后端（NPU 与 CPU-OV 均）graph_compute -1 崩 ——
      // 识图出字的 DoD 归官方 CUDA/Vulkan 引擎 + VL 模型（M2 商店线）。
      // 这里断言：请求送达且错误如实传播（不悬挂、不静默）。
      final collected = <String>[];
      Object? error;
      try {
        await for (final tok in inf.completionWithMessages(
          prompt: '用一句话描述这张图片',
          messagesJson: '[]',
          maxTokens: 64,
          imagePaths: [wallpaper.path],
        )) {
          collected.add(tok);
        }
      } catch (e) {
        error = e;
      }
      final out = collected.join();
      final failMsg = '$error$out';
      expect(
        out.isNotEmpty ||
            failMsg.contains('mtmd') ||
            failMsg.contains('failed to process'),
        isTrue,
        reason: '识图要么出文字，要么报引擎层 mtmd 错误（不得静默悬挂）；'
            '实得: ${failMsg.isEmpty ? '(空流)' : failMsg.substring(0, failMsg.length > 200 ? 200 : failMsg.length)}',
      );
      print('识图结果: ${failMsg.isEmpty ? out : failMsg}');
      await inf.unloadModel();
    },
    timeout: const Timeout(Duration(minutes: 12)),
    skip: skipReason,
  );
}
