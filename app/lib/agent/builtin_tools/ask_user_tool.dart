/// ask_user_question 工具（DSH tool-ask-user 语义）—— 模型在缺信息/需确认
/// 时向用户提问，回合暂停等待回答，答案作为工具结果回填继续执行。
///
/// 回答通道由接入层注入 [ask] 回调（chat_provider 挂接 UI 待回答卡片 +
/// 输入区），工具本体不依赖 Flutter。用户取消回合时接入层以错误完成
/// completer，工具如实回填「用户未回答」。
library;

import 'dart:async' show TimeoutException;

import '../tool_definition.dart';

/// 回答等待上限（10 分钟）：防止用户永不回答把回合挂死；
/// 超时按失败回填，模型应基于已有信息继续或如实说明被搁置。
const Duration kAskUserTimeout = Duration(minutes: 10);

/// 构造 ask_user_question 工具。
///
/// [ask]：弹出待回答卡片并等待用户作答；返回 null = 用户跳过/取消。
ToolDefinition createAskUserTool({
  required Future<String?> Function(String question, List<String> options) ask,
}) {
  return ToolDefinition(
    isConcurrencySafe: (_) => false, // 副作用工具：独占执行（P2-A）
    name: 'ask_user_question',
    description:
        '向用户提问以获取缺失信息或确认关键选择（回合会暂停等待用户回答）。'
        '仅在「不做假设就无法继续」时使用：问句要具体、一次只问一件事，'
        '能给出候选项就给 options（≤4 个）。能从上下文或工具结果合理推断'
        '的信息不要问，直接采用并说明假设。',
    parameters: {
      'type': 'object',
      'properties': {
        'question': {
          'type': 'string',
          'description': '要问用户的问题（具体、自包含）',
        },
        'options': {
          'type': 'array',
          'items': {'type': 'string'},
          'description': '候选项（可选，≤4 个；用户也可自由输入）',
        },
      },
      'required': ['question'],
    },
    // 提问挂起回合属预期行为，不受常规工具超时约束（比 toolTimeout 大）。
    timeout: kAskUserTimeout,
    execute: (args) async {
      final question = (args['question'] as String?)?.trim() ?? '';
      if (question.isEmpty) {
        return ToolResult.error('缺少 question 参数');
      }
      final options = [
        for (final o in (args['options'] as List?) ?? <dynamic>[])
          if (o != null && o.toString().trim().isNotEmpty)
            o.toString().trim(),
      ].take(4).toList();
      try {
        final answer = await ask(question, options).timeout(kAskUserTimeout);
        if (answer == null || answer.trim().isEmpty) {
          return ToolResult.error(
              '用户没有回答这个问题（跳过了）。请基于已有信息继续，'
              '或如实说明该信息缺失对结果的影响，不要再次询问同一问题。');
        }
        return ToolResult(content: '用户回答：${answer.trim()}');
      } on TimeoutException {
        return ToolResult.error(
            '等待用户回答超时（10 分钟）。请基于已有信息继续执行并给出结果，'
            '在回答中说明哪些决策是自行假设的。');
      }
    },
  );
}
