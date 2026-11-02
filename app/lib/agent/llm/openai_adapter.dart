/// API adapter —— 包裹 [OpenAiService]（OpenAI 兼容接口）。
///
/// 双协议路由（能力驱动，对照 DSH `native-tools` / prompt-json）：
/// - **原生**（`capabilities.nativeToolCall == true` 且带工具）：工具 schema 走
///   请求体 `tools`，模型产出结构化 `delta.tool_calls`，由
///   [OpenAiNativeStreamAssembler] 流式组装——文本协议的解析降级/截断/
///   思考污染问题在此路径不存在。
/// - **文本**（无原生能力）：与本地路线同构，response 文本交给注入的
///   [ToolProtocol] 解析。
///
/// 失败归一化为 [LlmFailure]（事实，不含策略）；HTTP 状态码分档：
/// 429/5xx 瞬态可重试，4xx（除 429）为 invalidRequest 永久失败档。
library;

import 'dart:async';
import 'dart:convert';

import 'package:dio/dio.dart';
import 'package:flutter/foundation.dart';

import '../../models/api_model.dart';
import '../../providers/agent_stream_processor.dart';
import '../../services/openai_service.dart';
import 'adapter.dart';
import 'base_engine_adapter.dart';
import '../capability.dart';
import 'thinking_effort.dart';
import '../protocol/tool_protocol.dart';
import '../tool_definition.dart';

/// 把 [ToolDefinition] 列表渲染为 OpenAI function 工具 schema。
/// 工具 schema 按 name 排序后构建：请求体 tools 数组逐字节稳定，
/// 是 OpenAI 兼容服务端**前缀缓存命中**的前提（每 turn 重建 registry
/// 也不能让顺序漂移，否则缓存全失效、计费翻倍）。
List<Map<String, dynamic>> buildOpenAiToolsSchema(List<ToolDefinition> tools) {
  final sorted = [...tools]..sort((a, b) => a.name.compareTo(b.name));
  return sorted
      .map((t) => {
            'type': 'function',
            'function': {
              'name': t.name,
              'description': t.description,
              'parameters': t.parameters,
            },
          })
      .toList();
}

/// 把 [SessionLog.deriveModelMessages] 的中性消息翻译为 OpenAI 线格式。
///
/// 关键差异（相对文本路线的 convertApiMessages）：
/// - assistant 的 `tool_calls`（type:tool_call/function_name/arguments）翻译为
///   OpenAI `{id, type:'function', function:{name, arguments:JSON字符串}}`——
///   保留后 `role:'tool'` 消息才有配对锚点，严格服务端不再 400；
/// - `role:'tool'` 保留并携带 `tool_call_id`。
List<Map<String, dynamic>> toOpenAiWireMessages(
    List<Map<String, dynamic>> messages) {
  final out = <Map<String, dynamic>>[];
  for (final m in messages) {
    final role = m['role'] as String? ?? 'user';
    final content = m['content'] as String? ?? '';
    if (role == 'tool') {
      out.add({
        'role': 'tool',
        'tool_call_id': m['tool_call_id'] as String? ?? '',
        'content': content,
      });
      continue;
    }
    if (role == 'assistant') {
      final calls = m['tool_calls'] as List<dynamic>?;
      if (calls != null && calls.isNotEmpty) {
        final wire = <Map<String, dynamic>>[];
        for (final c in calls) {
          if (c is! Map<String, dynamic>) continue;
          final name = ((c['function_name'] ?? c['name']) as String?) ?? '';
          if (name.isEmpty) continue;
          final rawArgs = c['arguments'];
          final argsStr = rawArgs == null
              ? '{}'
              : (rawArgs is String ? rawArgs : jsonEncode(rawArgs));
          final id = c['id'] as String? ?? '';
          wire.add({
            // 缺 id 时用消息内序号兜底（服务端要求 id 在消息内可配对即可）。
            'id': id.isNotEmpty ? id : 'call_${wire.length}',
            'type': 'function',
            'function': {'name': name, 'arguments': argsStr},
          });
        }
        if (wire.isNotEmpty) {
          out.add({'role': 'assistant', 'content': content, 'tool_calls': wire});
          continue;
        }
      }
    }
    out.add({'role': role, 'content': content});
  }
  return out;
}

