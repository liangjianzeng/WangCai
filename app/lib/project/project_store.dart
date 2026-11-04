/// 项目注册表（桌面独立版 v0.0.3）—— 项目层级与激活态的落盘真源。
///
/// 布局（全部在 %APPDATA%\WangCai 数据区，与设计 §8/§12 对齐）：
/// - `projects.json`：项目注册表（数组，JSON 明文，仿 DevStore 纪律：
///   单文件、损坏条目丢弃、fail-loud 于日志）；
/// - `active_project.json`：`{"activeProjectId": "..."}`（仿
///   `DevStore.active_workspace.json` 的 active 机制）；
/// - `projects/<safe-project-id>/sessions/<convId>.jsonl`：会话 JSONL 真相源
///   （goals/traces/metrics 同挂项目目录）。
///
/// 移除项目**不删数据**（会话树保留在磁盘），与"删除会话才删文件"分层。
library;

import 'dart:convert';
import 'dart:io';

import 'package:flutter/foundation.dart' show debugPrint;
import 'package:path/path.dart' as p;

import '../platform/wangcai_paths.dart';
import 'project.dart';

final class ProjectStore {
  ProjectStore({this.baseDirOverride});

  /// 测试注入的全局默认实例（生产恒 null）。
  static ProjectStore? testDefault;

  /// 统一取用入口（显式优先，其次测试默认，最后新建）。
  static ProjectStore resolve([ProjectStore? explicit]) =>
      explicit ?? testDefault ?? ProjectStore();

  /// 测试注入：数据区根目录（null = WangCaiPaths.dataRoot()）。
  final String? baseDirOverride;

  Future<String> rootDir() async {
    final o = baseDirOverride;
    if (o != null) return o;
    return WangCaiPaths.dataRoot().path;
  }

  Future<String> _registryFile() async =>
      p.join(await rootDir(), 'projects.json');
  Future<String> _activeFile() async =>
      p.join(await rootDir(), 'active_project.json');

  Future<void> _ensureDir(String dir) async {
    if (!Directory(dir).existsSync()) {
      Directory(dir).createSync(recursive: true);
    }
  }

  // ---------------------------------------------------------------------------
  // 注册表读写
  // ---------------------------------------------------------------------------

  /// 全部项目（按 lastOpenedAt/createdAt 倒序由调用方自己排）。损坏条目丢弃。
  Future<List<Project>> loadProjects() async {
    try {
      final f = File(await _registryFile());
      if (!f.existsSync()) return <Project>[];
      final decoded = jsonDecode(f.readAsStringSync());
      if (decoded is! List) return <Project>[];
      final out = <Project>[];
      for (final e in decoded) {
        if (e is! Map<String, dynamic>) continue;
        try {
          final prj = Project.fromJson(e);
          if (prj != null) out.add(prj);
        } catch (_) {}
      }
      return out;
    } catch (e) {
      debugPrint('[Project] 注册表读取失败: $e');
      return <Project>[];
    }
  }

  Future<void> saveProjects(List<Project> list) async {
    final path = await _registryFile();
    await _ensureDir(p.dirname(path));
    File(path).writeAsStringSync(
        const JsonEncoder.withIndent('  ').convert(list.map((e) => e.toJson()).toList()));
  }

  Future<Project?> projectById(String id) async {
    return (await loadProjects()).where((x) => x.id == id).firstOrNull;
  }

  /// 新建或替换（按 id）。
  Future<void> upsert(Project project) async {
    final list = await loadProjects();
    final i = list.indexWhere((x) => x.id == project.id);
    if (i >= 0) {
      list[i] = project;
    } else {
      list.add(project);
    }
    await saveProjects(list);
  }

  /// 便捷创建：安全化命名 + 生成 id + 立刻可用。
  Future<Project> create({
    required String name,
    required String workspacePath,
    String? sshConfigId,
  }) async {
    final now = DateTime.now();
    final prj = Project(
      id: newProjectId(),
      name: name.trim().isEmpty ? '新项目' : name.trim(),
      workspacePath: workspacePath.trim(),
      sshConfigId: (sshConfigId ?? '').trim().isEmpty ? null : sshConfigId!.trim(),
      createdAt: now,
      lastOpenedAt: now,
    );
    await upsert(prj);
    return prj;
  }

