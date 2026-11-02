/// Dev 上下文构建器（Dev Agent）—— 系统提示注入段。
///
/// 分层注入（每层有 token 预算）：
/// - 工作区上下文（≤80 token）：项目名/后端/分支/当前任务一句话；
/// - 当前计划（≤120 token）：进行中步骤 + 已完成计数；
/// - 工作区记忆（≤80 token）：该 workspace 最近记忆摘要。
/// 全部可随配置关闭（开发模式关闭 = 零注入，零回归）。
library;

import 'dart:convert';
import 'dart:io';

import 'package:path/path.dart' as p;

import 'package:flutter/foundation.dart' show debugPrint;

import 'dev_workspace_actions.dart' show defaultRemoteProjectPathPlaceholder;
import 'workspace.dart';
import 'workspace_store.dart';

/// 注入段的字符预算（粗略：中文按字符计，比 token 保守）。
const int kDevWorkspaceChars = 160; // ~80 token
const int kDevPlanChars = 240; // ~120 token
const int kDevMemoryChars = 160; // ~80 token

/// 加载工作区（含默认）。
Future<DevWorkspace?> _loadWorkspace(String? workspaceId,
    {DevStore? store}) async {
  if (workspaceId == null || workspaceId == DevWorkspace.kDefaultId) {
    return DevWorkspace.defaultWorkspace;
  }
  final s = DevStore.resolve(store);
  final workspaces = await s.loadWorkspaces();
  return workspaces.where((w) => w.id == workspaceId).firstOrNull;
}

/// 构建「工作区上下文」段。
Future<String> buildWorkspaceContextSection(
    {String? workspaceId, String? taskId, DevStore? store}) async {
  final ws = await _loadWorkspace(workspaceId, store: store);
  if (ws == null) return '';
  final backendName = switch (ws.backend) {
    WorkspaceBackend.localApp => '本地沙盒',
    WorkspaceBackend.embedded => '内嵌工具沙箱（本地执行）',
    WorkspaceBackend.termux => 'Termux（手机 Linux）',
    WorkspaceBackend.remotePc => '远程电脑',
  };
  final buf = StringBuffer('<workspace:context>\n');
  buf.write('当前工作区：「${ws.name}」（$backendName）');
  if (ws.isRemote) {
    final path = (ws.remotePath ?? '').trim();
    // 没填路径也要给模型一个明确落点：工具层首次使用时会自动建这个目录。
    // 以前这里直接省略路径 → 模型以为"没有工作区"而拒绝动手（真机表现 =
    // 连上远程电脑却只在手机上忙），现在必须看得见路径 + 「会自动创建」。
    buf.write(path.isEmpty
        ? '，远端路径 ${defaultRemoteProjectPathPlaceholder(ws.name)}'
            '（未指定，首次使用时自动创建，直接开始即可）'
        : '，远端路径 $path');
  }
  if (ws.currentBranch != null) {
    buf.write('，分支 ${ws.currentBranch}');
  }
  buf.write('\n');
  // 当前任务一句话。
  if (taskId != null && taskId.isNotEmpty) {
    try {
      final tasks = await (DevStore.resolve(store)).loadTasks();
      final task = tasks.where((t) => t.id == taskId).firstOrNull;
      if (task != null) {
        buf.write('当前任务：「${task.title}」（${task.status.name}）');
        buf.write('\n');
      }
    } catch (e) {
      debugPrint('[Dev] task load failed: $e');
    }
  }
  buf.write('文件/命令类工具作用域为当前工作区。');
  buf.write(switch (ws.backend) {
    WorkspaceBackend.termux || WorkspaceBackend.remotePc =>
      '远端工作区用 ssh_exec / ssh_read_file / ssh_write_file 操作'
          '（Termux 优先走 RUN_COMMAND 免 SSH 通道，自动回落 SSH）。',
    WorkspaceBackend.embedded =>
      '本地执行用 dev_shell / run_tests；git 用 git_* 工具（进程内，无需 git 命令）。',
    WorkspaceBackend.localApp =>
      '本地执行用 dev_shell / run_tests；git 用 git_* 工具（进程内）。',
  });
  buf.write('\n</workspace:context>');
  final text = buf.toString();
  return text.length <= kDevWorkspaceChars * 2 ? text : text;
}

