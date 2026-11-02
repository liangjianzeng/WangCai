/// 「☑ 任务清单」结构化卡片：解析 [renderTodoCardText] 生成的固定格式文本
/// （首行标题 + 逐行 `徽标 序号. 内容`），渲染为带状态图标的清单视图。
///
/// 显示约定（与 todo_tool 状态归一化一致）：
/// - `✓` 已完成 → 绿色勾 + 灰化删除线；
/// - `▶` 进行中 → 橙色旋转箭头 + 高亮底色；
/// - `○` 待办   → 灰色空心圈。
///
/// 对话内气泡（chat_bubble）与计划面板（home_screen）共用本组件，
/// 保证两处任务列表展示完全一致。
library;

import 'package:flutter/material.dart';

class TodoChecklistCard extends StatelessWidget {
  final String content;

  const TodoChecklistCard({super.key, required this.content});

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final lines = content.split('\n');
    final title = lines.first.trim();
    final rows = <Widget>[];
    for (final raw in lines.skip(1)) {
      final line = raw.trim();
      if (line.isEmpty) continue;
      final badge = line.startsWith('✓')
          ? _Badge.done
          : line.startsWith('▶')
              ? _Badge.running
              : _Badge.pending;
      final text = line.length > 1 ? line.substring(1).trim() : line;
      final (icon, color) = switch (badge) {
        _Badge.done => (Icons.check_circle, Colors.green),
        _Badge.running => (Icons.autorenew, Colors.orange),
        _Badge.pending => (Icons.radio_button_unchecked, Colors.grey),
      };
      rows.add(Container(
        margin: const EdgeInsets.symmetric(vertical: 1),
        padding: badge == _Badge.running
            ? const EdgeInsets.symmetric(horizontal: 6, vertical: 3)
            : const EdgeInsets.symmetric(horizontal: 6, vertical: 1),
        decoration: badge == _Badge.running
            ? BoxDecoration(
                color: Colors.orange.withValues(alpha: 0.10),
                borderRadius: BorderRadius.circular(6),
              )
            : null,
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Padding(
              padding: const EdgeInsets.only(top: 2),
              child: Icon(icon, size: 14, color: color),
            ),
            const SizedBox(width: 6),
            Expanded(
              child: Text(
                text,
                style: TextStyle(
                  fontSize: 13,
                  height: 1.35,
                  color: badge == _Badge.done
                      ? theme.colorScheme.onSurfaceVariant.withValues(alpha: 0.55)
                      : null,
                  decoration:
                      badge == _Badge.done ? TextDecoration.lineThrough : null,
                ),
              ),
            ),
          ],
        ),
      ));
    }
    return Column(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(title,
            style: const TextStyle(fontSize: 14, fontWeight: FontWeight.w600)),
        if (rows.isNotEmpty) const SizedBox(height: 4),
        ...rows,
      ],
    );
  }
}

enum _Badge { done, running, pending }
