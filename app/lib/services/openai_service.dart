// ============================================================
// OpenAI-compatible remote inference service.
//
// Implements the standard OpenAI `chat/completions` (SSE streaming)
// protocol over dio, so any OpenAI-compatible endpoint (OpenAI 官方、
// 本地 llama.cpp server、vLLM 等) can serve as a remote model fallback.
// The chat layer routes to this service ONLY when the local model is
// unavailable (local-first policy), and consumes a Stream<String> that
// mirrors the local engine's token stream.
// ============================================================

import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:dio/dio.dart';

import '../models/api_model.dart';
import '../models/chat_message.dart';

/// OpenAI 兼容端点的 HTTP/网络异常（携带状态码，供失败归一化分档）。
///
/// 4xx（除 429）是确定性错误（参数/鉴权/路由），重试无意义；
/// 429/5xx 是瞬态错误。状态码随异常携带，adapter 才能可靠分档。
class OpenAiHttpException implements Exception {
  final int? statusCode;
  final String message;

  OpenAiHttpException({this.statusCode, required this.message});

  @override
  String toString() => message;
}

/// SSE 流停摆异常：连接建立后连续 [idle] 未收到任何数据（含心跳）。
///
/// 典型成因是中转/网关把请求挂住不回包（真机实测：端点 13 分钟零字节，
/// 回合表面"思考中"实为无限等待）。抛出后由 adapter 归一化为
/// [LlmFailureCode.timeout]（可重试档），UI 出现重试横幅而非无限转圈。
class OpenAiStallException implements Exception {
  final Duration idle;
  const OpenAiStallException(this.idle);

  @override
  String toString() =>
      '端点停摆：${idle.inSeconds}s 未收到任何响应数据（连接可能已被网关挂起）';
}

/// OpenAI 兼容远程推理服务。密钥明文由配置持有，此处仅用于请求头。
class OpenAiService {
  OpenAiService({Dio? dio, Duration? stallIdle})
      : _dio = dio ??
            Dio(BaseOptions(
              // 连接/发送必须有界：DNS/握手挂起不能拖死整个智能体回合。
              // 接收侧不设全局 receiveTimeout（长生成合法），流式空闲由
              // [_sseStallIdle] 看门狗单独守护（见 _sseDataPayloads）。
              connectTimeout: const Duration(seconds: 20),
              sendTimeout: const Duration(seconds: 30),
            )),
        _stallIdle = stallIdle ?? _sseStallIdle;

  final Dio _dio;

  /// 流式空闲看门狗阈值：连续这么久没收到任何 SSE 数据（含心跳/注释行）
  /// 判定端点停摆。慢流合法（每个 chunk 重置计时），只拦"彻底没数据"。
  static const Duration _sseStallIdle = Duration(seconds: 120);

  /// 实际生效的看门狗阈值（可注入缩短，供回归测试）。
  final Duration _stallIdle;

  /// 当前流式请求的取消令牌，用于「停止生成」。
  CancelToken? _cancelToken;

  /// 最近一次流式请求末尾的 usage（{prompt_tokens, completion_tokens, ...}）。
  /// 由底层 SSE 通道统一收集，供普通聊天路径（chatCompletion 只 yield 文本、
  /// 不透传 usage）读取上下文占用；服务端未带则保持 null。
  Map<String, dynamic>? lastUsage;

  /// 归一化 chat/completions 端点：
  /// - 去首尾空白、去尾部斜杠；
  /// - 若用户已带 `/chat/completions` 则不重复拼接。
  static String normalizeChatUrl(String baseUrl) {
    var url = baseUrl.trim();
    while (url.endsWith('/')) {
      url = url.substring(0, url.length - 1);
    }
    if (url.endsWith('/chat/completions')) return url;
    return '$url/chat/completions';
  }

  Map<String, String> _headers(String apiKey) {
    return {
      'Accept': 'text/event-stream',
      'Content-Type': 'application/json',
      if (apiKey.isNotEmpty) 'Authorization': 'Bearer $apiKey',
    };
  }

