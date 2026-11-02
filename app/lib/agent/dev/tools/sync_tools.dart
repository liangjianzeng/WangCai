/// 工作区同步工具（P2-D4，Phase D 的 MVP 形态）：本地镜像 ↔ 远端工作区
/// 双向文件同步（SFTP），mtime 判新旧、冲突不静默覆盖（默认报告跳过）。
///
/// 语义（诚实优先，不做静默合并）：
/// - `push`：本地较新 → 上传；远端较新 → 冲突（overwrite=true 才覆盖）；
/// - `pull`：远端较新 → 下载；本地较新 → 冲突（同上）；
/// - 单侧缺失的文件按"新增"处理（push 补建远端目录，pull 补建本地目录）；
/// - 双方 mtime 相同 → 跳过不动；
/// - `.git/` 恒跳过（git 状态经 git 工具走，不做文件级同步）。
library;

import 'dart:io';

import 'package:dartssh2/dartssh2.dart';
import 'package:flutter/foundation.dart' show debugPrint;
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';

import '../../tool_definition.dart';
import '../ssh/ssh_credentials.dart' show SshConfig;
import '../ssh/ssh_environment.dart';
import '../workspace.dart';
import '../dev_workspace_actions.dart' show ensureWorkspaceRemoteDir;
import 'ssh_tools.dart'
    show ensureSshConnectionFor, resolveRemoteRoot, toRemotePath;

/// 单次同步处理的文件数上限（防失控；超出部分如实报告"未处理"）。
const int kSyncMaxFiles = 500;

/// 单个文件同步大小上限（与 ssh_write_file 上限一致）。
const int kSyncMaxFileBytes = 65536;

/// 本地镜像根目录（与 file_tools._workspaceDir 同构）。
Future<Directory> _localWorkspaceDir(String workspaceId) async {
  final docs = await getApplicationDocumentsDirectory();
  return Directory(p.join(docs.path, 'workspace', 'projects',
      sanitizeWorkspaceDirName(workspaceId)));
}

/// 递归收集相对路径（跳 .git；上限 [kSyncMaxFiles]）。
Future<List<String>> _walkLocal(Directory dir, {int limit = kSyncMaxFiles}) async {
  final out = <String>[];
  if (!await dir.exists()) return out;
  final rootLen = dir.path.length;
  final stack = <Directory>[dir];
  while (stack.isNotEmpty && out.length < limit) {
    final d = stack.removeLast();
    await for (final e in d.list(followLinks: false)) {
      if (out.length >= limit) break;
      final rel = e.path.substring(rootLen + 1).replaceAll('\\', '/');
      if (rel == '.git' || rel.startsWith('.git/')) continue;
      if (e is Directory) {
        stack.add(e);
      } else if (e is File) {
        out.add(rel);
      }
    }
  }
  return out;
}

/// 远端递归收集相对路径（SFTP listdir；跳 .git；上限同上）。
Future<List<String>> _walkRemote(SftpClient sftp, String root) async {
  final out = <String>[];
  final dirs = <List<String>>[[]]; // 相对段
  while (dirs.isNotEmpty && out.length < kSyncMaxFiles) {
    final seg = dirs.removeLast();
    final abs = seg.isEmpty ? root : '$root/${seg.join('/')}';
    List<SftpName> entries;
    try {
      entries = await sftp.listdir(abs);
    } catch (_) {
      // 目录不存在/无权限 → 跳过。**必须裸 catch**：dartssh2 的 SftpStatusError
      // 不实现 Exception，`on Exception` 抓不到 ⇒ 远端目录缺失能打死整条消息。
      continue;
    }
    for (final e in entries) {
      if (out.length >= kSyncMaxFiles) break;
      final name = e.filename;
      if (name == '.' || name == '..') continue;
      final rel = [...seg, name].join('/');
      if (rel == '.git' || rel.startsWith('.git/')) continue;
      final attr = e.attr;
      if (attr.isDirectory) {
        dirs.add([...seg, name]);
      } else {
        out.add(rel);
      }
    }
  }
  return out;
}

