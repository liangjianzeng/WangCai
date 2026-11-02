/// Git 工具组（Dev Agent Phase C，L1 扩展三后端分派）。
///
/// 分派规则（按工作区后端）：
/// - 本地后端（localApp/embedded/默认工作区）→ JGit 进程内执行
///   （embedded_git.dart，零 exec，W^X 安全）；
/// - 远端后端（termux/remotePc）→ SSH 在远端执行 git 命令（原路径不变）。
///
/// 安全：commit 本地操作默认允许；push 属"影响远端"操作，工具声明
/// sandbox_permissions 升级字段，模型须带 justification 请求用户批准。
/// 破坏性命令（reset --hard / push --force）被黑名单拒绝。
library;

import 'dart:io';

import '../../sandbox.dart' show withEscalationFields;
import '../../tool_definition.dart';
import '../ssh/ssh_credentials.dart' show SshConfig;
import '../workspace.dart';
import '../workspace_store.dart';
import 'embedded_git.dart' show LocalGit;
import '../dev_workspace_actions.dart' show defaultRemoteProjectPathPlaceholder;
import 'ssh_tools.dart' show remoteCdPrefix, sshRunInWorkspace;

/// bash 单引号转义（message 安全入 `git commit -m '...'`）。
String _singleQuote(String s) => "'${s.replaceAll("'", r"'\''")}'";

/// 解析 git 工作根目录与执行面（本地 JGit / 远端 SSH）。
///
/// - null/'default' → 默认工作区（documents/workspace，本地 JGit）；
/// - 本地工作区（localApp/embedded）→ projects/<safe-id> 本地目录；
/// - 远端工作区 → remotePath（SSH 执行）。
Future<({bool remote, String root, DevWorkspace? ws})> _resolveGitRoot(
    Map<String, dynamic> args) async {
  final wsId = effectiveWorkspaceOf(args);
  final store = DevStore.resolve();
  if (wsId == null || wsId == DevWorkspace.kDefaultId) {
    return (remote: false, root: await store.defaultWorkspaceDir(), ws: null);
  }
  final workspaces = await store.loadWorkspaces();
  final ws = workspaces.where((w) => w.id == wsId).firstOrNull;
  if (ws == null) throw StateError('工作区不存在：$wsId');
  if (ws.isRemote) {
    // 目录「有就用、没有就建」：未填路径时给占位 ~/projects/<安全名>，
    // 由工具层在连上后绝对化 + mkdir（不再一上来就甩「未配置远端路径」）。
    final root = (ws.remotePath ?? '').trim();
    return (
      remote: true,
      root: root.isEmpty ? defaultRemoteProjectPathPlaceholder(ws.name) : root,
      ws: ws
    );
  }
  return (remote: false, root: await store.workspaceLocalMirror(wsId), ws: ws);
}

/// 统一错误包装（StateError → ToolResult.error）。
///
/// 支持可选 `path` 参数（工作区内相对子目录）：git_clone 克隆出的仓库在
/// `<工作区>/<name>/`，status/diff/log 等 git 工具靠它指向子目录仓库——
/// 此前只能作用于工作区根，子目录仓库一律 RepositoryNotFound（真机实锤）。
Future<ToolResult> _gitTool(
  Map<String, dynamic> args,
  Future<ToolResult> Function(bool remote, String root) body,
) async {
  bool remote;
  String root;
  try {
    final r = await _resolveGitRoot(args);
    remote = r.remote;
    root = r.root;
  } on StateError catch (e) {
    return ToolResult.error(e.message);
  }
  final path = (args['path'] as String?)?.trim() ?? '';
  if (path.isNotEmpty) {
    final rel = path.replaceAll('\\', '/');
    if (rel.startsWith('/') || rel.split('/').contains('..') || rel.isEmpty) {
      return ToolResult.error('path 必须是工作区内的相对子目录（不允许 .. 与绝对路径）');
    }
    root = root.endsWith('/') ? '$root$rel' : '$root/$rel';
  }
  return body(remote, root);
}

// ---------------------------------------------------------------------------
// git_status
// ---------------------------------------------------------------------------

