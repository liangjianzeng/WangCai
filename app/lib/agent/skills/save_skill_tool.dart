/// save_skill 工具 —— 模型自主创建/更新技能（用户"自我觉醒沉淀能力"诉求）。
///
/// 此前技能只能由用户在设置页手写 SKILL.md——模型在对话中发现的
/// 可复用流程、用户"把这个做法存成技能"的诉求都没有落地通道。
/// 本工具补齐"创建 → 落盘 → 即时注册"链路：写入用户技能目录
/// （与设置页管理 UI、loadUserSkills 扫描同一存储，零新格式），
/// 并 [SkillProvider.registerUser] 进当前回合的 provider——本回合内
/// 立即可 load_skill，下回合起自动出现在 `<available_skills>` 目录。
library;

import '../tool_definition.dart';
import 'provider.dart';
import 'skill.dart';

/// 创建 save_skill 工具。[provider] 与注入目录/load_skill 的是同一实例。
/// [skillsDirOverride] 仅测试注入（正常路径写默认用户技能目录）。
ToolDefinition createSaveSkillTool(SkillProvider provider,
    {String? skillsDirOverride}) {
  return ToolDefinition(
    isConcurrencySafe: (_) => false, // 副作用工具：独占执行（P2-A）
    name: 'save_skill',
    description: '把可复用的任务流程/方法论固化为长期技能（跨会话生效）。'
        '两种时机调用：① 用户要求"记住这套做法/存成技能"；'
        '② 你发现本回合的任务处理方式日后还会重复用到。'
        '保存后立即生效：之后同类任务会先 load_skill 按技能指引执行。',
    parameters: {
      'type': 'object',
      'properties': {
        'name': {
          'type': 'string',
          'description': '技能名（唯一标识，如：周报生成 / code-review）',
        },
        'description': {
          'type': 'string',
          'description': '一句话描述（做什么，显示在技能目录）',
        },
        'whenToUse': {
          'type': 'string',
          'description': '何时触发（什么请求应该用这个技能）',
        },
        'content': {
          'type': 'string',
          'description': '技能正文：完整的执行指引（步骤/格式要求/注意事项，'
              '可引用真实工具名 read_file/web_search/python_exec/export_file 等）',
        },
      },
      'required': ['name', 'description', 'whenToUse', 'content'],
    },
    execute: (args) async {
      final name = (args['name'] as String?)?.trim() ?? '';
      final description = (args['description'] as String?)?.trim() ?? '';
      final whenToUse = (args['whenToUse'] as String?)?.trim() ?? '';
      final content = (args['content'] as String?)?.trim() ?? '';
      if (name.isEmpty) return ToolResult.error('缺少 name 参数');
      if (description.isEmpty) return ToolResult.error('缺少 description 参数');
      if (whenToUse.isEmpty) return ToolResult.error('缺少 whenToUse 参数');
      if (content.isEmpty) return ToolResult.error('缺少 content 参数（技能正文）');
      if (content.length > 65536) {
        return ToolResult.error('技能正文过长（${content.length} 字符，上限 65536）');
      }
      try {
        final dirName = await writeUserSkill(
          name: name,
          description: description,
          whenToUse: whenToUse,
          body: content,
          skillsDirOverride: skillsDirOverride,
        );
        // 即时注册：本回合内立即可 load_skill（无需等下回合重扫描）。
        provider.registerUser(Skill(
          name: dirName,
          description: description,
          whenToUse: whenToUse,
          body: content,
          rank: kRankUser,
        ));
        return ToolResult(content: '已保存技能「$dirName」并即时生效：'
            '本回合可 load_skill 加载，之后每回合自动出现在技能目录。'
            '用户也可在 设置→智能体→技能 中查看/编辑。');
      } on ArgumentError catch (e) {
        return ToolResult.error('保存失败：${e.message}');
      } catch (e) {
        return ToolResult.error('保存失败：$e');
      }
    },
  );
}
