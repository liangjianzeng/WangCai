// 数据目录布局（设计 §8）：%LOCALAPPDATA%\WangCai\ 下可写区。
// 生产由 path_provider 构建；测试注入临时目录。
import 'dart:io';

class EnginePaths {
  EnginePaths({
    required this.dataDir,
    required this.enginesDir,
    required this.modelsDir,
    required this.cacheRoot,
    required this.ledgerDir,
  });

  factory EnginePaths.root(Directory root) => EnginePaths(
        dataDir: root,
        enginesDir: Directory('${root.path}${Platform.pathSeparator}engines'),
        modelsDir: Directory('${root.path}${Platform.pathSeparator}models'),
        cacheRoot: Directory('${root.path}${Platform.pathSeparator}cache'),
        ledgerDir: Directory('${root.path}${Platform.pathSeparator}engines'),
      );

  final Directory dataDir;
  final Directory enginesDir; // 引擎商店安装的官方 llama.cpp 版本目录在此之下
  final Directory modelsDir; // GGUF 模型库
  final Directory cacheRoot; // per-profile OV 编译缓存
  final Directory ledgerDir; // port.json 进程账本（§3 崩溃清理）

  Directory cacheDirFor(String profileId) =>
      Directory('${cacheRoot.path}${Platform.pathSeparator}$profileId');

  File ledgerFile(String instanceId) => File(
      '${ledgerDir.path}${Platform.pathSeparator}$instanceId.port.json');

  Future<void> ensureDirs() async {
    for (final d in [enginesDir, cacheRoot, ledgerDir]) {
      if (!await d.exists()) await d.create(recursive: true);
    }
  }
}
