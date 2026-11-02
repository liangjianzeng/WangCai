// ============================================================
// API 路线「思考强度」档位 → 各家 OpenAI 兼容端点请求体字段映射。
//
// 为什么需要这张表：各家把"想多少"暴露成了**不同字段、不同层级、不同取值**，
// 而本 App 只会说 OpenAI 兼容一种方言。盲传不认的字段 = 严格端点直接 400，
// 所以必须按模型族发**各家认的那一个**，族不认的一律不发（宁可没效果，
// 也不能把用户的 API 智能体打成不可用）。
//
// 依据（各家公开接口规范，2026-10 核对）：
//   OpenAI gpt-5 / o 系、xAI grok、MiniMax M2、DashScope OpenAI 兼容
//     → 顶层 reasoning_effort: minimal | low | medium | high（gpt-5 另有 none）
//   Anthropic Claude（经 OpenAI 兼容网关）
//     → thinking: { type: enabled, budget_tokens: N }（预算必须 < max_tokens）
//   Google Gemini（OpenAI 兼容 extra body）
//     → thinking_config: { thinking_budget: N, include_thoughts: true }
//   DeepSeek reasoner / V3.2+、Kimi K2（Moonshot）
//     → thinking: { type: enabled | disabled }（只有开关，无档位）
//   智谱 GLM-4.5/4.6
//     → thinking: { enabled: true | false }
//   Qwen3（DashScope 兼容）→ 顶层 enable_thinking: bool（+ thinking_budget: N）
//   vLLM / SGLang 自托管  → chat_template_kwargs: { enable_thinking: bool }
//                          （部分构建另认顶层 thinking_budget）
//
// 档位到 token 预算（预算制族用）：low 1024 / medium 2048 / high 4096，
// 并夹到 max_tokens - 256 以内（Anthropic 强制 budget_tokens < max_tokens）。
// ============================================================

/// 思考强度档位（用户可见：不干预 / 关 / 低 / 中 / 高）。
enum ThinkingEffort {
  /// 不干预：一个思考字段都不发，行为与旧版逐字节一致（安全默认）。
  passthrough,

  /// 明确关思考（省 token、防失控）。
  off,
  low,
  medium,
  high,
}

/// 模型族：决定思考参数发到哪、发什么。
enum ThinkingFamily {
  /// 顶层 reasoning_effort（OpenAI o/gpt-5 系、xAI、MiniMax、多数网关）。
  reasoningEffort,

  /// thinking.budget_tokens（Anthropic 系网关）。
  anthropicThinking,

  /// thinking_config.thinking_budget（Gemini extra body）。
  geminiThinkingConfig,

  /// thinking.type = enabled/disabled（DeepSeek reasoner、Kimi K2）。
  thinkingType,

  /// thinking.enabled = true/false（智谱 GLM）。
  thinkingEnabled,

  /// 顶层 enable_thinking（DashScope 兼容 Qwen）。
  qwenEnableThinking,

  /// chat_template_kwargs.enable_thinking（vLLM / SGLang 自托管）。
  vllmChatTemplateKwargs,

  /// 族不识别：什么都不发。
  none,
}

/// 设置里落盘用的字符串 ↔ 枚举（null / 未知串 = [ThinkingEffort.passthrough]）。
ThinkingEffort thinkingEffortFromKey(String? key) => switch (key) {
      'off' => ThinkingEffort.off,
      'low' => ThinkingEffort.low,
      'medium' => ThinkingEffort.medium,
      'high' => ThinkingEffort.high,
      _ => ThinkingEffort.passthrough,
    };

String? thinkingEffortToKey(ThinkingEffort effort) => switch (effort) {
      ThinkingEffort.passthrough => null,
      ThinkingEffort.off => 'off',
      ThinkingEffort.low => 'low',
      ThinkingEffort.medium => 'medium',
      ThinkingEffort.high => 'high',
    };

/// 档位中文名（UI 与日志共用，避免各处文案漂移）。
String thinkingEffortLabel(ThinkingEffort effort) => switch (effort) {
      ThinkingEffort.passthrough => '不干预',
      ThinkingEffort.off => '关',
      ThinkingEffort.low => '低',
      ThinkingEffort.medium => '中',
      ThinkingEffort.high => '高',
    };

