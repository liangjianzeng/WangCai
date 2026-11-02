/// 目标工具组（P1-A 无人值守续跑）+ 计划模式出口工具（exit_plan）。
///
/// - `goal_set`：模型把长任务声明为持久目标（驱动器据此在回合结束后
///   自动续跑，直到 goal_complete 或轮数耗尽）。
/// - `goal_complete`：目标完成（或确认无法完成）时终结目标。
/// - `exit_plan`（计划模式专用）：只读规划完成后请求用户批准；批准即
///   设定为目标并自动进入执行（goal 驱动器接管）。
library;

import '../tool_definition.dart';
import '../goal/goal_store.dart';

/// 目标工具组：goal_set / goal_complete / goal_cancel。
List<ToolDefinition> createGoalTools({
  required GoalStore store,
  required String conversationId,
  required int maxRounds,
  void Function(String planCardText)? onPlanChanged,
}) =>
    [
      ToolDefinition(
        name: 'goal_set',
        description:
            '把当前长任务声明为持久目标（无人值守续跑）。设定后每个回合结束时，'
            '若目标未完成会自动开新回合继续推进（上限 $maxRounds 轮），'
            '直到你调用 goal_complete。适用于需要多回合才能完成的任务；'
            '单回合可完成的简单任务不要用。',
        parameters: {
          'type': 'object',
          'properties': {
            'goal': {
              'type': 'string',
              'description': '目标描述（完成的判定标准要具体）'
            },
          },
          'required': ['goal'],
        },
        execute: (args) async {
          final text = (args['goal'] as String?)?.trim() ?? '';
          if (text.isEmpty) return ToolResult.error('goal 不能为空');
          final g = await store.setGoal(conversationId,
              goalText: text, maxRounds: maxRounds, origin: 'user');
          onPlanChanged?.call(g.planCardText());
          return ToolResult(
              content: '目标已设定（无人值守续跑，上限 ${g.maxRounds} 轮）：\n'
                  '${g.goal}\n'
                  '每回合结束若未调用 goal_complete，将自动继续推进。');
        },
      ),
      ToolDefinition(
        name: 'goal_complete',
        description:
            '宣告当前目标完成（或确认无法完成，用 note 说明原因）。'
            '调用后不再自动续跑。目标完成前不要调用。',
        parameters: {
          'type': 'object',
          'properties': {
            'summary': {
              'type': 'string',
              'description': '完成情况说明（做了什么、结果如何）'
            },
          },
          'required': ['summary'],
        },
        execute: (args) async {
          final summary = (args['summary'] as String?)?.trim() ?? '';
          final finished = await store.finish(conversationId, GoalStatus.done);
          if (finished == null) {
            return ToolResult.error('当前没有活跃目标');
          }
          onPlanChanged
              ?.call(finished.copyWith(status: GoalStatus.done).planCardText());
          return ToolResult(
              content: '目标已标记完成：${summary.isEmpty ? finished.goal : summary}');
        },
      ),
      ToolDefinition(
        name: 'goal_cancel',
        description: '取消当前目标（不再自动续跑）。仅在用户明确要求放弃时使用。',
        parameters: {
          'type': 'object',
          'properties': {
            'reason': {'type': 'string', 'description': '取消原因'},
          },
          'required': ['reason'],
        },
        execute: (args) async {
          final finished = await store.finish(
              conversationId, GoalStatus.cancelled);
          if (finished == null) return ToolResult.error('当前没有活跃目标');
          onPlanChanged?.call(
              finished.copyWith(status: GoalStatus.cancelled).planCardText());
          return ToolResult(content: '目标已取消：${finished.goal}');
        },
      ),
    ];

