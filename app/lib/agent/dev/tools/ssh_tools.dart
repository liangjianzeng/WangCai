/// SSH 开发环境工具（Dev Agent Phase B）—— 默认不注册，设置开启后挂载。
///
/// 连接策略（真机教训：别让用户手动连接）：
/// - 工具执行前按工作区绑定的配置**自动连接**（配置不完整/缺失给出明确诊断）；
/// - 执行中连接断开 → 自动重连一次并重试；
/// - 错误信息带 `[SSH]` 前缀并区分未配置/连接失败/执行失败，防模型幻觉成功。
/// 路径以"相对当前工作区"呈现，执行层映射到远端根目录。
library;

import 'dart:convert';

import 'package:flutter/foundation.dart' show debugPrint;

import '../../builtin_tools/shell_tool.dart'
    show kShellOutputLimit; // 复用同一截断上限语义
import '../../sandbox.dart' show withEscalationFields;
import '../../tool_definition.dart';
import '../dev_workspace_actions.dart'
    show defaultRemoteProjectPathPlaceholder, ensureWorkspaceRemoteDir;
import '../safety.dart';
import '../ssh/secret_store.dart' show resolveSshSecretsAll;
import '../ssh/ssh_credentials.dart' show SshConfig;
import '../ssh/ssh_diagnostics.dart';
import '../ssh/ssh_environment.dart';
import '../termux_intent.dart';
import '../workspace.dart';
import '../workspace_store.dart';

/// 单次远端读文件上限（与本地 read_file 对齐）。
const int kSshReadFileLimit = 8192;

/// 单次远端写入上限（与本地 write_file 对齐）。
const int kSshWriteFileLimit = 65536;

/// 解析远端工作区根目录。
///
/// - workspaceId 缺失/默认 → 错误（默认工作区是本地，无远端路径）；
/// - 工作区不存在 / backend 非远端 → 错误；
/// - **remotePath 空 → 不再报错**，给占位 `~/projects/<安全名>`，由
///   `ensureWorkspaceRemoteDir` 在连上后绝对化并 `mkdir -p`（2026-10-27 用户定案：
///   目录"有就用、没有就建"，不该每条消息都甩个 No such file or directory）。
/// 返回 `(root, workspace)`。
Future<({String root, DevWorkspace workspace})> resolveRemoteRoot(
    String? workspaceId) async {
  if (workspaceId == null || workspaceId == DevWorkspace.kDefaultId) {
    throw StateError('当前工作区是本地默认工作区，没有远端路径。'
        '请先切换到 Termux/远程电脑工作区，或使用本地文件工具');
  }
  final store = DevStore.resolve();
  final workspaces = await store.loadWorkspaces();
  final ws = workspaces.where((w) => w.id == workspaceId).firstOrNull;
  if (ws == null) {
    throw StateError('工作区不存在：$workspaceId');
  }
  if (!ws.isRemote) {
    throw StateError('工作区「${ws.name}」是本地后端，无远端路径');
  }
  final root = (ws.remotePath ?? '').trim();
  return (
    root: root.isEmpty ? defaultRemoteProjectPathPlaceholder(ws.name) : root,
    workspace: ws
  );
}

/// 远端「进目录」前缀：**目录不存在就地创建**。
///
/// 两条独立防线里的第二条（第一条是 [ensureSshConnectionFor] 里的一次性 mkdir）：
/// 会话中途目录被删、或 intent 免 SSH 通道（没连接也可用）时，
/// `cd 不存在的目录` 仍会让整条命令以 errno 收场，模型只会反复重试。
/// `~` 开头的路径**不能加引号**（引号里波浪号不展开），名称已由
/// `sanitizeWorkspaceDirName` 约束，无注入面。
String remoteCdPrefix(String root) {
  final dir = root.startsWith('~') ? root : sq(root);
  return 'mkdir -p $dir && cd $dir';
}

/// 远端路径的父目录（SFTP 写文件前建父目录用；无 `/` 时返回空串）。
String remoteParentDir(String path) {
  final i = path.lastIndexOf('/');
  if (i <= 0) return '';
  return path.substring(0, i);
}


