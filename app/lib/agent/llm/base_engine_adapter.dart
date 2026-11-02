/// 引擎 adapter 共享基类 —— 本地与 API 两条路线共用的取消、
/// 能力快照（prepareCall）与解析/错误归一化工具。
///
/// 两条路线差异仅在 [generate]：本地走 `InferenceService`，
/// API 走 `OpenAiService`。其余（取消竞跑、文本解析、错误归一化）共用。
///
/// 注意：Dart 的命名遮蔽（前导 `_`）是**按库（文件）**的，子类跨库
/// 无法访问基类私有成员。故供子类复用的状态与工具一律**公开**
/// （[currentSub] / [convertEngineMessages] / [parseAndResult] 等），
/// 仅内部私有字段（[protocol] / [capabilities]）保留 `_`。
library;

import 'dart:async';

import 'package:dio/dio.dart';

import '../../providers/agent_stream_processor.dart';
import 'adapter.dart';
import '../capability.dart';
import '../protocol/tool_protocol.dart';

abstract class BaseEngineAdapter implements LlmAdapter {
  final ToolProtocol _protocol;
  final EngineCapabilities? _capabilities;

  /// 当前进行中的流订阅（子类 [generate] 管理，[cancel] 统一中止）。
  /// dynamic：文本路线是 `StreamSubscription<String>`，API 原生工具路线是
  /// 结构化事件流订阅（`StreamSubscription<Map<String, dynamic>>`），
  /// 取消只需 `.cancel()`，无需元素类型。
  StreamSubscription<dynamic>? currentSub;

  /// 能力快照只读访问（子类协议路由用；Dart 私有按库隔离，
  /// 子类跨库读不到 `_capabilities`，故开只读门）。
  EngineCapabilities? get capabilities => _capabilities;

  BaseEngineAdapter({
    required ToolProtocol protocol,
    EngineCapabilities? capabilities,
  })  : _protocol = protocol,
        _capabilities = capabilities;

  /// 唯一实现点，由子类 [LocalEngineAdapter] / [OpenAiAdapter] 覆写。
  @override
  Future<LlmResult> generate(
    GenerateOptions options, {
    StreamController<String>? onToken,
    StreamController<String>? onThinking,
    Completer<void>? cancel,
  }) {
    throw UnimplementedError('子类须覆写 generate');
  }

  /// 取消当前进行中的生成（两条路线共用安全网：中止流订阅）。
  @override
  void cancel() {
    currentSub?.cancel();
    currentSub = null;
  }

  /// 绑定能力快照（Phase 3，DSH `prepareCall` 端侧简化）。
  /// 协议在调用准备时按能力驱动固化，避免运行中换模型导致协议不一致。
  @override
  PreparedLlmCall prepareCall(String model) =>
      PreparedLlmCall(adapter: this, model: model, capabilities: _capabilities);

  // ---------------------------------------------------------------------------
  // 共享工具（公开，供子类跨库调用）
  // ---------------------------------------------------------------------------

  /// 引擎消息转换（local 用）：助手剥除 tool_calls；tool 结果角色按模板
  /// 能力分流——Bailing V3（Ling 3.x）模板原生支持 role:tool（渲染为
  /// `<role>OBSERVATION</role>\n<tool_response>…`，贴合训练分布），其余
  /// 模板不识别 tool 角色（minja 渲染会**静默丢消息**）→ 保持 tool→user。
  List<Map<String, dynamic>> convertEngineMessages(
      List<Map<String, dynamic>> messages) {
    // 仅 Bailing V3 模板吃 role:tool（其 jinja 有 `message.role == "tool"`
    // 分支）；其余模板没有该分支，tool 消息会落不进任何渲染分支被丢弃。
    final keepToolRole = _capabilities?.toolTemplate == 'bailing-v3';
    final out = <Map<String, dynamic>>[];
    for (final m in messages) {
      final role = m['role'] as String?;
      final content = m['content'] as String? ?? '';
      if (role == 'tool') {
        out.add({'role': keepToolRole ? 'tool' : 'user', 'content': content});
      } else {
        // 文本协议从 response 文本解析，工具调用不入历史。
        out.add({'role': role, 'content': content});
      }
    }
    return out;
  }

  /// API 消息转换：'tool' 保留 role:tool（OpenAI 支持），助手剥除 tool_calls。
  List<Map<String, dynamic>> convertApiMessages(
      List<Map<String, dynamic>> messages) {
    final out = <Map<String, dynamic>>[];
    for (final m in messages) {
      final role = m['role'];
      final content = m['content'] as String? ?? '';
      out.add({'role': role, 'content': content});
    }
    return out;
  }

