/// LLM adapter seam（Phase 3）—— 模型调用抽象。
///
/// Phase 1 依赖此 seam；本地实现 [LocalEngineAdapter]（lib/agent/llm/local_adapter.dart），
/// API 实现（lib/agent/llm/openai_adapter.dart，Phase 3）共用同一接口。
///
/// 设计（对照 DSH `LlmAdapter` Part 12）：
/// - adapter 只报告**事实**（文本 + 工具调用 + 失败事实），不做策略；
/// - 失败归一化为 [LlmFailure]（code + 事实字段），策略（重试/压缩/终态）由主循环瀑布决定；
/// - `generate` 是纯模型调用；工具执行不在 adapter 里（主循环负责）。
library;

import 'dart:async';

import '../capability.dart';
import '../tool_definition.dart';

/// 生成被取消时抛出的异常（本 SDK 无 flutter/services 的
/// CancelController，故用自定义异常 + [Completer] 表达取消）。
/// 独立于 Exception 以避免其仅含 factory 构造器的限制。
final class AgentCancelledException {
  const AgentCancelledException();
}

/// 思考流失控守卫阈值（**累计**字符数）：
///
/// 口径（唯一真源是 [AgentStreamProcessor.thinkingRunaway]，adapter 不许自量块长）：
/// 累计思考超过该字数、且本步还没产出有用内容 → 主动停流止损，
/// 按 [LlmFailureCode.thinkingOverflow] 处理（可抢救 + 关思考重试一次）。
///
/// 为什么必须是累计：端侧小模型爱 `think…response…think…response` 反复横跳，
/// 只量「当前块」会每块归零 → 总量无上限（实测 4 万字独白畅通无阻，
/// 把每轮 token 预算与上下文吃光，就是用户报的"思考超 32k"）。
const int kMaxThinkingChars = 6000;

/// 模型 provider 类型（本地引擎 / 远程 API）。
enum ProviderKind {
  local,
  api,
}

/// 模型请求失败归一化（事实，不含策略）。
enum LlmFailureCode {
  contextWindowExceeded, // 上下文窗口超出（本地引擎常见于长对话）
  rateLimit,             // 限流（429 / 本地引擎资源耗尽）
  server,                // 服务端 5xx
  timeout,               // 超时
  transport,             // 网络传输 / native channel 错误
  invalidRequest,        // 请求非法（HTTP 4xx 除 429：参数/鉴权/路由错误，确定性失败，重试无意义）
  noAdapter,             // 无可用适配器
  emptyResponse,         // 响应为空
  toolCallTruncated,     // 工具调用块生成到一半被截断（token 预算不足）
  toolCallSyntax,        // 工具调用块语法坏到容错解析也解不开（如 <tool_call><名</tool_call>）；
                         // 可重试：重新采样 + 失败反思注记常能产出正确格式
  modelNotReady,         // 本地引擎未加载模型（isLoaded=false）；重试无益
  thinkingOverflow,      // 思考失控：超长未闭合，已主动中止（确定性失败，重试无意义）
  unknown,
}

/// 模型请求失败。
final class LlmFailure {
  final LlmFailureCode code;
  final String message;
  final int? status;
  final int? providerRetryAfterMs;
  final String? requestId;

  const LlmFailure({
    required this.code,
    required this.message,
    this.status,
    this.providerRetryAfterMs,
    this.requestId,
  });

  bool get isContextWindowExceeded => code == LlmFailureCode.contextWindowExceeded;
  bool get isModelNotReady => code == LlmFailureCode.modelNotReady;
  bool get isRetryableTransient =>
      code == LlmFailureCode.rateLimit ||
      code == LlmFailureCode.server ||
      code == LlmFailureCode.timeout ||
      code == LlmFailureCode.transport;
}

/// 一次模型请求的选项。
final class GenerateOptions {
  final ProviderKind provider;
  /// 历史消息（role/content 对；role ∈ {user, assistant, system, tool}）。
  /// 由 [SessionLog.deriveModelMessages] 派生；adapter 负责按 provider 翻译。
  final List<Map<String, dynamic>> messages;
  /// 可见工具（本地路线进 system 工具段；API 路线原生 tools）。
  final List<ToolDefinition> tools;
  final double temperature;
  final int? maxTokens;
  final String modelId;
  final String? imagePath;
  final String? audioPath;