ToolDefinition createGitStatusTool({List<SshConfig> sshConfigs = const []}) {
  return ToolDefinition(
    name: 'git_status',
    description:
        '查看 git 仓库状态：当前分支、改动文件、未跟踪文件。'
        '开发任务开始时先调用确认基线。'
        'path 可选：仓库在当前工作区下的相对子目录（如 git_clone 克隆出的 '
        'TongYi-Lite/）；缺省 = 工作区根。',
    parameters: {
      'type': 'object',
      'properties': {
        'path': {
          'type': 'string',
          'description': '可选：仓库相对工作区的子目录（默认工作区根）',
        },
      },
    },
    timeout: const Duration(seconds: 15),
    execute: (args) => _gitTool(args, (remote, root) async {
      if (remote) {
        return sshRunInWorkspace(args, (r) {
          return '${remoteCdPrefix(root)} && git status --short --branch 2>/dev/null || '
              'echo "NOT_A_GIT_REPO"';
        }, sshConfigs: sshConfigs);
      }
      final res = await LocalGit.status(root);
      if (!res.ok) return ToolResult.error('git_status 失败：${res.output}');
      return ToolResult(
          content: res.output.isEmpty ? '（无改动，工作区干净）' : res.output);
    }),
  );
}

// ---------------------------------------------------------------------------
// git_diff
// ---------------------------------------------------------------------------

ToolDefinition createGitDiffTool({List<SshConfig> sshConfigs = const []}) {
  return ToolDefinition(
    name: 'git_diff',
    description:
        '查看 git 仓库改动：文件统计 + 具体 diff。'
        '可选 file 只看单个文件；staged=true 看已暂存改动。'
        'path 可选：仓库在当前工作区下的相对子目录（缺省 = 工作区根）。'
        '输出按 4000 字符截断，大改动先看统计再按文件细看。',
    parameters: {
      'type': 'object',
      'properties': {
        'file': {'type': 'string', 'description': '可选：只看某个文件'},
        'staged': {'type': 'boolean', 'description': '是否看已暂存改动（默认 false）'},
        'path': {
          'type': 'string',
          'description': '可选：仓库相对工作区的子目录（默认工作区根）',
        },
      },
    },
    timeout: const Duration(seconds: 15),
    execute: (args) {
      final file = (args['file'] as String?)?.trim() ?? '';
      final staged = (args['staged'] as bool?) ?? false;
      return _gitTool(args, (remote, root) async {
        if (remote) {
          return sshRunInWorkspace(args, (r) {
            final scope = staged ? '--staged' : '';
            final fileArg = file.isEmpty ? '' : ' $file';
            return '${remoteCdPrefix(root)} && git diff $scope$fileArg --stat && '
                'echo "---" && git diff $scope$fileArg';
          }, sshConfigs: sshConfigs);
        }
        final res = await LocalGit.diff(root, staged: staged, file: file);
        if (!res.ok) return ToolResult.error('git_diff 失败：${res.output}');
        return ToolResult(content: res.output.isEmpty ? '（无改动）' : res.output);
      });
    },
  );
}

// ---------------------------------------------------------------------------
// git_log
// ---------------------------------------------------------------------------

ToolDefinition createGitLogTool({List<SshConfig> sshConfigs = const []}) {
  return ToolDefinition(
    name: 'git_log',
    description:
        '查看 git 仓库最近提交历史（默认最近 10 条，一行摘要）。'
        '可选 n 指定条数；path 可选：仓库相对工作区的子目录（缺省 = 工作区根）。',
    parameters: {
      'type': 'object',
      'properties': {
        'n': {'type': 'number', 'description': '条数（默认 10）'},
        'path': {
          'type': 'string',
          'description': '可选：仓库相对工作区的子目录（默认工作区根）',
        },
      },
    },
    timeout: const Duration(seconds: 15),
    execute: (args) {
      final n = ((args['n'] as num?)?.toInt() ?? 10).clamp(1, 50);
      return _gitTool(args, (remote, root) async {
        if (remote) {
          return sshRunInWorkspace(args, (r) {
            return '${remoteCdPrefix(root)} && git log --oneline -$n 2>/dev/null || '
                'echo "NOT_A_GIT_REPO"';
          }, sshConfigs: sshConfigs);
        }
        final res = await LocalGit.log(root, n: n);
        if (!res.ok) return ToolResult.error('git_log 失败：${res.output}');
        return ToolResult(content: res.output.isEmpty ? '（暂无提交）' : res.output);
      });
    },
  );
}

// ---------------------------------------------------------------------------
// git_commit
// ---------------------------------------------------------------------------