  /// 发起流式 chat/completions，返回增量文本流（与本地接口同形）。
  ///
  /// [messages] 为 OpenAI 消息数组。纯文本消息形如 `{role, content}`；
  /// 带图消息（当 API 支持视觉）为 content-parts 形式：
  /// ```
  /// {"role": "user", "content": [
  ///   {"type": "text", "text": "..."},
  ///   {"type": "image_url", "image_url": {"url": "data:image/jpeg;base64,..."}}
  /// ]}
  /// ```
  /// 网络/鉴权/解析失败时抛出可读中文 [Exception]，由调用方兜底。
  Stream<String> chatCompletion({
    required ApiModelConfig config,
    required List<Map<String, dynamic>> messages,
    double? temperature,
    int? maxTokens,
    Map<String, dynamic>? extraBody,
  }) async* {
    await for (final payload in _sseDataPayloads(
      config: config,
      messages: messages,
      temperature: temperature,
      maxTokens: maxTokens,
      extraBody: extraBody,
    )) {
      if (payload == '[DONE]') break;
      try {
        final json = jsonDecode(payload) as Map<String, dynamic>;
        final choices = json['choices'] as List?;
        if (choices == null || choices.isEmpty) continue;
        final first = choices.first;
        if (first is! Map<String, dynamic>) continue;
        final delta = first['delta'];
        final content =
            (delta is Map<String, dynamic>) ? delta['content'] : null;
        if (content is String && content.isNotEmpty) {
          yield content;
        }
      } catch (_) {
        // 忽略无法解析的行（心跳/注释/不完整 JSON），继续下一行。
      }
    }
  }

  /// 发起流式 chat/completions，返回**结构化增量事件流**（原生工具调用用）。
  ///
  /// 事件形如：
  /// - `{'type': 'text', 'text': ...}` —— content 增量；
  /// - `{'type': 'tool_call', 'index': int, 'id': String?, 'name': String?,
  ///    'argumentsFragment': String?}` —— `delta.tool_calls` 增量分片
  ///    （arguments 是 JSON 字符串分片，须按 index 拼齐后整体 jsonDecode）；
  /// - `{'type': 'finish', 'reason': String}` —— finish_reason
  ///    （stop / length / tool_calls…）。
  ///
  /// [tools] 为 OpenAI function 工具 schema（`{type:'function', function:{…}}`）；
  /// 传入后请求体带 `tools` 字段，模型才能产出原生 tool_calls。
  Stream<Map<String, dynamic>> chatCompletionEvents({
    required ApiModelConfig config,
    required List<Map<String, dynamic>> messages,
    List<Map<String, dynamic>>? tools,
    double? temperature,
    int? maxTokens,
    Map<String, dynamic>? extraBody,
  }) async* {
    await for (final payload in _sseDataPayloads(
      config: config,
      messages: messages,
      tools: tools,
      temperature: temperature,
      maxTokens: maxTokens,
      extraBody: extraBody,
    )) {
      if (payload == '[DONE]') break;
      Map<String, dynamic> json;
      try {
        final decoded = jsonDecode(payload);
        if (decoded is! Map<String, dynamic>) continue;
        json = decoded;
      } catch (_) {
        continue; // 心跳/注释/不完整 JSON
      }
      final choices = json['choices'] as List?;
      // usage 末块（include_usage 开启后服务端在流末发 choices:[] + usage）：
      // 下游（assembler/上下文占用条）要消费它，choices 空时也要 yield 出去。
      if (choices == null || choices.isEmpty) {
        final usage = json['usage'];
        if (usage is Map<String, dynamic>) {
          yield {'type': 'usage', 'usage': usage};
        }
        continue;
      }
      final first = choices.first;
      if (first is! Map<String, dynamic>) continue;
      final delta = first['delta'];
      if (delta is Map<String, dynamic>) {
        final content = delta['content'];
        if (content is String && content.isNotEmpty) {
          yield {'type': 'text', 'text': content};
        }
        // 思考增量（DeepSeek/Qwen 兼容端 reasoning_content；OpenRouter 端
        // reasoning）。不产出则思考型模型长推理期间 UI 无任何反馈。
        final reasoning = delta['reasoning_content'] ?? delta['reasoning'];
        if (reasoning is String && reasoning.isNotEmpty) {
          yield {'type': 'thinking', 'text': reasoning};
        }
        final calls = delta['tool_calls'];
        if (calls is List) {
          for (final c in calls) {
            if (c is! Map<String, dynamic>) continue;
            final fn = c['function'];
            yield {
              'type': 'tool_call',
              'index': (c['index'] as num?)?.toInt() ?? 0,
              'id': c['id'] is String ? c['id'] : null,
              'name': fn is Map<String, dynamic> ? fn['name'] : null,
              'argumentsFragment':
                  fn is Map<String, dynamic> ? fn['arguments'] : null,
            };
          }
        }
      }
      final reason = first['finish_reason'];
      if (reason is String && reason.isNotEmpty) {
        yield {'type': 'finish', 'reason': reason};
      }
      // token 用量（OpenAI/DeepSeek 兼容端在末块携带 usage；无则跳过）。
      final usage = json['usage'];
      if (usage is Map<String, dynamic>) {
        yield {'type': 'usage', 'usage': usage};
      }
    }
  }

