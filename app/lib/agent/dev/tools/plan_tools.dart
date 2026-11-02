/// 开发计划工具（Dev Agent Phase C）—— 跨回合的结构化步骤计划。
///
/// 与 todo（回合内即时清单）区分：plan 持久化绑定到 DevTask，
/// 状态机推进（进行中步骤 → done），DevContext 注入摘要。
/// 全部经 [DevStore] 读写，无 SSH 依赖。
library;

import '../../tool_definition.dart';
import '../task.dart';
import '../workspace.dart';
import '../workspace_store.dart';

/// 从任务列表找任务；不存在返回 null。
Future<DevTask?> _findTask(DevStore store, String taskId) async {
  final tasks = await store.loadTasks();
  return tasks.where((t) => t.id == taskId).firstOrNull;
}

/// 任务是否属于工作区：默认工作区（default/null）收编无主任务，
/// 非默认工作区按 workspaceId 精确匹配。
bool taskBelongsToWorkspace(DevTask task, String? workspaceId) {
  if (workspaceId == null ||
      workspaceId.isEmpty ||
      workspaceId == DevWorkspace.kDefaultId) {
    final wid = task.workspaceId;
    return wid == null || wid.isEmpty || wid == DevWorkspace.kDefaultId;
  }
  return task.workspaceId == workspaceId;
}

/// 新任务 id（可读 + 唯一）。
String newDevTaskId() => 'task_${DateTime.now().millisecondsSinceEpoch}';

/// 解析步骤数组参数（[{title, detail?, verify?}]）；非法条目丢弃。
List<DevPlanStep> _parseSteps(List<dynamic> raw, {bool? done}) {
  final out = <DevPlanStep>[];
  for (final item in raw) {
    if (item is! Map<String, dynamic>) continue;
    final title = (item['title'] as String?)?.trim();
    if (title == null || title.isEmpty) continue;
    out.add(DevPlanStep(
      id: 's${out.length + 1}',
      title: title,
      detail: (item['detail'] as String?)?.trim() ?? '',
      verify: (item['verify'] as String?)?.trim(),
      done: done ?? (item['done'] as bool?) ?? false,
    ));
  }
  return out;
}

/// 创建开发任务（可选一步建计划）。参数：`title`（必填）、
/// `workspace_id`（可选，省略 = 当前激活工作区）、`steps`（可选步骤数组）。
ToolDefinition createTaskCreateTool({DevStore? store}) {
  return ToolDefinition(
    isConcurrencySafe: (_) => false, // 副作用工具：独占执行（P2-A）
    name: 'task_create',
    description:
        '创建开发任务（规划的载体），返回 task_id（后续 plan_update/plan_list 用）。'
        '可带 steps 数组一步建立计划，步骤格式 {"title": 标题, "detail": 要点, "verify": 完成标准}。'
        'workspace_id 省略时绑定当前工作区。',
    parameters: {
      'type': 'object',
      'properties': {
        'title': {'type': 'string', 'description': '任务标题（一句话说清要做什么）'},
        'workspace_id': {
          'type': 'string',
          'description': '所属工作区 id（省略 = 当前工作区）',
        },
        'steps': {
          'type': 'array',
          'description': '可选：有序步骤列表（一步建立计划）',
          'items': {
            'type': 'object',
            'properties': {
              'title': {'type': 'string', 'description': '步骤标题'},
              'detail': {'type': 'string', 'description': '实施要点'},
              'verify': {'type': 'string', 'description': '完成标准'},
            },
            'required': ['title'],
          },
        },
      },
      'required': ['title'],
    },
    timeout: const Duration(seconds: 10),
    execute: (args) async {
      final title = (args['title'] as String?)?.trim() ?? '';
      if (title.isEmpty) return ToolResult.error('缺少 title 参数');
      final s = store ?? DevStore();
      // 工作区归属：显式 workspace_id 校验存在；省略 = 注入的当前工作区。
      final injected = effectiveWorkspaceOf(args);
      var workspaceId = (args['workspace_id'] as String?)?.trim() ?? '';
      if (workspaceId.isNotEmpty && workspaceId != DevWorkspace.kDefaultId) {
        final workspaces = await s.loadWorkspaces();
        if (!workspaces.any((w) => w.id == workspaceId)) {
          return ToolResult.error('工作区不存在：$workspaceId（用 task_list 或工作区上下文里的 id）');
        }
      } else {
        workspaceId =
            (injected != null && injected != DevWorkspace.kDefaultId)
                ? injected
                : '';
      }
      final steps = _parseSteps(args['steps'] as List? ?? const []);
      final task = DevTask(
        id: newDevTaskId(),
        title: title,
        workspaceId: workspaceId.isEmpty ? null : workspaceId,
        status:
            steps.isEmpty ? DevTaskStatus.planning : DevTaskStatus.implementing,
        plan: steps.isEmpty ? null : DevPlan(steps: steps, currentStep: 0),
        createdAt: DateTime.now(),
        updatedAt: DateTime.now(),
      );
      await s.saveTask(task);
      final wsSuffix = workspaceId.isEmpty ? '' : '，工作区 $workspaceId';
      return ToolResult(
        content: steps.isEmpty
            ? '任务已创建：${task.id}「$title」$wsSuffix。'
                '用 plan_create 为它建立执行计划。'
            : '任务已创建：${task.id}「$title」$wsSuffix，'
                '计划 ${steps.length} 步，当前第 1 步：${steps.first.title}。',
      );
    },
  );
}

