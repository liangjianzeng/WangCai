/// 待办清单工具（持久化，v3：**按会话隔离**）。
///
/// 语义照抄 DSH 的 todo 工具：`todo_write` 全量替换任务清单；
/// `todo_list` 只读当前清单（供模型规划下一步）。清单按会话落盘
/// `ApplicationSupport/agent_todo_<convId>.json`——跨 turn、跨重启保留，
/// 且不同会话互不可见（v2 是全局单文件，计划面板在任何会话都显示同一份
/// 清单，用户反馈"计划状态应该跟着会话任务走"）。
/// 旧全局 `agent_todo.json` 首次被某会话读取时一次性迁移（迁移即删除，
/// 只归第一个打开的会话，避免继续全局可见）。
library;

import 'dart:convert';
import 'dart:io';

import 'package:flutter/foundation.dart' show visibleForTesting;
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';

import '../tool_definition.dart';

/// 各会话的进程级清单缓存（key = conversationId；写入即落盘）。
final Map<String, List<Map<String, String>>> _todoStores = {};
String? _todoBaseDir;

/// 会话 id → 文件名安全段。
String _safeConv(String conversationId) =>
    conversationId.replaceAll(RegExp(r'[^\w-]'), '_');

Future<String> _baseDir() async {
  _todoBaseDir ??= (await getApplicationSupportDirectory()).path;
  return _todoBaseDir!;
}

Future<File> _fileOf(String conversationId) async {
  final base = await _baseDir();
  return File(p.join(base, 'agent_todo_${_safeConv(conversationId)}.json'));
}

/// 旧全局文件路径（v2 遗留；迁移后删除）。
Future<File> _legacyFile() async {
  final base = await _baseDir();
  return File(p.join(base, 'agent_todo.json'));
}

Future<List<Map<String, String>>> _store(String conversationId) async {
  final cached = _todoStores[conversationId];
  if (cached != null) return cached;
  try {
    final file = await _fileOf(conversationId);
    if (file.existsSync()) {
      final decoded = jsonDecode(file.readAsStringSync());
      if (decoded is List) {
        return _todoStores[conversationId] = [
          for (final e in decoded)
            if (e is Map<String, dynamic>) _cleanItem(e),
        ];
      }
    }
    // v2 → v3 迁移：旧全局文件内容归入**第一个读取的会话**并删除全局文件
    //（不删会让后续每个会话都继承同一份清单——正是要修的跨会话可见）。
    final legacy = await _legacyFile();
    if (legacy.existsSync()) {
      final decoded = jsonDecode(legacy.readAsStringSync());
      final items = <Map<String, String>>[
        if (decoded is List)
          for (final e in decoded)
            if (e is Map<String, dynamic>) _cleanItem(e),
      ];
      _todoStores[conversationId] = items;
      final f = await _fileOf(conversationId);
      f.writeAsStringSync(jsonEncode(items));
      legacy.deleteSync();
      return items;
    }
  } catch (_) {
    // 坏文件/测试环境无插件 → 空清单，不影响工具可用性。
  }
  return _todoStores[conversationId] = <Map<String, String>>[];
}

/// 写入即落盘（best-effort：失败不阻断，内存清单仍有效）。
Future<void> _persist(String conversationId) async {
  final store = _todoStores[conversationId];
  if (store == null) return;
  try {
    final file = await _fileOf(conversationId);
    await file.writeAsString(jsonEncode(store));
  } catch (_) {}
}

/// 测试专用：清空全部会话的待办清单缓存 + 删除测试期间落盘的会话文件
///（不删的话下一个用例会从磁盘读到旧清单——v3 每次都读盘）。
@visibleForTesting
void resetTodoStore() {
  _todoStores.clear();
  final base = _todoBaseDir;
  if (base == null) return;
  final dir = Directory(base);
  if (!dir.existsSync()) return;
  for (final f in dir.listSync()) {
    if (f is File &&
        p.basename(f.path).startsWith('agent_todo_')) {
      try {
        f.deleteSync();
      } catch (_) {}
    }
  }
}

/// 测试专用：注入旧全局遗留文件（v2 迁移路径测试用）。
@visibleForTesting
void debugSeedLegacyTodoFile(String json) {
  _todoBaseDir = Directory.systemTemp.createTempSync('todo_test').path;
  File(p.join(_todoBaseDir!, 'agent_todo.json')).writeAsStringSync(json);
}

/// 生成待办清单文本。
String _render(List<Map<String, String>> items) {
  if (items.isEmpty) return '当前没有待办任务。';
  final lines = <String>[];
  for (var i = 0; i < items.length; i++) {
    final item = items[i];
    lines.add('${i + 1}. [${item['status']}] ${item['content']}');
  }
  return '当前待办清单（共 ${items.length} 项）：\n${lines.join('\n')}';
}