  /// 共享 SSE 通道：发起请求并产出 `data:` 载荷行（不含 `data:` 前缀）。
  ///
  /// HTTP/网络错误抛 [OpenAiHttpException]（携带状态码，供 adapter 分档）。
  /// 严格端点 400 兜底：报错点名某个**可选**字段时，去掉它给一份可重发的 body；
  /// 无可去掉的东西返回 null（调用方按原样抛错）。
  ///
  /// 为什么值得单独抽出来：思考强度字段（reasoning_effort / thinking /
  /// thinking_config / enable_thinking / chat_template_kwargs）是**按族发**的，
  /// 族判错时不能让整条 API 智能体不可用——丢档位可以，丢请求不行。
  static Map<String, dynamic>? bodyWithoutRejectedFields(
      Map<String, dynamic> body, String detail) {
    final msg = detail.toLowerCase();
    final drop = <String>[];
    if (body.containsKey('stream_options') &&
        (msg.contains('stream_options') || msg.contains('include_usage'))) {
      drop.add('stream_options');
    }
    const thinkingKeys = [
      'reasoning_effort',
      'thinking',
      'thinking_config',
      'thinking_budget',
      'enable_thinking',
      'chat_template_kwargs',
    ];
    // 点名任一思考字段，或只说 unknown parameter / extra fields not permitted
    // 这类不点名的报错：把**整组**思考字段去掉。理由：它们出自同一次族映射，
    // 端点拒了一个就说明它不讲这一族方言，留半个只会再撞一次 400。
    // （stream_options 更基础，不因泛化报错被顺带丢掉。）
    bool namedThinking = false;
    for (final k in thinkingKeys) {
      if (body.containsKey(k) && msg.contains(k)) {
        namedThinking = true;
        break;
      }
    }
    final generic = msg.contains('unknown parameter') ||
        msg.contains('unrecognized') ||
        msg.contains('extra fields') ||
        msg.contains('not permitted') ||
        msg.contains('unexpected parameter') ||
        msg.contains('invalid parameter');
    if (namedThinking) {
      drop.addAll(thinkingKeys.where((k) => body.containsKey(k)));
    } else if (drop.isEmpty && generic) {
      // 已点名 stream_options 时不做这步：先只去掉被点名的那个，最小改动优先
      // （同时去掉思考档位会白丢用户配的档位，且只有一次重试机会）。
      drop.addAll(thinkingKeys.where((k) => body.containsKey(k)));
    }
    if (drop.isEmpty) return null;
    return Map<String, dynamic>.from(body)
      ..removeWhere((k, _) => drop.contains(k));
  }