  /// 移除项目记录（**不删会话/数据目录**；默认项目不可移除）。成功返回 true。
  Future<bool> remove(String id) async {
    if (id == Project.kDefaultId) return false;
    final list = await loadProjects();
    final before = list.length;
    list.removeWhere((x) => x.id == id);
    if (list.length == before) return false;
    await saveProjects(list);
    // 激活的正是被删项目 → 回落到默认/第一个，避免幽灵激活。
    if ((await loadActiveProjectId()) == id) {
      await clearActiveProjectId();
    }
    return true;
  }

  // ---------------------------------------------------------------------------
  // 激活态
  // ---------------------------------------------------------------------------

  /// 读激活项目 id（无/坏 → null；调用方回落默认项目）。
  Future<String?> loadActiveProjectId() async {
    try {
      final f = File(await _activeFile());
      if (!f.existsSync()) return null;
      final decoded = jsonDecode(f.readAsStringSync());
      if (decoded is Map<String, dynamic>) {
        final id = (decoded['activeProjectId'] as String?)?.trim();
        return (id == null || id.isEmpty) ? null : id;
      }
    } catch (e) {
      debugPrint('[Project] 激活项目读取失败: $e');
    }
    return null;
  }

  /// 落盘激活项目并刷新 lastOpenedAt。
  Future<void> setActiveProjectId(String id) async {
    final path = await _activeFile();
    await _ensureDir(p.dirname(path));
    File(path).writeAsStringSync(jsonEncode({'activeProjectId': id}));
    final prj = await projectById(id);
    if (prj != null) {
      await upsert(prj.copyWith(lastOpenedAt: DateTime.now()));
    }
  }

  Future<void> clearActiveProjectId() async {
    try {
      final f = File(await _activeFile());
      if (f.existsSync()) f.deleteSync();
    } catch (_) {}
  }

  // ---------------------------------------------------------------------------
  // 项目目录树
  // ---------------------------------------------------------------------------

  /// 项目数据目录：`<root>/projects/<safe-id>/`（取目录即建目录）。
  Future<String> projectDir(String projectId) async {
    final dir =
        p.join(await rootDir(), 'projects', safeProjectDirName(projectId));
    await _ensureDir(dir);
    return dir;
  }

  /// 会话 JSONL 目录：`<root>/projects/<safe-id>/sessions/`（取目录即建目录）。
  Future<String> sessionsDir(String projectId) async {
    final dir = p.join(await projectDir(projectId), 'sessions');
    await _ensureDir(dir);
    return dir;
  }

  /// 项目作用域子目录（goals/traces/metrics 用），如 `projectSubDir(id, 'goals')`。
  Future<String> projectSubDir(String projectId, String name) async {
    final dir = p.join(await projectDir(projectId), name);
    await _ensureDir(dir);
    return dir;
  }

  // ---------------------------------------------------------------------------
  // 默认项目
  // ---------------------------------------------------------------------------

  /// 确保内置默认项目存在（迁移与首启共用；幂等）。
  /// [defaultWorkspacePath] = documents/workspace（旧 DevWorkspace 默认区语义）。
  Future<Project> ensureDefault(String defaultWorkspacePath) async {
    final list = await loadProjects();
    final existing = list.where((x) => x.id == Project.kDefaultId).firstOrNull;
    if (existing != null) return existing;
    final prj = Project(
      id: Project.kDefaultId,
      name: Project.kDefaultName,
      workspacePath: defaultWorkspacePath,
      createdAt: DateTime.now(),
    );
    list.insert(0, prj);
    await saveProjects(list);
    debugPrint('[Project] 已创建默认项目 → $defaultWorkspacePath');
    return prj;
  }
}