/// 构造 workspace_sync 工具。
ToolDefinition createWorkspaceSyncTool(
    {List<SshConfig> sshConfigs = const []}) {
  return ToolDefinition(
    isConcurrencySafe: (_) => false, // 批量写文件，独占执行
    name: 'workspace_sync',
    description:
        '在本地镜像与远端工作区之间同步文件（push = 本地→远端，pull = 远端→本地）。'
        '按修改时间判新旧：较新一方覆盖，单侧新增直接补建；双方都改过（冲突）'
        '默认只报告不覆盖，确认要覆盖时传 overwrite=true。.git 目录恒跳过。'
        '适合：本地改完推到远端跑测试（push），或远端有新产物拉回来（pull）。',
    parameters: {
      'type': 'object',
      'properties': {
        'direction': {
          'type': 'string',
          'enum': ['push', 'pull'],
          'description': 'push = 本地镜像 → 远端（默认）；pull = 远端 → 本地镜像',
        },
        'overwrite': {
          'type': 'boolean',
          'description': '冲突时是否覆盖（默认 false = 只报告）',
        },
      },
      'required': ['direction'],
    },
    execute: (args) async {
      final direction = args['direction'] as String? ?? 'push';
      if (direction != 'push' && direction != 'pull') {
        return ToolResult.error('direction 只能是 push 或 pull');
      }
      final overwrite = args['overwrite'] == true;
      final wsId = effectiveWorkspaceOf(args);
      if (wsId == null || wsId == DevWorkspace.kDefaultId) {
        return ToolResult.error(
            '当前是本地默认工作区，无需同步；请先切换到远端工作区');
      }
      final remote = await resolveRemoteRoot(wsId);
      final connErr = await ensureSshConnectionFor(
          SshEnvironmentService.instance, remote.workspace, sshConfigs);
      if (connErr != null) {
        return ToolResult.error('[SSH] $connErr');
      }
      final ssh = SshEnvironmentService.instance;
      // 目录「有就用、没有就建」，并把 `~`/占位路径换成绝对路径（SFTP 只认绝对路径）。
      final ready = await ensureWorkspaceRemoteDir(remote.workspace);
      if (ready.error != null) return ToolResult.error('[SSH] ${ready.error}');
      final root = ready.root ?? remote.root;
      final localDir = await _localWorkspaceDir(wsId);
      if (!await localDir.exists()) {
        await localDir.create(recursive: true);
      }

      try {
        final sftp = await ssh.openSftp();
        final localFiles = await _walkLocal(localDir);
        final remoteFiles = await _walkRemote(sftp, root);
        final localSet = localFiles.toSet();
        final remoteSet = remoteFiles.toSet();
        final all = {...localSet, ...remoteSet};
        final transferred = <String>[];
        final conflicts = <String>[];
        final skipped = <String>[];
        var unprocessed = 0;

        Future<void> upload(String rel) async {
          final bytes =
              await File(p.join(localDir.path, rel)).readAsBytes();
          if (bytes.length > kSyncMaxFileBytes) {
            skipped.add('$rel（超单文件上限 $kSyncMaxFileBytes 字节）');
            return;
          }
          final abs = toRemotePath(root, rel);
          // 逐级建远端目录（mkdir 失败=已存在，忽略）。
          final segs = rel.split('/')..removeLast();
          var cur = root;
          for (final s in segs) {
            cur = '$cur/$s';
            try {
              await sftp.mkdir(cur);
            } catch (_) {
              // 已存在（SftpStatusError 不实现 Exception ⇒ 只能裸 catch）。
            }
          }
          await ssh.writeFileBytes(abs, bytes);
          transferred.add('$rel（→远端）');
        }

        Future<void> download(String rel) async {
          final bytes = await ssh.readFileBytes(toRemotePath(root, rel),
              maxBytes: kSyncMaxFileBytes);
          final f = File(p.join(localDir.path, rel));
          await f.parent.create(recursive: true);
          await f.writeAsBytes(bytes);
          transferred.add('$rel（←远端）');
        }

        for (final rel in all) {
          if (transferred.length + conflicts.length + skipped.length >=
              kSyncMaxFiles) {
            unprocessed++;
            continue;
          }
          final localF = File(p.join(localDir.path, rel));
          final localExists = await localF.exists();
          final remoteExists = remoteSet.contains(rel);
          if (localExists && !remoteExists) {
            if (direction == 'push') {
              await upload(rel);
            } else {
              // pull：远端没有 → 本地独有，不动（防误删）。
              skipped.add('$rel（仅本地存在）');
            }
            continue;
          }
          if (!localExists && remoteExists) {
            if (direction == 'pull') {
              await download(rel);
            } else {
              skipped.add('$rel（仅远端存在，push 不删除）');
            }
            continue;
          }
          // 双方都有：比 mtime。
          final localStat = await localF.stat();
          final remoteAttr =
              await sftp.stat(toRemotePath(root, rel));
          final lm = localStat.modified.millisecondsSinceEpoch ~/ 1000;
          final rm = remoteAttr.modifyTime;
          if (rm == null || lm == rm) {
            continue; // 相同/未知 → 不动
          }
          final localNewer = lm > rm;
          final shouldTransfer = direction == 'push' ? localNewer : !localNewer;
          if (shouldTransfer || overwrite) {
            if (direction == 'push') {
              await upload(rel);
            } else {
              await download(rel);
            }
          } else {
            // 目标侧反而更新 = 冲突（overwrite=true 时上面已强制覆盖）。
            conflicts.add(rel);
          }
        }

        final buf = StringBuffer();
        buf.writeln('同步完成（$direction，${all.length} 个文件比对）：');
        buf.writeln('已传输 ${transferred.length} 个'
            '${transferred.isEmpty ? '' : '：\n${_joinLimit(transferred)}'}');
        if (conflicts.isNotEmpty) {
          buf.writeln('⚠️ 冲突 ${conflicts.length} 个（双方都有修改，未覆盖）'
              '：\n${_joinLimit(conflicts)}\n'
              '确认覆盖请重跑并带 overwrite=true');
        }
        if (skipped.isNotEmpty) {
          buf.writeln('跳过 ${skipped.length} 个：\n${_joinLimit(skipped)}');
        }
        if (unprocessed > 0) {
          buf.writeln('⚠️ 另有 $unprocessed 个文件超出单次处理上限，未处理');
        }
        return ToolResult(content: buf.toString());
      } catch (e) {
        debugPrint('[sync] failed: $e');
        return ToolResult.error('[SSH] 同步失败: $e');
      }
    },
  );
}

String _joinLimit(List<String> items) {
  const perItem = 80;
  const maxLines = 20;
  final shown = items
      .take(maxLines)
      .map((s) => s.length > perItem ? '${s.substring(0, perItem)}…' : s)
      .join('\n');
  return items.length > maxLines ? '$shown\n…共 ${items.length} 个' : shown;
}