  Stream<String> _sseDataPayloads({
    required ApiModelConfig config,
    required List<Map<String, dynamic>> messages,
    List<Map<String, dynamic>>? tools,
    double? temperature,
    int? maxTokens,
    Map<String, dynamic>? extraBody,
  }) async* {
    // 中断上一轮（若存在），并为本轮创建新令牌。
    _cancelToken?.cancel();
    _cancelToken = CancelToken();

    final url = normalizeChatUrl(config.baseUrl);
    final body = <String, dynamic>{
      'model': config.model,
      'messages': messages,
      'stream': true,
      // OpenAI 兼容标准：要求末块回 usage（prompt_tokens 等）。vLLM/SGLang 等
      // 端点流式默认**不回 usage**，不带上它 lastUsage（顶部上下文占用条数据源）
      // 永远为 null（2026-10-03 Bonsai2 端点实测实锤）。严格端点不认识该字段
      // 时的 400/422 兜底重试见下方 catch。
      'stream_options': const {'include_usage': true},
      'temperature': temperature ?? config.effectiveTemperature,
      'max_tokens': maxTokens ?? config.effectiveMaxTokens,
      if (tools != null && tools.isNotEmpty) 'tools': tools,
      // 思考强度档位等端点专属字段（一族一字段，见 thinking_effort.dart）；
      // 族判错时由下方 400 兜底整组去掉重发。
      if (extraBody != null) ...extraBody,
    };

    Future<Response<ResponseBody>> post(Map<String, dynamic> b) =>
        _dio.post<ResponseBody>(
          url,
          data: b,
          options: Options(
            responseType: ResponseType.stream,
            headers: _headers(config.apiKey),
          ),
          cancelToken: _cancelToken,
        );

    Response<ResponseBody> response;
    try {
      response = await post(body);
    } on DioException catch (e) {
      final status = e.response?.statusCode;
      final optionalFieldStatus = status == 400 || status == 404 || status == 422;
      final detail = optionalFieldStatus ? await _describeApiError(e) : '';
      // 端点不认可选字段（stream_options / 思考参数）→ 去掉再试一次：
      // 宁可丢 usage、丢思考档位，也不能让整个请求失败。
      final retryBody =
          optionalFieldStatus ? bodyWithoutRejectedFields(body, detail) : null;
      if (retryBody != null) {
        try {
          response = await post(retryBody);
        } on DioException catch (e2) {
          throw OpenAiHttpException(
            statusCode: e2.response?.statusCode,
            message: await _describeApiError(e2),
          );
        }
      } else if (optionalFieldStatus) {
        throw OpenAiHttpException(statusCode: status, message: detail);
      } else {
        throw OpenAiHttpException(
          statusCode: e.response?.statusCode,
          message: await _describeApiError(e),
        );
      }
    }

    if (response.statusCode != 200) {
      throw OpenAiHttpException(
        statusCode: response.statusCode,
        message: 'API 请求失败：HTTP ${response.statusCode}',
      );
    }

    // 逐行解析 SSE：data: {json} ... data: [DONE]
    // dio 流式响应：response.data 是 ResponseBody，其 .stream 为字节流。
    final byteStream = response.data?.stream ?? const Stream<Uint8List>.empty();
    final lines = utf8.decoder.bind(byteStream).transform(const LineSplitter());
    // 停摆看门狗：`Stream.timeout` 监听**两个事件之间**的静默时长，超限
    // 即向流注入 [OpenAiStallException]（await for 处抛出、上游订阅随之
    // 取消）。慢流合法——每个 chunk 到达都会重置计时；只拦"彻底没数据"。
    final guarded = lines.timeout(
      _stallIdle,
      onTimeout: (sink) => sink.addError(OpenAiStallException(_stallIdle)),
    );

    try {
      await for (final rawLine in guarded) {
      final line = rawLine.trim();
      if (!line.startsWith('data:')) continue;
      final payload = line.substring(5).trim();
      if (payload.isEmpty) continue;
      // 统一收集末块 usage（OpenAI/DeepSeek/llama.cpp 兼容端在末块携带），
      // 供普通聊天路径读取上下文占用；无 usage 块则保持上次值。
      if (payload != '[DONE]') {
        try {
          final parsed = jsonDecode(payload) as Map<String, dynamic>;
          final usage = parsed['usage'];
          if (usage is Map<String, dynamic>) {
            lastUsage = usage;
            assert(() {
              // ignore: avoid_print
              print('[SSE] usage captured: prompt_tokens='
                  '${usage['prompt_tokens']}');
              return true;
            }());
          }
        } catch (_) {
          // 非 JSON 载荷（心跳/注释）忽略。
        }
      }
      yield payload;
      }
    } on OpenAiStallException {
      // 主动掐断挂死的连接（上游订阅已随 await for 抛错取消，CancelToken
      // 兜底确保底层 socket 关闭），异常原样上抛 → adapter 归一化为
      // timeout 档 → 失败瀑布有界重试。
      _cancelToken?.cancel('sse stall');
      rethrow;
    }
  }

