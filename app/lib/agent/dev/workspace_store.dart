/// 开发工作区/任务/计划持久化（Dev Agent Phase A/C）。
///
/// - 工作区元数据：`ApplicationSupport/dev/workspaces/<safe-id>.json`；
/// - 开发任务元数据：`ApplicationSupport/dev/tasks/<safe-id>.json`；
/// - 开发计划：随任务文件存（tasks/<id>.json 内嵌 plan）。
/// 全部 JSON 明文、单文件、无迁移链（v1）；损坏条目丢弃（fail-loud 于日志）。
library;

import 'dart:convert';
import 'dart:io';

import 'package:flutter/foundation.dart' show debugPrint;
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';

import 'workspace.dart';
import 'task.dart';

final class DevStore {
  DevStore({this.baseDirOverride});

  /// 测试注入的全局默认实例（工具层无显式注入点时使用；生产恒 null）。
  /// 仅测试可写：setUp 里设为 override 实例，tearDown 还原 null。
  static DevStore? testDefault;

  /// 工具层取 store 的统一入口（显式 store 优先，其次测试默认，最后新建）。
  static DevStore resolve([DevStore? explicit]) =>
      explicit ?? testDefault ?? DevStore();

  /// 测试注入：绕过 path_provider 直接指定根目录（null = 真实 ApplicationSupport）。
  final String? baseDirOverride;

  /// ApplicationSupport/dev/ 根目录（测试时 = override/dev）。
  Future<String> _devDir() async {
    if (baseDirOverride != null) return p.join(baseDirOverride!, 'dev');
    final base = await getApplicationSupportDirectory();
    return p.join(base.path, 'dev');
  }

  Future<String> _workspaceDir() async => p.join(await _devDir(), 'workspaces');
  Future<String> _taskDir() async => p.join(await _devDir(), 'tasks');

  Future<void> _ensureDir(String dir) async {
    if (!Directory(dir).existsSync()) {
      Directory(dir).createSync(recursive: true);
    }
  }

  String _safe(String id) =>
      Uri.encodeComponent(id.replaceAll(RegExp(r'[^A-Za-z0-9_\-]'), '-'));

  // ---------------------------------------------------------------------------
  // 工作区
  // ---------------------------------------------------------------------------

  /// 列出全部持久化工作区（默认工作区不落盘，由调用方合成）。
  Future<List<DevWorkspace>> loadWorkspaces() async {
    final dir = await _workspaceDir();
    if (!Directory(dir).existsSync()) return const [];
    final out = <DevWorkspace>[];
    await for (final f in Directory(dir).list()) {
      if (f is! File || !f.path.endsWith('.json')) continue;
      try {
        final ws = DevWorkspace.fromJson(
            jsonDecode(f.readAsStringSync()) as Map<String, dynamic>);
        if (ws != null) out.add(ws);
      } catch (_) {}
    }
    return out;
  }

  Future<void> saveWorkspace(DevWorkspace ws) async {
    if (ws.isDefault) return; // 默认工作区不落盘
    final dir = await _workspaceDir();
    await _ensureDir(dir);
    File(p.join(dir, '${_safe(ws.id)}.json'))
        .writeAsStringSync(jsonEncode(ws.toJson()));
  }

  Future<void> deleteWorkspace(String id) async {
    if (id == DevWorkspace.kDefaultId) return;
    final dir = await _workspaceDir();
    final f = File(p.join(dir, '${_safe(id)}.json'));
    if (f.existsSync()) f.deleteSync();
  }

  /// 激活工作区 id 落盘位置：`ApplicationSupport/dev/active_workspace.json`。
  Future<String> _activeFile() async =>
      p.join(await _devDir(), 'active_workspace.json');

  /// 读「上次激活的工作区」（跨启动记住"我在哪儿干活"；无/坏 → null）。
  Future<String?> loadActiveWorkspaceId() async {
    try {
      final f = File(await _activeFile());
      if (!f.existsSync()) return null;
      final decoded = jsonDecode(f.readAsStringSync());
      if (decoded is Map<String, dynamic>) {
        final id = (decoded['activeWorkspaceId'] as String?)?.trim();
        return (id == null || id.isEmpty) ? null : id;
      }
    } catch (e) {
      debugPrint('[Dev] 激活工作区读取失败: $e');
    }
    return null;
  }

  /// 落盘「当前激活的工作区」。
  ///
  /// 实锤修复：`InferenceSettings.devWorkspaceId` 只写不读，而
  /// `DevSessionController._activeWorkspaceId` 只在内存 → 杀 App 重开就悄悄
  /// 回落「本地沙盒」，注入给模型的 `<workspace:context>` 变成本地，
  /// 表现就是"连上了远程电脑，它却不肯在电脑上干活"。
  Future<void> saveActiveWorkspaceId(String id) async {
    try {
      final path = await _activeFile();
      await _ensureDir(p.dirname(path));
      File(path).writeAsStringSync(jsonEncode({'activeWorkspaceId': id}));
    } catch (e) {
      debugPrint('[Dev] 激活工作区落盘失败: $e');
    }
  }

  /// 删掉激活标记（激活的工作区被删除时调用，避免下次启动指向幽灵 id）。
  Future<void> clearActiveWorkspaceId() async {
    try {
      final f = File(await _activeFile());
      if (f.existsSync()) f.deleteSync();
    } catch (_) {}
  }

  /// 工作区本地镜像目录：`documents/workspace/projects/<safe-id>/`。
  /// 测试（baseDirOverride）下 = `<override>/projects/<safe-id>`（不触 path_provider）。
  ///
  /// **取目录即建目录**：dev_shell / 本地 git 都是"进目录再干活"，目录不存在时
  /// 每条消息都会撞 `No such file or directory`（与远端"有就用、没有就建"同一条策略）。
  Future<String> workspaceLocalMirror(String id) async {
    final dir = baseDirOverride != null
        ? p.join(baseDirOverride!, 'projects', _safe(id))
        : p.join((await getApplicationDocumentsDirectory()).path, 'workspace',
            'projects', _safe(id));
    await _ensureDir(dir);
    return dir;
  }

  /// 默认工作区根目录（documents/workspace；测试 override 下 = <override>/workspace）。
  /// 同 [workspaceLocalMirror]：取目录即建目录，dev_shell 才不会一进门就撞空目录。
  Future<String> defaultWorkspaceDir() async {
    final dir = baseDirOverride != null
        ? p.join(baseDirOverride!, 'workspace')
        : p.join((await getApplicationDocumentsDirectory()).path, 'workspace');
    await _ensureDir(dir);
    return dir;
  }

  // ---------------------------------------------------------------------------
  // 任务（含计划）
  // ---------------------------------------------------------------------------

  Future<List<DevTask>> loadTasks() async {
    final dir = await _taskDir();
    if (!Directory(dir).existsSync()) return const [];
    final out = <DevTask>[];
    await for (final f in Directory(dir).list()) {
      if (f is! File || !f.path.endsWith('.json')) continue;
      try {
        final task = DevTask.fromJson(
            jsonDecode(f.readAsStringSync()) as Map<String, dynamic>);
        if (task != null) out.add(task);
      } catch (_) {}
    }
    return out;
  }

  Future<void> saveTask(DevTask task) async {
    final dir = await _taskDir();
    await _ensureDir(dir);
    File(p.join(dir, '${_safe(task.id)}.json'))
        .writeAsStringSync(jsonEncode(task.toJson()));
  }

  Future<void> deleteTask(String id) async {
    final dir = await _taskDir();
    final f = File(p.join(dir, '${_safe(id)}.json'));
    if (f.existsSync()) f.deleteSync();
  }
}