/// 相对路径 → 远端绝对路径（相对基于工作区远端根目录）。
String toRemotePath(String root, String rawPath) {
  final trimmed = rawPath.trim();
  if (trimmed.isEmpty) return root;
  if (trimmed.startsWith('/')) return trimmed; // 已是绝对路径
  return '$root/${trimmed.replaceAll(RegExp(r'^\./'), '')}';
}

/// bash 单引号转义：所有插入远端 shell 的模型可控值都必须过这里。
///
/// 可用性评估 P1-8：`cd $root`、`git push $remote$branch`、`cd $root/$cwd`
/// 全是裸插值，模型给个 `branch: "x && touch pwned"` 即逃逸，带空格路径也直接炸。
String sq(String s) => "'${s.replaceAll("'", r"'\''")}'";

/// 确保 SSH 连接（按工作区绑定的配置自动连接/切换）。
///
/// 返回错误信息（null = 已连接可用）。
///
/// ⚠️ 完整性必须在**回填凭据之后**判：私钥/登录密码被 secret_store 搬进
/// 安全存储后，settings 里的配置只剩空槽位，直接判 `isComplete` 恒为 false
/// （密码登录尤其致命——密码正是被剥离的字段），表现为"配好了却报未配置"。
Future<String?> ensureSshConnectionFor(
    SshEnvironmentService ssh, DevWorkspace ws, List<SshConfig> sshConfigs) async {
  // 已连接且配置匹配（都未绑定或绑定相同）：直接复用。
  if (ssh.isConnected) {
    final activeId = ssh.activeConfig?.id;
    final wsId = ws.sshConfigId;
    if (wsId == null || wsId.isEmpty || activeId == wsId) return null;
    // 绑定不同配置：需要切换。
  }
  final resolved = await resolveSshSecretsAll(sshConfigs);
  SshConfig? cfg;
  final wsId = ws.sshConfigId;
  if (wsId == null || wsId.isEmpty) {
    // 未绑定配置：自动取列表里第一份完整配置。
    for (final c in resolved) {
      if (c.isComplete) {
        cfg = c;
        break;
      }
    }
    if (cfg == null) {
      return 'SSH 未配置：请在「设置 → 开发者」中配置 Termux/远程电脑连接'
          '（远程电脑可用账号密码直接登录，不必装公钥）';
    }
  } else {
    for (final c in resolved) {
      if (c.id == wsId) {
        cfg = c;
        break;
      }
    }
    if (cfg == null || !cfg.isComplete) {
      return 'SSH 配置不完整：工作区「${ws.name}」绑定的连接配置缺失或未填完整，'
          '请在「设置 → 开发者」补全（用户名 + 私钥或登录密码）';
    }
  }
  if (!await ssh.ensureConnected(cfg)) {
    final target = ws.backend == WorkspaceBackend.remotePc
        ? SshTargetKind.remotePc
        : sshTargetKindOf(cfg);
    return 'SSH 连接失败：'
        '${classifySshFailure(ssh.lastError, target: target, passwordAuth: cfg.usesPassword, keyAuth: cfg.usesKey)}';
  }
  // 连上 ≠ 能干活：工作区目录不在，后面每个工具都会撞 `cd: No such file`。
  // 这里一次性「有就用、没有就建」（含 ~ 绝对化 + 路径回填），后续调用命中缓存。
  final dir = await ensureWorkspaceRemoteDir(ws);
  if (dir.error != null) return dir.error;
  return null;
}