/// 族覆盖串（设置里的高级选项）↔ 枚举；null/未知 = 自动探测。
ThinkingFamily? thinkingFamilyFromKey(String? key) => switch (key) {
      'reasoning_effort' => ThinkingFamily.reasoningEffort,
      'anthropic' => ThinkingFamily.anthropicThinking,
      'gemini' => ThinkingFamily.geminiThinkingConfig,
      'thinking_type' => ThinkingFamily.thinkingType,
      'thinking_enabled' => ThinkingFamily.thinkingEnabled,
      'qwen' => ThinkingFamily.qwenEnableThinking,
      'vllm' => ThinkingFamily.vllmChatTemplateKwargs,
      'none' => ThinkingFamily.none,
      _ => null,
    };

String? thinkingFamilyToKey(ThinkingFamily? family) => switch (family) {
      null => null,
      ThinkingFamily.reasoningEffort => 'reasoning_effort',
      ThinkingFamily.anthropicThinking => 'anthropic',
      ThinkingFamily.geminiThinkingConfig => 'gemini',
      ThinkingFamily.thinkingType => 'thinking_type',
      ThinkingFamily.thinkingEnabled => 'thinking_enabled',
      ThinkingFamily.qwenEnableThinking => 'qwen',
      ThinkingFamily.vllmChatTemplateKwargs => 'vllm',
      ThinkingFamily.none => 'none',
    };

/// 族的中文说明（设置页下拉用；括注实际发送的字段，便于用户自查抓包）。
String thinkingFamilyLabel(ThinkingFamily family) => switch (family) {
      ThinkingFamily.reasoningEffort =>
        'reasoning_effort（OpenAI / grok / MiniMax）',
      ThinkingFamily.anthropicThinking => 'thinking.budget_tokens（Claude）',
      ThinkingFamily.geminiThinkingConfig => 'thinking_config（Gemini）',
      ThinkingFamily.thinkingType => 'thinking.type（DeepSeek / Kimi）',
      ThinkingFamily.thinkingEnabled => 'thinking.enabled（智谱 GLM）',
      ThinkingFamily.qwenEnableThinking => 'enable_thinking（Qwen / DashScope）',
      ThinkingFamily.vllmChatTemplateKwargs =>
        'chat_template_kwargs（vLLM / SGLang）',
      ThinkingFamily.none => '不发思考字段',
    };

/// 族自动探测：先看模型名，再看端点地址（自托管没有稳定模型名前缀）。
///
/// 判定顺序有意"具体优先"：deepseek/kimi/glm 这些即便跑在 vLLM 上，也应该
/// 发它们认得的 thinking.type / thinking.enabled，而不是 vLLM 模板参数。
ThinkingFamily detectThinkingFamily(String model, {String? baseUrl}) {
  final m = model.toLowerCase().trim();
  final u = (baseUrl ?? '').toLowerCase();

  bool hasAny(List<String> keys) => keys.any((k) => m.contains(k));

  // 1) 厂商专属开关族（模型名最权威）
  if (hasAny(['deepseek-r1', 'deepseek-reasoner', 'deepseek-v3.2',
          'deepseek-v3.1', 'deepseek-thinking'])) {
    return ThinkingFamily.thinkingType;
  }
  if (hasAny(['kimi-k2', 'kimi thinking', 'moonshot'])) {
    return ThinkingFamily.thinkingType;
  }
  if (hasAny(['glm-4.5', 'glm-4.6', 'glm-4.5v', 'codegeex'])) {
    return ThinkingFamily.thinkingEnabled;
  }
  if (hasAny(['claude'])) return ThinkingFamily.anthropicThinking;
  if (hasAny(['gemini'])) return ThinkingFamily.geminiThinkingConfig;
  if (hasAny(['grok'])) return ThinkingFamily.reasoningEffort;
  if (hasAny(['minimax-m2', 'minimax-m1'])) {
    return ThinkingFamily.reasoningEffort;
  }
  if (hasAny(['gpt-5', 'gpt-5.1', 'chatgpt-', 'o1', 'o3', 'o4'])) {
    return ThinkingFamily.reasoningEffort;
  }

  // 2) Qwen 系：DashScope 与 vLLM 自托管发的字段不同，按地址分流
  if (hasAny(['qwen2.5', 'qwen3', 'qwq'])) {
    return _isSelfHosted(u)
        ? ThinkingFamily.vllmChatTemplateKwargs
        : ThinkingFamily.qwenEnableThinking;
  }

  // 3) 只知道是自托管 → vLLM/SGLang 模板参数（本地端点最常见）
  if (_isSelfHosted(u)) return ThinkingFamily.vllmChatTemplateKwargs;

  // 4) 云端但族不明 → 发最通用的 reasoning_effort 风险偏高（严格端点会 400），
  //    交给上层「400 去掉思考字段重试一次」兜底，这里仍返回 reasoningEffort
  //    只有在明显是 OpenAI 官方时才用；否则一律 none（什么都不发）。
  if (u.contains('api.openai.com') || u.contains('openai')) {
    return ThinkingFamily.reasoningEffort;
  }
  return ThinkingFamily.none;
}