/// 计划模式出口工具：请求用户批准计划。批准 → 目标落库（origin=plan），
/// 驱动器自动接管执行；拒绝/修改 → 返回用户意见，模型修订后再请求。
ToolDefinition createExitPlanTool({
  required GoalStore store,
  required String conversationId,
  required int maxRounds,
  required Future<String?> Function(String question, List<String> options)
      ask,
  void Function(String planCardText)? onPlanChanged,
}) =>
    ToolDefinition(
      isConcurrencySafe: (_) => false, // 阻塞等待用户，独占执行
      name: 'exit_plan',
      description:
          '计划模式专用：规划完成后，把完整执行计划提交用户审批。'
          'plan = 完整计划文本（目标/步骤/每步验证方式/风险）；'
          'steps = 结构化步骤数组（title 必填、detail/verify 选填）——提供 steps 后'
          '用户可在计划面板看到步骤级进度，执行中每完成/开始一步调用 '
          'plan_step_update 更新状态。'
          '用户批准后自动开始执行（无人值守续跑）；被拒绝时按意见修订后可再次提交。',
      parameters: {
        'type': 'object',
        'properties': {
          'plan': {
            'type': 'string',
            'description': '完整执行计划（目标/步骤/验证/风险）'
          },
          'title': {
            'type': 'string',
            'description': '计划短标题（≤20 字，省略取 plan 开头）'
          },
          'steps': {
            'type': 'array',
            'items': {
              'type': 'object',
              'properties': {
                'title': {'type': 'string', 'description': '步骤名'},
                'detail': {'type': 'string', 'description': '要点'},
                'verify': {'type': 'string', 'description': '完成标准/验证方式'},
              },
              'required': ['title'],
            },
            'description': '结构化步骤（推荐；计划面板按此显示进度）'
          },
        },
        'required': ['plan'],
      },
      execute: (args) async {
        final plan = (args['plan'] as String?)?.trim() ?? '';
        if (plan.isEmpty) return ToolResult.error('plan 不能为空');
        final answer = await ask(
          '智能体提交了执行计划，是否批准并开始执行？\n\n$plan',
          ['批准执行', '不批准（回复修改意见）'],
        );
        if (answer == null) {
          return ToolResult.error('用户未回应审批请求，计划未批准。'
              '请总结计划要点后结束本轮，等待用户指示。');
        }
        // 精确匹配批准选项；「不批准（…）」含"批准"字样，必须先排除。
        final approved = answer.contains('批准执行') &&
            !answer.contains('不批准');
        if (approved) {
          final steps = <PlanStep>[];
          final rawSteps = args['steps'];
          if (rawSteps is List) {
            for (final e in rawSteps) {
              if (e is Map) {
                final m = e.cast<String, dynamic>();
                final t = (m['title'] as String?)?.trim() ?? '';
                if (t.isNotEmpty) {
                  steps.add(PlanStep(
                    title: t,
                    detail: (m['detail'] as String?)?.trim() ?? '',
                    verify: (m['verify'] as String?)?.trim() ?? '',
                  ));
                }
              }
            }
          }
          final title = (args['title'] as String?)?.trim() ?? '';
          final g = await store.setGoal(conversationId,
              goalText: plan,
              maxRounds: maxRounds,
              origin: 'plan',
              title: title.isEmpty ? null : title,
              steps: steps);
          onPlanChanged?.call(g.planCardText());
          final stepNote = steps.isEmpty
              ? ''
              : '（共 ${steps.length} 步；执行中每开始/完成一步调用 '
                  'plan_step_update 更新状态，用户在计划面板可见进度）';
          return ToolResult(content:
              '✅ 计划已获批准，并已设定为持久目标（无人值守执行，上限 $maxRounds 轮）'
              '$stepNote。请用一两句话向用户确认即将开始执行，然后结束本轮回答；'
              '系统会自动开启执行回合。');
        }
        return ToolResult(
            content: '❌ 用户未批准计划，意见：$answer\n'
                '请根据意见修订计划，可再次调用 exit_plan 提交。');
      },
    );

/// 计划步骤状态更新工具（计划实体化；命名 plan_step_update 以避开 Dev 档
/// plan_update——两者共存于开发模式+API 档的注册表）：执行中每完成/开始一步调用，
/// 用户在计划面板与对话内计划卡实时看到进度。步骤序号 1-based。
ToolDefinition createPlanStepUpdateTool({
  required GoalStore store,
  required String conversationId,
  void Function(String planCardText)? onPlanChanged,
}) =>
    ToolDefinition(
      name: 'plan_step_update',
      description:
          '更新当前计划的步骤状态（与 Dev 档 plan_update 不同，这个只改步骤状态）。'
          '每开始一步（status=running）和完成一步'
          '（status=done）都要调用；某步确认失败用 failed 并说明原因。'
          '没有活跃计划时返回错误——那种情况直接干活即可。',
      parameters: {
        'type': 'object',
        'properties': {
          'step_index': {
            'type': 'integer',
            'description': '步骤序号（从 1 起，与计划面板编号一致）'
          },
          'status': {
            'type': 'string',
            'enum': ['pending', 'running', 'done', 'failed'],
            'description': '新状态',
          },
          'note': {
            'type': 'string',
            'description': '可选：一句话说明（做了什么/为何失败）'
          },
        },
        'required': ['step_index', 'status'],
      },
      execute: (args) async {
        final idx = (args['step_index'] as num?)?.toInt() ?? 0;
        final statusName = args['status'] as String? ?? '';
        final PlanStepStatus status;
        try {
          status = PlanStepStatus.values.byName(statusName);
        } on ArgumentError {
          return ToolResult.error('status 只能是 pending/running/done/failed');
        }
        final err = await store.updateStep(conversationId,
            stepIndex: idx, status: status);
        if (err != null) return ToolResult.error(err);
        final g = await store.load(conversationId);
        if (g != null) onPlanChanged?.call(g.planCardText());
        final note = (args['note'] as String?)?.trim() ?? '';
        return ToolResult(
            content: '步骤 $idx 已置 ${status.name}'
                '${note.isEmpty ? '' : '：$note'}\n'
                '${g?.progressText() ?? ''}');
      },
    );
