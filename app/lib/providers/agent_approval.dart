/// 沙箱升级审批通道 —— 对照 DSH `ctx.approval` 的注入 seam。
///
/// agent 循环执行带 `sandbox_permissions` 的调用前，经此通道请求用户确认
/// （allowed-once：批准后仅本次调用以完整文件系统模式执行）。
/// UI 层注入真实实现；未注入时升级请求返回明确错误（fail-closed，不执行）。
///
/// v0.0.4 Phase 4b（计划书 §5.2）：审批 UI 从全局 AlertDialog 改为
/// **composer 接管**（对齐 DSH ApprovalPanel）——请求入
/// [pendingApprovalsProvider] 队列，对话区在输入框上方渲染 ApprovalCard，
/// 用户就地批准/拒绝；无弹窗打断上下文。
library;

import 'dart:async';

import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../agent/agent.dart';
import '../agent/tools/pipeline.dart' show ToolPreExecuteApprover;

/// 全局审批通道：默认 null（无审批服务 → 升级请求 fail-closed）。
/// UI 层通过覆盖此 Provider 注入实现。
final sandboxApproverProvider =
    Provider<AgentSandboxApprover?>((ref) => null);

/// 流水线 pre-execute `ask` 审批通道（Phase 6，§12.3）。
/// 默认 null：无审批服务时 ask 视为拒绝（fail-closed）。
final toolPreApproverProvider =
    Provider<ToolPreExecuteApprover?>((ref) => null);

/// 一条挂起的审批请求（composer 接管形态）。
class PendingApproval {
  final String id;
  final String title;
  final String detail;

  /// null = 无危险动作按钮（如只读信息）；有值 = 「允许」按钮动作描述。
  final String? allowLabel;
  final Completer<bool> completer;
  PendingApproval({
    required this.id,
    required this.title,
    required this.detail,
    this.allowLabel,
    required this.completer,
  });
}

/// 挂起审批队列（单槽：agent 回合内审批天然串行，简化为一次一条）。
class PendingApprovalsNotifier extends StateNotifier<PendingApproval?> {
  PendingApprovalsNotifier() : super(null);

  int _seq = 0;

  /// 入队并等待用户决议。队列忙（上一条还没决议）则排队等。
  Future<bool> enqueue({
    required String title,
    required String detail,
    String? allowLabel,
  }) async {
    final id = 'appr_${DateTime.now().microsecondsSinceEpoch}_${_seq++}';
    final c = Completer<bool>();
    final req = PendingApproval(
        id: id, title: title, detail: detail, allowLabel: allowLabel, completer: c);
    // 串行化：等前一条出槽（正常场景 agent 逐条请求，几乎不等待）。
    var guard = 0;
    while (state != null && guard < 600) {
      await Future<void>.delayed(const Duration(milliseconds: 100));
      guard++;
    }
    if (!c.isCompleted) state = req;
    try {
      return await c.future;
    } finally {
      if (state?.id == id) state = null;
    }
  }

  /// 用户决议（ApprovalCard 调用）。
  void resolve(String id, bool granted) {
    final s = state;
    if (s != null && s.id == id && !s.completer.isCompleted) {
      s.completer.complete(granted);
    }
  }
}

/// v0.0.4 Phase 4b：composer 接管式审批的挂起队列。
final pendingApprovalsProvider =
    StateNotifierProvider<PendingApprovalsNotifier, PendingApproval?>(
        (ref) => PendingApprovalsNotifier());