  /// 解析最终文本流 → [LlmResult]（两条路线共用）。
  ///
  /// 解析最终文本流 → [LlmResult]（两条路线共用）。
  ///
  /// 优先用 [AgentStreamProcessor.cleanText]（原始流去掉思考块、保留工具调用）
  /// 喂协议解析——而非原始流，否则 Qwen 的  think/response 思考块
  /// 会渗入 LlmResult.text，成为历史 assistant 内容，污染上下文、
  /// 把"思考内容"冒充回复并断开执行链。processor 未经流喂入（cleanText 空）
  /// 时退回 [rawBuffer]（测试桩/调用方自持缓冲的形态）。
  ///
  /// 空响应兜底（fail-loud）：流干净结束但既无文本也无工具调用时抛
  /// [LlmFailureCode.emptyResponse] 走失败瀑布——否则主循环会把空结果当
  /// "最终回答" 静默完成，UI 存一条空白消息（API 思考型模型推理耗尽
  /// max_tokens 时的真实形态）。
  Future<LlmResult> parseAndReturn(
      StringBuffer rawBuffer, AgentStreamProcessor processor) async {
    processor.finish();
    final clean = processor.cleanText;
    final text = clean.isEmpty ? rawBuffer.toString() : clean;
    final outcome =
        await _protocol.parseStream(Stream<String>.value(text));
    final result = LlmResult(text: outcome.text, toolCalls: outcome.toolCalls);
    if (result.text.trim().isEmpty && !result.hasToolCalls) {
      throw const LlmFailure(
        code: LlmFailureCode.emptyResponse,
        message: '模型返回空响应（无文本也无工具调用）',
      );
    }
    return result;
  }

  /// 流终态 vs cancel 竞跑；返回 true 表示 cancel 先行。
  Future<bool> race(Future done, Completer<void>? cancel) async {
    if (cancel == null) {
      await done;
      return false;
    }
    return await Future.any([
      done.then((_) => false),
      cancel.future.then((_) => true),
    ]);
  }

  /// 引擎（本地）错误归一化。
  LlmFailureCode mapEngineError(String msg) {
    final lower = msg.toLowerCase();
    if (lower.contains('context') ||
        lower.contains('上下文') ||
        lower.contains('context window') ||
        lower.contains('overflow')) {
      return LlmFailureCode.contextWindowExceeded;
    }
    if (lower.contains('timeout')) {
      return LlmFailureCode.timeout;
    }
    if (lower.contains('rate') || lower.contains('限流')) {
      return LlmFailureCode.rateLimit;
    }
    return LlmFailureCode.transport;
  }

  /// API 错误归一化（dio 异常）。4xx（除 429）为请求非法——确定性错误，
  /// 归 [LlmFailureCode.invalidRequest] 永久失败档（重试无意义）；
  /// 但 4xx 文案命中上下文溢出 → [LlmFailureCode.contextWindowExceeded]
  /// （走压缩瀑布，见 [mapApiStatus]）；429 → 限流，5xx → 服务端错误，均可重试。
  LlmFailureCode mapApiError(DioException e) {
    switch (e.type) {
      case DioExceptionType.connectionTimeout:
      case DioExceptionType.sendTimeout:
      case DioExceptionType.receiveTimeout:
        return LlmFailureCode.timeout;
      case DioExceptionType.badResponse:
        return mapApiStatus(
          e.response?.statusCode,
          message: friendlyApiError(e),
        );
      default:
        return LlmFailureCode.transport;
    }
  }

  /// 上下文溢出文案特征（小写匹配）。各主流 OpenAI 兼容端点措辞不一，
  /// 宁可窄勿宽——误判会把真正的参数错误送去压缩重试（必失败）。
  static const List<String> _contextOverflowPatterns = [
    'context length',
    'context_length',
    'context window',
    'maximum context',
    'max context length',
    'prompt is too long',
    'too many input tokens',
    'input tokens exceed',
    'reduce the length',
    '上下文长度',
    '上下文窗口',
    '超出上下文',
    '超过上下文',
  ];

  /// message 是否为上下文溢出类错误文案。
  static bool isContextOverflowMessage(String? message) {
    if (message == null || message.isEmpty) return false;
    final lower = message.toLowerCase();
    for (final p in _contextOverflowPatterns) {
      if (lower.contains(p)) return true;
    }
    return false;
  }

  /// 按 HTTP 状态码分档失败类别（[OpenAiHttpException] 与 dio 共用）。
  ///
  /// [message]：错误详情文案（含响应体时）。4xx 且文案命中上下文溢出
  /// （OpenAI/DeepSeek/Qwen 等的 "maximum context length is N tokens"）→
  /// 归 [LlmFailureCode.contextWindowExceeded]——失败瀑布第一步触发压缩、
  /// 压缩成功后有界重试；否则 4xx 归 invalidRequest（终态失败）。
  LlmFailureCode mapApiStatus(int? statusCode, {String? message}) {
    if (statusCode == 429) return LlmFailureCode.rateLimit;
    if (statusCode != null && statusCode >= 500) {
      return LlmFailureCode.server;
    }
    if (statusCode != null && statusCode >= 400) {
      if (isContextOverflowMessage(message)) {
        return LlmFailureCode.contextWindowExceeded;
      }
      return LlmFailureCode.invalidRequest;
    }
    return LlmFailureCode.transport;
  }

  String friendlyApiError(DioException e) {
    final code = e.response?.statusCode;
    final msg = e.response?.statusMessage ?? '';
    final reason = e.message ?? e.type.toString();
    if (code == 429) return 'API 限流（HTTP $code）：$msg';
    if (code != null && code >= 500) {
      return 'API 服务端错误（HTTP $code）：$msg';
    }
    return 'API 请求失败（HTTP ${code ?? ''}）：$reason';
  }
}