/// 列出当前工作区的开发任务（id/标题/状态/进度）。
ToolDefinition createTaskListTool({DevStore? store}) {
  return ToolDefinition(
    name: 'task_list',
    description:
        '列出当前工作区的开发任务：task_id、标题、状态与计划进度。'
        '用于找回已有任务的 task_id。',
    parameters: {
      'type': 'object',
      'properties': {
        'workspace_id': {
          'type': 'string',
          'description': '按工作区过滤（省略 = 当前工作区）',
        },
      },
    },
    timeout: const Duration(seconds: 10),
    execute: (args) async {
      final s = store ?? DevStore();
      final injected = effectiveWorkspaceOf(args);
      var wsId = (args['workspace_id'] as String?)?.trim() ?? '';
      if (wsId.isEmpty) wsId = injected ?? '';
      final tasks = await s.loadTasks();
      final shown = wsId.isEmpty
          ? tasks
          : tasks.where((t) => taskBelongsToWorkspace(t, wsId)).toList();
      if (shown.isEmpty) {
        return ToolResult(content: '当前工作区还没有任务。用 task_create 创建。');
      }
      shown.sort((a, b) => b.updatedAt.compareTo(a.updatedAt));
      const statusNames = {
        DevTaskStatus.planning: '规划中',
        DevTaskStatus.implementing: '实施中',
        DevTaskStatus.verifying: '验证中',
        DevTaskStatus.done: '已完成',
        DevTaskStatus.blocked: '受阻',
      };
      final lines = [
        for (final t in shown)
          '${t.id} 「${t.title}」 ${statusNames[t.status]}'
              '${t.plan != null && t.plan!.steps.isNotEmpty
                  ? ' 进度 ${t.plan!.steps.where((s) => s.done).length}/${t.plan!.steps.length}'
                  : ''}',
      ];
      return ToolResult(content: lines.join('\n'));
    },
  );
}

