/// 长期记忆工具（持久化到 workspace/memory.json，跨会话保留）。
///
/// `memory_set` 写入键值，`memory_get` 读取全部记忆。模型可用它记住
/// 用户偏好/事实，跨会话延续（对齐 DSH 的记忆/持久化能力）。
library;

import 'dart:convert';
import 'dart:io';

import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';

import '../dev/workspace.dart' show DevWorkspace, sanitizeWorkspaceDirName;
import '../tool_definition.dart';

/// 记忆文件路径：全局 = workspace/memory.json；
/// 工作区作用域 = workspace/projects/<safe-id>/memory.json（独立文件）。
Future<File> _memoryFile(String? workspaceId) async {
  final docs = await getApplicationDocumentsDirectory();
  final wsId = workspaceId == null || workspaceId == DevWorkspace.kDefaultId
      ? null
      : workspaceId;
  final dir = Directory(p.join(docs.path, 'workspace',
      wsId == null ? '' : p.join('projects', sanitizeWorkspaceDirName(wsId))));
  if (!await dir.exists()) await dir.create(recursive: true);
  return File(p.join(dir.path, 'memory.json'));
}

/// 读取现有记忆（按工作区作用域）。
Future<Map<String, String>> _readAll(String? workspaceId) async {
  final file = await _memoryFile(workspaceId);
  if (!await file.exists()) return <String, String>{};
  try {
    final decoded = jsonDecode(await file.readAsString());
    if (decoded is Map<String, dynamic>) {
      return decoded.map((k, v) => MapEntry(k, v.toString()));
    }
  } catch (_) {}
  return <String, String>{};
}

/// 写入记忆（原子写 tmp + rename）。
Future<void> _writeAll(Map<String, String> memory, String? workspaceId) async {
  final file = await _memoryFile(workspaceId);
  final tmp = File('${file.path}.tmp');
  await tmp.writeAsString(jsonEncode(memory), flush: true);
  await tmp.rename(file.path);
}

/// 写入一条记忆。参数：`key`、`value`、可选 `workspace`（工作区作用域）。
ToolDefinition createMemorySetTool() {
  return ToolDefinition(
    isConcurrencySafe: (_) => false, // 副作用工具：独占执行（P2-A）
    name: 'memory_set',
    description:
        '写入一条长期记忆（跨会话保留，如用户偏好/重要事实）。'
        'key 为记忆名称，value 为内容。同 key 覆盖。'
        '可选 workspace 参数把记忆限定到指定工作区（Dev 开发模式下自动限定当前工作区）。',
    parameters: {
      'type': 'object',
      'properties': {
        'key': {'type': 'string', 'description': '记忆键'},
        'value': {'type': 'string', 'description': '记忆内容'},
        'workspace': {'type': 'string', 'description': '可选：工作区 id（默认全局记忆）'},
      },
      'required': ['key', 'value'],
    },
    execute: (args) async {
      final key = (args['key'] as String?)?.trim() ?? '';
      final value = (args['value'] as String?)?.trim() ?? '';
      final workspaceId = (args['workspace'] as String?)?.trim();
      if (key.isEmpty) return ToolResult.error('缺少 key 参数');
      if (value.isEmpty) return ToolResult.error('value 为空');
      final memory = await _readAll(workspaceId);
      memory[key] = value;
      await _writeAll(memory, workspaceId);
      return ToolResult(content: '已记住：$key = $value');
    },
  );
}

/// 读取全部记忆（可选 workspace 作用域）。
ToolDefinition createMemoryGetTool() {
  return ToolDefinition(
    name: 'memory_get',
    description:
        '读取长期记忆（只读，不修改）。可选 workspace 参数读取指定工作区记忆。',
    parameters: {
      'type': 'object',
      'properties': {
        'workspace': {'type': 'string', 'description': '可选：工作区 id（默认全局记忆）'},
      },
    },
    execute: (args) async {
      final workspaceId = (args['workspace'] as String?)?.trim();
      final memory = await _readAll(workspaceId);
      if (memory.isEmpty) return ToolResult(content: '当前没有长期记忆。');
      final entries = memory.entries.toList()..sort((a, b) => a.key.compareTo(b.key));
      return ToolResult(content: entries.map((e) => '${e.key}: ${e.value}').join('\n'));
    },
  );
}

/// 全局记忆快照（系统提示自动注入用）：最多 [maxEntries] 条，value 截断到
/// [maxValueChars] 字符。无记忆返回空列表；读文件失败按无记忆处理。
Future<List<MapEntry<String, String>>> readGlobalMemorySnapshot({
  int maxEntries = 8,
  int maxValueChars = 80,
}) async {
  final memory = await _readAll(null);
  if (memory.isEmpty) return const [];
  final entries = memory.entries.toList()
    ..sort((a, b) => a.key.compareTo(b.key));
  return entries
      .take(maxEntries)
      .map((e) => MapEntry(
          e.key,
          e.value.length > maxValueChars
              ? '${e.value.substring(0, maxValueChars)}…'
              : e.value))
      .toList();
}

/// 删除一条全局记忆（设置页记忆管理用）。返回是否发生了删除。
Future<bool> deleteGlobalMemoryEntry(String key) async {
  final memory = await _readAll(null);
  if (!memory.containsKey(key)) return false;
  memory.remove(key);
  await _writeAll(memory, null);
  return true;
}

/// 清空全部全局记忆（设置页记忆管理用）。返回删除的条数。
Future<int> clearGlobalMemory() async {
  final memory = await _readAll(null);
  if (memory.isEmpty) return 0;
  final n = memory.length;
  await _writeAll(<String, String>{}, null);
  return n;
}
