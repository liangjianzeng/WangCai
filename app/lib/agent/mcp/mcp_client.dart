/// MCP（Model Context Protocol）客户端 —— P2-B，仅远程 HTTP 形态。
///
/// 覆盖 Streamable HTTP 传输（MCP 2025-03-26 规范）：POST JSON-RPC 2.0；
/// 响应可能是 `application/json` 或 `text/event-stream`（SSE 帧，取匹配
/// id 的 data 行）。不支持 stdio（端侧无进程 spawn 生态）。
///
/// 工具映射：server 的 tools/list → [ToolDefinition]
///（名字 `mcp_<server>_<tool>`，执行 = tools/call，content text 拼接）。
library;

import 'dart:async';
import 'dart:convert';

import 'package:dio/dio.dart';

import '../tool_definition.dart';

/// 一个远程 MCP server 的配置（settings 持久化）。
class McpServerConfig {
  final String id;
  final String name;

  /// 端点 URL（如 http://100.81.83.59:3000/mcp）。
  final String url;

  /// 自定义请求头（如 Authorization）。
  final Map<String, String> headers;
  final bool enabled;

  const McpServerConfig({
    required this.id,
    required this.name,
    required this.url,
    this.headers = const {},
    this.enabled = true,
  });

  Map<String, dynamic> toJson() => {
        'id': id,
        'name': name,
        'url': url,
        'headers': headers,
        'enabled': enabled,
      };

  factory McpServerConfig.fromJson(Map<String, dynamic> m) => McpServerConfig(
        id: m['id'] as String? ?? '',
        name: m['name'] as String? ?? '',
        url: m['url'] as String? ?? '',
        headers: (m['headers'] as Map<String, dynamic>?)?.cast<String, String>() ??
            const {},
        enabled: m['enabled'] as bool? ?? true,
      );

  McpServerConfig copyWith({String? name, String? url, bool? enabled}) =>
      McpServerConfig(
        id: id,
        name: name ?? this.name,
        url: url ?? this.url,
        headers: headers,
        enabled: enabled ?? this.enabled,
      );
}

/// JSON-RPC 响应。
class _RpcResponse {
  final dynamic result;
  final Map<String, dynamic>? error;
  final int? id;
  const _RpcResponse(this.result, this.error, this.id);
}

/// MCP 客户端（一个 server 一个实例；有状态：session id）。
class McpClient {
  final McpServerConfig config;
  final Dio _dio;
  String? _sessionId;
  int _nextId = 1;

  static const _protocolVersion = '2025-03-26';

  McpClient(this.config, {Dio? dio}) : _dio = dio ?? Dio();

  Map<String, String> get _baseHeaders => {
        'Accept': 'application/json, text/event-stream',
        ...config.headers,
        if (_sessionId != null) 'Mcp-Session-Id': _sessionId!,
      };

  /// 发一个 JSON-RPC 请求并等待匹配 id 的响应。
  Future<_RpcResponse> _request(String method, Map<String, dynamic> params,
      {Duration timeout = const Duration(seconds: 15)}) async {
    final id = _nextId++;
    final body = {
      'jsonrpc': '2.0',
      'id': id,
      'method': method,
      'params': params,
    };
    final res = await _dio.post<dynamic>(
      config.url,
      data: body,
      options: Options(
        headers: _baseHeaders,
        responseType: ResponseType.plain,
        validateStatus: (s) => s != null && s < 500,
        // 响应可能是 JSON 或 SSE，都不让 dio 解析。
      ),
    );
    _captureSessionId(res);
    if (res.statusCode == 202) {
      // 通知型请求，无响应体。
      return _RpcResponse(null, null, id);
    }
    return _parseRpcBody('${res.data}', id);
  }

  void _captureSessionId(Response<dynamic> res) {
    final sid = res.headers.value('mcp-session-id');
    if (sid != null && sid.isNotEmpty) _sessionId = sid;
  }

  /// 解析 JSON 或 SSE 帧两种响应形态。
  _RpcResponse _parseRpcBody(String body, int requestId) {
    final trimmed = body.trim();
    if (trimmed.startsWith('{')) {
      return _fromJsonText(trimmed, requestId);
    }
    // SSE：逐帧找 data: 行，解析出 id 匹配的响应。
    for (final line in trimmed.split('\n')) {
      final l = line.trim();
      if (!l.startsWith('data:')) continue;
      final payload = l.substring(5).trim();
      if (payload.isEmpty) continue;
      try {
        final r = _fromJsonText(payload, requestId);
        if (r.id == requestId) return r;
      } on FormatException {
        // 非 JSON 帧（注释/心跳）跳过。
      }
    }
    throw FormatException('MCP 响应中未找到匹配 id=$requestId 的结果');
  }

