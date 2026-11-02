/// 子代理接缝（DSH Part 11）—— 多实现共存的能力契约。
///
/// 端侧简化：单一实现（in-process）+ 两种模式（spawn / fork）。
/// - **能力 seam**：`SubagentProvider` 抽象，`start` 返回 [SubagentRun]。
/// - **fork seed**：父会话日志中"到最后一个 `turn/end` 为止"的已完成前缀
///   （DSH Part 11.3），截断到该前缀避免拖入进行中的 turn。
/// - **审批恒 `never`**（DSH Part 7.11 不变量 10）：子代理不请求 UI 审批；
///   端侧落定为**自动拒绝沙箱升级**（子代理不可升 `danger-full-access`）。
/// - **深度 ≤ 2**（DSH Part 11.10 不变量 6）：`delegationDepth` 固定 2。
library;

import '../session/event.dart';
import '../session/log.dart';

/// 子代理能力快照（对照 DSH `SubagentCapabilities`）。端侧固定值。
final class SubagentCapabilities {
  /// 能否覆盖 provider/model/maxTokens（端侧：子代理用父模型，否）。
  final bool agentOptions;
  /// 能否要求结构化输出（端侧暂无，否）。
  final bool outputSchema;
  /// 能否限制委派深度（端侧：固定 2，是）。
  final bool depthLimit;
  /// 能否裁剪子代理工具集（端侧：继承父工具，否）。
  final bool toolFilter;
  /// 能否注入 per-child 人设（端侧暂无，否）。
  final bool persona;

  const SubagentCapabilities({
    this.agentOptions = false,
    this.outputSchema = false,
    this.depthLimit = true,
    this.toolFilter = false,
    this.persona = false,
  });
}

/// 子代理启动请求。[mode] 为 `spawn`（空白）或 `fork`（继承父上下文前缀）。
/// [depth]：调用方当前委派深度（0 = 顶层）。子代理 = depth + 1。
final class SubagentStartRequest {
  final String task;
  final String mode;
  final int depth;

  const SubagentStartRequest({
    required this.task,
    required this.mode,
    this.depth = 0,
  });
}

/// 子代理结果 → 工具结果映射（DSH `SubagentRun.result`）。
final class SubagentResult {
  /// 子代理最终回答（失败/中断时为最后一帧可见文本）。
  final String output;
  /// 是否失败（error / interrupted / max-tokens 为 true；completed 为 false）。
  final bool isError;
  /// 停止原因（`TurnEndReasonKind.name`）。
  final String? stopReason;
  /// 诊断（≤4096 字节，可选）。
  final String? diagnostic;

  const SubagentResult({
    required this.output,
    this.isError = false,
    this.stopReason,
    this.diagnostic,
  });

  factory SubagentResult.fromError(String msg) =>
      SubagentResult(output: msg, isError: true, stopReason: 'error');
}

/// 一次子代理运行的句柄。[result] 在子代理 turn 结束（或异常）时完成。
final class SubagentRun {
  final String id;
  final SessionLog session;
  final Future<SubagentResult> result;

  SubagentRun(this.id, this.session, this.result);

  /// 释放（子代理 session 可被 GC；端侧无持久化资源）。
  void dispose() {}
}

/// 子代理 provider 契约（DSH `SubagentProvider`）。
abstract class SubagentProvider {
  /// 名称：`spawn` 或 `fork`。
  final String name;
  final SubagentCapabilities capabilities;

  /// 仅 `fork` 为 true（继承父上下文）。
  final bool inheritsParentContext;

  const SubagentProvider({
    required this.name,
    required this.capabilities,
    this.inheritsParentContext = false,
  });

  /// 启动一次子代理；返回 [SubagentRun]。
  Future<SubagentRun> start(SubagentStartRequest request);

  /// 向已结束的子代理续轮（DSH `send_message`）：对 [id] 对应的子代理
  /// 会话追加一条用户消息并再跑一个 turn。子代理不存在/已回收时抛错。
  Future<SubagentResult> sendMessage(String id, String message);
}

/// 子代理启动时的最大委派深度（DSH Part 11.10 固定 2）。
const int kSubagentMaxDepth = 2;

/// 子代理委派超出深度上限。
final class SubagentMaxDepthExceeded {
  final int depth;
  final String message;
  SubagentMaxDepthExceeded(this.depth)
      : message = '子代理委派深度 $depth 超过上限 $kSubagentMaxDepth';

  @override
  String toString() => message;
}

/// fork seed 切法（DSH Part 11.3）：父会话中"到最后一个 `turn/end` 为止"的
/// 已完成前缀。无 `turn/end` 时返回空（fork 等价于 spawn）。
List<SessionEvent> completedTurnPrefix(SessionLog parent) {
  SessionEvent? lastEnd = null;
  for (var i = parent.rawEvents.length - 1; i >= 0; i--) {
    if (parent.rawEvents[i].type == kEventTurnEnd) {
      lastEnd = parent.rawEvents[i];
      break;
    }
  }
  if (lastEnd == null) return const [];
  return parent.rawEvents
      .where((e) => e.seq <= lastEnd!.seq)
      .toList();
}
