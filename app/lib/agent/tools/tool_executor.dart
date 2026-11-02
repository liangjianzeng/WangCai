/// 工具执行器（Phase 1）—— 封装「校验 + 审批 + 执行 + 超时」。
///
/// 对照 DSH 六段流水线（Part 6）的 execute/guards 段。Phase 2 会用
/// [lib/agent/tools/pipeline.dart] 的六段流水线（pre-execute → guards →
/// execute → projectContent → post-execute → finalizeContent）替代/包装本类，
/// 但本类提供共享的执行语义（必填校验、沙箱审批、超时、错误回填），
/// 新 loop 与旧 runAgent 共用，避免行为漂移。
library;

import '../dev/workspace.dart' show kWorkspaceIdArgKey;
import '../sandbox.dart';
import '../tool_definition.dart';
import '../tool_registry.dart';

/// 执行单个工具：未知工具 / 执行异常均回填可读错误并继续（fail-open 于模型）。
final class ToolExecutor {
  final ToolRegistry registry;
  final String modelId;
  final Duration timeout;
  final AgentSandboxApprover? sandboxApprover;

  /// 当前激活工作区 id 解析器（Dev Agent）：null = 不注入（默认工作区，
  /// 旧行为零回归）。返回 null/空 → 不注入 `_workspaceId` 键。
  final Future<String?> Function()? workspaceResolver;

  const ToolExecutor({
    required this.registry,
    required this.modelId,
    required this.timeout,
    this.sandboxApprover,
    this.workspaceResolver,
  });

  /// 执行一个工具调用；返回 [ToolResult]（失败时 [isError]=true，content 为可读原因）。
  Future<ToolResult> execute(ToolCall call) async {
    // 1. 查工具（按模型过滤）。
    ToolDefinition? tool;
    try {
      tool = registry.lookup(call.name, modelId: modelId);
    } catch (e) {
      return ToolResult.error('工具查找失败: $e');
    }
    if (tool == null) {
      return ToolResult.error('未知工具 "${call.name}"（当前模型不可用）');
    }

    final rawArgs = call.arguments ?? const <String, dynamic>{};

    // 2. 执行前统一必填校验（对照 DSH validateArgs）：缺参数时给出明确引导，
    //    回填给模型补全参数后重试，而不是直接执行失败。
    final violations = validateRequiredArguments(rawArgs, tool.parameters);
    if (violations.isNotEmpty) {
      return ToolResult.error(
          '工具 "${call.name}" 参数不完整：${violations.join('；')}。请补全参数后重试');
    }

    // 3. 沙箱升级审批（对照 DSH approveEscalation）：解析并校验升级请求，
    //    执行前经用户确认通道；批准后本次调用以完整模式执行。
    final Map<String, dynamic> args;
    try {
      final escalation = extractEscalation(rawArgs);
      if (escalation != null) {
        if (!escalation.isStrictlyWider) {
          return ToolResult.error(
              '沙箱升级到 "${escalation.requestedMode.value}" 并不比当前模式更宽');
        }
        final approver = sandboxApprover;
        if (approver == null) {
          return ToolResult.error(
              '沙箱升级需要审批通道，但当前未注入（接入层未提供审批）');
        }
        final granted = await approver(escalation, call.name);
        if (!granted) {
          return ToolResult.error(
              '用户拒绝了沙箱升级到 "${escalation.requestedMode.value}"');
        }
      }
      // 剔除升级参数，把生效模式以内部键传给工具执行体。
      args = <String, dynamic>{...rawArgs}
        ..remove('sandbox_permissions')
        ..remove('justification');
      if (escalation != null) {
        args[kSandboxModeArgKey] = escalation.requestedMode.value;
      }
    } on FormatException catch (e) {
      return ToolResult.error('工具 "${call.name}" 沙箱升级参数无效：${e.message}');
    }

    // 3.5 工作区注入（Dev Agent）：把当前激活工作区 id 以内部键传给工具
    //     执行体（对齐 `_sandboxMode` 模式；模型不感知）。
    final resolver = workspaceResolver;
    if (resolver != null) {
      try {
        final wsId = await resolver();
        if (wsId != null && wsId.isNotEmpty) {
          args[kWorkspaceIdArgKey] = wsId;
        }
      } catch (_) {
        // 解析失败不阻断执行（默认工作区兜底）。
      }
    }

    // 4. 执行 + 超时 + 三层错误防护。
    //
    // 工具自己声明的 timeout 优先于全局 toolTimeout：联网搜索这类网络工具需要
    // 30s 预算，而全局默认是 15s。此前 ToolDefinition.timeout 从未被消费，
    // 所有工具都被一刀切（web_search 实测要 20s+，必然报"执行超时"）。
    final effectiveTimeout = tool.timeout ?? timeout;
    Future<ToolResult> future;
    try {
      future = tool.execute(args);
    } catch (e) {
      // execute 同步抛错（非 async 实现）。
      return ToolResult.error('工具 "${call.name}" 执行失败: $e');
    }
    try {
      return await future
          .then((value) => value,
              onError: (Object e, StackTrace st) =>
                  ToolResult.error('工具 "${call.name}" 执行失败: $e'))
          .timeout(effectiveTimeout,
              onTimeout: () => ToolResult.error(
                  '工具 "${call.name}" 执行超时（${effectiveTimeout.inSeconds}s）'));
    } catch (e) {
      // timeout 阶段的错误兜底。
      return ToolResult.error('工具 "${call.name}" 执行失败: $e');
    }
  }
}