  /// 测试连接：发一个最小的非流式 chat/completions（max_tokens=1），
  /// 校验 baseUrl / apiKey / model 是否可用。
  ///
  /// 返回 null 表示成功；否则返回可读中文错误信息。
  Future<String?> testConnection(ApiModelConfig config) async {
    final url = normalizeChatUrl(config.baseUrl);
    final body = <String, dynamic>{
      'model': config.model,
      'messages': [
        {'role': 'user', 'content': 'ping'},
      ],
      'stream': false,
      'max_tokens': 1,
    };
    try {
      final response = await _dio.post<Map<String, dynamic>>(
        url,
        data: body,
        options: Options(
          responseType: ResponseType.json,
          headers: _headers(config.apiKey),
        ),
      );
      if (response.statusCode != 200) {
        return 'HTTP ${response.statusCode}';
      }
      final choices = response.data?['choices'];
      if (choices is List && choices.isNotEmpty) {
        return null; // 成功
      }
      return '响应缺少 choices';
    } on DioException catch (e) {
      return _friendlyDioError(e);
    }
  }

  /// 停止当前流式生成（中断 SSE 请求）。
  void stop() {
    _cancelToken?.cancel();
  }

  /// 把聊天历史（含图片）构建成 OpenAI 消息数组。
  ///
  /// [visionCapable] 为 true 时，带图用户消息转成 content-parts（base64 image_url）；
  /// 为 false 时图片被剥离为纯文本（content 空则用 `[图片]` 占位符），
  /// 保证不支持视觉的 API 永不收到原始图片数据（历史会话安全）。
  ///
  /// 单个图片读取失败时降级为纯文本，不影响整轮生成。
  static Future<List<Map<String, dynamic>>> buildMessages(
    List<ChatMessage> history, {
    required bool visionCapable,
  }) async {
    final messages = <Map<String, dynamic>>[];

    for (final msg in history) {
      if (msg.role != MessageRole.user) {
        if (msg.content.isNotEmpty) {
          messages.add({'role': 'assistant', 'content': msg.content});
        }
        continue;
      }

      // 仅当 API 支持视觉时，才尝试把图片 base64 编码为 image_url part。
      // 模型视图优先：visionPaths（长图切块序列）> imagePaths（原图）。
      // 切片是临时产物（7 天保留），历史消息重发时若切片文件已被清理，
      // 回退原图（服务端自有压缩，好过丢图）。
      final paths = <String>[];
      if (visionCapable) {
        final vision = msg.visionPaths;
        if (vision != null && vision.isNotEmpty) {
          paths.addAll(vision.where((p) => File(p).existsSync()));
          if (paths.isEmpty && msg.imagePaths != null) {
            paths.addAll(msg.imagePaths!);
          }
        } else if (msg.imagePaths != null) {
          paths.addAll(msg.imagePaths!);
        }
        // imagePath 仅在两个列表都为空的历史行里兜底补入（模型视图有值时
        // 绝不把原图再塞回去——imagePath 属用户视图）。
        if (msg.imagePath != null &&
            msg.imagePath!.isNotEmpty &&
            paths.isEmpty &&
            (msg.imagePaths == null || msg.imagePaths!.isEmpty) &&
            (msg.visionPaths == null || msg.visionPaths!.isEmpty)) {
          paths.insert(0, msg.imagePath!);
        }
      }

      final parts = <Map<String, dynamic>>[];
      for (final p in paths) {
        final b64 = await encodeImageFile(p);
        if (b64 == null) continue;
        parts.add({
          'type': 'image_url',
          'image_url': {
            'url': 'data:${mimeForPath(p)};base64,$b64',
          },
        });
      }

      if (parts.isNotEmpty) {
        if (msg.content.isNotEmpty) {
          parts.insert(0, {'type': 'text', 'text': msg.content});
        }
        messages.add({'role': 'user', 'content': parts});
      } else {
        // 无图 / 不支持视觉 / 读取失败 → 纯文本；空内容用占位符，让模型知道此处有图。
        messages.add({
          'role': 'user',
          'content': msg.content.isNotEmpty ? msg.content : '[图片]',
        });
      }
    }
    return messages;
  }