ToolDefinition createGitCommitTool({List<SshConfig> sshConfigs = const []}) {
  return ToolDefinition(
    isConcurrencySafe: (_) => false, // 副作用工具：独占执行（P2-A）
    name: 'git_commit',
    description:
        '提交 git 仓库改动：files 为要提交的文件（相对仓库根，可用 "." 提交全部），'
        'message 为提交说明。提交前建议先 git_diff 自查。'
        'path 可选：仓库相对工作区的子目录（缺省 = 工作区根）。'
        '这是本地操作，不需要批准。',
    parameters: {
      'type': 'object',
      'properties': {
        'files': {
          'type': 'array',
          'description': '要提交的文件（相对仓库根；"." 提交全部改动）',
          'items': {'type': 'string'},
        },
        'message': {'type': 'string', 'description': '提交说明'},
        'path': {
          'type': 'string',
          'description': '可选：仓库相对工作区的子目录（默认工作区根）',
        },
      },
      'required': ['files', 'message'],
    },
    timeout: const Duration(seconds: 15),
    execute: (args) {
      final rawFiles = args['files'] as List? ?? const [];
      final message = (args['message'] as String?)?.trim() ?? '';
      if (rawFiles.isEmpty) return Future.value(ToolResult.error('files 为空（"." 提交全部）'));
      if (message.isEmpty) return Future.value(ToolResult.error('message 为空'));
      final files = [
        for (final f in rawFiles)
          if (f is String && f.trim().isNotEmpty) f.trim(),
      ];
      if (files.isEmpty) return Future.value(ToolResult.error('files 为空'));
      return _gitTool(args, (remote, root) async {
        if (remote) {
          return sshRunInWorkspace(args, (r) {
            final addArgs = files.join(' ');
            return '${remoteCdPrefix(root)} && git add $addArgs && git commit -m ${_singleQuote(message)}';
          }, sshConfigs: sshConfigs);
        }
        final res = await LocalGit.commit(root, files: files, message: message);
        if (!res.ok) return ToolResult.error('git_commit 失败：${res.output}');
        return ToolResult(content: res.output.isEmpty ? '已提交' : res.output);
      });
    },
  );
}

// ---------------------------------------------------------------------------
// git_push
// ---------------------------------------------------------------------------

ToolDefinition createGitPushTool({List<SshConfig> sshConfigs = const []}) {
  return ToolDefinition(
    isConcurrencySafe: (_) => false, // 副作用工具：独占执行（P2-A）
    name: 'git_push',
    description:
        '推送当前分支到远端仓库。会改动远端代码，需要用户批准：'
        '请带 sandbox_permissions + justification 请求批准后执行。'
        '本地工作区走 https：需要凭据时带 username + token（用户提供后原样传入）。',
    parameters: withEscalationFields({
      'type': 'object',
      'properties': {
        'remote': {'type': 'string', 'description': '可选：远端名（默认 origin）'},
        'branch': {'type': 'string', 'description': '可选：分支名（默认当前分支）'},
        'username': {'type': 'string', 'description': '可选：https 用户名（本地工作区）'},
        'token': {'type': 'string', 'description': '可选：https 访问令牌（本地工作区）'},
      },
    }),
    timeout: const Duration(seconds: 30),
    execute: (args) {
      final remote = (args['remote'] as String?)?.trim() ?? 'origin';
      final branch = (args['branch'] as String?)?.trim() ?? '';
      final username = (args['username'] as String?)?.trim() ?? '';
      final token = (args['token'] as String?)?.trim() ?? '';
      return _gitTool(args, (remoteFlag, root) async {
        if (remoteFlag) {
          return sshRunInWorkspace(args, (r) {
            final branchArg = branch.isEmpty ? '' : ' $branch';
            return '${remoteCdPrefix(root)} && git push $remote$branchArg';
          },
              timeout: const Duration(seconds: 30),
              sshConfigs: sshConfigs);
        }
        final res = await LocalGit.push(root,
            remote: remote,
            branch: branch.isEmpty ? null : branch,
            username: username.isEmpty ? null : username,
            password: token.isEmpty ? null : token);
        if (!res.ok) return ToolResult.error('git_push 失败：${res.output}');
        return ToolResult(content: res.output.isEmpty ? '已推送' : res.output);
      });
    },
  );
}

// ---------------------------------------------------------------------------
// git_clone（L1 新增：本地工作区一键拉仓库；远端走 ssh_exec 由模型自行执行）
// ---------------------------------------------------------------------------

