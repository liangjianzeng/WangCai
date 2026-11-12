/// 生图提示词扩写确认卡（2026-11-12「一实例三角色」方案，交互用户定案
/// 「先扩写，确认后再生图」）。
///
/// 渲染条件见 [ImageGenConfirmUnit]：assistant 消息 genMeta 带未确认
/// `pendingImageGen:{original,rewritten,…}`。卡面 = 可编辑扩写文（预填，
/// 用户改多少算多少）+ 折叠「原话」+ 三键：
///   「🎨 生图」编辑框现值走 [confirmImageGen]；「用原话」原始提示词直发；
///   「重扩」对 original 再扩一次刷新卡面（扩写失败保持现卡）。
/// 确认后 genMeta.confirmed=true → 本卡不再渲染，消息回归普通回答文本，
/// 出图进度由生图占位卡（imageGenJobsProvider）接管。
library;

import 'dart:convert';

import 'package:flutter/material.dart';

import '../models/chat_message.dart';

class ImageGenConfirmCard extends StatefulWidget {
  const ImageGenConfirmCard({
    super.key,
    required this.message,
    required this.busy,
    required this.onConfirm,
    required this.onUseOriginal,
    required this.onRegenerate,
  });

  /// genMeta 带 pendingImageGen 的 assistant 消息（重扩后同 id 内容更新，
  /// didUpdateWidget 跟随刷新编辑框）。
  final ChatMessage message;

  /// 本会话有生图 job 在跑 → 三键全部禁用（防并发双发）。
  final bool busy;

  /// 「🎨 生图」：编辑框现值（用户没改就是扩写文）。
  final Future<void> Function(String editedPrompt) onConfirm;

  /// 「用原话」：原始提示词直发生图。
  final Future<void> Function() onUseOriginal;

  /// 「重扩」：对 original 再扩一次。
  final Future<void> Function() onRegenerate;

  @override
  State<ImageGenConfirmCard> createState() => _ImageGenConfirmCardState();
}

class _ImageGenConfirmCardState extends State<ImageGenConfirmCard> {
  late final TextEditingController _controller =
      TextEditingController(text: _rewritten);
  bool _originalExpanded = false;
  bool _regen = false; // 重扩在途（转圈 + 防连点）
  bool _submitting = false; // 确认在途（job 起来前的一瞬也锁键）

  Map<String, dynamic> get _meta {
    try {
      final j = jsonDecode(widget.message.genMeta ?? '');
      if (j is Map<String, dynamic>) return j;
    } catch (_) {}
    return const {};
  }

  String get _original => _meta['original']?.toString() ?? widget.message.content;
  String get _rewritten =>
      _meta['rewritten']?.toString() ?? widget.message.content;

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  @override
  void didUpdateWidget(covariant ImageGenConfirmCard oldWidget) {
    super.didUpdateWidget(oldWidget);
    // 重扩落库后同 id 消息刷新：内容变了且用户没在手改 → 跟上最新扩写文。
    if (widget.message.genMeta != oldWidget.message.genMeta &&
        _controller.text == (_rewrittenOf(oldWidget) ?? '')) {
      _controller.text = _rewritten;
    }
  }

  static String? _rewrittenOf(ImageGenConfirmCard w) {
    try {
      final j = jsonDecode(w.message.genMeta ?? '');
      if (j is Map<String, dynamic>) return j['rewritten']?.toString();
    } catch (_) {}
    return null;
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final disabled = widget.busy || _submitting;
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 4),
      child: Card(
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            mainAxisSize: MainAxisSize.min,
            children: [
              Row(
                children: [
                  Icon(Icons.auto_awesome,
                      size: 16, color: theme.colorScheme.primary),
                  const SizedBox(width: 8),
                  Expanded(
                    child: Text('生图确认 · 扩写后可编辑',
                        style: TextStyle(
                            fontSize: 13,
                            fontWeight: FontWeight.w600,
                            color: theme.colorScheme.onSurfaceVariant)),
                  ),
                ],
              ),
              const SizedBox(height: 6),
              // 折叠「原话 → 扩写」：默认收起省屏，点开对读。
              InkWell(
                onTap: () => setState(
                    () => _originalExpanded = !_originalExpanded),
                child: Padding(
                  padding: const EdgeInsets.symmetric(vertical: 2),
                  child: Row(
                    children: [
                      Icon(
                          _originalExpanded
                              ? Icons.expand_less
                              : Icons.expand_more,
                          size: 16,
                          color: theme.colorScheme.onSurfaceVariant),
                      const SizedBox(width: 4),
                      Expanded(
                        child: Text(
                          _originalExpanded ? '原话' : '原话：$_original',
                          maxLines: _originalExpanded ? 1 : 2,
                          overflow: TextOverflow.ellipsis,
                          style: TextStyle(
                              fontSize: 12,
                              color: theme.colorScheme.onSurfaceVariant),
                        ),
                      ),
                    ],
                  ),
                ),
              ),
              if (_originalExpanded)
                Padding(
                  padding: const EdgeInsets.fromLTRB(20, 2, 0, 4),
                  child: Text(_original,
                      style: TextStyle(
                          fontSize: 12,
                          color: theme.colorScheme.onSurfaceVariant)),
                ),
              const SizedBox(height: 2),
              TextField(
                controller: _controller,
                enabled: !disabled,
                maxLines: 5,
                minLines: 2,
                style: const TextStyle(fontSize: 14),
                decoration: const InputDecoration(
                  isDense: true,
                  border: OutlineInputBorder(),
                ),
              ),
              const SizedBox(height: 6),
              Row(
                mainAxisAlignment: MainAxisAlignment.end,
                children: [
                  TextButton(
                    onPressed:
                        disabled ? null : () => widget.onUseOriginal(),
                    child: const Text('用原话'),
                  ),
                  const SizedBox(width: 4),
                  TextButton.icon(
                    onPressed: (disabled || _regen)
                        ? null
                        : () async {
                            setState(() => _regen = true);
                            try {
                              await widget.onRegenerate();
                            } finally {
                              if (mounted) setState(() => _regen = false);
                            }
                          },
                    icon: _regen
                        ? const SizedBox(
                            width: 14,
                            height: 14,
                            child: CircularProgressIndicator(strokeWidth: 2))
                        : const Icon(Icons.refresh, size: 16),
                    label: const Text('重扩'),
                  ),
                  const SizedBox(width: 8),
                  FilledButton.icon(
                    onPressed:
                        disabled ? null : () => _confirm(_controller.text),
                    icon: const Icon(Icons.brush, size: 16),
                    label: const Text('🎨 生图'),
                  ),
                ],
              ),
            ],
          ),
        ),
      ),
    );
  }

  Future<void> _confirm(String edited) async {
    setState(() => _submitting = true);
    try {
      await widget.onConfirm(edited);
    } finally {
      if (mounted) setState(() => _submitting = false);
    }
  }
}
