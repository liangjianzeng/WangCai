/// 沙箱授权体系 —— 对照 DSH `@deepseek-ai/dsh-sandbox` 的 escalation.ts。
///
/// 设计（对齐 DSH）：
/// - **严格更宽阶梯**：`workspace-write`（默认，app workspace 沙盒内）
///   → `danger-full-access`（app 权限内完整文件系统访问，含公共存储）。
/// - **模型表达升级**：带参数工具附加 `sandbox_permissions`（目标模式）+
///   `justification`（一句话理由）；二者必须成对出现（对照 DSH validateEscalationArgs）。
/// - **执行前审批**：agent 循环在执行前解析升级请求，经注入的
///   [AgentSandboxApprover] 转用户确认（allowed-once），批准后仅本次调用生效。
/// - **拒绝/升级标记**：与 DSH 同一套模型可见文案，便于模型识别策略拒绝并正确重试。
library;

/// 沙箱模式（对照 DSH `SandboxMode`）。字符串值与 DSH 保持一致，便于模型迁移。
enum SandboxMode {
  /// 默认：仅可读写 app workspace 沙盒目录。
  workspaceWrite('workspace-write'),

  /// 完整访问：app 权限内可访问的完整文件系统（含公共存储 /sdcard 等）。
  dangerFullAccess('danger-full-access');

  const SandboxMode(this.value);

  /// DSH 兼容的字符串值。
  final String value;

  static SandboxMode? fromValue(String? value) {
    for (final mode in SandboxMode.values) {
      if (mode.value == value) return mode;
    }
    return null;
  }
}

/// 模型发起的一次沙箱升级请求（对照 DSH `EscalationRequest`）。
class SandboxEscalation {
  /// 请求的目标模式（必须严格宽于当前有效模式）。
  final SandboxMode requestedMode;

  /// 一句话理由，原样展示给用户（对照 DSH justification）。
  final String justification;

  /// 当前有效模式（默认 workspace-write）。
  final SandboxMode effectiveMode;

  const SandboxEscalation({
    required this.requestedMode,
    required this.justification,
    this.effectiveMode = SandboxMode.workspaceWrite,
  });

  /// 是否严格更宽（对照 DSH `WIDER_MODES`）。
  bool get isStrictlyWider {
    if (requestedMode == effectiveMode) return false;
    // 唯一允许的升级路径：workspace-write → danger-full-access。
    return effectiveMode == SandboxMode.workspaceWrite &&
        requestedMode == SandboxMode.dangerFullAccess;
  }
}

/// 审批通道：把升级请求转给用户确认。
///
/// 由接入层（UI）注入：返回 `true` = 批准（本次调用以完整模式执行）；
/// `false` = 拒绝（工具返回明确错误，模型可解释或放弃）。
/// 对照 DSH `EscalationApprover.request(...)` → `allowed-once` / `rejected`。
typedef AgentSandboxApprover =
    Future<bool> Function(SandboxEscalation escalation, String toolName);

/// 从工具参数中提取升级请求；无 `sandbox_permissions` 时返回 null。
///
/// 校验（对照 DSH `validateEscalationArgs`）：
/// - `sandbox_permissions` 与 `justification` 必须成对出现；
/// - justification 必须是非空句子。
/// 校验失败抛 [FormatException]，由调用方转为工具错误回填。
SandboxEscalation? extractEscalation(
  Map<String, dynamic> args, {
  SandboxMode effectiveMode = SandboxMode.workspaceWrite,
}) {
  final rawMode = args['sandbox_permissions'] as String?;
  if (rawMode == null) {
    // 模型不应单独给 justification。
    if (args['justification'] != null) {
      throw const FormatException('justification 只能在带 sandbox_permissions 时使用');
    }
    return null;
  }
  final justification = (args['justification'] as String?)?.trim() ?? '';
  if (justification.isEmpty) {
    throw const FormatException('sandbox_permissions 需要一句话 justification（用户审批需要理由）');
  }
  final mode = SandboxMode.fromValue(rawMode);
  if (mode == null) {
    throw FormatException('未知沙箱模式 "$rawMode"（可用: ${SandboxMode.values.map((m) => m.value).join(' / ')}）');
  }
  return SandboxEscalation(
    requestedMode: mode,
    justification: justification,
    effectiveMode: effectiveMode,
  );
}

/// 内部传递键：agent 循环审批通过后，把生效模式写入工具执行参数。
/// 工具执行体读取此键决定路径作用域（workspace 内 / 完整文件系统）。
const String kSandboxModeArgKey = '_sandboxMode';

/// 读取工具执行参数中的生效沙箱模式（无键时默认 workspace-write）。
SandboxMode effectiveModeOf(Map<String, dynamic> args) {
  final mode = SandboxMode.fromValue(args[kSandboxModeArgKey] as String?);
  return mode ?? SandboxMode.workspaceWrite;
}

/// 升级参数 schema 片段：文件/命令类工具声明沙箱升级能力（对照 DSH bash 的
/// `sandbox_permissions` / `justification` 参数）。
/// 模型带 `sandbox_permissions` + `justification` 请求完整文件系统访问，
/// 执行前经用户审批（agent 循环处理），批准后本次调用生效。
const Map<String, dynamic> kEscalationFields = {
  'sandbox_permissions': {
    'type': 'string',
    'enum': ['danger-full-access'],
    'description': '请求完整文件系统访问（仅作为被拒后的一次性重试，需用户批准）',
  },
  'justification': {
    'type': 'string',
    'description': '配合 sandbox_permissions：一句话说明为什么需要该访问',
  },
};

/// 追加升级字段到工具 schema（保持参数顺序：必填在前，升级在后）。
Map<String, dynamic> withEscalationFields(Map<String, dynamic> parameters) {
  return {
    ...parameters,
    'properties': {
      ...(parameters['properties'] as Map<String, dynamic>),
      ...kEscalationFields,
    },
  };
}

/// 模型可见的拒绝标记（对照 DSH `sandboxDenialMarker`）。
String sandboxDenialMarker(SandboxMode mode) =>
    '[sandbox: file access denied under ${mode.value} mode]';

/// 模型可见的升级提示（对照 DSH `escalationHintMarker`）。
/// [subject] 为被拒动作的名词（`command` / `operation`）。
String escalationHintMarker(String subject) =>
    '[sandbox: escalation available — retry this exact $subject once with '
    'sandbox_permissions (the narrowest wider mode that suffices) + '
    'justification; the approval prompt asks the user]';