/// P2-D2：读取远端工作区根目录的 AGENTS.md（SFTP，≤64KB）。
/// 任何失败（无远端工作区/未配置/连接失败/文件不存在）返回 null，
/// 调用方静默降级为只注入本地 AGENTS.md。
Future<String?> readRemoteAgentsMd(
    String? workspaceId, List<SshConfig> sshConfigs) async {
  try {
    final remote = await resolveRemoteRoot(workspaceId);
    final sshErr = await ensureSshConnectionFor(
        SshEnvironmentService.instance, remote.workspace, sshConfigs);
    if (sshErr != null) return null;
    // SFTP 不认 `~`：用确保过的绝对根目录（ensureSshConnectionFor 内已建目录）。
    final ready = await ensureWorkspaceRemoteDir(remote.workspace);
    final root = ready.root ?? remote.root;
    if (root.startsWith('~')) return null;
    final path = toRemotePath(root, 'AGENTS.md');
    final bytes = await SshEnvironmentService.instance
        .readFileBytes(path, maxBytes: 65536);
    return utf8.decode(bytes, allowMalformed: true);
  } catch (e) {
    // 必须是裸 catch：以前写 `on Exception`，而 dartssh2 的 SftpStatusError
    // 不实现 Exception ⇒ 远端没有 AGENTS.md 就能把**整条消息发送**打死
    // （真机「发送失败: SftpStatusError: No such file(code 2)」）。
    // 这个函数是"锦上添花"的上下文注入，任何失败都必须静默降级。
    debugPrint('[Dev] 读远端 AGENTS.md 失败（忽略）: $e');
    return null;
  }
}

/// termux 后端：先试 RUN_COMMAND intent 免 SSH 通道（L2），不可用回落 SSH。
///
/// 回落条件 = 通道不可用（Termux 未装/未开 allow-external-apps）；
/// 命令超时不回落（命令可能已在 Termux 侧执行，重复执行有副作用）。
/// 返回 null = 走 SSH。
Future<ToolResult?> _tryTermuxIntent(
    DevWorkspace ws, String fullCommand, Duration timeout) async {
  if (ws.backend != WorkspaceBackend.termux) return null;
  try {
    final res = await TermuxIntentService.instance.run(fullCommand,
        timeout: timeout);
    final out = res.output.trim();
    final truncated = out.length > kShellOutputLimit
        ? '${out.substring(0, kShellOutputLimit)}\n…（已截断）'
        : out;
    return ToolResult(
        content: truncated.isEmpty ? '（无输出，exit=${res.exit}）' : truncated,
        isError: !res.ok);
  } on StateError catch (e) {
    if (e.message.startsWith('Termux 通道不可用')) {
      return null; // 回落 SSH
    }
    return ToolResult.error('[TERMUX] ${e.message}');
  }
}

/// termux 后端：intent 读文件（免 SSH）。返回 null = 走 SSH。
/// 读取截断语义与 ssh_read_file 一致（kSshReadFileLimit）。
Future<ToolResult?> _termuxRead(DevWorkspace ws, String remotePath) async {
  if (ws.backend != WorkspaceBackend.termux) return null;
  try {
    final content =
        await TermuxIntentService.instance.readFile(remotePath);
    if (content == null) {
      return ToolResult.error('[TERMUX] 读取失败或文件不存在：$remotePath');
    }
    return ToolResult(
      content: content.length <= kSshReadFileLimit
          ? content
          : '${content.substring(0, kSshReadFileLimit)}\n…（已截断）',
    );
  } on StateError catch (e) {
    if (e.message.startsWith('Termux 通道不可用')) return null;
    return ToolResult.error('[TERMUX] ${e.message}');
  }
}

/// termux 后端：intent 写文件（免 SSH）。返回 null = 走 SSH。
Future<ToolResult?> _termuxWrite(
    DevWorkspace ws, String remotePath, String content) async {
  if (ws.backend != WorkspaceBackend.termux) return null;
  try {
    final ok = await TermuxIntentService.instance.writeFile(remotePath, content);
    return ok
        ? ToolResult(content: '已写入 $remotePath（${content.length} 字符）')
        : ToolResult.error('[TERMUX] 写入失败（内容过大或命令失败）');
  } on StateError catch (e) {
    if (e.message.startsWith('Termux 通道不可用')) return null;
    return ToolResult.error('[TERMUX] ${e.message}');
  }
}

