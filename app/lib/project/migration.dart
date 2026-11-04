/// 一次性迁移：旧平铺会话 → 项目树（v0.0.3 Phase 1，设计 §12）。
///
/// 做三件事（全部**幂等可重入**，崩了重跑无副作用）：
/// 1. 确保内置默认项目存在（workspacePath = documents/workspace，即旧
///    DevWorkspace 默认区语义）；
/// 2. `ApplicationSupport/sessions/*.jsonl` → 默认项目 sessions 目录：
///    整目录先备份 `sessions.backup/`（只备一次），再逐文件搬移；
///    目标已存在 = 上次搬过，跳过；
/// 3. SQLite：`projectId IS NULL` 的会话一次性归入默认项目。
///
/// 纪律：迁移失败绝不阻塞启动（调用方 catch 后照常跑）——读取侧本来就有
/// 旧平铺双路径兜底，迁移只是"把家搬完"，不是"开关"。
library;

import 'dart:io';

import 'package:flutter/foundation.dart' show debugPrint;
import 'package:path/path.dart' as p;

import '../agent/dev/workspace_store.dart';
import '../services/storage_service.dart';
import 'project.dart';
import 'project_store.dart';
import '../platform/wangcai_paths.dart';

/// 迁移结果（日志与测试断言用）。
final class MigrationReport {
  int movedFiles = 0;
  int skippedFiles = 0;
  bool backedUp = false;
  int assignedConversations = 0;

  bool get didAnything =>
      movedFiles > 0 || backedUp || assignedConversations > 0;

  @override
  String toString() =>
      'MigrationReport(moved=$movedFiles skipped=$skippedFiles '
      'backedUp=$backedUp assigned=$assignedConversations)';
}

/// 执行迁移（见文件头注释）。[defaultWorkspacePath]/[legacySessionsDir]
/// 供测试显式注入（不依赖 path_provider）；生产缺省 = documents/workspace
/// 与 ApplicationSupport/sessions。备份目录恒为 `<legacyDir>.backup`。
Future<MigrationReport> migrateLegacySessions({
  ProjectStore? projects,
  StorageService? storage,
  String? defaultWorkspacePath,
  Directory? legacySessionsDir,
}) async {
  final report = MigrationReport();
  final store = ProjectStore.resolve(projects);
  final db = storage ?? StorageService();

  final ws = defaultWorkspacePath ?? await DevStore().defaultWorkspaceDir();
  await store.ensureDefault(ws);

  // --- 1. 旧平铺目录 → 默认项目 sessions 树 --------------------------------
  final legacyDir = legacySessionsDir ??
      Directory(
          p.join(WangCaiPaths.legacyAppSupportHome().path, 'sessions'));
  if (legacyDir.existsSync()) {
    final backup = Directory('${legacyDir.path}.backup');
    if (!backup.existsSync()) {
      try {
        _copyTree(legacyDir, backup);
        report.backedUp = true;
      } catch (e) {
        // 备份失败 → 宁可不搬（原始数据原地保留，双路径读取仍安全）。
        debugPrint('[Project] sessions 备份失败，跳过搬移（数据仍在原位）: $e');
        return report;
      }
    }
    final targetDir = await store.sessionsDir(Project.kDefaultId);
    await for (final f in legacyDir.list()) {
      if (f is! File || !f.path.endsWith('.jsonl')) continue;
      final target = File(p.join(targetDir, p.basename(f.path)));
      if (target.existsSync()) {
        report.skippedFiles++;
        continue;
      }
      try {
        await f.rename(target.path);
        report.movedFiles++;
      } catch (_) {
        // 跨卷 rename 失败等 → 复制 + 删原。
        try {
          await f.copy(target.path);
          await f.delete();
          report.movedFiles++;
        } catch (e) {
          debugPrint('[Project] 会话文件搬移失败 ${f.path}: $e');
        }
      }
    }
  }

  // --- 2. SQLite：未归属会话归入默认项目 ------------------------------------
  try {
    report.assignedConversations =
        await db.assignNullProjectConversations(Project.kDefaultId);
  } catch (e) {
    debugPrint('[Project] 会话归属回填失败（读取侧有 NULL 兜底，不致命）: $e');
  }

  if (report.didAnything) {
    debugPrint('[Project] 旧会话迁移完成: $report');
  }
  return report;
}

/// 递归复制目录（Dart 的 Directory 没有 copySync；备份用，同步实现足够——
/// sessions 目录只有小 JSONL 文件，且发生在启动一次性路径上）。
void _copyTree(Directory src, Directory dst) {
  dst.createSync(recursive: true);
  for (final e in src.listSync(recursive: true, followLinks: false)) {
    final rel = p.relative(e.path, from: src.path);
    final target = p.join(dst.path, rel);
    if (e is Directory) {
      Directory(target).createSync(recursive: true);
    } else if (e is File) {
      File(target).parent.createSync(recursive: true);
      e.copySync(target);
    }
  }
}
