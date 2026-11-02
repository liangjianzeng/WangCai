/// API 路线视觉 + 思考流回归：
/// - kick 把 imagePath 写入 user/message 事件，deriveModelMessages 投影该键
///   （此前 API 路线图片从未进请求体——静默丢图）；
/// - attachWireImages 把带图 user 消息转 OpenAI content-parts；
/// - OpenAiNativeStreamAssembler：reasoning 事件收集 + content 内嵌
///   `<think>` 剥离（可跨分片），思考不进可见文本。
library;

import 'dart:async';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:tongyi_lite/agent/llm/adapter.dart';
import 'package:tongyi_lite/agent/llm/openai_adapter.dart';
import 'package:tongyi_lite/agent/loop/agent.dart';
import 'package:tongyi_lite/agent/session/session.dart';
import 'package:tongyi_lite/agent/tool_registry.dart';
import 'package:tongyi_lite/services/openai_service.dart';

void main() {
  group('SessionLog：user/message 携带 imagePath', () {
    test('kick 写入 imagePath → deriveModelMessages 投影', () async {
      final log = SessionLog.fromEvents([]);
      final agent = ReactLoopAgent(
        session: log,
        adapter: _NoCallAdapter(),
        registry: ToolRegistry(),
        modelId: 'm',
        providerKind: ProviderKind.api,
        systemPrompt: 'sys',
      );
      // adapter 恒抛（不应触发模型调用）；user 事件在 step 前已入 log。
      try {
        await agent.kick('看这张图', imagePath: '/tmp/x.png');
      } catch (_) {}
      final msgs = log.deriveModelMessages();
      final user = msgs.firstWhere((m) => m['role'] == 'user');
      expect(user['imagePath'], '/tmp/x.png');
    });

    test('无图消息不投影 imagePath 键', () {
      final log = SessionLog.fromEvents([]);
      log.append(kEventUserMessage, {'content': '纯文本'});
      final user = log.deriveModelMessages().first;
      expect(user.containsKey('imagePath'), isFalse);
    });
  });

  group('attachWireImages', () {
    test('带图 user 消息转 image_url content-parts（文本在前）', () async {
      final f = await File(
              '${Directory.systemTemp.path}/vt_test_${DateTime.now().microsecondsSinceEpoch}.png')
          .writeAsBytes([1, 2, 3]);
      addTearDown(() => f.deleteSync());

      final wire = await attachWireImages([
        {'role': 'system', 'content': 'sys'},
        {'role': 'user', 'content': '这是什么', 'imagePath': f.path},
        {'role': 'user', 'content': '无图追问'},
      ], [
        {'role': 'system', 'content': 'sys'},
        {'role': 'user', 'content': '这是什么', 'imagePath': f.path},
        {'role': 'user', 'content': '无图追问'},
      ]);

      expect(wire[0]['content'], 'sys');
      final parts = wire[1]['content'] as List;
      expect(parts[0], {'type': 'text', 'text': '这是什么'});
      expect(parts[1]['type'], 'image_url');
      // MIME 按扩展名（.png 文件必须标 image/png——硬标 jpeg 会被严格端拒收）。
      expect((parts[1]['image_url'] as Map)['url'],
          startsWith('data:image/png;base64,'));
      expect(wire[2]['content'], '无图追问'); // 无图不转
    });

    test('图片文件不存在 → 降级纯文本', () async {
      final wire = await attachWireImages(
        [
          {'role': 'user', 'content': 'hi', 'imagePath': '/nonexistent/x.png'},
        ],
        [
          {'role': 'user', 'content': 'hi', 'imagePath': '/nonexistent/x.png'},
        ],
      );
      expect(wire[0]['content'], 'hi');
    });
  });

  group('OpenAiNativeStreamAssembler 思考通道', () {
    test('reasoning/thinking 事件全量收集，不进 text', () {
      final a = OpenAiNativeStreamAssembler();
      a.addEvent({'type': 'thinking', 'text': '推理中'});
      a.addEvent({'type': 'text', 'text': '答案'});
      a.addEvent({'type': 'thinking', 'text': '更多'});
      expect(a.thinkingSoFar, '推理中更多');
      expect(a.textSoFar, '答案');
    });

    test('content 内嵌 <think> 跨分片剥离', () {
      final a = OpenAiNativeStreamAssembler();
      for (final frag in ['<thi', 'nk>先想', '清楚</thi', 'nk>然后作答']) {
        a.addEvent({'type': 'text', 'text': frag});
      }
      expect(a.textSoFar, '然后作答');
      // 开闭标签本身不算思考内容。
      expect(a.thinkingSoFar, '先想清楚');
    });

    test('普通文本含 < 不误伤（"<a" 开头）', () {
      final a = OpenAiNativeStreamAssembler();
      a.addEvent({'type': 'text', 'text': 'a < b 且 <strong> 标签'});
      expect(a.textSoFar, 'a < b 且 <strong> 标签');
      expect(a.thinkingSoFar, isEmpty);
    });

    test('finalize 归还残留标签候选', () {
      final a = OpenAiNativeStreamAssembler();
      a.addEvent({'type': 'text', 'text': '结尾悬着 <thi'});
      final r = a.finalize();
      expect(r.text, '结尾悬着 <thi');
    });
  });
}

class _NoCallAdapter extends LlmAdapter {
  @override
  Future<LlmResult> generate(
    GenerateOptions options, {
    StreamController<String>? onToken,
    StreamController<String>? onThinking,
    Completer<void>? cancel,
  }) async {
    throw StateError('测试不应触发模型调用');
  }
}
