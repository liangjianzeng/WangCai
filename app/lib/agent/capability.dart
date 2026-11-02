/// 引擎能力模型 —— 协议选择的依据。
///
/// 设计原则：能力 = **静态声明（模型目录）+ 运行时探测（引擎上报）双源合并**。
/// 静态声明是"预期"（加载前即可预估协议），运行时探测是"事实"（加载后确认）。
/// 探测缺失的字段回退静态声明 —— 新模型入目录即可工作；原生改造后引擎一上报，
/// 协议自动切换，无需改代码。
class EngineCapabilities {
  /// 模型/引擎是否支持原生工具调用（API 天然支持；本地看引擎/模型模板）。
  final bool nativeToolCall;

  /// 是否支持 grammar / 结构化约束采样。
  final bool structuredOutput;

  /// 是否支持 JSON 约束。
  final bool jsonMode;

  /// 可并行工具调用数；0 = 不支持并行。
  final int maxParallelToolCalls;

  /// 模型原生上下文上限（token）。
  final int maxContextTokens;

  /// 原生工具调用模板/格式标识（如 `openai`、`spark-native`），
  /// 供 native-tools 协议选择对应 adapter 变体。
  final String? toolTemplate;

  const EngineCapabilities({
    this.nativeToolCall = false,
    this.structuredOutput = false,
    this.jsonMode = false,
    this.maxParallelToolCalls = 0,
    this.maxContextTokens = 0,
    this.toolTemplate,
  });

  /// 静态声明（模型目录）与运行时探测（引擎上报）的合并结果。
  ///
  /// 合并规则：运行时探测为"事实"，缺失字段回退静态声明（"预期"）。
  /// [declared] 为模型目录声明的能力；[probed] 为引擎加载后上报的真实能力，
  /// 可为 null（引擎未上报时完全采用声明）。
  factory EngineCapabilities.resolve({
    required EngineCapabilities declared,
    EngineCapabilities? probed,
  }) {
    if (probed == null) return declared;
    return EngineCapabilities(
      nativeToolCall: probed.nativeToolCall,
      structuredOutput: probed.structuredOutput,
      jsonMode: probed.jsonMode,
      maxParallelToolCalls: probed.maxParallelToolCalls,
      maxContextTokens: probed.maxContextTokens,
      toolTemplate: probed.toolTemplate ?? declared.toolTemplate,
    );
  }

  EngineCapabilities copyWith({
    bool? nativeToolCall,
    bool? structuredOutput,
    bool? jsonMode,
    int? maxParallelToolCalls,
    int? maxContextTokens,
    String? toolTemplate,
    bool clearToolTemplate = false,
  }) {
    return EngineCapabilities(
      nativeToolCall: nativeToolCall ?? this.nativeToolCall,
      structuredOutput: structuredOutput ?? this.structuredOutput,
      jsonMode: jsonMode ?? this.jsonMode,
      maxParallelToolCalls: maxParallelToolCalls ?? this.maxParallelToolCalls,
      maxContextTokens: maxContextTokens ?? this.maxContextTokens,
      toolTemplate: clearToolTemplate ? null : toolTemplate ?? this.toolTemplate,
    );
  }

  @override
  bool operator ==(Object other) =>
      other is EngineCapabilities &&
      other.nativeToolCall == nativeToolCall &&
      other.structuredOutput == structuredOutput &&
      other.jsonMode == jsonMode &&
      other.maxParallelToolCalls == maxParallelToolCalls &&
      other.maxContextTokens == maxContextTokens &&
      other.toolTemplate == toolTemplate;

  @override
  int get hashCode =>
      Object.hash(nativeToolCall, structuredOutput, jsonMode,
          maxParallelToolCalls, maxContextTokens, toolTemplate);

  @override
  String toString() => 'EngineCapabilities(nativeToolCall=$nativeToolCall, '
      'structuredOutput=$structuredOutput, jsonMode=$jsonMode, '
      'maxParallelToolCalls=$maxParallelToolCalls, maxContextTokens=$maxContextTokens, '
      'toolTemplate=$toolTemplate)';
}
