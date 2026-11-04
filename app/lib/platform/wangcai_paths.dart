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

  // —— v0.0.4 数据家统一（DSH ~/.dsh 单家纪律）——————————————————
  // 此前全仓散落四个家：%APPDATA%\WangCai（dataRoot）、path_provider 旧家
  // （Runner.rc 旧身份 com.dgxspark\wangcai_app）、跟 CWD 走的 getDatabasesPath、
  // Documents 混入。v0.0.4 起写入一律进 dataRoot()；旧家只读不写。

  /// 测试注入点（非 null 时 legacyAppSupportHome 返回它）。
  static Directory Function()? legacyHomeOverrideForTest;

  /// 旧家（v0.0.3 及以前 path_provider ApplicationSupport 的实际落点，
  /// 由 Runner.rc 旧身份决定）。只读：迁移源 + JSONL 平铺只读兜底。
  static Directory legacyAppSupportHome() {
    final o = legacyHomeOverrideForTest;
    if (o != null) return o();
    final appData = Platform.environment['APPDATA'];
    final root = (appData != null && appData.isNotEmpty)
        ? appData
        : Directory.systemTemp.path;
    return Directory('$root${Platform.pathSeparator}com.dgxspark'
        '${Platform.pathSeparator}wangcai_app');
  }

  /// 数据子目录（不创建）：dataDir('dev','ssh') = %APPDATA%\WangCai\dev\ssh。
  static Directory dataDir(String a, [String? b]) => Directory(b == null
      ? '${dataRoot().path}${Platform.pathSeparator}$a'
      : '${dataRoot().path}${Platform.pathSeparator}$a'
          '${Platform.pathSeparator}$b');

  /// 启动时一次性搬迁的旧家子目录清单（同名整体搬进 dataRoot()）。
  /// 'sessions' 刻意不在列：旧平铺 JSONL 是只读兜底（store.dart legacyPathFor）。
  static const _legacyMigrateSubdirs = [
    'goals', 'metrics', 'traces', 'agent_spill', 'skills', //
    'dev', 'profiles', 'vision_slices', 'tts', 'tts_cache',
  ];

  /// 旧家 → 新家搬迁（main.dart 启动早期调用一次）。幂等、同卷 rename、
  /// 任何一步失败都静默（新家照常工作，旧数据原地不丢）：
  /// ① 旧在&新不在 → 旧改名 .migrating → 再改名成新家（第二步失败数据留
  ///    .migrating，下次启动自愈续搬）；② 旧在&新在 → 旧改名 .migrated 备份，
  ///    不动新数据；③ 旧不在&.migrating 在 → 续搬；④ 都不在 → no-op。
  /// 另：旧家根的 agent_todo_*.json 归拢进 dataDir('todo')，AGENTS.md 见
  /// [migrateLegacyFiles]。
  static void migrateLegacyHome() {
    try {
      final legacy = legacyAppSupportHome();
      if (!legacy.existsSync()) return;
      for (final name in _legacyMigrateSubdirs) {
        _moveSubdir(Directory('${legacy.path}${Platform.pathSeparator}$name'),
            dataDir(name));
      }
      // v2/v3 遗留的 todo 文件在旧家根（agent_todo.json 全局 + agent_todo_<conv>.json），
      // 归拢进 todo/——todo_tool._baseDir 新家同目录，_legacyFile 链路自动闭环。
      final todoDir = dataDir('todo');
      for (final f in legacy.listSync()) {
        final n = f is File ? f.uri.pathSegments.last : '';
        if (n == 'agent_todo.json' ||
            (n.startsWith('agent_todo_') && n.endsWith('.json'))) {
          try {
            if (!todoDir.existsSync()) todoDir.createSync(recursive: true);
            final t = File('${todoDir.path}'
                '${Platform.pathSeparator}${f.uri.pathSegments.last}');
            if (!t.existsSync()) f.renameSync(t.path);
          } catch (_) {}
        }
      }
      _moveFile(
          File('${legacy.path}${Platform.pathSeparator}AGENTS.md'),
          File(dataDir('AGENTS.md').path));
    } catch (_) {}
  }

  static void _moveSubdir(Directory from, Directory to) {
    try {
      if (!from.existsSync()) {
        // ③ 自愈：上次搬到一半留在 .migrating。
        final mid = Directory('${from.path}.migrating');
        if (mid.existsSync() && !to.existsSync()) mid.renameSync(to.path);
        return;
      }
      final mid = Directory('${from.path}.migrating');
      if (mid.existsSync()) return; // 上次没搬完，留给自愈分支处理
      from.renameSync(mid.path); // 先摘牌再搬，全程旧数据不删
      if (to.existsSync()) {
        mid.renameSync('${from.path}.migrated'); // ② 新家已有：旧数据留备份
      } else {
        try {
          mid.renameSync(to.path); // ① 正常搬迁
        } catch (_) {
          mid.renameSync('${from.path}.migrated'); // 失败也不丢数据
        }
      }
    } catch (_) {}
  }

  static void _moveFile(File from, File to) {
    try {
      if (!from.existsSync()) return;
      if (to.existsSync()) {
        from.renameSync('${from.path}.migrated');
      } else {
        to.parent.createSync(recursive: true);
        from.renameSync(to.path);
      }
    } catch (_) {}
  }


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

  /// 便携/装机形态的引擎目录候选（优先级序）：
  /// ① exe 邻侧 `Engines\wangcai\`（便携包布局，build-installer.ps1 staging
  ///    产物；README「首启自动识别」的真身，v0.0.2 遗留缺口在 v0.0.3 补上）；
  /// ② `{userappdata}\WangCai\engines\wangcai\`（Inno Setup 装机位，M4）。
  static List<Directory> bundledEngineDirs() => [
        Directory('${File(Platform.resolvedExecutable).parent.path}'
            '${Platform.pathSeparator}Engines${Platform.pathSeparator}wangcai'),
        Directory('${dataRoot().path}${Platform.pathSeparator}engines'
            '${Platform.pathSeparator}wangcai'),
      ];

  /// 安装器（非便携）形态的引擎目录；写侧/管理侧真源（Inno 卸载清理等）。
  static Directory bundledEngineDir() => bundledEngineDirs().last;

  /// 汪柴 llama-server.exe：WANGCAI_SERVER_EXE > 便携/装机引擎目录 >
  /// 开发机构建产物（repo）。
  static String? wangcaiServerExe() {
    final env = Platform.environment['WANGCAI_SERVER_EXE']?.trim();
    if (env != null && env.isNotEmpty && File(env).existsSync()) return env;
    for (final dir in bundledEngineDirs()) {
      final cand = '${dir.path}${Platform.pathSeparator}llama-server.exe';
      if (File(cand).existsSync()) return cand;
    }
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
    for (final dir in bundledEngineDirs()) {
      final ov = '${dir.path}${Platform.pathSeparator}ovlibs';
      if (Directory(ov).existsSync()) return [ov];
    }
    final repo = repoRoot();
    if (repo != null) {
      final cand = '${repo.path}${Platform.pathSeparator}ov'
          '${Platform.pathSeparator}openvino${Platform.pathSeparator}libs';
      if (Directory(cand).existsSync()) return [cand];
    }
    return const [];
  }
}
