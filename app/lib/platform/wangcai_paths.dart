// Windows 数据目录与开发机路径解析（设计 §8）。
// 数据区 %APPDATA%\WangCai；模型库 WANGCAI_MODEL_DIR 优先（开发机直指 repo
// 的 models/），再退到数据区 models/；引擎二进制 env 覆盖 > 开发机构建产物。
import 'dart:io';

import '../engine/engine_paths.dart';

class WangCaiPaths {
  /// 测试注入点（非 null 时 dataRoot 返回它，隔离真实 %APPDATA%）。
  static Directory Function()? dataRootOverrideForTest;

  /// %APPDATA%\WangCai（engines.json / per-profile 编译缓存 / 进程账本落这里）。
  static Directory dataRoot() {
    final o = dataRootOverrideForTest;
    if (o != null) return o();
    final appData = Platform.environment['APPDATA'];
    final root = (appData != null && appData.isNotEmpty)
        ? appData
        : Directory.systemTemp.path;
    return Directory('$root${Platform.pathSeparator}WangCai');
  }

  static EnginePaths enginePaths() => EnginePaths.root(dataRoot());

  /// 模型库根：WANGCAI_MODEL_DIR > %APPDATA%\WangCai\models。
  static Directory modelsRoot() {
    final env = Platform.environment['WANGCAI_MODEL_DIR']?.trim();
    if (env != null && env.isNotEmpty) return Directory(env);
    return enginePaths().modelsDir;
  }

  /// 模型文件搜索目录（顺序即优先级）：主库 → exe 同侧 models/（便携包）→
  /// 开发机构建仓库 models/（若存在）。去重交给调用方。
  static List<Directory> modelSearchDirs() {
    final out = <String>{};
    void add(Directory d) {
      try {
        if (d.existsSync()) out.add(d.absolute.path);
      } catch (_) {}
    }

    add(modelsRoot());
    final exeDir = File(Platform.resolvedExecutable).parent;
    add(Directory('${exeDir.path}${Platform.pathSeparator}models'));
    final repo = repoRoot();
    if (repo != null) add(Directory('${repo.path}${Platform.pathSeparator}models'));
    if (out.isEmpty) add(modelsRoot()); // 全不存在时保留主库（可创建）
    return out.map(Directory.new).toList();
  }

  /// 开发机定位：从 exe 位置向上找 WangCai 仓库根（marker：tools\chat-npu.ps1）。
  /// 装机形态返回 null（引擎走商店目录，M2）。
  static Directory? repoRoot() {
    var dir = File(Platform.resolvedExecutable).parent;
    for (var i = 0; i < 8; i++) {
      final marker = File('${dir.path}${Platform.pathSeparator}tools'
          '${Platform.pathSeparator}chat-npu.ps1');
      if (marker.existsSync()) return dir;
      if (dir.parent.path == dir.path) break;
      dir = dir.parent;
    }
    return null;
  }

  /// 安装器形态的引擎目录：{userappdata}\WangCai\engines\wangcai\（Inno
  /// Setup 打包位，M4）。装机用户没有 repo —— 二级解析靠这里。
  static Directory bundledEngineDir() => Directory(
      '${dataRoot().path}${Platform.pathSeparator}engines'
      '${Platform.pathSeparator}wangcai');

  /// 汪柴 llama-server.exe：WANGCAI_SERVER_EXE > 安装器引擎目录 >
  /// 开发机构建产物（repo）。
  static String? wangcaiServerExe() {
    final env = Platform.environment['WANGCAI_SERVER_EXE']?.trim();
    if (env != null && env.isNotEmpty && File(env).existsSync()) return env;
    final bundled = '${bundledEngineDir().path}${Platform.pathSeparator}'
        'llama-server.exe';
    if (File(bundled).existsSync()) return bundled;
    final repo = repoRoot();
    if (repo != null) {
      final cand = '${repo.path}${Platform.pathSeparator}src'
          '${Platform.pathSeparator}llama${Platform.pathSeparator}build'
          '${Platform.pathSeparator}bin${Platform.pathSeparator}llama-server.exe';
      if (File(cand).existsSync()) return cand;
    }
    return null;
  }

  /// OpenVINO 运行时 DLL 目录（PATH 前置）：WANGCAI_OV_LIBS（`;` 分隔）>
  /// 安装器引擎目录 ovlibs\ > 仓库 ov/openvino/libs。
  static List<String> ovLibsDirs() {
    final env = Platform.environment['WANGCAI_OV_LIBS']?.trim();
    if (env != null && env.isNotEmpty) {
      return env
          .split(Platform.environment['OS'] == 'Windows_NT' ? ';' : ':')
          .map((e) => e.trim())
          .where((e) => e.isNotEmpty && Directory(e).existsSync())
          .toList();
    }
    final bundled =
        '${bundledEngineDir().path}${Platform.pathSeparator}ovlibs';
    if (Directory(bundled).existsSync()) return [bundled];
    final repo = repoRoot();
    if (repo != null) {
      final cand = '${repo.path}${Platform.pathSeparator}ov'
          '${Platform.pathSeparator}openvino${Platform.pathSeparator}libs';
      if (Directory(cand).existsSync()) return [cand];
    }
    return const [];
  }
}
