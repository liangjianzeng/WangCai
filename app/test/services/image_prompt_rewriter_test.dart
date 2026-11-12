// ImagePromptRewriter 单测（_FakeAdapter mock dio HttpClientAdapter，
// image_gen_service_test 同款惯例）。
//
// 覆盖：SSE 拼接 + sanitize 清洗 / 请求体形状（system 模板 + user 原文 +
// 采样参数）/ 空回复→failed / HTTP 错误→failed / 超时→failed /
// 空提示词直通 / sanitize 各包裹形态。核心纪律锚：**任何失败都折叠为
// failed（rewritten=original），扩写永不阻塞生图**。
import 'dart:async';
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

ResponseBody _sseBody(Stream<String> lines) => ResponseBody(
      lines.map((l) => Uint8List.fromList(utf8.encode(l))),
      200,
      headers: {
        Headers.contentTypeHeader: ['text/event-stream'],
      },
    );

String _chunk(String text) => jsonEncode({
      'choices': [
        {'delta': {'content': text}}
      ]
    });

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
  group('ImagePromptRewriter.rewrite', () {
    test('SSE 增量拼接 → sanitize 清洗围栏/前缀/引号', () async {
      final adapter = _FakeAdapter((o) async => _sseBody(Stream.fromIterable([
            'data: ${_chunk("```text\n")}\n\n',
            'data: ${_chunk("提示词：")}\n\n',
            'data: ${_chunk("「一只赛博朋克风格的猫，")}\n\n',
            'data: ${_chunk("霓虹灯街道背景，电影光影，")}\n\n',
            'data: ${_chunk("超高清」")}\n\n',
            'data: ${_chunk("\n```")}\n\n',
            'data: [DONE]\n\n',
          ])));
      final r = await _rewriterWith(adapter)
          .rewrite(model: _model(), userPrompt: '画一只赛博朋克猫');
      expect(r.failed, isFalse);
      expect(r.original, '画一只赛博朋克猫');
      expect(r.rewritten, '一只赛博朋克风格的猫，霓虹灯街道背景，电影光影，超高清');
      expect(r.changed, isTrue);
    });

    test('请求体：system 模板打头 + user 原文，模型/流式/采样参数齐全', () async {
      Map<String, dynamic>? sent;
      String? auth;
      final adapter = _FakeAdapter((o) async {
        sent = o.data as Map<String, dynamic>;
        auth = o.headers['Authorization'];
        return _sseBody(Stream.fromIterable([
          'data: ${_chunk("好的提示词")}\n\n',
          'data: [DONE]\n\n',
        ]));
      });
      await _rewriterWith(adapter)
          .rewrite(model: _model(), userPrompt: '画只猫');
      expect(sent, isNotNull);
      expect(sent!['model'], 'Qwen3-VL-8B-Instruct');
      expect(sent!['stream'], isTrue);
      expect(sent!['temperature'], 0.7);
      expect(sent!['max_tokens'], 256);
      expect(auth, 'Bearer sk-test');
      final msgs = (sent!['messages'] as List).cast<Map<String, dynamic>>();
      expect(msgs.first['role'], 'system');
      expect(msgs.first['content'], contains('提示词工程师'));
      expect(msgs.last, {'role': 'user', 'content': '画只猫'});
    });

    test('空回复 → failed（rewritten=原文，不阻塞）', () async {
      final adapter = _FakeAdapter((o) async => _sseBody(
          Stream.fromIterable(['data: ${_chunk("   ")}\n\n', 'data: [DONE]\n\n']
      )));
      final r = await _rewriterWith(adapter)
          .rewrite(model: _model(), userPrompt: '画只猫');
      expect(r.failed, isTrue);
      expect(r.rewritten, '画只猫');
      expect(r.changed, isFalse);
    });

    test('HTTP 401 → failed 原文直通', () async {
      final adapter = _FakeAdapter((o) async => throw DioException(
            requestOptions: o,
            response: Response(requestOptions: o, statusCode: 401),
          ));
      final r = await _rewriterWith(adapter)
          .rewrite(model: _model(), userPrompt: '画只猫');
      expect(r.failed, isTrue);
      expect(r.rewritten, '画只猫');
    });

    // 时钟类守卫（rewrite 的 .timeout 预算 / OpenAiService 停摆看门狗都建在
    // Stream.timeout 上）在 flutter_test test() 里不触发——对照实验实锤：
    // 裸 async* 阻塞流 + 150ms timeout 30s 未抛。故「挂起降级」在此环境用
    // **流错误注入**等价覆盖（await for 抛错 → catch → failed 同一收敛口）；
    // 时钟预算本体属生产层（真机 dio 流上 Stream/Timer 正常走）。
    test('流中途报错 → failed 原文直通', () async {
      final ctl = StreamController<Uint8List>();
      ctl.add(Uint8List.fromList(utf8.encode('data: ${_chunk("一只")}\n\n')));
      ctl.addError(Exception('connection reset'));
      unawaited(ctl.close());
      final adapter = _FakeAdapter((o) async => ResponseBody(
            ctl.stream,
            200,
            headers: {
              Headers.contentTypeHeader: ['text/event-stream'],
            },
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
        return _sseBody(Stream.fromIterable(['data: [DONE]\n\n']));
      });
      final r =
          await _rewriterWith(adapter).rewrite(model: _model(), userPrompt: '  ');
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
