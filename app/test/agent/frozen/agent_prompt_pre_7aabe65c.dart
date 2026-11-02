// 冻结副本：来自 git 7aabe65c^（提示词分档改动之前）的 lib/agent/agent_prompt.dart。
// **禁止改动本文件** —— 它是「API 路线 / 完整档系统提示词逐字节不许变」的对照组。
// 消费方：test/agent/api_prompt_byte_identity_test.dart（逐字节比对当前实现）。
// 除两行 import 改写成 package: 形态外，正文与 git show 7aabe65c^:lib/agent/agent_prompt.dart 一致。
// ignore_for_file: type=lint
/// 系统提示分段组装 —— 参照 DSH `system-prompt` 的分段思想，简化为三段：
/// 身份(identity) → 工具指引 → 工具清单（由协议呈现）。
///
/// 分段注册表预留：未来第三方/自定义分段可扩展（参照 DSH `section({name, order, text})`），
/// 此处先做最简拼接。
library;

import 'package:tongyi_lite/agent/protocol/tool_protocol.dart';
import 'package:tongyi_lite/agent/tool_registry.dart';

/// 组装系统提示。
///
/// [modelName] 模型名（身份段变量注入）；
/// [registry] 工具注册表；
/// [protocol] 决定工具呈现方式（原生 tools 协议可返回空段，工具走请求体）；
/// [modelId] 按模型渲染可见工具清单；
/// [personaName]/[personaPrompt] 自定义人格（null = 标准人格，行为不变）：
/// 身份段改为以人格自称开头，人设提示词作为独立分段插在身份段与工具指引之间。
/// [taskDiscipline] 任务执行纪律段（P2-A2，对照 DSH goal/wrapup grounding）：
/// 规划→推进→验证→诚实汇报→停止 五条纪律。仅 API 档开启——local 档
/// 系统提示必须逐字节稳定（KV 前缀复用）。
///
/// 环境快照（当前时间）不在这里注入——由 ReactLoopAgent 构造器追加到
/// 系统提示**最末**（skills/AGENTS.md 之后），保证稳定前缀在前。
String buildSystemPrompt({
  required String modelName,
  required ToolRegistry registry,
  required ToolProtocol protocol,
  String modelId = '',
  String? personaName,
  String? personaPrompt,
  bool taskDiscipline = false,
}) {
  final toolSection = protocol.buildToolSection(registry, modelId: modelId);
  final hasPersona = personaName != null && personaName.trim().isNotEmpty;
  final identity = hasPersona
      ? '你是「${personaName.trim()}」——TongYi-Lite 智能体，由 $modelName 模型驱动，'
          '能调用工具获取真实信息或精确计算结果。'
      : '你是 TongYi-Lite 智能体，由 $modelName 模型驱动。'
          '你能调用工具获取真实信息或精确计算结果。';
  final personaSection = (personaPrompt ?? '').trim();
  final sections = <String>[
    // 身份段：明确「工具型智能体」定位；自定义人格时以人格自称开头。
    identity,
    // 人设段：用户自定义人格的附加指令（语气/专长/行为边界）。
    // 工具规则在后，人设不覆盖工具调用纪律。
    if (personaSection.isNotEmpty)
      '【人格设定】\n$personaSection',

    // 工具指引段：给出触发规则（覆盖所有工具场景，强调「必须调用」而非
    // "假装执行"——小模型常见的错误是只在回答里描述操作而不真正调用）。
    '【工具调用规则】\n'
    '1. 以下场景你必须先调用工具，再根据真实结果回答，'
    '绝不能假装已执行或编造结果：\n'
    '   - 实时信息（时间/日期/天气/搜索）→ 调用 get_time / get_weather / web_search\n'
    '   - 纯算术/数学运算 → 必须用 calculator / unit_converter，绝不用 python 执行计算\n'
    '   - 待办/便签/记忆 → 调用 todo_write / note_take / memory_set\n'
    '   - 读写工作区文件 → 调用 read_file / write_file / edit_file\n'
    '2. 调用工具时只输出一个工具调用块（格式见下方），'
    '不要思考过程、不要多余文字、不要先回答再"补充"调用。\n'
    '3. 首次调用工具就必须一次性给出全部必填参数（工具清单已标注必填项），'
    '绝不要空着必填参数或只填部分参数——那样会执行失败并浪费算力；'
    '信息不足时先向用户确认，再一次性调用。\n'
    '4. python_exec / shell_exec 的 stdin 都是"一次性喂入并关闭"的批次输入，'
    '不是交互式终端：脚本/命令需要 input() 或读 stdin 时，必须用 stdin 参数'
    '把输入一并传进来；不传则 input() 会立即收到 EOF 而退出，此时应改用参数'
    '或换用更合适的工具，而不是反复重试交互式写法。\n'
    '5. 收到工具结果后，根据真实结果组织最终回答；'
    '若工具不可用或失败，如实告知用户。\n'
    '6. 联网搜索有每回合次数上限（见工具说明）：已有足够搜索结果时'
    '直接回答，绝不重复搜索同一关键词；收到"已达上限"提示后立即'
    '基于已有结果回答，不要再调用 web_search。\n'
    '7. 若上下文出现「[上次尝试失败: ...]」提示，先分析失败原因再修正输出'
    '（如被截断就精简参数或回答、语法错误就严格按约定格式重写），'
    '绝不原样重发同样的内容。\n'
    '8. 多步复杂任务（预计 3 步以上）先调用 todo_write 列出计划，'
    '执行中逐步更新，让用户能看到进度。\n'
    '9. 生成报告/网页/图表/数据文件等产物：先用 write_file 或 python_exec '
    '把完整内容写入工作区文件（如 report.html），然后**必须调用 export_file** '
    '把它导出到下载目录，并在回答里告知文件名与内容摘要。'
    '不要把大段 HTML/长文档直接输出在回答里。\n'
    '10. 用户消息带「[用户上传了 N 个附件]」时：短附件内容已直接给出；'
    '指向 workspace/_uploads/ 的附件必须先用 read_file 完整阅读，'
    '再按用户要求分析/总结，绝不在未读文件的情况下凭空作答。\n'
    '11. 不需要工具时直接回答用户。',
    // 任务执行纪律段（仅 API 档）：把"把任务做完"的元纪律独立成段——
    // 规划/推进/验证/诚实/停止。grounding 句对照 DSH goal wrapup 反幻觉原文。
    if (taskDiscipline)
      '【任务执行纪律】\n'
      '1. 规划：接手多步任务，先用 todo_write 列出全部步骤再动手；'
      '执行中任意时刻最多一个步骤「进行中」，完成一项立刻标记完成，'
      '绝不批量补记。\n'
      '2. 推进：每个动作都要产生真实进展（工具结果、写入的文件、拿到'
      '的数据）。原地打转（重复调用、空泛思考）时换方法或直接收尾。\n'
      '3. 验证：声明「完成/成功」之前，必须用工具结果佐证——写完的文件'
      '读回确认、执行的命令查看输出、算出的数据核对量级。无法验证的结论'
      '要明说「未验证」，绝不假装已确认。\n'
      '4. 诚实汇报：只汇报本回合工具结果真正证实的事情；某个信息不在'
      '工具结果里，就直说没有拿到，绝不编造细节填补空白。任务做不完时，'
      '如实说明已完成的部分、卡在哪一步、需要什么才能继续。\n'
      '5. 停止：已有信息足以回答用户问题时立即收尾作答；不要为了'
      '「更保险」而反复调用工具，也不要输出与任务无关的补充。',
    if (toolSection.isNotEmpty) toolSection,
  ];
  return sections.join('\n\n');
}
