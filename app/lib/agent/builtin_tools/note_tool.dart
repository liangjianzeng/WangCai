/// 便签工具（内存态，进程内共享；重启清零）。
///
/// `note_take` 新增/覆盖便签，`note_list` 读取全部便签。
/// 语义与 todo 一致：全量管理，模型可据此规划。
library;

import 'package:flutter/foundation.dart' show visibleForTesting;

import '../tool_definition.dart';

/// 进程级便签（惰性初始化；重启即清空）。
Map<String, String>? _noteStore;

Map<String, String> _store() => _noteStore ??= <String, String>{};

/// 测试专用：清空便签。
@visibleForTesting
void resetNoteStore() {
  _noteStore = null;
}

/// 便签渲染文本。
String _render(Map<String, String> notes) {
  if (notes.isEmpty) return '当前没有便签。';
  final entries = notes.entries.toList()..sort((a, b) => a.key.compareTo(b.key));
  return entries.map((e) => '${e.key}: ${e.value}').join('\n');
}

/// 新增/覆盖便签。参数：`title`（键）、`content`（内容）。
ToolDefinition createNoteTakeTool() {
  return ToolDefinition(
    isConcurrencySafe: (_) => false, // 副作用工具：独占执行（P2-A）
    name: 'note_take',
    description: '新增或覆盖一条便签。title 为便签标题（键），content 为内容。',
    parameters: {
      'type': 'object',
      'properties': {
        'title': {'type': 'string', 'description': '便签标题'},
        'content': {'type': 'string', 'description': '便签内容'},
      },
      'required': ['title', 'content'],
    },
    execute: (args) async {
      final title = (args['title'] as String?)?.trim() ?? '';
      final content = (args['content'] as String?)?.trim() ?? '';
      if (title.isEmpty) return ToolResult.error('缺少 title 参数');
      if (content.isEmpty) return ToolResult.error('content 为空');
      _store()[title] = content;
      return ToolResult(content: '已保存便签「$title」：$content');
    },
  );
}

/// 读取全部便签。
ToolDefinition createNoteListTool() {
  return ToolDefinition(
    name: 'note_list',
    description: '读取当前全部便签（只读，不修改）。',
    parameters: const {'type': 'object'},
    execute: (args) async {
      return ToolResult(content: _render(_store()));
    },
  );
}
