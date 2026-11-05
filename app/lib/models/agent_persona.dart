// ============================================================
// 智能体人格（Persona）。
// 标准人格恒存在（kStandardPersonaId，行为与旧版完全一致，不落盘）；
// 用户可新增多个人格（名字 + 人设提示词），按场景切换。
// 人格列表与激活 id 持久化在 inference_settings.json。
// ============================================================

/// 内置标准人格 id（不存入 agentPersonas 列表）。
const String kStandardPersonaId = 'standard';

/// 一个自定义智能体人格。
///
/// - [id]     唯一标识（uuid），持久化与激活引用。
/// - [name]   界面显示名（如「写作助手」「严谨学者」）。
/// - [prompt] 人设提示词：注入系统提示词身份段之后的附加指令
///   （语气、专长、行为边界等）。空串 = 只有名字没有附加指令。
class AgentPersona {
  final String id;
  final String name;
  final String prompt;

  const AgentPersona({
    required this.id,
    required this.name,
    this.prompt = '',
  });

  AgentPersona copyWith({String? name, String? prompt}) {
    return AgentPersona(
      id: id,
      name: name ?? this.name,
      prompt: prompt ?? this.prompt,
    );
  }

  Map<String, dynamic> toJson() => {'id': id, 'name': name, 'prompt': prompt};

  factory AgentPersona.fromJson(Map<String, dynamic> json) {
    return AgentPersona(
      id: json['id'] as String? ?? '',
      name: json['name'] as String? ?? '',
      prompt: json['prompt'] as String? ?? '',
    );
  }
}
