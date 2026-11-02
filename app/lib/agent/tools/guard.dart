/// 工具防护（Phase 2）—— 对照 DSH `ctx.tools.guard()` 的单调 deny。
///
/// guard 只能 **deny**（never force-allow）或 abstain（放弃判断）。
/// 单调 deny：任一个 guard 返回 deny 即否决执行，不继续后续 guard。
library;

import '../tool_definition.dart';

/// guard 决策（单调 deny）。
enum GuardDecisionKind {
  deny,    // 否决执行（reason 为模型可见原因）
  abstain, // 本 guard 不判断
}

final class GuardDecision {
  final GuardDecisionKind kind;
  final String? reason;
  const GuardDecision(this.kind, {this.reason});

  static GuardDecision abstain() =>
      const GuardDecision(GuardDecisionKind.abstain);

  static GuardDecision deny(String reason) =>
      GuardDecision(GuardDecisionKind.deny, reason: reason);

  bool get isDeny => kind == GuardDecisionKind.deny;
}

/// 单次 guard 判断（纯同步，不阻塞）。
typedef ToolGuard = GuardDecision Function(ToolCall call,
    Map<String, dynamic> args);

/// 模型缓存保护 guard（AGENTS.md 铁律：卸载会清掉已下载模型缓存）。
/// 对照 DSH 模型缓存保护 guard（§6.5）。
final ToolGuard modelCacheGuard = (ToolCall call, Map<String, dynamic> args) {
  final cmd = (args['command'] as String? ?? '').toLowerCase();
  if (call.name == 'shell_exec' && cmd.contains('model_cache')) {
    return GuardDecision.deny(
        '模型缓存目录受保护。删除模型请用 model_manager，不要用 shell 直接 rm。');
  }
  if (call.name == 'shell_exec' && cmd.contains('models/')) {
    return GuardDecision.deny('模型目录受保护。删除模型请用 model_manager。');
  }
  final path = (args['path'] as String? ?? '').toLowerCase();
  if ((call.name == 'write_file' || call.name == 'edit_file') &&
      path.contains('/model_cache/')) {
    return GuardDecision.deny('模型缓存目录受保护，禁止直接读写。');
  }
  return GuardDecision.abstain();
};
