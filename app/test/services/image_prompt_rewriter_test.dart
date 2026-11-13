// ImagePromptRewriter 单测（_FakeAdapter mock dio HttpClientAdapter，
// image_gen_service_test 同款惯例）。
//
// 2026-11-13 扩写改**非流式**（chatCompletionOnce 整包 JSON——SSE 流式在
// App 实测「输出到一半断开」频繁复现，非流式无中途断连面），测试随形态
// 重写：完整 JSON 响应 / 请求体形状（system+user、无 stream 字段）/ 空回复
// → failed / HTTP 401 → failed / connectionTimeout → failed / 空提示词
// 直通 / sanitize 各包裹形态。时钟类超时守卫属生产层（flutter_test 下
// Stream/Future timeout 不触发——对照实验实锤），此处用 DioException
// connectionTimeout 注入等价覆盖「失败折叠为原文直通」的收敛口。
import 'dart:convert';
import 'dart:typed_data' show Uint8List;

import 'package:dio/dio.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:wangcai/models/api_model.dart';
import 'package:wangcai/services/image_prompt_rewriter.dart';
import 'package:wangcai/services/openai_service.dart';

class _FakeAdapter implements HttpClientAdapter {
  _FakeAdapter(this.onRequest);

  final Future<ResponseBody> Function(RequestOptions options) onRequest;

  @override
  void close({bool force = false}) {}

  @override
  Future<ResponseBody> fetch(RequestOptions options,
      Stream<Uint8List>? requestStream, Future<void>? cancelFuture) async {
    return onRequest(options);
  }
}

ResponseBody _jsonBody(Map<String, dynamic> json) => ResponseBody(
      Stream.value(Uint8List.fromList(utf8.encode(jsonEncode(json)))),
      200,
      headers: {Headers.contentTypeHeader: [Headers.jsonContentType]},
    );

Map<String, dynamic> _chatResponse(String content) => {
      'id': 'chatcmpl-x',
      'object': 'chat.completion',
      'choices': [
        {
          'index': 0,
          'message': {'role': 'assistant', 'content': content},
          'finish_reason': 'stop',
        }
      ],
      'usage': {'prompt_tokens': 55, 'completion_tokens': 80},
    };

ApiModelConfig _model() => const ApiModelConfig(
      id: 'm1',
      name: '8899 chat',
      baseUrl: 'http://127.0.0.1:8899/v1',
      apiKey: 'sk-test',
      model: 'Qwen3-VL-8B-Instruct',
    );

ImagePromptRewriter _rewriterWith(_FakeAdapter adapter,
        {Duration? timeout}) =>
    ImagePromptRewriter(
      openAi: OpenAiService(dio: Dio()..httpClientAdapter = adapter),
      timeout: timeout,
    );