/// 构建「当前计划」段。
Future<String> buildPlanSection(String? taskId, {DevStore? store}) async {
  if (taskId == null || taskId.isEmpty) return '';
  try {
    final tasks = await (DevStore.resolve(store)).loadTasks();
    final task = tasks.where((t) => t.id == taskId).firstOrNull;
    final plan = task?.plan;
    if (plan == null || plan.steps.isEmpty) return '';
    final buf = StringBuffer('<current-plan>\n');
    if (plan.allDone) {
      buf.write('计划全部完成，进入验证/收尾阶段。\n');
    } else {
      final next = plan.steps[plan.nextPendingIndex];
      buf.write('当前步骤：${next.title}');
      if (next.verify != null) {
        buf.write('（完成标准：${next.verify}）');
      }
      buf.write('\n已完成 ${plan.steps.where((s) => s.done).length}/${plan.steps.length}\n');
    }
    buf.write('</current-plan>');
    return buf.toString();
  } catch (e) {
    debugPrint('[Dev] plan load failed: $e');
    return '';
  }
}

/// 构建「工作区记忆」段（读 workspace 作用域 memory.json）。
Future<String> buildWorkspaceMemorySection(String? workspaceId,
    {DevStore? store}) async {
  if (workspaceId == null || workspaceId == DevWorkspace.kDefaultId) return '';
  try {
    final s = DevStore.resolve(store);
    // 读取 workspace 记忆文件（独立文件：workspace/projects/<id>/memory.json）。
    final docs = await s.workspaceLocalMirror(workspaceId);
    final file = File(p.join(docs, 'memory.json'));
    if (!await file.exists()) return '';
    final decoded = jsonDecode(await file.readAsString());
    if (decoded is! Map<String, dynamic>) return '';
    final entries = decoded.entries.map((e) => '${e.key}: ${e.value}').toList();
    if (entries.isEmpty) return '';
    final buf = StringBuffer('<workspace-memory>\n');
    for (final e in entries.take(4)) {
      buf.write('· ${e.substring(0, e.length > 60 ? 60 : e.length)}\n');
    }
    buf.write('</workspace-memory>');
    return buf.toString();
  } catch (e) {
    debugPrint('[Dev] memory load failed: $e');
    return '';
  }
}

/// Dev 工作循环指引（开发模式开启时注入，教模型按 Dev 循环走）。
const String kDevInstruction = '''
[开发工作循环]
你在进行开发任务时按以下顺序工作：
1. 先 git_status 确认当前仓库状态与分支；
2. 还没有任务/计划时，先 task_create 创建任务（可带 steps 一步建计划）；
   已有任务时用 task_list 找回 task_id，按 plan_list 看当前步骤，先完成当前步骤；
3. 改代码：read_file/ssh_read_file 看代码 → edit_file/write_file 或 ssh 写改；
4. 自查：git_diff 看改动是否合理；
5. 验证：run_tests 跑测试，失败就修再跑，直到通过；
6. 提交：git_commit（本地），需要推送时 git_push 并请求用户批准；
7. 更新计划：plan_update 标记步骤完成；
8. 最终回答：给出改动摘要、验证结果、提交信息。

[如实报告铁律]
- 工具返回 error 时，最终回答必须如实复述失败原因，禁止声称操作已成功；
- 未确认执行结果（工具未返回成功）时，不得编造"已创建/已提交/已验证"；
- SSH 相关错误带 [SSH] 前缀时，按提示重连或向用户说明，而不是跳过。
''';

/// 完整 Dev 注入文本（开发模式开启时调用；关闭返回空 = 零回归）。
Future<String> buildDevContext(
    {String? workspaceId,
    String? taskId,
    bool includeInstruction = true,
    DevStore? store}) async {
  final parts = <String>[];
  final wsSection = await buildWorkspaceContextSection(
      workspaceId: workspaceId, taskId: taskId, store: store);
  if (wsSection.isNotEmpty) parts.add(wsSection);
  final planSection = await buildPlanSection(taskId, store: store);
  if (planSection.isNotEmpty) parts.add(planSection);
  final memorySection =
      await buildWorkspaceMemorySection(workspaceId, store: store);
  if (memorySection.isNotEmpty) parts.add(memorySection);
  if (includeInstruction) parts.add(kDevInstruction.trim());
  return parts.join('\n\n');
}
