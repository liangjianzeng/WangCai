/// 文件类工具 —— 对齐 DSH 的 read/write/edit/glob/grep，作用域为应用沙盒
/// `documents/workspace`（模型可读写的工作目录），路径规范化防逃逸。
library;

import 'dart:io';

import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';

import '../dev/workspace.dart' show DevWorkspace, effectiveWorkspaceOf, sanitizeWorkspaceDirName;
import '../sandbox.dart';
import '../tool_definition.dart';

/// 单次读文件的最大字节（保护上下文预算）。
const int kReadFileLimit = 8192;

/// 单次写入的最大字节。
const int kWriteFileLimit = 65536;

/// 搜索结果的单文件最大匹配数。
const int kGrepPerFileLimit = 20;

/// 解析工作区根目录（Dev Agent）：
/// - null / 'default' → `documents/workspace`（旧行为零回归）；
/// - 其他本地工作区 → `documents/workspace/projects/<safe-id>/`（本地镜像）。
Future<Directory> _workspaceDir([String? workspaceId]) async {
  final docs = await getApplicationDocumentsDirectory();
  final wsId = workspaceId == null || workspaceId == DevWorkspace.kDefaultId
      ? null
      : workspaceId;
  final dir = Directory(p.join(docs.path, 'workspace',
      wsId == null ? '' : p.join('projects', sanitizeWorkspaceDirName(wsId))));
  if (!await dir.exists()) {
    await dir.create(recursive: true);
  }
  return dir;
}

/// 规范化路径并按沙箱模式限定作用域（对照 DSH fs 沙箱）。
///
/// - [SandboxMode.workspaceWrite]（默认）：相对路径解析到 workspace 内，
///   防 `../` 逃逸（现有策略）；
/// - [SandboxMode.dangerFullAccess]（用户批准后）：绝对路径直接使用
///   （如 `/sdcard/...`、`/storage/emulated/0/...`，依赖 All-Files-Access），
///   相对路径仍解析到 workspace；
/// - [workspaceId]：Dev 工作区（null/默认 = 默认工作区）。
Future<String> _resolveSafePath(String rawPath,
    {SandboxMode? mode, String? workspaceId}) async {
  final workspace = await _workspaceDir(workspaceId);
  if (mode == SandboxMode.dangerFullAccess) {
    final trimmed = rawPath.trim();
    if (p.isAbsolute(trimmed)) {
      return p.normalize(trimmed);
    }
  }
  final resolved = p.normalize(p.join(workspace.path, rawPath));
  final workspaceNorm = p.normalize(workspace.path);
  if (!p.equals(resolved, workspaceNorm) &&
      !resolved.startsWith('$workspaceNorm${p.separator}')) {
    throw ArgumentError('路径越界：$rawPath（仅允许 workspace 内）');
  }
  return resolved;
}

/// 追加升级字段到工具 schema（共享实现见 sandbox.dart）。
Map<String, dynamic> _withEscalation(Map<String, dynamic> parameters) =>
    withEscalationFields(parameters);

/// 读文件：返回内容（截断到 [kReadFileLimit]）。
ToolDefinition createReadFileTool() {
  return ToolDefinition(
    name: 'read_file',
    description:
        '读取工作区内文本文件内容。path 为相对 workspace 的路径（如 "notes/draft.txt"）；'
        '需要读取公共目录（/sdcard 等）时带 sandbox_permissions 请求完整访问。'
        '分析/修改文件前必须先 read_file 完整阅读，绝不在未读的情况下凭空作答或编辑；'
        '写入或编辑之后，用 read_file 读回核对结果再声称完成。',
    parameters: _withEscalation({
      'type': 'object',
      'properties': {
        'path': {'type': 'string', 'description': '相对 workspace 的文件路径，或绝对路径'},
      },
      'required': ['path'],
    }),
    execute: (args) async {
      final rawPath = (args['path'] as String?)?.trim() ?? '';
      if (rawPath.isEmpty) return ToolResult.error('缺少 path 参数');
      try {
        final path = await _resolveSafePath(rawPath,
            mode: effectiveModeOf(args), workspaceId: effectiveWorkspaceOf(args));
        final file = File(path);
        if (!await file.exists()) return ToolResult.error('文件不存在：$rawPath');
        final len = await file.length();
        if (len > kReadFileLimit * 2) {
          return ToolResult.error('文件过大（${len ~/ 1024}KB），仅支持读取前 ${kReadFileLimit ~/ 1024}KB');
        }
        final content = await file.readAsString();
        return ToolResult(
          content: content.length <= kReadFileLimit
              ? content
              : '${content.substring(0, kReadFileLimit)}\n…（已截断）',
        );
      } catch (e) {
        return ToolResult.error('读取失败：$e');
      }
    },
  );
}

