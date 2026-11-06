// T1.3 真 FFI 冒烟：OfflineTtsService（worker isolate 化后）实载本机 vits-zh 模型合成。
// 仅本机有模型与 DLL 目录时跑（CI/其他机器自动 skip）；模型目录与 DLL 目录与
// docs/M0-EVIDENCE-VOICE.md 台账一致。Windows 坑：worker 内 initBindings 前必须
// 绝对路径预载自家 onnxruntime（WANGCAI_SHERPA_DLL_DIR 指向 bin 目录）。
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:wangcai/tts/offline_tts_service.dart';

void main() {
  const dllDir = r'C:\dev-tools\voice-models\bin';
  const modelDir = r'C:\dev-tools\voice-models\tts-offline-zh';
  final ready = Directory(dllDir).existsSync() &&
      Directory(modelDir).existsSync() &&
      File('$modelDir\\tokens.txt').existsSync();

  test('worker isolate 实载 vits 合成冒烟（合成→WAV 落盘）', () async {
    final svc = OfflineTtsService(
      modelDir: modelDir,
      // 显式注入 DLL 目录：不依赖进程环境变量（全量套件并行跑时没有 env）。
      engineFactory: (l) => SherpaOfflineTtsEngine(l, dllDir: dllDir),
    );
    expect(svc.modelPresent, isTrue, reason: svc.notReadyReason);
    expect(svc.kind, OfflineTtsKind.vits);
    await svc.prewarm();
    expect(svc.lastFailureMessage, isNull,
        reason: 'worker 加载失败：${svc.lastFailureMessage}');
    final f = await svc.synthesizeToFile('汪柴离线朗读冒烟。', voice: 'x', rate: 0);
    expect(f, isNotNull, reason: '合成失败：${svc.lastFailureMessage}');
    expect(await f!.length(), greaterThan(2000));
    await svc.dispose();
  },
      // 4 核机全量并行时 isolate 加载会被饿死（单独 13s，全量曾 >3min 超时），
      // 给足 10 分钟。
      timeout: const Timeout(Duration(minutes: 10)),
      skip: ready ? null : '本机无 vits 模型/DLL（$modelDir），跳过真 FFI 冒烟');
}