/// 把带 `imagePath` 的 user 消息转为 OpenAI content-parts（base64 image_url）。
///
/// [toOpenAiWireMessages] / [convertApiMessages] 均为 1:1 投影，[wire] 与
/// [messages] 按下标对齐；图片读取失败时跳过该条（降级为纯文本），不影响整轮。
/// 调用方须先确认端点 visionCapable，否则历史里的图片永不发出。
///
/// 多图（WP 多图上传）：`imagePaths` 全量发送（首张与 imagePath 重合时去重）。
Future<List<Map<String, dynamic>>> attachWireImages(
  List<Map<String, dynamic>> wire,
  List<Map<String, dynamic>> messages,
) async {
  for (var i = 0; i < wire.length && i < messages.length; i++) {
    final src = messages[i];
    if (src['role'] != 'user') continue;
    final paths = <String>[];
    final multi = src['imagePaths'];
    if (multi is List && multi.isNotEmpty) {
      paths.addAll(multi.map((e) => '$e'));
    }
    final single = src['imagePath'];
    if (paths.isEmpty && single is String && single.isNotEmpty) {
      paths.add(single);
    } else if (single is String &&
        single.isNotEmpty &&
        !paths.contains(single)) {
      paths.insert(0, single);
    }
    if (paths.isEmpty) continue;
    final parts = <Map<String, dynamic>>[];
    for (final p in paths) {
      final b64 = await OpenAiService.encodeImageFile(p);
      if (b64 == null) continue;
      parts.add({
        'type': 'image_url',
        'image_url': {'url': 'data:${OpenAiService.mimeForPath(p)};base64,$b64'},
      });
    }
    if (parts.isEmpty) continue;
    final content = wire[i]['content'];
    if (content is String && content.isNotEmpty) {
      parts.insert(0, {'type': 'text', 'text': content});
    }
    wire[i]['content'] = parts;
  }
  return wire;
}

/// 原生工具调用的流式分片组装器。
///
/// OpenAI 流式 tool_calls 按 `index` 分片到达：首片带 id/name，
/// `function.arguments` 是 JSON 字符串的增量分片（跨多片拼齐后整体解码）。
///
/// 思考通道：`reasoning_content`/`reasoning` 增量直入思考缓冲；
/// content 内嵌 `<think>…</think>` 块经字符状态机剥离（不进可见文本，
/// 也不进 LlmResult——否则思考污染历史上下文）。
class OpenAiNativeStreamAssembler {
  final StringBuffer _text = StringBuffer();
  final Map<int, _PendingNativeCall> _pending = {};
  String? finishReason;

  /// 末块 usage（{prompt_tokens, completion_tokens, ...}；服务端未带则 null）。
  Map<String, dynamic>? usage;

  // ---- 思考通道（reasoning 字段 + 内嵌 <think> 剥离）----
  final StringBuffer _thinking = StringBuffer();
  final StringBuffer _pendingTag = StringBuffer();
  bool _inThink = false;

  static const String _openTag = '<think>';
  static const String _closeTag = '</think>';

  String get textSoFar => _text.toString();
  String get thinkingSoFar => _thinking.toString();

  /// 原生 tool_calls 分片累计字符数（WP5 进度反馈：大参数工具调用
  /// 生长期可见文本为空，UI 靠这个数字显示"正在生成工具调用参数"）。
  int get pendingToolCallChars {
    var n = 0;
    for (final p in _pending.values) {
      n += p.args.length + p.id.length + (p.name?.length ?? 0);
    }
    return n;
  }

  /// 消费一条 [OpenAiService.chatCompletionEvents] 事件。
  void addEvent(Map<String, dynamic> event) {
    switch (event['type']) {
      case 'text':
        final t = event['text'];
        if (t is String && t.isNotEmpty) _addText(t);
        break;
      case 'thinking':
        final t = event['text'];
        if (t is String) _thinking.write(t);
        break;
      case 'usage':
        final u = event['usage'];
        if (u is Map<String, dynamic>) usage = u;
        break;
      case 'tool_call':
        final idx = (event['index'] as num?)?.toInt() ?? 0;
        final slot = _pending.putIfAbsent(idx, _PendingNativeCall.new);
        final id = event['id'];
        if (id is String && id.isNotEmpty) slot.id = id;
        final name = event['name'];
        if (name is String && name.isNotEmpty && slot.name == null) {
          slot.name = name;
        }
        final frag = event['argumentsFragment'];
        if (frag is String) slot.args.write(frag);
        break;
      case 'finish':
        final r = event['reason'];
        if (r is String) finishReason = r;
        break;
    }
  }