  /// 按扩展名给出图片 MIME（长图切块产物为 PNG，误标 jpeg 会被严格服务端拒收）。
  static String mimeForPath(String path) {
    final lower = path.toLowerCase();
    if (lower.endsWith('.png')) return 'image/png';
    if (lower.endsWith('.webp')) return 'image/webp';
    if (lower.endsWith('.gif')) return 'image/gif';
    if (lower.endsWith('.bmp')) return 'image/bmp';
    return 'image/jpeg';
  }

  /// 图片 base64 编码（带缓存：agent 每个 step 重放历史会重复编码同一图）。
  static Future<String?> encodeImageFile(String path) async {
    final cached = _imageB64Cache[path];
    if (cached != null) return cached;
    try {
      final file = File(path);
      if (!await file.exists()) return null;
      final bytes = await file.readAsBytes();
      final b64 = base64Encode(bytes);
      if (_imageB64Cache.length >= 8)
        _imageB64Cache.remove(_imageB64Cache.keys.first);
      _imageB64Cache[path] = b64;
      return b64;
    } catch (_) {
      return null;
    }
  }

  /// path → base64 缓存（上限 8 张，FIFO 淘汰）。
  static final Map<String, String> _imageB64Cache = {};

  /// dio 异常 → 可读信息（含 4xx 响应体详情）。
  ///
  /// 上游 adapter 靠 message 文案做失败分档：上下文溢出类错误（400 +
  /// "context length exceeded" 等）的判定依据在**响应体**里，而 HTTP reason
  /// phrase 只有 "Bad Request"。流式请求的 badResponse 响应体是未消费的
  /// ResponseBody 字节流，这里异步读出（上限 4KB），优先提取
  /// `error.message` / `message` JSON 字段，取不到就放原始片段。
  Future<String> _describeApiError(DioException e) async {
    final base = _friendlyDioError(e);
    if (e.type != DioExceptionType.badResponse) return base;
    final bodyText = await _readErrorBody(e.response?.data);
    if (bodyText == null || bodyText.isEmpty) return base;
    return '$base | 响应体: $bodyText';
  }

  /// 读错误响应体文本；提取 `error.message`/`message`，失败回退原始片段。
  /// 任何读取异常都静默降级为 null（不能因读体失败掩盖原错误）。
  static Future<String?> _readErrorBody(Object? data) async {
    try {
      String raw;
      if (data is ResponseBody) {
        final bytes = <int>[];
        await for (final chunk in data.stream.cast<List<int>>()) {
          bytes.addAll(chunk);
          if (bytes.length >= 4096) break;
        }
        raw = utf8.decode(bytes, allowMalformed: true);
      } else if (data is String) {
        raw = data;
      } else if (data is Map) {
        raw = jsonEncode(data);
      } else {
        return null;
      }
      raw = raw.trim();
      if (raw.isEmpty) return null;
      if (raw.length > 2048) raw = raw.substring(0, 2048);
      try {
        final json = jsonDecode(raw);
        if (json is Map) {
          final err = json['error'];
          if (err is Map && err['message'] is String) {
            return err['message'] as String;
          }
          if (json['message'] is String) return json['message'] as String;
        }
      } catch (_) {
        // 非 JSON 体，用原始片段。
      }
      return raw;
    } catch (_) {
      return null;
    }
  }