/// 写文件：覆盖写入（目录自动创建）。
ToolDefinition createWriteFileTool() {
  return ToolDefinition(
    isConcurrencySafe: (_) => false, // 副作用工具：独占执行（P2-A）
    name: 'write_file',
    description:
        '覆盖写入文本到工作区文件（目录自动创建）；需要写公共目录（/sdcard 等）时'
        '带 sandbox_permissions 请求完整访问。content 必须是完整最终内容'
        '（整文件替换）；只改局部用 edit_file 更省。',
    parameters: _withEscalation({
      'type': 'object',
      'properties': {
        'path': {'type': 'string', 'description': '相对 workspace 的文件路径，或绝对路径'},
        'content': {'type': 'string', 'description': '完整文件内容'},
      },
      'required': ['path', 'content'],
    }),
    execute: (args) async {
      final rawPath = (args['path'] as String?)?.trim() ?? '';
      final content = (args['content'] as String?) ?? '';
      if (rawPath.isEmpty) return ToolResult.error('缺少 path 参数');
      if (content.isEmpty) return ToolResult.error('content 为空');
      if (content.length > kWriteFileLimit) {
        return ToolResult.error('内容过大（>${kWriteFileLimit ~/ 1024}KB）');
      }
      try {
        final path = await _resolveSafePath(rawPath,
            mode: effectiveModeOf(args), workspaceId: effectiveWorkspaceOf(args));
        await File(path).parent.create(recursive: true);
        await File(path).writeAsString(content, flush: true);
        return ToolResult(content: '已写入 $rawPath（${content.length} 字符）');
      } catch (e) {
        return ToolResult.error('写入失败：$e');
      }
    },
  );
}

/// 编辑文件：替换 oldString → newString（oldString 必须唯一）。
ToolDefinition createEditFileTool() {
  return ToolDefinition(
    isConcurrencySafe: (_) => false, // 副作用工具：独占执行（P2-A）
    name: 'edit_file',
    description:
        '替换工作区文件中的文本（oldString 必须唯一，出现多次会报错）；'
        '编辑公共目录文件时带 sandbox_permissions 请求完整访问。'
        'oldString 要带足够上下文（含缩进的连续原文），先 read_file 确认原文'
        '再编辑；报「出现 N 次」就扩长 oldString，不要盲改。',
    parameters: _withEscalation({
      'type': 'object',
      'properties': {
        'path': {'type': 'string', 'description': '相对 workspace 的文件路径，或绝对路径'},
        'oldString': {'type': 'string', 'description': '被替换的原文'},
        'newString': {'type': 'string', 'description': '替换后的文本'},
      },
      'required': ['path', 'oldString', 'newString'],
    }),
    execute: (args) async {
      final rawPath = (args['path'] as String?)?.trim() ?? '';
      final oldString = (args['oldString'] as String?) ?? '';
      final newString = (args['newString'] as String?) ?? '';
      if (rawPath.isEmpty) return ToolResult.error('缺少 path 参数');
      if (oldString.isEmpty) return ToolResult.error('oldString 为空');
      try {
        final path = await _resolveSafePath(rawPath,
            mode: effectiveModeOf(args), workspaceId: effectiveWorkspaceOf(args));
        final file = File(path);
        if (!await file.exists()) return ToolResult.error('文件不存在：$rawPath');
        final content = await file.readAsString();
        final count = _countOccurrences(content, oldString);
        if (count == 0) return ToolResult.error('未找到要替换的文本');
        if (count > 1) {
          return ToolResult.error('oldString 出现 $count 次，需提供更长的上下文');
        }
        final updated = content.replaceFirst(oldString, newString);
        await file.writeAsString(updated, flush: true);
        return ToolResult(content: '已替换 1 处（${updated.length} 字符）');
      } catch (e) {
        return ToolResult.error('编辑失败：$e');
      }
    },
  );
}