  /// 多图（多图上传/长图切块，≤10）：API 路线全量发送 image_url parts；
  /// 本地引擎视觉同样按序全量送原生（mtmd 逐张编码），[imagePath] 恒为首张。
  final List<String>? imagePaths;

  /// 生成过程状态流（WP5）：adapter 推轻量状态行，UI 据此显示
  /// "正在生成工具调用参数…"等过程反馈。约定格式：
  /// `toolgen|<chars>|<preview>`（工具调用块生成中）/ `toolgen|0|`（结束）。
  final StreamController<String>? onStatus;

  /// 本步强制不思考（端侧思考失控治理，默认 false）。
  ///
  /// 两个来源：① 主循环对"工具决策步"强制关思考（工具步只需产出调用，
  /// 长思考纯烧端侧预算且是失控高发区）；② 上一步因思考失控被止损后的
  /// 那次重试——同一模型同一配置原样重发必然再次失控，必须换条件重采样。
  /// 本地路线落实为原生 enableThinking 临时关闭；API 路线服务端自决
  /// （不同服务端关思考的私有参数不一，盲传会 400），仅重采样。
  final bool forceNoThinking;

  const GenerateOptions({
    required this.provider,
    required this.messages,
    required this.tools,
    required this.temperature,
    this.maxTokens,
    required this.modelId,
    this.imagePath,
    this.audioPath,
    this.imagePaths,
    this.onStatus,
    this.forceNoThinking = false,
  });
}

/// 一次模型请求的结果。
final class LlmResult {
  final String text;
  final List<ToolCall> toolCalls;

  /// 服务端 token 用量（API 路线，SSE 末块 usage 原样透传；
  /// {prompt_tokens, completion_tokens, ...}，本地路线恒 null）。
  final Map<String, dynamic>? usage;

  const LlmResult({
    required this.text,
    this.toolCalls = const [],
    this.usage,
  });

  bool get hasToolCalls => toolCalls.isNotEmpty;
}

/// 一次模型调用的**能力快照**（Phase 3，对应 DSH Part 9.7 的 `prepareCall`）。
///
/// 端侧无 HMR，故将 DSH「绑定注册代际」简化为**能力快照**：协议选择在
/// [prepareCall] 时按能力驱动**固化**，避免运行中换模型导致协议不一致。
///
/// - [adapter]：本次调用绑定的 adapter（local/API）。
/// - [model]：模型标识（local=模型 id；api=API 模型 name）。
/// - [capabilities]：加载时冻结的 [EngineCapabilities] 快照；null 表示未知。
final class PreparedLlmCall {
  final LlmAdapter adapter;
  final String model;
  final EngineCapabilities? capabilities;
  const PreparedLlmCall({
    required this.adapter,
    required this.model,
    this.capabilities,
  });
}

abstract class LlmAdapter {
  /// 一次模型请求。
  ///
  /// [cancel] 若传入，adapter 应在流处理中与取消竞跑：取消先行则抛
  /// [AgentCancelledException]，让主循环把 turn 收为 interrupted。
  /// [onThinking] 思考增量通道（可选）：adapter 把思考型模型的推理流
  /// （reasoning 字段 / `<think>` 块）以**全量快照**形式推给它，
  /// 供 UI 单独流式展示——不进 LlmResult，不进历史。
  Future<LlmResult> generate(
    GenerateOptions options, {
    StreamController<String>? onToken,
    StreamController<String>? onThinking,
    Completer<void>? cancel,
  });

  /// 取消当前进行中的生成（adapter 实现：本地引擎 stopGeneration / API stop）。
  void cancel() {}

  /// 绑定本次调用的能力快照（DSH `prepareCall` 端侧简化）。
  ///
  /// 默认实现：仅绑定 adapter + model。具体 adapter 可覆写以注入
  /// 加载时冻结的 [EngineCapabilities]（协议选择的依据）。
  PreparedLlmCall prepareCall(String model) =>
      PreparedLlmCall(adapter: this, model: model);
}