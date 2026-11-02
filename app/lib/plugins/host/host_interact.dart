/// `app.interact` 的宿主实现：把插件的提问变成原生对话框。
///
/// 为什么值得单独做一个能力而不是让插件自己弹框：插件拿不到 `BuildContext`，
/// 也不该拿到 —— 提问的样式、取消语义、键盘类型由平台统一，作者只说"要一个数"。
/// 听写的「间隔几秒」走的就是这里（与智能体 `ask_user_question` 同一种交互形状）。
library;

import 'package:flutter/material.dart';
import 'package:plugin_kernel/plugin_kernel.dart';

/// 用全局 navigator key 弹框（app 已有 `appNavigatorKey`，见 `lib/main.dart`）。
final class HostInteract with CapabilityBase implements Interact {
  HostInteract({required this.navigatorKey, this.log});

  final GlobalKey<NavigatorState> navigatorKey;
  final void Function(String message)? log;

  @override
  final ServiceKey key = const ServiceKey<Interact>('app.interact');

  @override
  bool get available => true;

  @override
  String? get unavailableReason => null;

  BuildContext? get _context => navigatorKey.currentState?.context;

  @override
  Future<Outcome<double?>> askNumber({
    required String question,
    required double defaultValue,
    required double min,
    required double max,
  }) async {
    final context = _context;
    if (context == null) {
      return Outcome.err<double?>(
        code: PluginFailureKind.runtimeError,
        message: '现在弹不出提问框',
        hint: '回到对话页再试一次',
      );
    }
    log?.call('提问（数字）：$question');
    final presets = <double>[
      for (final v in const [1.0, 2.0, 3.0, 5.0, 10.0, 15.0, 30.0, 60.0])
        if (v >= min && v <= max) v,
    ];
    final raw = await showDialog<String>(
      context: context,
      builder: (ctx) => _NumberDialog(
        question: question,
        defaultValue: defaultValue,
        min: min,
        max: max,
        presets: presets,
      ),
    );
    if (raw == null) {
      log?.call('用户取消了提问');
      return const Ok<double?>(null);
    }
    final v = double.tryParse(raw.trim());
    if (v == null) {
      return Outcome.err<double?>(
        code: PluginFailureKind.badContent,
        message: '那个数没看懂',
        hint: '请输入 ${min.toStringAsFixed(0)}–${max.toStringAsFixed(0)} 之间的数字',
      );
    }
    if (v < min || v > max) {
      return Outcome.err<double?>(
        code: PluginFailureKind.badContent,
        message: '这个数超出范围了',
        hint: '请输入 ${min.toStringAsFixed(0)}–${max.toStringAsFixed(0)} 之间的数字',
      );
    }
    return Ok<double?>(v);
  }

  @override
  Future<Outcome<String?>> askChoice({
    required String question,
    required List<String> options,
    String? defaultValue,
  }) async {
    final context = _context;
    if (context == null) {
      return Outcome.err<String?>(
        code: PluginFailureKind.runtimeError,
        message: '现在弹不出选择框',
        hint: '回到对话页再试一次',
      );
    }
    if (options.isEmpty) {
      return Outcome.err<String?>(
        code: PluginFailureKind.configInvalid,
        message: '没有可选项',
        hint: '至少要给一个选项',
      );
    }
    log?.call('提问（选择）：$question');
    final picked = await showDialog<String>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: Text(question, style: const TextStyle(fontSize: 16)),
        contentPadding: const EdgeInsets.symmetric(vertical: 8),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            for (final o in options)
              RadioListTile<String>(
                dense: true,
                title: Text(o, style: const TextStyle(fontSize: 14)),
                value: o,
                groupValue: defaultValue,
                onChanged: (v) => Navigator.of(ctx).pop(v),
              ),
          ],
        ),
        actions: [
          TextButton(onPressed: () => Navigator.of(ctx).pop(), child: const Text('取消')),
        ],
      ),
    );
    return Ok<String?>(picked);
  }
}

class _NumberDialog extends StatefulWidget {
  const _NumberDialog({
    required this.question,
    required this.defaultValue,
    required this.min,
    required this.max,
    required this.presets,
  });

  final String question;
  final double defaultValue;
  final double min;
  final double max;
  final List<double> presets;

  @override
  State<_NumberDialog> createState() => _NumberDialogState();
}

class _NumberDialogState extends State<_NumberDialog> {
  late final TextEditingController _controller =
      TextEditingController(text: _fmt(widget.defaultValue));

  static String _fmt(double v) => v == v.roundToDouble() ? v.toStringAsFixed(0) : '$v';

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return AlertDialog(
      title: Text(widget.question, style: const TextStyle(fontSize: 16)),
      content: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          TextField(
            controller: _controller,
            autofocus: true,
            keyboardType: const TextInputType.numberWithOptions(decimal: true),
            onSubmitted: (v) => Navigator.of(context).pop(v),
          ),
          if (widget.presets.isNotEmpty) ...[
            const SizedBox(height: 10),
            Wrap(
              spacing: 6,
              runSpacing: 6,
              children: [
                for (final v in widget.presets)
                  ActionChip(
                    label: Text(_fmt(v), style: const TextStyle(fontSize: 13)),
                    visualDensity: VisualDensity.compact,
                    onPressed: () => Navigator.of(context).pop(_fmt(v)),
                  ),
              ],
            ),
          ],
          const SizedBox(height: 6),
          Text('可填范围 ${_fmt(widget.min)}–${_fmt(widget.max)}',
              style: TextStyle(fontSize: 12, color: Theme.of(context).hintColor)),
        ],
      ),
      actions: [
        TextButton(onPressed: () => Navigator.of(context).pop(), child: const Text('取消')),
        FilledButton(
          onPressed: () => Navigator.of(context).pop(_controller.text),
          child: const Text('确定'),
        ),
      ],
    );
  }
}
