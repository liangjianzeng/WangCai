/// 工具六段流水线（Phase 2）—— 对照 DSH Part 6。
///
/// 端侧语义（§6.1）：
///   1. pre-execute（waterfall）：allow / deny / ask（可否执行，不改参数）
///   2. guards（单调 deny）：只 deny / abstain
///   3. execute：委托 [ToolExecutor]（lookup + 必填校验 + 沙箱审批 + 执行 + 超时）
///   4. projectContent：合并入 finalize（展示格式）
///   5. post-execute：accept / block / replace（可改最终内容）
///   6. finalizeContent：合并入 finalize（spill + 落盘 meta）
///
/// 端侧简化：段 4/6 合并为"结果落盘"（spill + meta）；段 5 为 post-execute。
library;

import 'dart:async';

import '../context_eng/spill.dart';
import '../session/log.dart';
import '../tool_definition.dart';
import 'guard.dart';
import 'tool_executor.dart';

/// 流水线 pre-execute 决策。
enum ToolPreExecuteDecision {
  allow,
  deny,
  ask,
}

/// pre-execute 监听器（waterfall，顺序执行；首个非 allow 即终止）。
typedef ToolPreExecuteListener =
    Future<ToolPreExecuteDecision> Function(ToolCall call, Map<String, dynamic> args);

/// pre-execute `ask` 时的审批通道（fail-closed：无 approver 视为拒绝）。
typedef ToolPreExecuteApprover = Future<bool> Function(ToolCall call);

/// post-execute 监听器（accept / block / replace；返回替换后的 [ToolResult]）。
typedef PostExecuteListener =
    ToolResult Function(ToolCall call, ToolResult result);

/// 六段流水线。
final class ToolPipeline {
  /// 执行核心（stage 3）；内含 [ToolRegistry]（lookup/过滤）与执行语义。
  final ToolExecutor executor;
  final List<ToolPreExecuteListener>? preListeners;
  final ToolPreExecuteApprover? preApprover;
  final List<ToolGuard>? guards;
  final List<PostExecuteListener>? postListeners;
  /// 溢写（stage 6 合并）；sessionLog 供追加 spill/locate。
  final Spill? spill;
  final SessionLog? sessionLog;

  ToolPipeline({
    required this.executor,
    this.preListeners,
    this.preApprover,
    this.guards,
    this.postListeners,
    this.spill,
    this.sessionLog,
  });

  /// 执行单个工具调用（完整六段）。
  Future<ToolResult> execute(ToolCall call, String modelId) async {
    final args = call.arguments ?? const <String, dynamic>{};
    final preListeners = this.preListeners ?? const <ToolPreExecuteListener>[];
    final guards = this.guards ?? const <ToolGuard>[];
    final postListeners = this.postListeners ?? const <PostExecuteListener>[];

    // ---- 1. pre-execute（waterfall）----
    for (final listener in preListeners) {
      final decision = await listener.call(call, args);
      switch (decision) {
        case ToolPreExecuteDecision.deny:
          return ToolResult.error('工具 "${call.name}" 被 pre-execute 拦截');
        case ToolPreExecuteDecision.ask:
          final approved = await (preApprover?.call(call) ??
              Future<bool>.value(false));
          if (!approved) {
            return ToolResult.error('工具 "${call.name}" 需要审批但被拒绝');
          }
          break;
        default:
          break;
      }
    }

    // ---- 2. guards（单调 deny）----
    for (final guard in guards) {
      final gd = guard.call(call, args);
      if (gd.isDeny) {
        return ToolResult.error(gd.reason ?? '工具 "${call.name}" 被 guard 拦截');
      }
    }

    // ---- 3. execute（委托 ToolExecutor）----
    var result = await executor.execute(call);

    // ---- 5. post-execute（accept / block / replace）----
    for (final pl in postListeners) {
      result = pl.call(call, result);
    }

    // ---- 6. finalizeContent（spill + 落盘 meta）----
    final session = this.sessionLog;
    if (spill != null && session != null) {
      final decision = await spill!.decide(session, call, result);
      result = ToolResult(
        content: decision.contentForModel(result.content),
        isError: result.isError,
      );
    }

    return result;
  }
}
