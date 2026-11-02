// KV 管理 / 压缩重构回归（2026-10-06）：
//
// 1. token 估算器：中文加权（旧 chars/4 口径对中文低估 ~3 倍，
//    主动压缩迟迟不触发直到撞服务端硬墙）。
// 2. CompactionStats：压缩必须可观测——before/after token、遮蔽数、来源。
import 'package:flutter_test/flutter_test.dart';
import 'package:tongyi_lite/agent/context_eng/compaction.dart';
import 'package:tongyi_lite/agent/context_eng/token_estimate.dart';
import 'package:tongyi_lite/agent/loop/failure.dart';
import 'package:tongyi_lite/agent/session/event.dart';
import 'package:tongyi_lite/agent/session/session.dart';

void main() {
  group('estimateContextTokens（中文加权）', () {
    test('纯 ASCII ≈ 4 字符/token', () {
      // 400 个 ASCII 字符 ≈ 100 token。
      expect(estimateContextTokens([
        {'role': 'user', 'content': 'a' * 400},
      ]), 100);
    });

    test('纯中文 ≈ 0.75 token/字（不再 chars/4 低估 3 倍）', () {
      // 400 个汉字 → 300 token（旧口径只有 100）。
      final est = estimateContextTokens([
        {'role': 'user', 'content': '中' * 400},
      ]);
      expect(est, 300);
    });

    test('混合文本按字符集分别计权', () {
      // 40 ASCII（10 tok）+ 40 汉字（30 tok）= 40。
      final text = 'abcdefghij' * 4 + '混合中文测试字符' * 5;
      expect(text.runes.length, 80);
      final est = estimateContextTokens([
        {'role': 'user', 'content': text},
      ]);
      expect(est, 10 + 30);
    });

    test('tool_calls 按每 call ~40 tok 计入', () {
      final est = estimateContextTokens([
        {
          'role': 'assistant',
          'content': '',
          'tool_calls': [1, 2, 3],
        },
      ]);
      expect(est, 120);
    });
  });

  group('CompactionStats（压缩可观测）', () {
    SessionLog buildOldRoundsLog() {
      final log = SessionLog.fromEvents(const []);
      log.append(kEventSystemMessage, {'content': 'sys'},
          source: const {'kind': 'system'});
      for (var i = 1; i <= 8; i++) {
        log.append(kEventUserMessage, {'content': '用户任务诉求 $i'});
        log.append(kEventStepStart, {'turn': i, 'step': 1});
        log.append(kEventToolCall, {
          'callId': 'c$i',
          'name': 'web_search',
          'arguments': {'q': '查询$i'},
        });
        log.append(kEventToolResult, {
          'callId': 'c$i',
          'name': 'web_search',
          'content': '搜索结果内容$i' * 20, // ~140 CJK 字 → 旧区有大户可裁
        });
        log.append(kEventStepEnd, {'turn': i, 'step': 1});
        log.append(kEventTurnEnd, {'turn': i, 'reason': 'completed'});
      }
      return log;
    }

    test('success 时带统计：before > after、遮蔽数、provider', () async {
      final log = buildOldRoundsLog();
      final result = await DeterministicCompaction(keepRounds: 5)
          .decide(ref: SessionRef(log), turn: 0, step: 0, reason: 'x');
      expect(result.kind, CompactionResultKind.success);
      final stats = result.stats;
      expect(stats, isNotNull);
      expect(stats!.beforeTokens, greaterThan(0));
      expect(stats.afterTokens, lessThan(stats.beforeTokens));
      expect(stats.savedTokens, greaterThan(0));
      expect(stats.maskedEvents, greaterThan(0));
      expect(stats.provider, 'deterministic-prune');
      expect(stats.summaryChars, greaterThan(0));
    });

    test('failure 时 stats 为 null（无前进无可报）', () async {
      final log = SessionLog.fromEvents(const []);
      log.append(kEventSystemMessage, {'content': 'sys'},
          source: const {'kind': 'system'});
      log.append(kEventUserMessage, {'content': '只有一轮'});
      final result = await DeterministicCompaction(keepRounds: 5)
          .decide(ref: SessionRef(log), turn: 0, step: 0, reason: 'x');
      expect(result.kind, CompactionResultKind.failure);
      expect(result.stats, isNull);
    });
  });
}
