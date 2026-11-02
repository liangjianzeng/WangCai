/// API 档上下文生命周期三修复的回归测试（2026-10-01，对照 DSH 差距分析 Tier 1）。
///
/// 覆盖：
/// - 工具结果投影剪枝（deriveModelMessages >8192 字符 → 头 4096 + 省略标记 +
///   尾 1024；存储原文不动、UI 视图完整）；
/// - buildSystemPrompt 的 environmentNote 段（注入/不注入，稳定前缀不被破坏）。
library;

import 'package:flutter_test/flutter_test.dart';
import 'package:tongyi_lite/agent/llm/adapter.dart';
import 'package:tongyi_lite/agent/loop/agent.dart';
import 'package:tongyi_lite/agent/session/session.dart';
import 'package:tongyi_lite/agent/tool_definition.dart';
import 'package:tongyi_lite/agent/tool_registry.dart';

import '../helpers/fake_llm.dart';

ToolDefinition _tool(String name) => ToolDefinition(
      name: name,
      description: '测试工具 $name',
      parameters: {'type': 'object', 'properties': {}, 'required': []},
      execute: (args) => Future.value(const ToolResult(content: 'ok')),
    );

void main() {
  group('工具结果投影剪枝（tool-result-pruner）', () {
    test('短结果原样投影', () {
      final log = SessionLog.fromEvents([]);
      log.append(kEventToolResult, {
        'callId': 'c1',
        'content': '短结果',
        'isError': false,
      });
      final msgs = log.deriveModelMessages();
      expect(msgs.single['content'], '短结果');
    });

    test('超长结果投影为头 4096 + 省略标记 + 尾 1024', () {
      final content = 'H' * 4096 +
          'M' * 6000 + // 中段将被省略
          'T' * 1024;
      final log = SessionLog.fromEvents([]);
      log.append(kEventToolResult, {
        'callId': 'c1',
        'content': content,
        'isError': false,
      });
      final msgs = log.deriveModelMessages();
      final projected = msgs.single['content'] as String;
      expect(projected.startsWith('H' * 4096), isTrue);
      expect(projected.endsWith('T' * 1024), isTrue);
      expect(projected.contains('中间省略 6000 字符'), isTrue);
      // 投影长度远小于原文
      expect(projected.length, lessThan(content.length));
    });

    test('存储原文不动：rawEvents 事件里仍是完整内容', () {
      final content = 'X' * 20000;
      final log = SessionLog.fromEvents([]);
      log.append(kEventToolResult, {'callId': 'c1', 'content': content});
      final raw = log.rawEvents
          .firstWhere((e) => e.type == kEventToolResult)
          .data['content'] as String;
      expect(raw.length, 20000);
      // 投影两次结果一致（纯函数，每步重建可复现）
      expect(log.deriveModelMessages().single['content'],
          log.deriveModelMessages().single['content']);
    });

    test('UI 视图（deriveChatMessages）完整显示不剪枝', () {
      final content = 'Y' * 20000;
      final log = SessionLog.fromEvents([]);
      log.append(kEventToolResult, {'callId': 'c1', 'content': content});
      final ui = log.deriveChatMessages();
      expect(ui.single.content.length, 20000);
    });
  });

  group('系统提示环境快照段（ReactLoopAgent.environmentNote）', () {
    test('传 environmentNote → 追加【环境】段且位于系统提示最末', () {
      final log = SessionLog.fromEvents([]);
      ReactLoopAgent(
        session: log,
        adapter: FakeLlmAdapter(const []),
        registry: ToolRegistry()..register(_tool('get_time')),
        modelId: 'test-model',
        providerKind: ProviderKind.local,
        systemPrompt: 'BASE PROMPT',
        agentsMd: 'GUIDE MD',
        environmentNote: '当前时间：2026-10-01 15:00（星期四）',
      );
      final sys = log.rawEvents
          .firstWhere((e) => e.type == kEventSystemMessage)
          .data['content'] as String;
      expect(sys.startsWith('BASE PROMPT'), isTrue);
      expect(sys.contains('<workspace:guidance>'), isTrue);
      // 环境段在 AGENTS.md 之后、恒置最末（稳定前缀在前，cache 友好）。
      expect(sys.indexOf('<workspace:guidance>'), lessThan(sys.indexOf('【环境】')));
      expect(
          sys.endsWith('【环境】当前时间：2026-10-01 15:00（星期四）'), isTrue);
    });

    test('不传 environmentNote → 系统提示不含【环境】段（local 档 KV 稳定）', () {
      final log = SessionLog.fromEvents([]);
      ReactLoopAgent(
        session: log,
        adapter: FakeLlmAdapter(const []),
        registry: ToolRegistry()..register(_tool('get_time')),
        modelId: 'test-model',
        providerKind: ProviderKind.local,
        systemPrompt: 'BASE PROMPT',
      );
      final sys = log.rawEvents
          .firstWhere((e) => e.type == kEventSystemMessage)
          .data['content'] as String;
      expect(sys.contains('【环境】'), isFalse);
    });
  });
}