  /// content 增量 → 逐字符过 `<think>` 状态机（标签可跨分片）。
  void _addText(String t) {
    for (var i = 0; i < t.length; i++) {
      _addTextChar(t[i]);
    }
  }

  void _addTextChar(String ch) {
    if (_inThink) {
      _thinking.write(ch);
      final t = _thinking.toString();
      if (t.endsWith(_closeTag)) {
        // 闭合标签本身不算思考内容。
        _thinking
          ..clear()
          ..write(t.substring(0, t.length - _closeTag.length));
        _inThink = false;
      }
      return;
    }
    if (_pendingTag.isEmpty) {
      if (ch == '<') {
        _pendingTag.write(ch);
      } else {
        _text.write(ch);
      }
      return;
    }
    final candidate = _pendingTag.toString() + ch;
    if (_openTag.startsWith(candidate)) {
      _pendingTag
        ..clear()
        ..write(candidate);
      if (candidate == _openTag) {
        _pendingTag.clear();
        _inThink = true;
      }
      return;
    }
    // 猜错：把已缓冲的候选回退为普通文本（最后一个字符重判，可能是新标签起点）。
    _text.write(candidate.substring(0, candidate.length - 1));
    _pendingTag.clear();
    _addTextChar(ch);
  }

  /// 组装终态：文本 + 按 index 序排列的工具调用。
  ({String text, List<ToolCall> calls}) finalize() {
    // 流结束时残留的标签候选字符归还可见文本。
    _text.write(_pendingTag.toString());
    _pendingTag.clear();
    final indexes = _pending.keys.toList()..sort();
    final calls = <ToolCall>[];
    for (final idx in indexes) {
      final p = _pending[idx]!;
      Map<String, dynamic>? args;
      final raw = p.args.toString().trim();
      if (raw.isEmpty) {
        args = const {};
      } else {
        try {
          final decoded = jsonDecode(raw);
          if (decoded is Map<String, dynamic>) args = decoded;
        } catch (_) {
          // 分片拼齐后仍非法 JSON（服务端异常）→ args=null，
          // 交由执行前必填校验给出可读错误，模型可重试。
        }
      }
      calls.add(ToolCall(
        id: p.id.isNotEmpty ? p.id : 'call_${idx}_${DateTime.now().microsecondsSinceEpoch}',
        name: p.name ?? '',
        arguments: args,
      ));
    }
    return (text: _text.toString(), calls: calls);
  }
}

final class _PendingNativeCall {
  String id = '';
  String? name;
  final StringBuffer args = StringBuffer();
}

class OpenAiAdapter extends BaseEngineAdapter {
  final OpenAiService? _openAi;
  final ApiModelConfig? _apiModel;

  /// 思考失控守卫阈值（设置可调；默认 [kMaxThinkingChars]）。
  final int _maxThinkingChars;

  OpenAiAdapter({
    required ToolProtocol protocol,
    EngineCapabilities? capabilities,
    OpenAiService? openAi,
    ApiModelConfig? apiModel,
    int maxThinkingChars = kMaxThinkingChars,
  })  : _openAi = openAi,
        _apiModel = apiModel,
        _maxThinkingChars = maxThinkingChars,
        super(protocol: protocol, capabilities: capabilities);

  /// 取消：先中止 Dart 侧流（基类），再取消 API SSE 请求。
  @override
  void cancel() {
    super.cancel();
    _openAi?.stop();
  }

  @override
  Future<LlmResult> generate(
    GenerateOptions options, {
    StreamController<String>? onToken,
    StreamController<String>? onThinking,
    Completer<void>? cancel,
  }) async {
    if (_openAi == null || _apiModel == null) {
      throw LlmFailure(
        code: LlmFailureCode.noAdapter,
        message: 'API 路线未配置（未注入 OpenAiService / 模型配置）',
      );
    }
    // 能力驱动双路由：原生工具调用（API）优先，文本协议兜底。
    final useNative =
        (capabilities?.nativeToolCall ?? false) && options.tools.isNotEmpty;
    if (useNative) {
      return _generateNative(options,
          onToken: onToken, onThinking: onThinking, cancel: cancel);
    }
    return _generateTextProtocol(options,
        onToken: onToken, onThinking: onThinking, cancel: cancel);
  }

