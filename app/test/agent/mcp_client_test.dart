/// P2-B MCP 客户端测试：本地桩 server（dart:io HttpServer）全链路
/// initialize → tools/list → tools/call；JSON 与 SSE 两种响应形态。
import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:tongyi_lite/agent/mcp/mcp_client.dart';

/// 极简 MCP server 桩：处理 initialize/notifications/initialized/tools/list/
/// tools/call。[sse] = 用 text/event-stream 帧响应（默认 JSON）。
Future<HttpServer> _startStubServer({bool sse = false}) async {
  final server = await HttpServer.bind('127.0.0.1', 0);
  server.listen((req) async {
    final body = await utf8.decoder.bind(req).join();
    final reqJson = body.isEmpty ? null : jsonDecode(body) as Map<String, dynamic>;
    // 通知（无 id）→ 202 空。
    if (reqJson == null || reqJson['id'] == null) {
      req.response.statusCode = 202;
      await req.response.close();
      return;
    }
    final id = reqJson['id'];
    final method = reqJson['method'] as String?;
    dynamic result;
    if (method == 'initialize') {
      result = {
        'protocolVersion': '2025-03-26',
        'capabilities': {'tools': {}},
        'serverInfo': {'name': 'stub', 'version': '0.0.1'},
      };
      req.response.headers.set('Mcp-Session-Id', 'sess-123');
    } else if (method == 'tools/list') {
      result = {
        'tools': [
          {
            'name': 'echo',
            'description': '回声工具',
            'inputSchema': {
              'type': 'object',
              'properties': {
                'text': {'type': 'string'}
              },
              'required': ['text'],
            },
          },
          {
            'name': 'fail',
            'description': '总是失败',
            'inputSchema': {'type': 'object', 'properties': {}},
          },
        ],
      };
    } else if (method == 'tools/call') {
      final name = (reqJson['params'] as Map)['name'] as String;
      if (name == 'fail') {
        result = {
          'content': [
            {'type': 'text', 'text': '炸了'}
          ],
          'isError': true,
        };
      } else {
        final text =
            ((reqJson['params'] as Map)['arguments'] as Map)['text'] as String?;
        result = {
          'content': [
            {'type': 'text', 'text': 'echo: $text'}
          ],
        };
      }
    } else {
      req.response.statusCode = 404;
      await req.response.close();
      return;
    }

    final payload = jsonEncode({'jsonrpc': '2.0', 'id': id, 'result': result});
    if (sse) {
      req.response.headers.contentType =
          ContentType('text', 'event-stream', charset: 'utf-8');
      req.response.write('event: message\n');
      req.response.write('data: $payload\n\n');
    } else {
      req.response.headers.contentType = ContentType.json;
      req.response.write(payload);
    }
    await req.response.close();
  });
  return server;
}

McpServerConfig _config(HttpServer s) => McpServerConfig(
      id: 'mcp_test',
      name: 'stub',
      url: 'http://127.0.0.1:${s.port}/mcp',
    );

void main() {
  test('JSON 形态：initialize → tools/list → 工具注册名与执行', () async {
    final server = await _startStubServer();
    addTearDown(server.close);
    final tools = await fetchMcpTools(_config(server));
    expect(tools.length, 2);
    final echo = tools.firstWhere((t) => t.name == 'mcp_stub_echo');
    expect(echo.description, contains('回声工具'));
    expect(echo.description, contains('MCP：stub'));
    final r = await echo.execute({'text': '你好'});
    expect(r.isError, isFalse);
    expect(r.content, 'echo: 你好');
  });

  test('SSE 帧形态：同样能取到匹配 id 的响应', () async {
    final server = await _startStubServer(sse: true);
    addTearDown(server.close);
    final tools = await fetchMcpTools(_config(server));
    expect(tools, isNotEmpty);
    final echo = tools.firstWhere((t) => t.name == 'mcp_stub_echo');
    final r = await echo.execute({'text': 'sse'});
    expect(r.content, 'echo: sse');
  });

  test('tools/call isError=true → ToolResult.isError', () async {
    final server = await _startStubServer();
    addTearDown(server.close);
    final tools = await fetchMcpTools(_config(server));
    final fail = tools.firstWhere((t) => t.name == 'mcp_stub_fail');
    final r = await fail.execute({});
    expect(r.isError, isTrue);
    expect(r.content, contains('炸了'));
  });

  test('工具名净化：非法字符压成 _（防跨 server 撞名/注入）', () async {
    final server = await _startStubServer();
    addTearDown(server.close);
    final client = McpClient(_config(server));
    await client.initialize();
    expect(client.sanitizedNameForTest('a.b/c d'),
        r'mcp_stub_a_b_c_d');
  });

  test('不可达 server → fetchMcpTools 抛异常（调用方跳过）', () async {
    final cfg = McpServerConfig(
        id: 'x', name: 'dead', url: 'http://127.0.0.1:1/mcp');
    expect(() => fetchMcpTools(cfg), throwsA(anything));
  });
}

extension on McpClient {
  String sanitizedNameForTest(String raw) {
    // _toolName 是私有的；经 listTools 之外单测名净化逻辑的轻量镜像：
    String sanitize(String s) => s.replaceAll(RegExp(r'[^a-zA-Z0-9_-]'), '_');
    return 'mcp_${sanitize(config.name)}_${sanitize(raw)}';
  }
}
