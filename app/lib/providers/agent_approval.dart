/// 沙箱升级审批通道 —— 对照 DSH `ctx.approval` 的注入 seam。
///
/// agent 循环执行带 `sandbox_permissions` 的调用前，经此通道请求用户确认
/// （allowed-once：批准后仅本次调用以完整文件系统模式执行）。
/// UI 层（主界面/设置页）注入真实实现（弹确认框）；未注入时升级请求返回
/// 明确错误（fail-closed，不执行任何命令）。
library;

import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../agent/agent.dart';
import '../agent/tools/pipeline.dart' show ToolPreExecuteApprover;

/// 全局审批通道：默认 null（无审批服务 → 升级请求 fail-closed）。
/// UI 层通过覆盖此 Provider 注入确认框实现。
final sandboxApproverProvider =
    Provider<AgentSandboxApprover?>((ref) => null);

/// 流水线 pre-execute `ask` 审批通道（Phase 6 ApprovalDialog，§12.3）。
/// 默认 null：无审批服务时 ask 视为拒绝（fail-closed）。
/// UI 层（main.dart）覆盖为确认框实现。
final toolPreApproverProvider =
    Provider<ToolPreExecuteApprover?>((ref) => null);