bool _isSelfHosted(String url) {
  if (url.isEmpty) return false;
  const hints = [
    '127.0.0.1',
    'localhost',
    '0.0.0.0',
    ':8000',
    ':8080',
    ':8090',
    ':8081',
    ':3000',
    'vllm',
    'sglang',
    'lmstudio',
    'ollama',
    'dgx',
  ];
  return hints.any((h) => url.contains(h));
}

/// 档位 → token 预算（预算制族用；开关制族忽略）。
int thinkingBudgetTokens(ThinkingEffort effort) => switch (effort) {
      ThinkingEffort.off => 0,
      ThinkingEffort.low => 1024,
      ThinkingEffort.passthrough => 0,
      ThinkingEffort.medium => 2048,
      ThinkingEffort.high => 4096,
    };

/// **唯一真源**：档位 + 族 → 要并进请求体的字段（空 map = 一个都不发）。
///
/// [maxTokens] 用于把预算夹到 max_tokens 之下（Anthropic 硬性要求
/// budget_tokens 小于 max_tokens，否则 400）。
Map<String, dynamic> thinkingWireFields({
  required ThinkingEffort effort,
  required ThinkingFamily family,
  int? maxTokens,
}) {
  if (effort == ThinkingEffort.passthrough) return const {};
  if (family == ThinkingFamily.none) return const {};

  final wantThinking = effort != ThinkingEffort.off;

  switch (family) {
    case ThinkingFamily.reasoningEffort:
      // gpt-5 系支持 none；o 系无 none，off 退到 minimal（最省的一档）。
      final level = switch (effort) {
        ThinkingEffort.off => 'minimal',
        ThinkingEffort.low => 'low',
        ThinkingEffort.medium => 'medium',
        ThinkingEffort.high => 'high',
        ThinkingEffort.passthrough => '',
      };
      if (level.isEmpty) return const {};
      return {'reasoning_effort': level};

    case ThinkingFamily.anthropicThinking:
      if (!wantThinking) {
        return {'thinking': const {'type': 'disabled'}};
      }
      final budget = _clampBudget(thinkingBudgetTokens(effort), maxTokens);
      return {
        'thinking': {'type': 'enabled', 'budget_tokens': budget},
      };

    case ThinkingFamily.geminiThinkingConfig:
      // Gemini 0 = 关思考；-1 = 模型自适应（本 App 不用自适应，档位要可控）。
      final budget =
          wantThinking ? _clampBudget(thinkingBudgetTokens(effort), maxTokens) : 0;
      return {
        'thinking_config': {
          'thinking_budget': budget,
          'include_thoughts': wantThinking,
        },
      };

    case ThinkingFamily.thinkingType:
      return {
        'thinking': {'type': wantThinking ? 'enabled' : 'disabled'},
      };

    case ThinkingFamily.thinkingEnabled:
      return {
        'thinking': {'enabled': wantThinking},
      };

    case ThinkingFamily.qwenEnableThinking:
      if (!wantThinking) return {'enable_thinking': false};
      return {
        'enable_thinking': true,
        // DashScope 认 thinking_budget；严格 DashScope 不认时由上层去字段重试。
        'thinking_budget': _clampBudget(thinkingBudgetTokens(effort), maxTokens),
      };

    case ThinkingFamily.vllmChatTemplateKwargs:
      final kwargs = <String, dynamic>{'enable_thinking': wantThinking};
      if (wantThinking) {
        // 较新构建支持预算；不认的构建会忽略未知 kwargs（vLLM 对
        // chat_template_kwargs 里的多余键按模板变量处理，未用即忽略）。
        kwargs['thinking_budget'] =
            _clampBudget(thinkingBudgetTokens(effort), maxTokens);
      }
      return {
        'chat_template_kwargs': kwargs,
        // 顶层再带一份：SGLang 与部分 vLLM 包装只认顶层开关。
        'enable_thinking': wantThinking,
      };

    case ThinkingFamily.none:
      return const {};
  }
}

/// 预算夹逼：必须给正文留出余量，否则预算制端点直接 400。
int _clampBudget(int budget, int? maxTokens) {
  if (budget <= 0) return 0;
  if (maxTokens == null || maxTokens <= 0) return budget;
  final room = maxTokens - 256;
  if (room < 256) return 256 > maxTokens ? maxTokens : 256;
  return budget > room ? room : budget;
}