/// 共享：在远端工作区执行命令（git/verify/ssh 工具共用）。
///
/// [buildCommand]：接收远端根目录，返回要执行的完整命令。
/// [dangerText]：**只送黑名单的文本**（模型原始命令段）。不传时回落 [buildCommand]
/// 的结果 —— 但 `cd <remoteRoot> && ` 前缀含工作区名，旧版据此会把
/// "工作区叫 mount-app" 的所有命令误杀，故调用方应尽量只传模型命令。
/// 内部做：工作区解析 → intent 优先（Termux 免 SSH）→ 自动连接 → 断连重连重试 → 截断。
Future<ToolResult> sshRunInWorkspace(
  Map<String, dynamic> args,
  String Function(String root) buildCommand, {
  List<SshConfig> sshConfigs = const [],
  Duration timeout = const Duration(seconds: 30),
  int outputLimit = kShellOutputLimit,
  String? dangerText,
}) async {
  String fullCommand;
  DevWorkspace ws;
  String root;
  try {
    final wsId = effectiveWorkspaceOf(args);
    final remote = await resolveRemoteRoot(wsId);
    ws = remote.workspace;
    root = remote.root;
    fullCommand = buildCommand(root);
  } on StateError catch (e) {
    return ToolResult.error('${e.message}（ssh 工具需要远端工作区）');
  }
  final danger = checkDangerousCommand(dangerText ?? fullCommand);
  if (danger != null) {
    return ToolResult.error('危险命令被拒绝：$danger');
  }
  // termux 后端：intent 优先（免 SSH）。
  final intentResult = await _tryTermuxIntent(ws, fullCommand, timeout);
  if (intentResult != null) return intentResult;
  final ssh = SshEnvironmentService.instance;
  final connError = await ensureSshConnectionFor(ssh, ws, sshConfigs);
  if (connError != null) {
    return ToolResult.error('[SSH] $connError');
  }
  // 连上后根目录可能刚被"补全 + 建好"（空路径 / `~` → 绝对路径）：重建命令，
  // 让 git 等工具拿到与工作区记录一致的绝对目录（此处必然命中 mkdir 缓存）。
  final ready = await ensureWorkspaceRemoteDir(ws);
  if (ready.error != null) return ToolResult.error('[SSH] ${ready.error}');
  if (ready.root != null && ready.root != root) {
    root = ready.root!;
    fullCommand = buildCommand(root);
  }
  // 执行；连接类失败自动重连一次。
  for (var attempt = 0; attempt < 2; attempt++) {
    try {
      final output = await ssh.run(fullCommand, timeout: timeout);
      final trimmed = (output ?? '').trim();
      final truncated = trimmed.length > outputLimit
          ? '${trimmed.substring(0, outputLimit)}\n…（已截断）'
          : trimmed;
      return ToolResult(content: truncated.isEmpty ? '（无输出）' : truncated);
    } catch (e) {
      if (!ssh.isConnected && attempt == 0) {
        // 连接断了：自动重连一次再试。
        final retry = await ensureSshConnectionFor(ssh, ws, sshConfigs);
        if (retry == null) continue;
      }
      return ToolResult.error('[SSH] 命令执行失败：$e');
    }
  }
  return ToolResult.error('[SSH] 命令执行失败（已重试一次）');
}