ToolDefinition createGitCloneTool({List<SshConfig> sshConfigs = const []}) {
  return ToolDefinition(
    name: 'git_clone',
    isConcurrencySafe: (_) => false, // 副作用工具：写工作区（P2-A / 计划模式禁用）
    description:
        '克隆仓库到本地工作区下的新子目录 <工作区>/<name>（url 为 https 地址；'
        'name 缺省取 URL 仓库名，目标目录已存在非空会报错）。'
        '大仓库务必带 depth（浅克隆，如 depth=1 只拉最近一层提交）——'
        '只读代码/分析时推荐 depth=1，可大幅省流量与时间；浅克隆不能 push。'
        '需要凭据时带 username + token。'
        '远端工作区（Termux/远程电脑）不支持本工具，请用 ssh_exec 执行 git clone。',
    parameters: withEscalationFields({
      'type': 'object',
      'properties': {
        'url': {'type': 'string', 'description': 'https 仓库地址'},
        'name': {'type': 'string', 'description': '可选：目标目录名（默认取仓库名）'},
        'username': {'type': 'string', 'description': '可选：https 用户名'},
        'token': {'type': 'string', 'description': '可选：https 访问令牌'},
        'branch': {'type': 'string', 'description': '可选：分支（默认远端 HEAD）'},
        'depth': {
          'type': 'integer',
          'description': '可选：浅克隆深度（提交层数）。大仓库建议 1；'
              '不传 = 完整克隆（历史全量，大仓库很慢）',
        },
      },
      'required': ['url'],
    }),
    timeout: const Duration(seconds: 300),
    execute: (args) {
      final url = (args['url'] as String?)?.trim() ?? '';
      final name = (args['name'] as String?)?.trim() ?? '';
      final username = (args['username'] as String?)?.trim() ?? '';
      final token = (args['token'] as String?)?.trim() ?? '';
      final branch = (args['branch'] as String?)?.trim() ?? '';
      final depth = args['depth'] is num ? (args['depth'] as num).toInt() : null;
      if (url.isEmpty) return Future.value(ToolResult.error('缺少 url 参数'));
      if (url.startsWith('git@') || url.contains('ssh://')) {
        return Future.value(ToolResult.error(
            '本地工作区仅支持 https 克隆（ssh 协议不支持）。'
            '请改用 https 地址，或切到 Termux/远程工作区用 ssh_exec'));
      }
      return _gitTool(args, (remote, root) async {
        if (remote) {
          return ToolResult.error('git_clone 仅支持本地工作区；'
              '远端请用 ssh_exec 执行 git clone');
        }
        // 克隆目标必须是工作区下的**新子目录**（JGit 要求目标为空目录）。
        // 此前直接克隆进工作区根——根目录永不为空，恒报
        // "Destination path already exists and is not an empty directory"。
        final repoName = name.isNotEmpty
            ? name
            : url
                .replaceAll(RegExp(r'/+$'), '')
                .split('/')
                .last
                .replaceAll(RegExp(r'\.git$'), '');
        if (repoName.isEmpty) {
          return ToolResult.error('无法从 url 推断仓库名，请带 name 参数');
        }
        final target = root.endsWith('/')
            ? '$root$repoName'
            : '$root/$repoName';
        final targetDir = Directory(target);
        String? backupPath;
        if (targetDir.existsSync() &&
            targetDir.listSync(followLinks: false).isNotEmpty) {
          final hasGit = File('$target/.git').existsSync() ||
              Directory('$target/.git').existsSync();
          if (hasGit) {
            return ToolResult.error('目标目录已是一个 git 仓库：$target。'
                '更新代码请用 git_pull；确要重克隆请换一个 name 参数');
          }
          // 非仓库残留（如旧会话 HTTP 拉取的裸文件）→ 自动改名备份后重新克隆，
          // 不删任何数据（真机实锤：残留目录把 git_clone 永久堵死）。
          backupPath =
              '$target.bak-${DateTime.now().millisecondsSinceEpoch}';
          targetDir.renameSync(backupPath);
        }
        await targetDir.create(recursive: true);
        final res = await LocalGit.clone(url, target,
            username: username.isEmpty ? null : username,
            password: token.isEmpty ? null : token,
            branch: branch.isEmpty ? null : branch,
            depth: depth);
        if (!res.ok) {
          // 克隆失败把备份挪回来，不丢用户文件。
          if (backupPath != null) Directory(backupPath).renameSync(target);
          return ToolResult.error('git_clone 失败：${res.output}');
        }
        final tag = depth != null && depth > 0 ? '（浅克隆 depth=$depth）' : '';
        final bak = backupPath == null ? '' : '（旧目录已备份为 $backupPath）';
        return ToolResult(content: '已克隆到 $target$tag$bak');
      });
    },
  );
}