  /// 把 dio 异常转成可读中文信息。
  String _friendlyDioError(DioException e) {
    switch (e.type) {
      case DioExceptionType.connectionTimeout:
      case DioExceptionType.sendTimeout:
      case DioExceptionType.receiveTimeout:
        return '连接超时，请检查 baseUrl 与网络';
      case DioExceptionType.badResponse:
        final code = e.response?.statusCode;
        return '服务端返回异常（HTTP $code）：${e.response?.statusMessage ?? ''}';
      case DioExceptionType.connectionError:
        return '无法连接到服务端，请检查 baseUrl';
      default:
        return '请求失败：${e.message ?? e.type}';
    }
  }

  /// 拉取 API 端点的上下文槽位大小（token 数），用于顶部状态栏的上下文占用
  /// 百分比显示。
  ///
  /// 读取 `/v1/models` 的 `meta.n_ctx`（llama.cpp / vLLM 等原生端点返回；
  /// 官方 OpenAI 等可能没有该字段）。带 30 分钟内存缓存，避免每轮都拉。
  ///
  /// 返回 null 表示无法确定（端点无该字段 / 请求失败 / 非 200），调用方
  /// 此时应回退到配置值 [ApiModelConfig.contextWindow]。
  Future<int?> fetchContextWindow(ApiModelConfig config) async {
    final cached = _contextWindowCache[config.id];
    if (cached != null) {
      // 缓存命中：若仍在 30 分钟内直接返回，否则触发后台刷新。
      final now = DateTime.now();
      if (now.difference(cached.fetchedAt).inMilliseconds < _ctxCacheTtlMs) {
        return cached.value;
      }
    }

    // 归一化 baseUrl：`/v1` → `/v1/models`；已带 `/chat/completions` 时截断。
    var base = config.baseUrl.trim();
    while (base.endsWith('/')) {
      base = base.substring(0, base.length - 1);
    }
    if (base.endsWith('/chat/completions')) {
      base = base.substring(0, base.length - '/chat/completions'.length);
    }
    final url = '$base/models';

    int? value;
    try {
      final resp = await _dio.get<Map<String, dynamic>>(
        url,
        options: Options(
          responseType: ResponseType.json,
          headers: _headers(config.apiKey),
        ),
      );
      if (resp.statusCode == 200) {
        final data = resp.data;
        // llama.cpp `/v1/models` 形如 {"data":[{"meta":{"n_ctx": 57344}}]}。
        // 官方 OpenAI 形如 {"data":[{"id": ...}]}（无 meta），取不到返回 null。
        final list = data?['data'];
        if (list is List && list.isNotEmpty) {
          final first = list.first;
          final meta = first is Map<String, dynamic> ? first['meta'] : null;
          if (meta is Map<String, dynamic>) {
            value = (meta['n_ctx'] as num?)?.toInt();
          }
        }
      }
    } catch (_) {
      // 网络/解析失败 → 返回 null，调用方回退配置值；不覆盖已有缓存。
      return cached?.value ?? null;
    }

    // 更新缓存（成功或失败都记录，避免频繁重试；失败时 value 为 null）。
    _contextWindowCache[config.id] =
        _CachedCtx(value: value, fetchedAt: DateTime.now());
    return value ?? cached?.value ?? null;
  }

  /// 上下文槽位缓存：`config.id → (值, 拉取时间)`。
  static final Map<String, _CachedCtx> _contextWindowCache = {};

  /// 槽位缓存有效期：30 分钟。
  static const int _ctxCacheTtlMs = 30 * 60 * 1000;
}

/// 上下文槽位缓存条目（值 + 拉取时间）。
final class _CachedCtx {
  final int? value;
  final DateTime fetchedAt;
  const _CachedCtx({this.value, required this.fetchedAt});
}
