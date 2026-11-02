/// 智能体工具活动类型 —— 主循环与接入层共享的 UI 展示契约。
///
/// 旧 [runAgent] 循环已删除（2026：新引擎唯一），此文件只保留
/// 新主循环（ReactLoopAgent）与 ChatNotifier 会话层共用的展示类型。
library;

/// 工具执行活动（UI 展示用）。
class ToolActivity {
  final String name;
  /// 'executing' / 'done' / 'failed'。
  final String status;
  /// 完成/失败时的结果文本（executing 时为 null）。
  final String? result;

  const ToolActivity({
    required this.name,
    required this.status,
    this.result,
  });

  bool get isDone => status == 'done';
  bool get isFailed => status == 'failed';
}

/// 工具活动回调：工具执行开始/结束都会触发，供 UI 更新活动消息。
typedef AgentToolActivityCallback = Future<void> Function(ToolActivity activity);
