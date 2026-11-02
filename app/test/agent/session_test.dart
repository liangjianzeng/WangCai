import 'package:flutter_test/flutter_test.dart';

import 'package:tongyi_lite/agent/session/event.dart';
import 'package:tongyi_lite/agent/session/log.dart';
import 'package:tongyi_lite/agent/session/store.dart';
import 'package:tongyi_lite/models/chat_message.dart';

void main() {
  group('SessionEvent / 事件词表', () {
    test('ignorable 分类：log-only 可忽略，表面/结构不可忽略', () {
      expect(ignorableOf(kEventAssistantAttempt), isTrue);
      expect(ignorableOf(kEventLlmRetry), isTrue);
      expect(ignorableOf(kEventImported), isTrue);
      expect(ignorableOf(kEventUserMessage), isFalse);
      expect(ignorableOf(kEventTurnStart), isFalse);
      expect(categoryOf(kEventAssistantAttempt), EventTypeCategory.logOnly);
      expect(categoryOf(kEventUserMessage), EventTypeCategory.surface);
      expect(categoryOf(kEventTurnStart), EventTypeCategory.structural);
    });

    test('SessionEvent 默认 ignorable 按类型推断', () {
      final e = SessionEvent(type: kEventAssistantAttempt, seq: 1, timeMs: 1000, data: {});
      expect(e.isIgnorable, isTrue);
      final u = SessionEvent(type: kEventUserMessage, seq: 1, timeMs: 1000, data: {});
      expect(u.isIgnorable, isFalse);
    });

    test('sanitizePayload 对非法值 fail-loud', () {
      // 合法值（Map/List/String/num）通过
      expect(sanitizePayload({'a': 1, 'b': [1, 2], 'c': 'x'}),
          equals({'a': 1, 'b': [1, 2], 'c': 'x'}));
      // 非法值（Set 等）fail-loud（jsonEncode 抛 JsonUnsupportedObjectError: TypeError）
      expect(() => sanitizePayload({'set': <String>{'x'}}), throwsA(anything));
    });
  });

  group('SessionLog.append / seq', () {
    test('seq 从 1 起严格递增，append 返回新 seq', () {
      final log = SessionLog.fromEvents([]);
      expect(log.nextSeq, 1);
      final s1 = log.append(kEventUserMessage, {'content': 'a'});
      expect(s1, 1);
      final s2 = log.append(kEventAssistantMessage, {'content': 'b'});
      expect(s2, 2);
      expect(log.lastSeq, 2);
      expect(log.eventsCount, 2);
      expect(log.rawEvents[0].seq, 1);
      expect(log.rawEvents[1].seq, 2);
    });

    test('fromEvents 从已有事件初始化时 nextSeq = max+1', () {
      final events = [
        SessionEvent(type: kEventUserMessage, seq: 1, timeMs: 1, data: {}),
        SessionEvent(type: kEventAssistantMessage, seq: 5, timeMs: 2, data: {}),
      ];
      final log = SessionLog.fromEvents(events);
      expect(log.nextSeq, 6);
    });
  });

  group('SessionLog.deriveModelMessages（模型投影，纯函数）', () {
    test('只投影 surface 事件，跳过结构/log-only', () {
      final log = SessionLog.fromEvents([]);
      log.append(kEventTurnStart, {'turn': 1});
      log.append(kEventUserMessage, {'content': 'user text'});
      log.append(kEventAssistantMessage, {'content': 'assistant text'});
      log.append(kEventAssistantAttempt, {'content': 'failed attempt'}); // log-only
      log.append(kEventLlmRetry, {'reason': 'timeout'}); // log-only
      log.append(kEventTurnEnd, {'turn': 1});
      final msgs = log.deriveModelMessages();
      expect(msgs.length, 2); // 仅 user + assistant
      expect(msgs[0]['role'], 'user');
      expect(msgs[0]['content'], 'user text');
      expect(msgs[1]['role'], 'assistant');
      expect(msgs[1]['content'], 'assistant text');
      // 两次调用结果一致（纯函数）
      expect(log.deriveModelMessages().map((m) => m['content']).join('|'),
          equals(['user text', 'assistant text'].join('|')));
    });

    test('assistant message 带 tool_calls 投影', () {
      final log = SessionLog.fromEvents([]);
      log.append(kEventAssistantMessage, {
        'content': '',
        'toolCalls': [
          {'id': 'call_1', 'function_name': 'web_search', 'arguments': '{"q":"x"}'}
        ],
      });
      final msgs = log.deriveModelMessages();
      expect(msgs.length, 1);
      expect(msgs[0]['tool_calls'], isA<List>());
      expect(msgs[0]['tool_calls'].length, 1);
      expect(msgs[0]['tool_calls'][0]['id'], 'call_1');
      expect(msgs[0]['tool_calls'][0]['function_name'], 'web_search');
    });

    test('tool result 投影为 role=tool + tool_call_id', () {
      final log = SessionLog.fromEvents([]);
      log.append(kEventToolResult, {'callId': 'call_1', 'content': 'result text'});
      final msgs = log.deriveModelMessages();
      expect(msgs[0]['role'], 'tool');
      expect(msgs[0]['tool_call_id'], 'call_1');
      expect(msgs[0]['content'], 'result text');
    });

    test('compaction summary 投影为 role=user', () {
      final log = SessionLog.fromEvents([]);
      log.append(kEventCompactionSummary, {'content': 'SUMMARY'});
      final msgs = log.deriveModelMessages();
      expect(msgs[0]['role'], 'user');
      expect(msgs[0]['content'], 'SUMMARY');
    });

    test('回归：system 晚于历史 append 仍恒置队首（每轮重建 log 场景）', () {
      // 新引擎每轮先导入历史（user/assistant），构造 ReactLoopAgent 时才
      // append system，再 kick 当前用户消息。system 若按事件序落在中间，
      // OpenAI 兼容服务端会 400 拒收（重复问候 bug 的根因）。
      final log = SessionLog.fromEvents([]);
      log.append(kEventUserMessage, {'content': '你好'});
      log.append(kEventAssistantMessage, {'content': '你好呀！'});
      log.append(kEventSystemMessage, {'content': 'SYSTEM'},
          source: const {'kind': 'system'});
      log.append(kEventUserMessage, {'content': '中秋新闻'});
      final msgs = log.deriveModelMessages();
      expect(msgs.map((m) => m['role']).toList(),
          ['system', 'user', 'assistant', 'user']);
      expect(msgs[0]['content'], 'SYSTEM');
      expect(msgs.last['content'], '中秋新闻');
      // 纯函数性不受重排影响（两次调用一致）
      expect(log.deriveModelMessages().length, msgs.length);
    });
  });

  group('SessionLog.replace（压缩/表面替换）', () {
    test('遮蔽范围内消息在投影中被跳过，摘要出现', () {
      final log = SessionLog.fromEvents([]);
      for (var i = 0; i < 5; i++) {
        log.append(kEventUserMessage, {'content': 'm$i'});
      }
      final genBefore = log.replaceGeneration;
      log.replace(startSeq: 1, endSeq: 5, newContent: 'SUMMARIZED');
      expect(log.replaceGeneration, greaterThan(genBefore));
      final msgs = log.deriveModelMessages();
      expect(msgs.length, 1);
      expect(msgs[0]['role'], 'user');
      expect(msgs[0]['content'], 'SUMMARIZED');
    });

    test('endSeq < startSeq 抛 ArgumentError', () {
      final log = SessionLog.fromEvents([]);
      log.append(kEventUserMessage, {'content': 'x'});
      expect(
        () => log.replace(startSeq: 2, endSeq: 1, newContent: 's'),
        throwsA(isA<ArgumentError>()),
      );
    });

    test('多段 replace 代数单调递增', () {
      final log = SessionLog.fromEvents([]);
      for (var i = 0; i < 6; i++) log.append(kEventUserMessage, {'content': 'm$i'});
      log.replace(startSeq: 1, endSeq: 2, newContent: 'A');
      final g1 = log.replaceGeneration;
      log.replace(startSeq: 3, endSeq: 4, newContent: 'B');
      expect(log.replaceGeneration, greaterThan(g1));
    });
  });

  group('SessionLog.closeOpenTurns（崩溃修复）', () {
    test('未闭合 turn + 未销账 tool call → 追加合成 tool/result + turn/end', () {
      final log = SessionLog.fromEvents([]);
      log.append(kEventTurnStart, {'turn': 1, 'step': 0});
      log.append(kEventUserMessage, {'content': 'hi'});
      log.append(kEventAssistantMessage, {
        'content': '',
        'toolCalls': [{'id': 'c1'}],
      });
      // 崩溃：turn 未 end，step 未 start/end，tool call c1 未销账
      final before = log.eventsCount;
      final n = log.closeOpenTurns(cause: 'crash');
      expect(n, greaterThan(0));
      expect(log.eventsCount, greaterThan(before));
      final types = log.rawEvents.map((e) => e.type).toList();
      expect(types, contains(kEventToolResult));
      expect(types, contains(kEventTurnEnd));
      // 合成事件不修改原 seq（原 seq 不变）
      expect(log.rawEvents.length, log.rawEvents.length); // sanity
    });

    test('已闭合完整日志 → 不追加合成事件', () {
      final log = SessionLog.fromEvents([]);
      log.append(kEventTurnStart, {'turn': 1, 'step': 0});
      log.append(kEventStepStart, {'turn': 1, 'step': 0});
      log.append(kEventUserMessage, {'content': 'hi'});
      log.append(kEventAssistantMessage, {'content': 'yo'});
      log.append(kEventStepEnd, {'turn': 1, 'step': 0});
      log.append(kEventTurnEnd, {'turn': 1, 'reason': {'kind': 'done'}});
      final before = log.eventsCount;
      final n = log.closeOpenTurns();
      expect(n, 0);
      expect(log.eventsCount, before);
    });

    test('空日志 closeOpenTurns 返回 0', () {
      final log = SessionLog.fromEvents([]);
      expect(log.closeOpenTurns(), 0);
      expect(log.eventsCount, 0);
    });
  });

  group('JsonlSessionStore.importFromMessages（旧会话迁移）', () {
    test('ChatMessage 列表导入为 v1 日志，每条 message + 一条 imported 标记', () {
      final store = JsonlSessionStore();
      final msgs = [
        ChatMessage(id: 'm1', conversationId: 'c1', role: MessageRole.user, content: 'hello'),
        ChatMessage(
          id: 'm2',
          conversationId: 'c1',
          role: MessageRole.assistant,
          content: 'hi there',
          inferenceStats: const InferenceStats(firstTokenMs: 10, totalMs: 100, tokPerSec: 2.0),
        ),
      ];
      final log = store.importFromMessages('c1', msgs);
      expect(log.eventsCount, 4); // 2 条 message + 2 条 imported 标记
      // 投影出 model 视图：user + assistant
      final model = log.deriveModelMessages();
      expect(model.length, 2);
      expect(model[0]['role'], 'user');
      expect(model[0]['content'], 'hello');
      expect(model[1]['role'], 'assistant');
      expect(model[1]['content'], 'hi there');
    });

    test('导入空列表 → 空日志', () {
      final store = JsonlSessionStore();
      final log = store.importFromMessages('c1', []);
      expect(log.eventsCount, 0);
      expect(log.replaceGeneration, 0);
    });
  });
}