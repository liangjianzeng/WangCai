// v0.0.4 Phase 4b（计划书 §5.2）：审批 composer 接管（对齐 DSH ApprovalPanel）。
// 智能体请求用户决议时，此卡片渲染在对话区输入框上方——就地批准/拒绝，
// 不再弹全局对话框打断上下文。请求来自 pendingApprovalsProvider（main.dart
// 的 sandboxApprover / toolPreApprover override 入队）。
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../providers/agent_approval.dart' show pendingApprovalsProvider;

class ApprovalCard extends ConsumerWidget {
  const ApprovalCard({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final pending = ref.watch(pendingApprovalsProvider);
    if (pending == null) return const SizedBox.shrink();
    final scheme = Theme.of(context).colorScheme;
    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 0, 16, 4),
      child: Material(
        color: scheme.secondaryContainer.withValues(alpha: 0.55),
        borderRadius: BorderRadius.circular(12),
        child: Padding(
          padding: const EdgeInsets.fromLTRB(14, 10, 14, 10),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Row(children: [
                Icon(Icons.verified_user_outlined,
                    size: 16, color: scheme.primary),
                const SizedBox(width: 6),
                Expanded(
                  child: Text(pending.title,
                      style: const TextStyle(
                          fontSize: 13, fontWeight: FontWeight.w600)),
                ),
              ]),
              const SizedBox(height: 6),
              Text(pending.detail,
                  style: TextStyle(
                      fontSize: 12, color: scheme.onSurfaceVariant)),
              const SizedBox(height: 8),
              Row(mainAxisAlignment: MainAxisAlignment.end, children: [
                TextButton(
                  onPressed: () => ref
                      .read(pendingApprovalsProvider.notifier)
                      .resolve(pending.id, false),
                  child: const Text('拒绝'),
                ),
                const SizedBox(width: 6),
                FilledButton(
                  onPressed: () => ref
                      .read(pendingApprovalsProvider.notifier)
                      .resolve(pending.id, true),
                  child: Text(pending.allowLabel ?? '允许'),
                ),
              ]),
            ],
          ),
        ),
      ),
    );
  }
}
