/// Agent Hooks（Phase 5）—— 对照 DSH Part 12.5。
///
/// 端侧简化：Dart 事件订阅。保留四类 hook：
/// - `agent/pre-step`：否决 step（返回 reject）
/// - `tools/pre-execute`：deny/ask（对应 [ToolPreExecuteListener]）
/// - `tools/post-execute`：观察/审计（对应 [PostExecuteListener]）
/// - `tools/result`：同步通知（read-only）
library;

import '../tool_definition.dart';

/// 步骤上下文（`agent/pre-step` 可用信息）。
final class PreStepContext {
  final int turn;
  final int step;
  final String modelId;
  final List<Map<String, dynamic>> history;
  const PreStepContext({
    required this.turn,
    required this.step,
    required this.modelId,
    required this.history,
  });
}

/// step 否决决策。
enum PreStepDecision {
  allow,
  reject,
}

/// step 否决结果（reject 时 [reason] 模型可见）。
final class PreStepDecisionResult {
  final PreStepDecision decision;
  final String? reason;
  const PreStepDecisionResult(this.decision, {this.reason});
  static const PreStepDecisionResult allow =
      PreStepDecisionResult(PreStepDecision.allow);
}

/// `agent/pre-step` 监听器（同步/异步均可，返回 reject 则否决本 step）。
typedef PreStepListener =
    Future<PreStepDecisionResult> Function(PreStepContext ctx);

/// `tools/result` 监听器（read-only 同步通知，无返回值影响主流程）。
typedef ToolResultListener = void Function(ToolCall call, ToolResult result);

/// Hook 事件总线（`ctx.on`）。注册后在对应节点同步触发。
final class AgentHooks {
  final List<PreStepListener> _preStepListeners;
  final List<ToolResultListener> _resultListeners;

  AgentHooks({List<PreStepListener>? preStep, List<ToolResultListener>? result})
      : _preStepListeners = List.from(preStep ?? const []),
        _resultListeners = List.from(result ?? const []);

  /// 注册 pre-step hook（可多次；首个 reject 即否决）。
  void onPreStep(PreStepListener listener) => _preStepListeners.add(listener);

  /// 注册 tools/result hook（read-only）。
  void onToolsResult(ToolResultListener listener) =>
      _resultListeners.add(listener);

  /// 执行 pre-step listeners；任一 reject 则返回 false（否决）。
  Future<bool> shouldProceed(PreStepContext ctx) async {
    for (final listener in _preStepListeners) {
      final result = await listener.call(ctx);
      if (result.decision == PreStepDecision.reject) return false;
    }
    return true;
  }

  /// 通知 result listeners（read-only；listener 异常不中断主流程）。
  void notifyResult(ToolCall call, ToolResult result) {
    for (final listener in _resultListeners) {
      try {
        listener.call(call, result);
      } catch (_) {
        // 忽略：read-only hook 异常不应影响工具执行。
      }
    }
  }

  int get preStepCount => _preStepListeners.length;
  int get resultCount => _resultListeners.length;
}