/// ssh_exec：在远端执行命令（cwd 相对工作区）。
ToolDefinition createSshExecTool({List<SshConfig> sshConfigs = const []}) {
  return ToolDefinition(
    isConcurrencySafe: (_) => false, // 副作用工具：独占执行（P2-A）
    name: 'ssh_exec',
    description:
        '在 SSH 开发环境（Termux/远程电脑）执行 shell 命令。'
        '命令默认在工作区远端根目录下运行。输出截断到 ${kShellOutputLimit} 字符，超时 30s。'
        '需要完整文件系统访问时带 sandbox_permissions 请求用户批准。'
        '危险命令（rm -rf /、reboot、git push --force 等）会被拒绝。'
        '连接会自动建立，无需手动操作。',
    parameters: withEscalationFields({
      'type': 'object',
      'properties': {
        'command': {'type': 'string', 'description': '要执行的 shell 命令'},
        'cwd': {'type': 'string', 'description': '可选：相对当前工作区的目录（默认工作区根）'},
      },
      'required': ['command'],
    }),
    timeout: const Duration(seconds: 30),
    execute: (args) async {
      final command = (args['command'] as String?)?.trim() ?? '';
      if (command.isEmpty) return ToolResult.error('缺少 command 参数');
      final cwd = (args['cwd'] as String?)?.trim() ?? '';
      if (cwd.replaceAll('\\', '/').split('/').contains('..')) {
        return ToolResult.error('cwd 必须是工作区内的相对子目录（不允许 ..）');
      }
      // 危险命令只看模型传入的 command 段（不把 `cd <root> && ` 前缀喂进黑名单）。
      final danger = checkDangerousCommand(command);
      if (danger != null) {
        return ToolResult.error('危险命令被拒绝：$danger');
      }
      // 工作区 → 远端根目录映射。前缀自带 mkdir：目录没建过也直接开工。
      String fullCommand;
      try {
        final wsId = effectiveWorkspaceOf(args);
        final remote = await resolveRemoteRoot(wsId);
        fullCommand =
            '${remoteCdPrefix(toRemotePath(remote.root, cwd))} && $command';
        final ssh = SshEnvironmentService.instance;
        // termux 后端：intent 优先（免 SSH）。
        //
        // 可用性评估 P1-15：旧版**先连 SSH 再试 intent**，连接失败即 return，
        // 于是"没配 sshd 的 Termux"主打工具 ssh_exec 直接报连接失败 ——
        // 号称的免 SSH 通道对 ssh_exec 完全失效（而 sshRunInWorkspace 是 intent
        // 优先，造成"有的工具能用有的不能"）。现与共享执行器统一：intent 先行。
        final intentResult = await _tryTermuxIntent(
            remote.workspace, fullCommand, const Duration(seconds: 30));
        if (intentResult != null) return intentResult;
        final connError =
            await ensureSshConnectionFor(ssh, remote.workspace, sshConfigs);
        if (connError != null) {
          return ToolResult.error('[SSH] $connError');
        }
        for (var attempt = 0; attempt < 2; attempt++) {
          try {
            final output = await ssh.run(fullCommand,
                timeout: const Duration(seconds: 30));
            final trimmed = (output ?? '').trim();
            final truncated = trimmed.length > kShellOutputLimit
                ? '${trimmed.substring(0, kShellOutputLimit)}\n…（已截断）'
                : trimmed;
            return ToolResult(
                content: truncated.isEmpty ? '（无输出）' : truncated);
          } catch (e) {
            if (!ssh.isConnected && attempt == 0) {
              final retry =
                  await ensureSshConnectionFor(ssh, remote.workspace, sshConfigs);
              if (retry == null) continue;
            }
            return ToolResult.error('[SSH] 命令执行失败：$e');
          }
        }
        return ToolResult.error('[SSH] 命令执行失败（已重试一次）');
      } on StateError catch (e) {
        return ToolResult.error('${e.message}（ssh 工具需要远端工作区）');
      }
    },
  );
}

/// ssh_read_file：远端读文件（SFTP）。
ToolDefinition createSshReadFileTool({List<SshConfig> sshConfigs = const []}) {
  return ToolDefinition(
    name: 'ssh_read_file',
    description:
        '读取 SSH 开发环境中当前工作区文件的内容。path 为相对工作区的路径。'
        '读取前 ${kSshReadFileLimit} 字符，超过部分截断。连接自动建立。',
    parameters: {
      'type': 'object',
      'properties': {
        'path': {'type': 'string', 'description': '相对当前工作区的文件路径'},
      },
      'required': ['path'],
    },
    timeout: const Duration(seconds: 30),
    execute: (args) async {
      final rawPath = (args['path'] as String?)?.trim() ?? '';
      if (rawPath.isEmpty) return ToolResult.error('缺少 path 参数');
      String remotePath;
      DevWorkspace ws;
      try {
        final wsId = effectiveWorkspaceOf(args);
        final remote = await resolveRemoteRoot(wsId);
        ws = remote.workspace;
        remotePath = toRemotePath(remote.root, rawPath);
      } on StateError catch (e) {
        return ToolResult.error('${e.message}（ssh 工具需要远端工作区）');
      }
      // termux 后端：intent 优先（免 SSH，base64 免截断）。
      final termuxRead = await _termuxRead(ws, remotePath);
      if (termuxRead != null) return termuxRead;
      final ssh = SshEnvironmentService.instance;
      final connError = await ensureSshConnectionFor(ssh, ws, sshConfigs);
      if (connError != null) {
        return ToolResult.error('[SSH] $connError');
      }
      try {
        // SFTP 不认 `~`，且工作区目录可能压根没建过：连上后绝对化 + 确保存在。
        final ready = await ensureWorkspaceRemoteDir(ws);
        if (ready.error != null) return ToolResult.error('[SSH] ${ready.error}');
        if (ready.root != null) remotePath = toRemotePath(ready.root!, rawPath);
        final bytes = await ssh.readFileBytes(remotePath);
        final content = utf8.decode(bytes, allowMalformed: true);
        return ToolResult(
          content: content.length <= kSshReadFileLimit
              ? content
              : '${content.substring(0, kSshReadFileLimit)}\n…（已截断）',
        );
      } catch (e) {
        return ToolResult.error('[SSH] 远端读取失败：$e');
      }
    },
  );
}