  /// 原生工具调用路径：tools 进请求体，tool_calls 结构化组装。
  Future<LlmResult> _generateNative(
    GenerateOptions options, {
    StreamController<String>? onToken,
    StreamController<String>? onThinking,
    Completer<void>? cancel,
  }) async {
    final openAi = _openAi!;
    final model = _apiModel!;
    final wireMessages = toOpenAiWireMessages(options.messages);
    // 视觉：带 imagePath 的 user 消息转 content-parts（visionCapable 才发）。
    if (model.visionCapable) {
      await attachWireImages(wireMessages, options.messages);
    }
    final tools = buildOpenAiToolsSchema(options.tools);
    final assembler = OpenAiNativeStreamAssembler();
    // 流终态（null=干净完成，非 null=错误）。
    final outcome = Completer<Object?>();
    StreamSubscription<Map<String, dynamic>>? sub;
    bool _streamFinished = false;
    void _finishStream(Object? err) {
      if (_streamFinished) return;
      _streamFinished = true;
      outcome.complete(err);
    }

    try {
      // 思考失控守卫（local/API 同规）：累计思考超预算且尚无产出 → 停 SSE 止损。
      var _thinkingOverflow = false;
      var _thinkingCharsAtTrigger = 0;
      // WP5：API 路线工具调用以原生 tool_calls 分片到达（reasoning 内容在
      // assembler 思考通道），工具参数生长期 assembler 文本为空——
      // 用思考通道+分片累计长度合成提示，避免 UI 干转圈。
      var _toolGenActive = false;
      sub = openAi.chatCompletionEvents(
        config: model,
        messages: wireMessages,
        tools: tools,
        temperature: options.temperature,
        maxTokens: options.maxTokens ?? 512,
        extraBody: _thinkingFields(options.maxTokens ?? 512),
      ).listen(
        (event) {
          assembler.addEvent(event);
          if (onToken != null) {
            onToken.add(assembler.textSoFar);
          }
          if (onThinking != null) {
            onThinking.add(assembler.thinkingSoFar);
          }
          if (!_thinkingOverflow &&
              assembler.thinkingSoFar.length > _maxThinkingChars &&
              assembler.textSoFar.trim().length <
                  AgentStreamProcessor.kMinUsefulChars &&
              assembler.pendingToolCallChars == 0) {
            _thinkingOverflow = true;
            _thinkingCharsAtTrigger = assembler.thinkingSoFar.length;
            openAi.stop();
          }
          if (options.onStatus != null) {
            final pendingFrag = assembler.pendingToolCallChars;
            if (pendingFrag > 0) {
              _toolGenActive = true;
              options.onStatus!.add('toolgen|$pendingFrag|');
            } else if (_toolGenActive) {
              _toolGenActive = false;
              options.onStatus!.add('toolgen|0|');
            }
          }
        },
        onError: (Object e, [StackTrace? s]) {
          // async 生成器出错不关流 → 显式取消并标记完成。
          sub?.cancel();
          _finishStream(e);
        },
        onDone: () => _finishStream(null),
      );
      currentSub = sub;
      if (await race(outcome.future, cancel)) {
        throw const AgentCancelledException();
      }
      // 思考失控先于错误判定：stop() 会以 cancel 错误收场，若先走 error
      // 分支会归为 transport（可重试）→ 失控思考被重试 5 遍。
      if (_thinkingOverflow) {
        // 先抢救再判死：止损前已产出的正文/工具调用照样交付。
        final salvaged = assembler.finalize();
        if (salvaged.text.trim().isNotEmpty || salvaged.calls.isNotEmpty) {
          debugPrint('[AgentLlm] API 原生路线思考失控已止损'
              '（累计 $_thinkingCharsAtTrigger 字），已有产出 → 照常返回');
          return LlmResult(
            text: salvaged.text,
            toolCalls: salvaged.calls,
            usage: assembler.usage,
          );
        }
        throw LlmFailure(
          code: LlmFailureCode.thinkingOverflow,
          message: '思考失控：已累计思考 $_thinkingCharsAtTrigger 字仍无任何产出，'
              '已主动中止（阈值 $_maxThinkingChars 字）。'
              '本次自动改用「不思考」重试一次；若频繁出现，'
              '请在 设置→智能体 调大「思考失控守卫阈值」',
        );
      }
      final error = await outcome.future;
      if (error != null) {
        final f = _normalizeStreamError(error);
        if (f.code == LlmFailureCode.invalidRequest) {
          // 请求体带 tools 被服务端拒收：端点很可能不支持 function calling。
          // fail-loud + 明确指引，不静默降级文本协议（会产生解析降级新问题）。
          throw LlmFailure(
            code: f.code,
            message: '${f.message}'
                '（当前端点可能不支持 tools/function calling，'
                '请检查 API 服务是否支持原生工具调用）',
          );
        }
        throw f;
      }
      final r = assembler.finalize();
      if (r.text.trim().isEmpty && r.calls.isEmpty) {
        // 空响应 fail-loud：推理耗尽 max_tokens（finish=length）等场景，
        // 不能当"最终回答"静默完成。
        throw LlmFailure(
          code: LlmFailureCode.emptyResponse,
          message: assembler.finishReason == null
              ? '模型返回空响应（无文本也无工具调用）'
              : '模型返回空响应（finish_reason=${assembler.finishReason}）',
        );
      }
      return LlmResult(text: r.text, toolCalls: r.calls, usage: assembler.usage);
    } on AgentCancelledException catch (e) {
      rethrow;
    } on LlmFailure catch (e) {
      rethrow;
    } catch (e) {
      throw LlmFailure(
        code: LlmFailureCode.transport,
        message: 'API 调用失败: $e',
      );
    } finally {
      sub?.cancel();
      if (identical(sub, currentSub)) {
        currentSub = null;
      }
    }
  }

