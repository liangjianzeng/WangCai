// ============================================================
// Remote OpenAI-compatible model configuration.
// Each entry maps a display name to an OpenAI-compatible endpoint
// ({baseUrl}/chat/completions). Configs are persisted (plaintext) in
// the same settings JSON as local inference settings.
// ============================================================

/// 一个 OpenAI 兼容的远程模型配置。
///
/// 字段说明：
/// - [id]      本地生成的唯一标识（uuid），用于持久化与激活引用。
/// - [name]    界面显示名（如 "GPT-4o"）。
/// - [baseUrl] OpenAI 兼容端点根地址（如 `https://api.openai.com/v1`，
///   或本地 `http://127.0.0.1:8080/v1`）。服务调用时自动补 `/chat/completions`。
/// - [apiKey]  访问密钥（明文存本地 JSON，适合本地个人使用）。
/// - [model]   远端模型名（如 `gpt-4o`、`qwen2.5-7b-instruct`）。
/// - [temperature] 可空的生成温度；null 用全局默认 0.7。
/// - [maxTokens]   可空的输出上限；null 用全局默认 1024。
/// - [visionCapable] 该端点是否支持图像理解。由于无法可靠自动探测，由用户在
///   设置里手动勾选；为 true 时，带图消息会以 OpenAI content-parts 形式
///   （base64 image_url）发送，否则图片会被剥离为纯文本。
class ApiModelConfig {
  final String id;
  final String name;
  final String baseUrl;
  final String apiKey;
  final String model;
  final double? temperature;
  final int? maxTokens;
  final bool visionCapable;
  final int? contextWindow;

  /// 思考强度档位：null(=不干预) / off / low / medium / high。
  ///
  /// 为什么挂在**每条 API 配置**上而不是做成全局一个开关：不同端点对思考的
  /// 支持度差别极大（有的只有开关、有的是预算、有的根本不认），一个全局值
  /// 必然把某些端点配错（本仓 MTP 全局 bool 的老坑，AGENTS.md 已记）。
  /// 一条配置 = 一个模型 = 一个档位，天然按模型覆盖。
  /// null 时**一个思考字段都不发**，行为与旧版逐字节一致（安全默认）。
  final String? thinkingEffort;

  /// 思考参数族覆盖（高级）：null = 按模型名/端点自动探测。
  /// 取值见 thinking_effort.dart 的 thinkingFamilyFromKey（如 vllm / qwen /
  /// thinking_type / reasoning_effort…）。自动探测判错时用户可手工钉死。
  final String? thinkingFamily;

  const ApiModelConfig({
    required this.id,
    required this.name,
    required this.baseUrl,
    required this.apiKey,
    required this.model,
    this.temperature,
    this.maxTokens,
    this.visionCapable = false,
    this.contextWindow,
    this.thinkingEffort,
    this.thinkingFamily,
  });

  /// 生效温度：配置值 ?? 0.7。
  double get effectiveTemperature => temperature ?? 0.7;

  /// 生效输出上限：配置值 ?? 1024（与本地推理默认一致）。
  int get effectiveMaxTokens => maxTokens ?? 1024;

  ApiModelConfig copyWith({
    String? name,
    String? baseUrl,
    String? apiKey,
    String? model,
    double? temperature,
    int? maxTokens,
    bool? visionCapable,
    int? contextWindow,
    bool clearTemperature = false,
    bool clearMaxTokens = false,
    bool clearContextWindow = false,
    String? thinkingEffort,
    String? thinkingFamily,
    bool clearThinkingEffort = false,
    bool clearThinkingFamily = false,
  }) {
    return ApiModelConfig(
      id: id,
      name: name ?? this.name,
      baseUrl: baseUrl ?? this.baseUrl,
      apiKey: apiKey ?? this.apiKey,
      model: model ?? this.model,
      temperature: clearTemperature ? null : temperature ?? this.temperature,
      maxTokens: clearMaxTokens ? null : maxTokens ?? this.maxTokens,
      visionCapable: visionCapable ?? this.visionCapable,
      contextWindow:
          clearContextWindow ? null : contextWindow ?? this.contextWindow,
      thinkingEffort:
          clearThinkingEffort ? null : thinkingEffort ?? this.thinkingEffort,
      thinkingFamily:
          clearThinkingFamily ? null : thinkingFamily ?? this.thinkingFamily,
    );
  }

  Map<String, dynamic> toJson() => {
        'id': id,
        'name': name,
        'baseUrl': baseUrl,
        'apiKey': apiKey,
        'model': model,
        'temperature': temperature,
        'maxTokens': maxTokens,
        'visionCapable': visionCapable,
        'contextWindow': contextWindow,
        'thinkingEffort': thinkingEffort,
        'thinkingFamily': thinkingFamily,
      };

  factory ApiModelConfig.fromJson(Map<String, dynamic> json) {
    return ApiModelConfig(
      id: json['id'] as String? ?? '',
      name: json['name'] as String? ?? '',
      baseUrl: json['baseUrl'] as String? ?? '',
      apiKey: json['apiKey'] as String? ?? '',
      model: json['model'] as String? ?? '',
      temperature: (json['temperature'] as num?)?.toDouble(),
      maxTokens: (json['maxTokens'] as num?)?.toInt(),
      visionCapable: json['visionCapable'] as bool? ?? false,
      contextWindow: (json['contextWindow'] as num?)?.toInt(),
      thinkingEffort: json['thinkingEffort'] as String?,
      thinkingFamily: json['thinkingFamily'] as String?,
    );
  }
}