  _RpcResponse _fromJsonText(String text, int requestId) {
    final m = jsonDecode(text);
    if (m is! Map<String, dynamic>) {
      throw FormatException('MCP 响应不是对象');
    }
    return _RpcResponse(
      m['result'],
      m['error'] is Map<String, dynamic>
          ? m['error'] as Map<String, dynamic>
          : null,
      (m['id'] as num?)?.toInt(),
    );
  }

  /// 握手：initialize + initialized 通知。失败抛异常（由调用方决定跳过）。
  Future<void> initialize() async {
    final res = await _request('initialize', {
      'protocolVersion': _protocolVersion,
      'capabilities': {},
      'clientInfo': {'name': 'TongYi-Lite', 'version': '0.2.8'},
    });
    if (res.error != null) {
      throw Exception('MCP initialize 失败: ${res.error}');
    }
    // initialized 通知（无 id，无响应）。
    await _dio.post<dynamic>(
      config.url,
      data: {
        'jsonrpc': '2.0',
        'method': 'notifications/initialized',
      },
      options: Options(
        headers: _baseHeaders,
        responseType: ResponseType.plain,
        validateStatus: (s) => s != null && s < 500,
      ),
    );
  }

  /// 拉取 server 工具清单。
  Future<List<ToolDefinition>> listTools() async {
    final res = await _request('tools/list', const {});
    if (res.error != null) {
      throw Exception('MCP tools/list 失败: ${res.error}');
    }
    final tools = res.result?['tools'];
    if (tools is! List) return const [];
    final out = <ToolDefinition>[];
    for (final t in tools) {
      if (t is! Map<String, dynamic>) continue;
      final name = t['name'] as String?;
      if (name == null || name.isEmpty) continue;
      out.add(ToolDefinition(
        name: _toolName(name),
        description:
            '${t['description'] as String? ?? '（无描述）'}（MCP：${config.name}）',
        parameters:
            (t['inputSchema'] as Map<String, dynamic>?) ?? const {},
        execute: (args) => callTool(name, args),
        timeout: const Duration(seconds: 120),
      ));
    }
    return out;
  }

  /// 调用 server 工具；content text 部分拼接回填。
  Future<ToolResult> callTool(String rawName, Map<String, dynamic> args) async {
    try {
      final res = await _request('tools/call', {
        'name': rawName,
        'arguments': args,
      }, timeout: const Duration(seconds: 120));
      if (res.error != null) {
        return ToolResult.error('MCP 工具 $rawName 错误: ${res.error}');
      }
      final result = res.result;
      if (result is! Map<String, dynamic>) {
        return ToolResult.error('MCP 工具 $rawName 返回了意外结构');
      }
      final buf = StringBuffer();
      final content = result['content'];
      if (content is List) {
        for (final part in content) {
          if (part is Map<String, dynamic> && part['type'] == 'text') {
            buf.writeln(part['text'] as String? ?? '');
          }
        }
      }
      final text = buf.toString().trim();
      if (text.isEmpty) {
        return ToolResult.error('MCP 工具 $rawName 没有返回文本内容');
      }
      return ToolResult(
        content: text,
        isError: result['isError'] as bool? ?? false,
      );
    } on Exception catch (e) {
      return ToolResult.error('MCP 工具 $rawName 调用失败: $e');
    }
  }

  /// 工具名映射：`mcp_<server名>_<原始名>`，非法字符压成 `_`，
  /// 防止跨 server 撞名与协议注入。
  String _toolName(String raw) {
    String sanitize(String s) =>
        s.replaceAll(RegExp(r'[^a-zA-Z0-9_-]'), '_');
    return 'mcp_${sanitize(config.name)}_${sanitize(raw)}';
  }
}

/// 连接一个 server 并拉取工具清单；失败抛异常（调用方决定跳过该 server）。
Future<List<ToolDefinition>> fetchMcpTools(McpServerConfig config,
    {Dio? dio}) async {
  final client = McpClient(config, dio: dio);
  await client.initialize();
  return client.listTools();
}
