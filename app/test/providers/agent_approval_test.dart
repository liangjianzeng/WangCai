import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:wangcai/providers/agent_approval.dart';

// ---------------------------------------------------------------------------
// v0.0.4.1 DSH pending-interaction 对齐：审批挂起会话 id 的派生 provider。
// 会话列表浮标（Rows.tsx 行状态点语义）据此提示"哪个会话在等用户决议"。
// ---------------------------------------------------------------------------

void main() {
  test('入队带 conversationId → 派生 provider 跟踪；决议后归 null', () async {
    final container = ProviderContainer();
    addTearDown(container.dispose);

    expect(container.read(pendingApprovalConversationProvider), isNull);

    final notifier = container.read(pendingApprovalsProvider.notifier);
    final decision = notifier.enqueue(
      title: '请求执行工具',
      detail: '参数：…',
      conversationId: 'conv-a',
      allowLabel: '允许（仅本次）',
    );

    expect(container.read(pendingApprovalConversationProvider), 'conv-a');

    final pending = container.read(pendingApprovalsProvider)!;
    expect(pending.conversationId, 'conv-a');
    notifier.resolve(pending.id, true);

    expect(await decision, isTrue);
    expect(container.read(pendingApprovalConversationProvider), isNull);
  });

  test('不带 conversationId 的入队不影响派生值（旧调用点兼容）', () async {
    final container = ProviderContainer();
    addTearDown(container.dispose);

    final notifier = container.read(pendingApprovalsProvider.notifier);
    final decision = notifier.enqueue(title: 't', detail: 'd');
    expect(container.read(pendingApprovalConversationProvider), isNull);

    notifier.resolve(container.read(pendingApprovalsProvider)!.id, false);
    expect(await decision, isFalse);
  });
}