  /// 文本协议路径（与本地路线同构）：response 文本交给注入协议解析。
  Future<LlmResult> _generateTextProtocol(
    GenerateOptions options, {
    StreamController<String>? onToken,
    StreamController<String>? onThinking,
    Completer<void>? cancel,
  }) async {
    final openAi = _openAi!;
    final model = _apiModel!;
    // 文本路线：'tool' 保留 role:tool（部分服务端宽容处理），助手剥除 tool_calls。
    final apiMessages = convertApiMessages(options.messages);
    // 视觉：带 imagePath 的 user 消息转 content-parts（visionCapable 才发）。
    if (model.visionCapable) {
      await attachWireImages(apiMessages, options.messages);
    }
    final rawBuffer = StringBuffer();
    final processor = AgentStreamProcessor();
    // 思考失控守卫标志（同原生路线；口径用 thinkingRunaway = 跨块累计 + 无产出）。
    var _thinkingOverflow = false;
    var _thinkingCharsAtTrigger = 0;
    // 流终态（null=干净完成，非 null=错误）。
    final outcome = Completer<Object?>();
    StreamSubscription<String>? sub;
    bool _streamFinished = false;
    void _finishStream(Object? err) {
      if (_streamFinished) return;
      _streamFinished = true;
      outcome.complete(err);
    }

    try {
      sub = openAi.chatCompletion(
        config: model,
        messages: apiMessages,
        temperature: options.temperature,
        maxTokens: options.maxTokens ?? 512,
        extraBody: _thinkingFields(options.maxTokens ?? 512),
      ).listen(
        (token) {
          if (token.isEmpty) return;
          rawBuffer.write(token);
          processor.add(token);
          if (onToken != null) {
            onToken!.add(processor.visibleText);
          }
          if (onThinking != null) {
            onThinking!.add(processor.thinkingText);
          }
          if (!_thinkingOverflow &&
              processor.thinkingRunaway(_maxThinkingChars)) {
            _thinkingOverflow = true;
            _thinkingCharsAtTrigger = processor.thinkingCharsSoFar;
            openAi.stop();
          }
        },
        onError: (Object e, [StackTrace? s]) {
          // async 生成器出错不关流 → 显式取消并标记完成。
          sub?.cancel();
          _finishStream(e);
        },
        onDone: () => _finishStream(null),
      );
      currentSub = sub;
      if (await race(outcome.future, cancel)) {
        throw const AgentCancelledException();
      }
      // 思考失控先于错误判定（stop() 以 cancel 收场，别让它进可重试档）。
      if (_thinkingOverflow) {
        // 先抢救再判死：止损前已产出的工具调用/答案照样有效。
        if (processor.hasToolCalls ||
            processor.visibleText.trim().length >=
                AgentStreamProcessor.kMinUsefulChars) {
          debugPrint('[AgentLlm] API 文本路线思考失控已止损'
              '（累计 $_thinkingCharsAtTrigger 字），已有产出 → 照常返回');
          return parseAndReturn(rawBuffer, processor);
        }
        throw LlmFailure(
          code: LlmFailureCode.thinkingOverflow,
          message: '思考失控：已累计思考 $_thinkingCharsAtTrigger 字仍无任何产出，'
              '已主动中止（阈值 $_maxThinkingChars 字）。'
              '本次自动改用「不思考」重试一次；若频繁出现，'
              '请在 设置→智能体 调大「思考失控守卫阈值」',
        );
      }
      final error = await outcome.future;
      if (error != null) {
        throw _normalizeStreamError(error);
      }
      return parseAndReturn(rawBuffer, processor);
    } on AgentCancelledException catch (e) {
      rethrow;
    } on DioException catch (e) {
      throw LlmFailure(code: mapApiError(e), message: friendlyApiError(e));
    } catch (e) {
      throw LlmFailure(
        code: LlmFailureCode.transport,
        message: 'API 调用失败: $e',
      );
    } finally {
      sub?.cancel();
      if (identical(sub, currentSub)) {
        currentSub = null;
      }
    }
  }