/// 列出文件：递归 glob（对齐 DSH glob）。
ToolDefinition createListFilesTool() {
  return ToolDefinition(
    name: 'list_files',
    description:
        '列出工作区文件。pattern 为 glob（如 "**/*.txt"），缺省列出全部。',
    parameters: {
      'type': 'object',
      'properties': {
        'pattern': {'type': 'string', 'description': 'glob 模式'},
      },
    },
    execute: (args) async {
      try {
        final workspace =
            await _workspaceDir(effectiveWorkspaceOf(args));
        final files = <String>[];
        await for (final entity in workspace.list(recursive: true)) {
          if (entity is File) {
            files.add(p.relative(entity.path, from: workspace.path));
          }
        }
        files.sort();
        final pattern = (args['pattern'] as String?)?.trim() ?? '';
        var matches = files;
        if (pattern.isNotEmpty) {
          matches = files.where(_matchesGlob(pattern)).toList();
        }
        if (matches.isEmpty) return ToolResult(content: '无匹配文件');
        final limited = matches.take(100).toList();
        return ToolResult(
          content: '共 ${matches.length} 个文件${matches.length > 100 ? '（仅显示前 100）' : ''}：\n'
              '${limited.join('\n')}',
        );
      } catch (e) {
        return ToolResult.error('列出失败：$e');
      }
    },
  );
}

/// 搜索内容：递归 grep（对齐 DSH grep）。
ToolDefinition createSearchTextTool() {
  return ToolDefinition(
    name: 'search_text',
    description:
        '在工作区文件内容中搜索正则 pattern（如 "TODO|bug"），返回文件名:行号:行。',
    parameters: {
      'type': 'object',
      'properties': {
        'pattern': {'type': 'string', 'description': '正则表达式'},
      },
      'required': ['pattern'],
    },
    execute: (args) async {
      final pattern = (args['pattern'] as String?)?.trim() ?? '';
      if (pattern.isEmpty) return ToolResult.error('缺少 pattern 参数');
      try {
        final re = RegExp(pattern);
        final workspace =
            await _workspaceDir(effectiveWorkspaceOf(args));
        final hits = <String>[];
        await for (final entity in workspace.list(recursive: true)) {
          if (entity is! File) continue;
          if (!(await _isTextFile(entity))) continue;
          try {
            final lines = await entity.readAsLines();
            var matched = 0;
            for (var i = 0; i < lines.length && matched < kGrepPerFileLimit; i++) {
              if (re.hasMatch(lines[i])) {
                final rel = p.relative(entity.path, from: workspace.path);
                hits.add('$rel:${i + 1}:${lines[i].length > 120 ? lines[i].substring(0, 117) + '…' : lines[i]}');
                matched++;
              }
            }
          } catch (_) {
            // 跳过无法读取的文件
          }
        }
        if (hits.isEmpty) return ToolResult(content: '无匹配');
        return ToolResult(content: hits.take(40).join('\n'));
      } catch (e) {
        return ToolResult.error('搜索失败：$e');
      }
    },
  );
}

/// 判断是否为文本文件（跳过二进制）。
Future<bool> _isTextFile(File file) async {
  final raf = await file.open();
  try {
    final bytes = await raf.read(2048);
    // 含 NUL 字节视为二进制。
    return !bytes.contains(0);
  } catch (_) {
    return false;
  } finally {
    await raf.close();
  }
}

int _countOccurrences(String haystack, String needle) {
  if (needle.isEmpty) return 0;
  var count = 0;
  var idx = 0;
  while ((idx = haystack.indexOf(needle, idx)) >= 0) {
    count++;
    idx += needle.length;
  }
  return count;
}

/// 简单 glob → 正则（支持 *、?、**）。
bool Function(String) _matchesGlob(String pattern) {
  final normalized = pattern.replaceAll(r'\', '/');
  final parts = normalized.split('/');
  final regex = StringBuffer('^');
  for (var i = 0; i < parts.length; i++) {
    final part = parts[i];
    if (part == '**') {
      regex.write('(?:.*/)?');
    } else {
      regex.write(RegExp.escape(part)
          .replaceAll(r'\*', '[^/]*')
          .replaceAll(r'\?', '[^/]'));
    }
    if (i < parts.length - 1) regex.write('/');
  }
  regex.write(r'$');
  return (path) => RegExp(regex.toString()).hasMatch(path);
}
