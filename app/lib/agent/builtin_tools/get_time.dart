/// 内置工具：get_time —— 返回当前日期与时间（含星期）。
library;

import '../tool_definition.dart';

/// 创建 get_time 工具（零依赖、无副作用、无参数）。
ToolDefinition createGetTimeTool() {
  return ToolDefinition(
    name: 'get_time',
    description: '返回当前日期与时间（含星期）。无参数。',
    parameters: const {
      'type': 'object',
      'properties': {},
      'additionalProperties': false,
    },
    execute: (args) async {
      final now = DateTime.now();
      const weekdays = ['一', '二', '三', '四', '五', '六', '日'];
      final weekday = weekdays[now.weekday - 1];
      final mm = now.month.toString().padLeft(2, '0');
      final dd = now.day.toString().padLeft(2, '0');
      final hh = now.hour.toString().padLeft(2, '0');
      final mi = now.minute.toString().padLeft(2, '0');
      final ss = now.second.toString().padLeft(2, '0');
      return ToolResult(
        content: '当前时间：${now.year}-$mm-$dd $hh:$mi:$ss（星期$weekday）',
      );
    },
  );
}
