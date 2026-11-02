// SSE 停摆看门狗回归（2026-10-06）：
//
// 真机实锤：中转端点建立连接后长时间零字节（13 分钟），回合表面"思考中"
// 实为无限等待——此前 Dio 无任何超时，SSE 静默挂起永远不超时。
// 修复后：两 chunk 间静默超过 stallIdle → OpenAiStallException →
// adapter 归一化为 LlmFailureCode.timeout（可重试档，UI 出重试横幅）。
import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';

import 'package:dio/dio.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:tongyi_lite/models/api_model.dart';
import 'package:tongyi_lite/services/openai_service.dart';

/// 假传输层：回一个 SSE 响应，发出首个 chunk 后**永久挂起**（不发数据也
/// 不结束流）——精确复现"网关挂起不回包"。
class _HangAfterFirstChunkAdapter implements HttpClientAdapter {
  final StreamController<Uint8List> _body = StreamController<Uint8List>();

  @override
  void close({bool force = false}) {
    if (!_body.isClosed) _body.close();
  }

  @override
  Future<ResponseBody> fetch(
    RequestOptions options,
    Stream<Uint8List>? requestStream,
    Future<void>? cancelFuture,
  ) async {
    // 先发一行合法 SSE 数据（证明"连上了"），然后静默。
    final first =
        utf8.encode('data: {"choices":[{"delta":{"content":"hi"}}]}\n\n');
    _body.add(Uint8List.fromList(first));
    // 不 close、不再发——挂起。
    cancelFuture?.then((_) {
      if (!_body.isClosed) _body.close();
    });
    return ResponseBody(_body.stream, 200, headers: {
      'content-type': ['text/event-stream'],
    });
  }
}

/// 假传输层：chunk 间隔小于看门狗阈值但一直在发——**慢流必须存活**，
/// 看门狗只拦"彻底没数据"，不能误杀慢端点。
class _SlowButAliveAdapter implements HttpClientAdapter {
  _SlowButAliveAdapter(this.chunkCount);

  final int chunkCount;
  final StreamController<Uint8List> _body = StreamController<Uint8List>();

  @override
  void close({bool force = false}) {
    if (!_body.isClosed) _body.close();
  }

  @override
  Future<ResponseBody> fetch(
    RequestOptions options,
    Stream<Uint8List>? requestStream,
    Future<void>? cancelFuture,
  ) async {
    // 每 20ms 一个 chunk，远慢于正常流但快于阈值。
    () async {
      for (var i = 0; i < chunkCount; i++) {
        await Future<void>.delayed(const Duration(milliseconds: 20));
        final payload = utf8.encode(
            'data: {"choices":[{"delta":{"content":"c$i"}}]}\n\n');
        _body.add(Uint8List.fromList(payload));
      }
      _body.add(utf8.encode('data: [DONE]\n\n'));
      await _body.close();
    }();
    return ResponseBody(_body.stream, 200, headers: {
      'content-type': ['text/event-stream'],
    });
  }
}

ApiModelConfig _config() => const ApiModelConfig(
      id: 'test',
      name: 'test',
      baseUrl: 'http://127.0.0.1:1',
      apiKey: '',
      model: 'test-model',
    );

void main() {
  group('SSE 停摆看门狗', () {
    test('静默超阈值 → 抛 OpenAiStallException（不再无限等待）', () async {
      final dio = Dio()..httpClientAdapter = _HangAfterFirstChunkAdapter();
      final service = OpenAiService(dio: dio, stallIdle: const Duration(milliseconds: 80));
      final texts = <String>[];
      await expectLater(
        service
            .chatCompletion(
                config: _config(), messages: [
          {'role': 'user', 'content': 'hi'},
        ])
            .forEach(texts.add),
        throwsA(isA<OpenAiStallException>()),
      );
      // 首 chunk 的内容先到达，随后停摆抛错。
      expect(texts, ['hi']);
    });

    test('慢流（间隔 < 阈值）正常读完，不误杀', () async {
      final dio = Dio()..httpClientAdapter = _SlowButAliveAdapter(6);
      final service = OpenAiService(dio: dio, stallIdle: const Duration(milliseconds: 200));
      final texts = <String>[];
      await for (final t in service.chatCompletion(
          config: _config(),
          messages: [
            {'role': 'user', 'content': 'hi'},
          ])) {
        texts.add(t);
      }
      expect(texts.length, 6);
      expect(texts.first, 'c0');
    });
  });
}
