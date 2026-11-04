// Windows 网关的 SSE→token 流核心状态机（M1-c）：reasoning 包裹、内联标签
// 退让、raw 模式、timings 归一、坏字节容忍。这些决定聊天/agent 在 Windows 上
// 与 Android 语义一致，全部纯逻辑可直接断言。
import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:wangcai/platform/local_server_inference.dart';

Map<String, dynamic> _chatChunk({String? content, String? reasoning}) => {
      'choices': [
        {
          'delta': {
            if (content != null) 'content': content,
            if (reasoning != null) 'reasoning_content': reasoning,
          }
        }
      ],
    };

void main() {
  group('ChatSseDecoder · chat 模式', () {
    test('reasoning→content：开/闭标签恰好各一次，正文透传', () {
      final d = ChatSseDecoder();
      final out = <String>[
        ...d.feedChunk(_chatChunk(reasoning: '先想')),
        ...d.feedChunk(_chatChunk(reasoning: '一下')),
        ...d.feedChunk(_chatChunk(content: '你好')),
      ];
      expect(out, [ChatSseDecoder.openTag, '先想', '一下', ChatSseDecoder.closeTag, '你好']);
      expect(d.finish(), isEmpty);
      expect(d.tokens, 3);
    });

    test('纯 content 流不加任何标签', () {
      final d = ChatSseDecoder();
      expect(d.feedChunk(_chatChunk(content: '今天')), ['今天']);
      expect(d.feedChunk(_chatChunk(content: '天气')), ['天气']);
      expect(d.finish(), isEmpty);
    });

    test('思考未闭合即断流：finish 补闭标签，不留悬挂 opener', () {
      final d = ChatSseDecoder();
      expect(d.feedChunk(_chatChunk(reasoning: '想到一半')), contains(ChatSseDecoder.openTag));
      expect(d.finish(), [ChatSseDecoder.closeTag]);
    });

    test('content 自带 think 标签（模板内联思考）→ 不再包裹', () {
      final d = ChatSseDecoder();
      // 标签用相邻字面量拼接，防工具链吞掉成对标记。
      final inline = '<' 'think' '>\n我想想';
      final first = d.feedChunk(_chatChunk(content: inline));
      expect(first, [inline]); // 原样透传，无自发开标签
      final later = d.feedChunk(_chatChunk(reasoning: '旁路思考'));
      expect(later, ['旁路思考']); // 已见内联标签，后续 reasoning 不包裹
      expect(d.finish(), isEmpty);
    });

    test('reasoning 与 content 交替：每段思考独立包裹', () {
      final d = ChatSseDecoder();
      final out = <String>[
        ...d.feedChunk(_chatChunk(reasoning: 'r1')),
        ...d.feedChunk(_chatChunk(content: 'a1')),
        ...d.feedChunk(_chatChunk(reasoning: 'r2')),
        ...d.feedChunk(_chatChunk(content: 'a2')),
      ];
      expect(out, [
        ChatSseDecoder.openTag, 'r1', ChatSseDecoder.closeTag,
        'a1',
        ChatSseDecoder.openTag, 'r2', ChatSseDecoder.closeTag,
        'a2',
      ]);
    });

    test('空 delta / 非 choices 块被忽略', () {
      final d = ChatSseDecoder();
      expect(d.feedChunk({}), isEmpty);
      expect(d.feedChunk({'choices': []}), isEmpty);
      expect(d.feedChunk({'choices': [{'delta': {}}]}), isEmpty);
    });

    test('timings 归一为 {n_gen,t_gen_ms,t_prompt_ms}（native 口径）', () {
      final d = ChatSseDecoder();
      d.feedChunk({
        'choices': [
          {'delta': {'content': 'x'}}
        ],
        'timings': {'predicted_n': 12, 'predicted_ms': 2400, 'prompt_ms': 800},
      });
      expect(d.timings, {'n_gen': 12, 't_gen_ms': 2400, 't_prompt_ms': 800});
    });
  });

  group('ChatSseDecoder · raw 模式（/completion）', () {
    test('只取顶层 content，忽略 choices', () {
      final d = ChatSseDecoder(rawMode: true);
      expect(d.feedChunk({'content': 'hello '}), ['hello ']);
      expect(d.feedChunk(_chatChunk(content: 'ignored')), isEmpty);
      expect(d.feedChunk({'content': 'world'}), ['world']);
      expect(d.tokens, 2);
    });
  });

  group('sseDataLines', () {
    test('多 chunk 字节流拆 data: 载荷；忽略空行/注释', () async {
      final raw = Stream<List<int>>.value(utf8.encode(
        'data: {"a":1}\n\n'
        ': ping\n'
        'event: whatever\n'
        'data: [DONE]\n',
      ));
      final out = await LocalServerInference.sseDataLines(raw).toList();
      expect(out, ['{"a":1}', '[DONE]']);
    });

    test('非 utf8 字节不炸流（allowMalformed）', () async {
      final bytes = <int>[
        ...utf8.encode('data: {"ok":1}\n'),
        0xFF, 0xFE, 0x41, // 非法 utf8
        ...utf8.encode('\ndata: {"ok":2}\n'),
      ];
      final out =
          await LocalServerInference.sseDataLines(Stream.value(bytes)).toList();
      expect(out.first, '{"ok":1}');
      expect(out.last, contains('{"ok":2}'));
    });
  });

  group('上下文超裁自愈（M1-d 实案：ctx 调小后续跑历史超新 ctx → 400）', () {
    test('溢出措辞识别', () {
      expect(LocalServerInference.isContextOverflowText(
              'Request processing failed: prompt (700 tokens) exceeds ctx (512)'),
          isTrue);
      expect(
          LocalServerInference.isContextOverflowText('n_ctx too small'), isTrue);
      expect(
          LocalServerInference.isContextOverflowText('invalid argument: tools'),
          isFalse);
    });

    test('有 system：保 system+末位，裁最旧中间轮', () {
      final body = <String, dynamic>{
        'messages': [
          {'role': 'system', 'content': 'S'},
          {'role': 'user', 'content': 'u1'},
          {'role': 'assistant', 'content': 'a1'},
          {'role': 'user', 'content': 'u2'},
          {'role': 'assistant', 'content': 'a2'},
          {'role': 'user', 'content': 'u3'},
        ],
      };
      expect(LocalServerInference.trimOldestHistory(body), isTrue);
      expect((body['messages'] as List)[1]['content'], 'a1'); // 裁掉了 u1
      expect(LocalServerInference.trimOldestHistory(body), isTrue);
      expect(LocalServerInference.trimOldestHistory(body), isTrue);
      expect(LocalServerInference.trimOldestHistory(body), isFalse); // 下限
      expect(body['messages'], hasLength(3));
      expect((body['messages'] as List).last['content'], 'u3'); // 末位永不裁
    });

    test('无 system / 太短 / 坏形态不裁', () {
      expect(
          LocalServerInference.trimOldestHistory({
            'messages': [
              {'role': 'user', 'content': 'u1'},
              {'role': 'user', 'content': 'u2'},
            ]
          }),
          isFalse);
      expect(LocalServerInference.trimOldestHistory({'messages': 'bad'}), isFalse);
      expect(LocalServerInference.trimOldestHistory({}), isFalse);
    });
  });
}
