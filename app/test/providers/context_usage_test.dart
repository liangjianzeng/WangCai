// 上下文占用快照回归（2026-10-06 KV 管理重构）：
//
// 本地引擎 KV 是单实例——快照只对刚测量完的会话有效。切会话/resetContext
// 后必须清掉陈旧值，否则旧会话细条继续显示是误导。
import 'package:flutter_test/flutter_test.dart';
import 'package:tongyi_lite/providers/context_usage_provider.dart';

void main() {
  test('update + usageFor：按会话存取', () {
    final n = ContextUsageNotifier();
    n.update('a', usedTokens: 100, windowTokens: 1000, windowSource: '原生');
    n.update('b', usedTokens: 500, windowTokens: 1000, windowSource: '实测');
    expect(n.usageFor('a')!.fraction, closeTo(0.1, 1e-9));
    expect(n.usageFor('b')!.fraction, closeTo(0.5, 1e-9));
    expect(n.usageFor(null), isNull);
  });

  test('clearExcept：保留指定会话，清掉其余陈旧快照', () {
    final n = ContextUsageNotifier();
    n.update('a', usedTokens: 100, windowTokens: 1000);
    n.update('b', usedTokens: 500, windowTokens: 1000);
    n.clearExcept('b');
    expect(n.usageFor('a'), isNull);
    expect(n.usageFor('b'), isNotNull);
    // 重复 clearExcept 幂等。
    n.clearExcept('b');
    expect(n.usageFor('b'), isNotNull);
  });

  test('clear：resetContext 后全清', () {
    final n = ContextUsageNotifier();
    n.update('a', usedTokens: 100, windowTokens: 1000);
    n.clear();
    expect(n.usageFor('a'), isNull);
  });

  test('fraction 防御：窗口缺失/非法 → null（UI 不显示）', () {
    final n = ContextUsageNotifier();
    n.update('a', usedTokens: 100, windowTokens: null);
    expect(n.usageFor('a')!.hasData, isFalse);
    n.update('a', usedTokens: 100, windowTokens: 0);
    expect(n.usageFor('a')!.hasData, isFalse);
    // 占用超窗口 → 夹紧到 1。
    n.update('a', usedTokens: 2000, windowTokens: 1000);
    expect(n.usageFor('a')!.fraction, 1.0);
  });
}