/// 全量替换待办清单。参数：`todos: [{content, status}]`。
/// 调用后返回当前完整清单与状态计数（待办/进行中/已完成）。
///
/// 执行期强制（DSH todo 纪律，不靠提示词自觉）：
/// - **单活跃**：同一时刻最多一个 `in_progress`（含 doing 等别名），
///   违反直接拒绝执行并返回修正指引（`toTodoList` throw 同语义）；
/// - 状态词归一化判定：done/completed/finished → 已完成；
///   in_progress/inprogress/doing/current → 进行中；其余 → 待办。
///   存储保留调用方原词（展示/测试兼容），仅判定时归一化。
ToolDefinition createTodoWriteTool(
    {required String conversationId,
    void Function(List<Map<String, String>> items)? onTodosChanged}) {
  return ToolDefinition(
    isConcurrencySafe: (_) => false, // 副作用工具：独占执行（P2-A）
    name: 'todo_write',
    description:
        '全量替换待办任务清单。todos 为任务数组，每项含 content（任务内容）'
        '与 status（状态：todo/in_progress/done）。发送完整清单（整表替换，'
        '无部分更新）；同一时刻最多一项 in_progress，完成一项立刻标记 done，'
        '不要批量补记。调用后返回当前完整清单与计数。',
    parameters: {
      'type': 'object',
      'properties': {
        'todos': {
          'type': 'array',
          'items': {
            'type': 'object',
            'properties': {
              'content': {'type': 'string'},
              'status': {'type': 'string'},
            },
            'required': ['content'],
          },
          'description': '任务数组',
        },
      },
      'required': ['todos'],
    },
    execute: (args) async {
      final raw = args['todos'];
      // 兼容 List 与 JSON 字符串两种形态（XML 协议值可能以字符串到达）。
      List? parsed;
      if (raw is List) {
        parsed = raw;
      } else if (raw is String) {
        final trimmed = raw.trim();
        if (trimmed.isNotEmpty && trimmed.startsWith('[')) {
          try {
            final decoded = jsonDecode(trimmed);
            if (decoded is List) parsed = decoded;
          } catch (_) {}
        }
      }
      if (parsed == null) {
        return ToolResult.error('缺少 todos 参数（应为任务数组）');
      }
      final items = <Map<String, String>>[];
      try {
        for (final e in parsed) {
          if (e is Map<String, dynamic>) {
            items.add(_cleanItem(e));
          } else if (e is Map) {
            items.add(_cleanItem(Map<String, dynamic>.from(e)));
          }
        }
      } on ArgumentError catch (e) {
        return ToolResult.error('$e');
      }
      if (items.isEmpty) {
        return ToolResult.error('todos 数组为空');
      }
      // 单活跃强制：>1 个进行中 → 拒绝执行（原清单保持不变），返回修正指引。
      final active = items.where((e) => _isInProgress(e['status'])).length;
      if (active > 1) {
        return ToolResult.error(
            '待办清单被拒绝：同时有 $active 项处于 in_progress。'
            '同一时刻只能有一项进行中——请把其余进行中项改回 todo'
            '（或已完成项标 done），重新发送完整清单。');
      }
      final store = await _store(conversationId)
        ..clear()
        ..addAll(items);
      await _persist(conversationId);
      // UI 通知：对话内"任务清单"活卡 upsert（chat_provider 接线）。
      onTodosChanged?.call(List.unmodifiable(items));
      return ToolResult(
          content: '待办清单已更新（${_countText(store)}）：\n${_render(store)}');
    },
  );
}

/// 状态归一化判定：是否「进行中」。
bool _isInProgress(String? status) {
  final s = (status ?? '').trim().toLowerCase();
  return s == 'in_progress' || s == 'inprogress' || s == 'doing' ||
      s == 'current' || s == 'active';
}

/// 状态归一化判定：是否「已完成」。
bool _isDone(String? status) {
  final s = (status ?? '').trim().toLowerCase();
  return s == 'done' || s == 'completed' || s == 'finished' || s == 'ok';
}

/// 状态计数一行（DSH `Updated todo list: X pending, Y in progress, Z
/// completed.` 同语义）。
String _countText(List<Map<String, String>> items) {
  var pending = 0, active = 0, done = 0;
  for (final e in items) {
    if (_isInProgress(e['status'])) {
      active++;
    } else if (_isDone(e['status'])) {
      done++;
    } else {
      pending++;
    }
  }
  return '待办 $pending · 进行中 $active · 已完成 $done';
}

/// UI 读取某会话当前待办清单（对话内任务清单活卡 / 计划面板用）。
/// 按会话隔离：不同会话各看各的清单（v2 全局单文件已废弃）。
Future<List<Map<String, String>>> readTodoStore(String conversationId) =>
    _store(conversationId);

/// 渲染对话内「任务清单」活卡文本（todo_write 成功后由接入层 upsert 固定
/// id 消息；徽标：✓ 已完成 / ▶ 进行中 / ○ 待办）。
String renderTodoCardText(List<Map<String, String>> items) {
  final buf = StringBuffer('☑ 任务清单（${_countText(items)}）');
  for (var i = 0; i < items.length; i++) {
    final e = items[i];
    final badge = _isDone(e['status'])
        ? '✓'
        : _isInProgress(e['status'])
            ? '▶'
            : '○';
    buf.write('\n$badge ${i + 1}. ${e['content'] ?? ''}');
  }
  return buf.toString();
}

/// 读取当前会话待办清单（只读，不修改）。
ToolDefinition createTodoListTool({required String conversationId}) {
  return ToolDefinition(
    name: 'todo_list',
    description: '读取当前待办任务清单（只读，不修改）。',
    parameters: const {'type': 'object'},
    execute: (args) async {
      return ToolResult(content: _render(await _store(conversationId)));
    },
  );
}

/// 清洗单个待办项：content 必填非空；status 缺省为 'todo'。
Map<String, String> _cleanItem(Map<String, dynamic> json) {
  final content = json['content']?.toString().trim() ?? '';
  if (content.isEmpty) {
    throw ArgumentError('任务内容不能为空');
  }
  final status = json['status']?.toString().trim() ?? 'todo';
  return {'content': content, 'status': status};
}