/// 创建/替换任务的计划。参数：`task_id`（必填）、`steps`（步骤数组）、
/// `title`/`workspace_id`（可选——task_id 不存在时自动创建任务并绑定）。
ToolDefinition createPlanCreateTool({DevStore? store}) {
  return ToolDefinition(
    isConcurrencySafe: (_) => false, // 副作用工具：独占执行（P2-A）
    name: 'plan_create',
    description:
        '为开发任务创建/替换结构化执行计划：有序步骤 + 每步完成标准（verify）。'
        'task_id 为当前任务 id（来自工作区上下文或 task_create 返回值）；'
        '任务不存在时自动创建（title 为任务标题，缺省用第一步标题）。'
        '步骤：{"title": 步骤标题, "detail": 实施要点, "verify": 完成标准}。',
    parameters: {
      'type': 'object',
      'properties': {
        'task_id': {'type': 'string', 'description': '开发任务 id'},
        'steps': {
          'type': 'array',
          'description': '有序步骤列表',
          'items': {
            'type': 'object',
            'properties': {
              'title': {'type': 'string', 'description': '步骤标题'},
              'detail': {'type': 'string', 'description': '实施要点'},
              'verify': {'type': 'string', 'description': '完成标准'},
            },
            'required': ['title'],
          },
        },
        'title': {
          'type': 'string',
          'description': '可选：任务不存在时自动创建任务的标题',
        },
        'workspace_id': {
          'type': 'string',
          'description': '可选：自动创建任务时绑定的工作区（缺省 = 当前工作区）',
        },
      },
      'required': ['task_id', 'steps'],
    },
    timeout: const Duration(seconds: 10),
    execute: (args) async {
      final taskId = (args['task_id'] as String?)?.trim() ?? '';
      final rawSteps = args['steps'] as List? ?? const [];
      if (taskId.isEmpty) return ToolResult.error('缺少 task_id 参数');
      final steps = _parseSteps(rawSteps);
      if (steps.isEmpty) return ToolResult.error('steps 为空或格式非法');
      final s = DevStore.resolve(store);
      var task = await _findTask(s, taskId);
      var createdNote = '';
      if (task == null) {
        // 自动建任务（DSH 薄护栏：模型给个描述性 id 即可起步，不必两次调用）。
        final injected = effectiveWorkspaceOf(args);
        var wsId = (args['workspace_id'] as String?)?.trim() ?? '';
        if (wsId.isNotEmpty && wsId != DevWorkspace.kDefaultId) {
          final workspaces = await s.loadWorkspaces();
          if (!workspaces.any((w) => w.id == wsId)) {
            return ToolResult.error('工作区不存在：$wsId');
          }
        } else {
          wsId = (injected != null && injected != DevWorkspace.kDefaultId)
              ? injected
              : '';
        }
        task = DevTask(
          id: taskId,
          title: (args['title'] as String?)?.trim().isNotEmpty == true
              ? (args['title'] as String).trim()
              : steps.first.title,
          workspaceId: wsId.isEmpty ? null : wsId,
          status: DevTaskStatus.planning,
          createdAt: DateTime.now(),
          updatedAt: DateTime.now(),
        );
        createdNote = '（任务 ${task.id} 已自动创建'
            '${wsId.isEmpty ? '' : '，工作区 $wsId'}）';
      }
      final updated = task.copyWith(
        plan: DevPlan(steps: steps, currentStep: 0),
        status: DevTaskStatus.implementing,
        updatedAt: DateTime.now(),
      );
      await s.saveTask(updated);
      return ToolResult(
        content: '计划已建立$createdNote（${steps.length} 步），当前第 1 步：'
            '${steps.first.title}'
            '${steps.first.verify != null ? '（完成标准：${steps.first.verify}）' : ''}',
      );
    },
  );
}

