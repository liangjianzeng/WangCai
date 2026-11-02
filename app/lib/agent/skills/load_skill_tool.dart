/// load_skill 工具 —— 按需加载技能全文（WP2c）。
///
/// 此前 system 只注入 `<available_skills>` 目录（name/description/whenToUse），
/// `SkillProvider.skillText()`（完整 body 渲染）没有任何调用方——模型看到
/// 技能清单却永远拿不到正文。本工具补上"目录 → 触发 → 加载 body"链路
/// （DSH Part 12.3 语义）：模型按 whenToUse 判断命中后调用本工具，
/// 返回 `<skill name="...">body</skill>` 注入下一轮上下文。
library;

import '../tool_definition.dart';
import 'provider.dart';

/// 创建 load_skill 工具。[provider] 与注入目录的是同一实例。
ToolDefinition createLoadSkillTool(SkillProvider provider) {
  final names = provider.skills.map((s) => s.name).toList();
  return ToolDefinition(
    name: 'load_skill',
    description: '加载指定技能的完整说明并按其指引执行。'
        '当任务匹配 <available_skills> 中某技能的 whenToUse 时调用。'
        '可用技能：${names.isEmpty ? "（无）" : names.join("、")}。',
    parameters: {
      'type': 'object',
      'properties': {
        'name': {
          'type': 'string',
          'description': '技能名（见 <available_skills> 列表）',
        },
      },
      'required': ['name'],
    },
    execute: (args) async {
      final raw = args['name'];
      final name = raw is String ? raw.trim() : '';
      if (name.isEmpty) {
        return ToolResult.error('缺少 name 参数（应为技能名）');
      }
      final text = provider.skillText(name);
      if (text.isEmpty) {
        return ToolResult.error(
            '未知技能 "$name"。可用技能：${names.isEmpty ? "（无）" : names.join("、")}');
      }
      return ToolResult(content: text);
    },
  );
}