void main() {
  group('ImagePromptRewriter.rewrite（非流式）', () {
    test('整包 JSON → sanitize 清洗围栏/前缀/引号', () async {
      final adapter = _FakeAdapter((o) async =>
          _jsonBody(_chatResponse('```text\n提示词：「一只赛博朋克风格的猫，'
              '霓虹灯街道背景，电影光影，超高清」\n```')));
      final r = await _rewriterWith(adapter)
          .rewrite(model: _model(), userPrompt: '画一只赛博朋克猫');
      expect(r.failed, isFalse);
      expect(r.original, '画一只赛博朋克猫');
      expect(r.rewritten, '一只赛博朋克风格的猫，霓虹灯街道背景，电影光影，超高清');
      expect(r.changed, isTrue);
    });

    test('请求体：system 模板打头 + user 原文，模型/采样参数齐全、无 stream 字段',
        () async {
      Map<String, dynamic>? sent;
      String? auth;
      final adapter = _FakeAdapter((o) async {
        sent = o.data as Map<String, dynamic>;
        auth = o.headers['Authorization'];
        return _jsonBody(_chatResponse('好的提示词'));
      });
      await _rewriterWith(adapter).rewrite(model: _model(), userPrompt: '画只猫');
      expect(sent, isNotNull);
      expect(sent!['model'], 'Qwen3-VL-8B-Instruct');
      expect(sent!.containsKey('stream'), isFalse,
          reason: '非流式语义：不携带 stream 字段');
      expect(sent!['temperature'], 0.7);
      expect(sent!['max_tokens'], 256);
      expect(auth, 'Bearer sk-test');
      expect(sent!['url'] as String?, isNull);
      final msgs = (sent!['messages'] as List).cast<Map<String, dynamic>>();
      expect(msgs.first['role'], 'system');
      expect(msgs.first['content'], contains('提示词工程师'));
      expect(msgs.last, {'role': 'user', 'content': '画只猫'});
      // URL 归一化：baseUrl 已带 /v1 → /v1/chat/completions
      // （normalizeChatUrl 在 OpenAiService 内，这里从 dio options 侧验证）。
    });

    test('URL 归一化：请求打到 baseUrl/chat/completions', () async {
      String? path;
      final adapter = _FakeAdapter((o) async {
        path = o.uri.toString();
        return _jsonBody(_chatResponse('好的'));
      });
      await _rewriterWith(adapter).rewrite(model: _model(), userPrompt: '画只猫');
      expect(path, contains('/v1/chat/completions'));
    });

    test('空 content → failed（rewritten=原文，不阻塞）', () async {
      final adapter = _FakeAdapter((o) async => _jsonBody(_chatResponse('   ')));
      final r = await _rewriterWith(adapter)
          .rewrite(model: _model(), userPrompt: '画只猫');
      expect(r.failed, isTrue);
      expect(r.rewritten, '画只猫');
      expect(r.changed, isFalse);
    });

    test('缺 choices / 空 choices → failed', () async {
      final adapter = _FakeAdapter((o) async => _jsonBody({'object': 'chat.completion'}));
      final r = await _rewriterWith(adapter)
          .rewrite(model: _model(), userPrompt: '画只猫');
      expect(r.failed, isTrue);
      expect(r.rewritten, '画只猫');
    });

    test('HTTP 401 → failed 原文直通', () async {
      final adapter = _FakeAdapter((o) async => throw DioException(
            requestOptions: o,
            type: DioExceptionType.badResponse,
            response: Response(requestOptions: o, statusCode: 401),
          ));
      final r = await _rewriterWith(adapter)
          .rewrite(model: _model(), userPrompt: '画只猫');
      expect(r.failed, isTrue);
      expect(r.rewritten, '画只猫');
    });

    test('连接超时（DioException 注入）→ failed（永不卡死生图）', () async {
      final adapter = _FakeAdapter((o) async => throw DioException(
            requestOptions: o,
            type: DioExceptionType.connectionTimeout,
          ));
      final r = await _rewriterWith(adapter)
          .rewrite(model: _model(), userPrompt: '画只猫');
      expect(r.failed, isTrue);
      expect(r.rewritten, '画只猫');
    });

    test('空提示词直通（不发请求）', () async {
      var called = false;
      final adapter = _FakeAdapter((o) async {
        called = true;
        return _jsonBody(_chatResponse('x'));
      });
      final r = await _rewriterWith(adapter)
          .rewrite(model: _model(), userPrompt: '  ');
      expect(called, isFalse);
      expect(r.failed, isFalse);
      expect(r.rewritten, '');
    });
  });

  group('sanitize', () {
    test('剥 markdown 围栏', () {
      expect(ImagePromptRewriter.sanitize('```\n猫\n```'), '猫');
      expect(ImagePromptRewriter.sanitize('```json\n\n猫\n\n```'), '猫');
    });
    test('剥「提示词：」类前缀', () {
      expect(ImagePromptRewriter.sanitize('优化后的提示词：一只猫'), '一只猫');
      expect(ImagePromptRewriter.sanitize('提示词 : 一只猫'), '一只猫');
    });
    test('剥首尾中英文引号', () {
      expect(ImagePromptRewriter.sanitize('“一只猫”'), '一只猫');
      expect(ImagePromptRewriter.sanitize('「一只猫」'), '一只猫');
    });
    test('正文中的引号不误伤', () {
      expect(ImagePromptRewriter.sanitize('写着“福”字的春联'), '写着“福”字的春联');
    });
  });
}