/// 更新计划。参数：`task_id`、`action`（mark_done | add_step）。
ToolDefinition createPlanUpdateTool({DevStore? store}) {
  return ToolDefinition(
    isConcurrencySafe: (_) => false, // 副作用工具：独占执行（P2-A）
    name: 'plan_update',
    description:
        '更新开发任务的计划状态：'
        'mark_done（step_id 标记完成，自动推进下一步）；'
        'add_step（追加步骤）。task_id 为当前任务 id。',
    parameters: {
      'type': 'object',
      'properties': {
        'task_id': {'type': 'string', 'description': '开发任务 id'},
        'action': {
          'type': 'string',
          'enum': ['mark_done', 'add_step'],
          'description': 'mark_done 标记步骤完成；add_step 追加步骤',
        },
        'step_id': {'type': 'string', 'description': '目标步骤 id（mark_done 用）'},
        'done': {'type': 'boolean', 'description': 'mark_done 是否完成（默认 true）'},
        'step': {
          'type': 'object',
          'description': '新步骤（add_step 用）：{title, detail?, verify?}',
          'properties': {
            'title': {'type': 'string'},
            'detail': {'type': 'string'},
            'verify': {'type': 'string'},
          },
        },
      },
      'required': ['task_id', 'action'],
    },
    timeout: const Duration(seconds: 10),
    execute: (args) async {
      final taskId = (args['task_id'] as String?)?.trim() ?? '';
      final action = (args['action'] as String?)?.trim() ?? '';
      if (taskId.isEmpty) return ToolResult.error('缺少 task_id 参数');
      final s = DevStore.resolve(store);
      final task = await _findTask(s, taskId);
      if (task == null) return ToolResult.error('任务不存在：$taskId');
      final plan = task.plan;
      if (plan == null) return ToolResult.error('任务还没有计划，先调用 plan_create');

      switch (action) {
        case 'mark_done':
          final stepId = (args['step_id'] as String?)?.trim() ?? '';
          if (stepId.isEmpty) return ToolResult.error('缺少 step_id 参数');
          final done = (args['done'] as bool?) ?? true;
          final idx = plan.steps.indexWhere((s) => s.id == stepId);
          if (idx < 0) return ToolResult.error('步骤不存在：$stepId');
          final steps = [
            for (var i = 0; i < plan.steps.length; i++)
              i == idx ? plan.steps[i].copyWith(done: done) : plan.steps[i],
          ];
          final updatedPlan = DevPlan(steps: steps, currentStep: plan.nextPendingIndex);
          final status = updatedPlan.allDone
              ? DevTaskStatus.verifying
              : task.status == DevTaskStatus.planning
                  ? DevTaskStatus.implementing
                  : task.status;
          final updated = task.copyWith(
            plan: updatedPlan,
            status: status,
            updatedAt: DateTime.now(),
          );
          await s.saveTask(updated);
          if (done) {
            final next = updatedPlan.steps
                .where((s) => !s.done)
                .firstOrNull;
            return ToolResult(
              content: updatedPlan.allDone
                  ? '全部 ${steps.length} 步已完成，进入验证阶段'
                  : '已完成：${plan.steps[idx].title}。'
                      '下一步：${next?.title ?? ''}'
                      '${next?.verify != null ? '（完成标准：${next!.verify}）' : ''}',
            );
          }
          return ToolResult(content: '已取消完成：${plan.steps[idx].title}');
        case 'add_step':
          final rawStep = args['step'] as Map<String, dynamic>?;
          final title = (rawStep?['title'] as String?)?.trim() ?? '';
          if (title.isEmpty) return ToolResult.error('add_step 需要 step.title');
          final newStep = DevPlanStep(
            id: 's${plan.steps.length + 1}',
            title: title,
            detail: (rawStep?['detail'] as String?)?.trim() ?? '',
            verify: (rawStep?['verify'] as String?)?.trim(),
          );
          final updated = task.copyWith(
            plan: plan.copyWith(steps: [...plan.steps, newStep]),
            updatedAt: DateTime.now(),
          );
          await s.saveTask(updated);
          return ToolResult(content: '已追加步骤：$title（现在共 ${updated.plan!.steps.length} 步）');
        default:
          return ToolResult.error('未知 action：$action（支持 mark_done / add_step）');
      }
    },
  );
}

/// 列出任务计划。
ToolDefinition createPlanListTool({DevStore? store}) {
  return ToolDefinition(
    name: 'plan_list',
    description:
        '查看开发任务的执行计划：步骤列表、完成状态、当前进行步骤与完成标准。',
    parameters: {
      'type': 'object',
      'properties': {
        'task_id': {'type': 'string', 'description': '开发任务 id'},
      },
      'required': ['task_id'],
    },
    timeout: const Duration(seconds: 10),
    execute: (args) async {
      final taskId = (args['task_id'] as String?)?.trim() ?? '';
      if (taskId.isEmpty) return ToolResult.error('缺少 task_id 参数');
      final s = DevStore.resolve(store);
      final task = await _findTask(s, taskId);
      if (task == null) return ToolResult.error('任务不存在：$taskId');
      final plan = task.plan;
      if (plan == null) return ToolResult.error('任务还没有计划，先调用 plan_create');
      final lines = <String>[];
      for (var i = 0; i < plan.steps.length; i++) {
        final s = plan.steps[i];
        lines.add('${s.done ? '✅' : (i == plan.nextPendingIndex ? '▶ ' : '  ')} '
            '${s.id} ${s.title}'
            '${s.verify != null ? ' [完成标准: ${s.verify}]' : ''}');
      }
      final summary = plan.allDone
          ? '全部完成'
          : '当前进行：${plan.steps[plan.nextPendingIndex].title}';
      return ToolResult(content: '$summary\n${lines.join('\n')}');
    },
  );
}