  /// 该端点的思考强度请求字段（档位=不干预时返回空 → 一个字段都不发）。
  ///
  /// 族优先取用户在设置里钉死的覆盖值，其次按模型名/端点自动探测；映射表是
  /// [thinkingWireFields] 这个纯函数（一族一字段，越界字段由测试当场拦）。
  /// 严格端点不认时由 [OpenAiService.bodyWithoutRejectedFields] 去掉重发——
  /// 丢档位可以，整条请求不能失败。
  Map<String, dynamic> _thinkingFields(int? maxTokens) {
    final cfg = _apiModel;
    if (cfg == null) return const {};
    final effort = thinkingEffortFromKey(cfg.thinkingEffort);
    if (effort == ThinkingEffort.passthrough) return const {};
    final family = thinkingFamilyFromKey(cfg.thinkingFamily) ??
        detectThinkingFamily(cfg.model, baseUrl: cfg.baseUrl);
    final fields = thinkingWireFields(
      effort: effort,
      family: family,
      maxTokens: maxTokens ?? cfg.effectiveMaxTokens,
    );
    if (fields.isNotEmpty) {
      debugPrint('[AgentLlm] 思考档位 ${cfg.model} '
          '族=${family.name} ${thinkingEffortLabel(effort)} → $fields');
    }
    return fields;
  }

  /// 流错误 → [LlmFailure]：[OpenAiHttpException]（携带状态码）按状态分档，
  /// message 含响应体详情（溢出文案在此 → contextWindowExceeded 走压缩瀑布）；
  /// SSE 停摆归 timeout 档；dio 异常走 [mapApiError]，其余归 transport。
  LlmFailure _normalizeStreamError(Object error) {
    if (error is OpenAiHttpException) {
      return LlmFailure(
        code: mapApiStatus(error.statusCode, message: error.message),
        message: error.message,
      );
    }
    // 端点停摆（连接后长时间零数据，网关挂起）→ timeout：可重试档，
    // 失败瀑布有限重试 + UI 重试横幅，不再表现为无限"思考中"。
    if (error is OpenAiStallException) {
      return LlmFailure(
          code: LlmFailureCode.timeout, message: error.toString());
    }
    if (error is DioException) {
      return LlmFailure(
        code: mapApiError(error),
        message: friendlyApiError(error),
      );
    }
    return LlmFailure(code: LlmFailureCode.transport, message: '$error');
  }
}