/// ssh_write_file：远端写文件（SFTP，覆盖截断）。
ToolDefinition createSshWriteFileTool({List<SshConfig> sshConfigs = const []}) {
  return ToolDefinition(
    isConcurrencySafe: (_) => false, // 副作用工具：独占执行（P2-A）
    name: 'ssh_write_file',
    description:
        '写入文本到 SSH 开发环境中当前工作区文件（覆盖，目录自动创建）。'
        'path 为相对工作区的路径，单次上限 ${kSshWriteFileLimit ~/ 1024}KB。连接自动建立。',
    parameters: {
      'type': 'object',
      'properties': {
        'path': {'type': 'string', 'description': '相对当前工作区的文件路径'},
        'content': {'type': 'string', 'description': '完整文件内容'},
      },
      'required': ['path', 'content'],
    },
    timeout: const Duration(seconds: 30),
    execute: (args) async {
      final rawPath = (args['path'] as String?)?.trim() ?? '';
      final content = (args['content'] as String?) ?? '';
      if (rawPath.isEmpty) return ToolResult.error('缺少 path 参数');
      if (content.isEmpty) return ToolResult.error('content 为空');
      if (content.length > kSshWriteFileLimit) {
        return ToolResult.error('内容过大（>${kSshWriteFileLimit ~/ 1024}KB）');
      }
      String remotePath;
      DevWorkspace ws;
      try {
        final wsId = effectiveWorkspaceOf(args);
        final remote = await resolveRemoteRoot(wsId);
        ws = remote.workspace;
        remotePath = toRemotePath(remote.root, rawPath);
      } on StateError catch (e) {
        return ToolResult.error('${e.message}（ssh 工具需要远端工作区）');
      }
      // termux 后端：intent 优先（免 SSH，base64 免换行截断）。
      final termuxWrite = await _termuxWrite(ws, remotePath, content);
      if (termuxWrite != null) return termuxWrite;
      final ssh = SshEnvironmentService.instance;
      final connError = await ensureSshConnectionFor(ssh, ws, sshConfigs);
      if (connError != null) {
        return ToolResult.error('[SSH] $connError');
      }
      try {
        // 描述里承诺的「目录自动创建」这次才真正兑现：SFTP open 不会自己建目录，
        // 工作区根目录没建过 / 写到子目录都会撞 `No such path`。
        final ready = await ensureWorkspaceRemoteDir(ws);
        if (ready.error != null) return ToolResult.error('[SSH] ${ready.error}');
        if (ready.root != null) remotePath = toRemotePath(ready.root!, rawPath);
        final parent = remoteParentDir(remotePath);
        if (parent.isNotEmpty) {
          await ssh.run('mkdir -p ${sq(parent)}',
              timeout: const Duration(seconds: 20));
        }
        await ssh.writeFileBytes(remotePath, utf8.encode(content));
        return ToolResult(content: '已写入 $rawPath（${content.length} 字符）');
      } catch (e) {
        return ToolResult.error('[SSH] 远端写入失败：$e');
      }
    },
  );
}
