// ============================================================
// 对话区过程行原语（2026-10-25 对话区重构阶段 2，对齐 DSH）。
//
// - [toolVariantOf]/[toolVariantSummary]：工具名 → 展示 variant 的纯函数
//   分类 + 参数摘要键优先级（DSH toolRowModel 同构），摘要取"第一个字符串
//   参数的首行"，不再 60 字 JSON 截断。
// - [SweepHighlight]：running 态扫光动画（300px 渐变光带 2.6s 循环）——
//   全 app 唯一 spinner 原则下的"执行中"结构化表达。
// - [DisclosureRow]：折叠行底座（图标+标题+点+单行摘要+chevron，整行点击），
//   ToolRow / ReasoningRow / 后续 notice 行族共用。
// ============================================================

import 'dart:convert';

import 'package:flutter/material.dart';

/// 工具展示 variant（对齐 DSH toolRowModel 的分类思路）。
enum ToolVariant { shell, read, write, edit, search, web, ask, todo, code, other }

/// 工具名 → variant。表格只列端侧真实工具名，未命中 = other。
ToolVariant toolVariantOf(String name) {
  switch (name) {
    case 'shell_exec':
    case 'run_code':
    case 'adb': // 远程 shell/注入：与本机 shell 同一形态（图标=终端）
      return ToolVariant.shell;
    case 'read_file':
      return ToolVariant.read;
    case 'write_file':
    case 'save_skill':
    case 'export_file':
      return ToolVariant.write;
    case 'edit_file':
      return ToolVariant.edit;
    case 'web_search':
      return ToolVariant.search;
    case 'fetch_url':
      return ToolVariant.web;
    case 'ask_user_question':
      return ToolVariant.ask;
    case 'todo_write':
      return ToolVariant.todo;
    default:
      return ToolVariant.other;
  }
}

/// 每类 variant 的摘要参数键优先级（命中第一个非空字符串参数）。
const Map<ToolVariant, List<String>> _kSummaryKeys = {
  // 'action' 给 adb（一个工具槽 + 动作枚举）：adb shell 有 command 优先显命令，
  // tap/screenshot 这类无 command 的动作退回显动作名。其余 shell 类工具无此参数。
  ToolVariant.shell: ['description', 'command', 'action', 'script'],
  ToolVariant.read: ['path', 'file_path', 'url'],
  ToolVariant.write: ['path', 'file_path', 'name'],
  ToolVariant.edit: ['path', 'file_path'],
  ToolVariant.search: ['query', 'q'],
  ToolVariant.web: ['url'],
  ToolVariant.ask: ['question'],
  ToolVariant.todo: ['title'],
  ToolVariant.code: ['description', 'script'],
  ToolVariant.other: ['path', 'query', 'url', 'name', 'description', 'command'],
};

/// 折叠行摘要：按 variant 键优先级取第一个字符串参数的**首行**；
/// 无命中返回 null（调用方回退参数 JSON 截断等旧口径）。
String? toolVariantSummary(ToolVariant variant, Map<String, dynamic> args) {
  for (final key in _kSummaryKeys[variant] ?? const <String>[]) {
    final v = args[key];
    if (v is String && v.trim().isNotEmpty) {
      final line = v.trim().split('\n').first.trim();
      return line.isEmpty ? null : line;
    }
  }
  return null;
}

/// running 态扫光：300px 渐变光带从左到右 2.6s 循环（DSH 工具行/思考行
/// 同款节奏）。[active] = false 时原样返回 child。
class SweepHighlight extends StatefulWidget {
  final bool active;
  final Widget child;
  const SweepHighlight({super.key, required this.active, required this.child});

  @override
  State<SweepHighlight> createState() => _SweepHighlightState();
}

class _SweepHighlightState extends State<SweepHighlight>
    with SingleTickerProviderStateMixin {
  late final AnimationController _ctrl;

  @override
  void initState() {
    super.initState();
    _ctrl = AnimationController(
        vsync: this, duration: const Duration(milliseconds: 2600));
    if (widget.active) _ctrl.repeat();
  }

  @override
  void didUpdateWidget(SweepHighlight old) {
    super.didUpdateWidget(old);
    if (widget.active && !_ctrl.isAnimating) {
      _ctrl.repeat();
    } else if (!widget.active && _ctrl.isAnimating) {
      _ctrl.stop();
    }
  }

  @override
  void dispose() {
    _ctrl.dispose();
    super.dispose();
  }  @override
  Widget build(BuildContext context) {
    final child = widget.child;
    if (!widget.active) return child;
    final base = Theme.of(context).colorScheme.surfaceContainerHighest;
    return ClipRect(
      child: AnimatedBuilder(
        animation: _ctrl,
        builder: (context, _) {
          return CustomPaint(
            foregroundPainter: _SweepPainter(
              t: _ctrl.value,
              color: base.withValues(alpha: 0.55),
            ),
            child: child,
          );
        },
      ),
    );
  }
}

class _SweepPainter extends CustomPainter {
  final double t; // 0..1
  final Color color;
  _SweepPainter({required this.t, required this.color});

  @override
  void paint(Canvas canvas, Size size) {
    // 90% 时间走完全程，末 10% 停顿（DSH keyframes 同款）。
    final p = (t / 0.9).clamp(0.0, 1.0);
    final w = size.width;
    final band = w.clamp(120.0, 300.0).toDouble();
    final x = -band + (w + band) * p;
    final rect = Rect.fromLTWH(x, 0, band, size.height);
    canvas.drawRect(
      rect,
      Paint()
        ..shader = LinearGradient(
          colors: [color.withValues(alpha: 0), color, color.withValues(alpha: 0)],
        ).createShader(rect),
    );
  }

  @override
  bool shouldRepaint(_SweepPainter oldDelegate) =>
      oldDelegate.t != t || oldDelegate.color != color;
}

/// 折叠行底座：`[leading] 标题 · 摘要 … [trailing] [chevron]`，整行点击
/// 展开/收起 [body]（null = 不可展开，chevron 隐藏）。
class DisclosureRow extends StatelessWidget {
  final Widget leading;
  final String title;
  final String? summary;

  /// 摘要/标题颜色（错误行传 error 色）。
  final Color? summaryColor;
  final bool expanded;
  final VoidCallback? onToggle;
  final Widget? body;
  final List<Widget> trailing;

  const DisclosureRow({
    super.key,
    required this.leading,
    required this.title,
    this.summary,
    this.summaryColor,
    this.expanded = false,
    this.onToggle,
    this.body,
    this.trailing = const [],
  });

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return InkWell(
      borderRadius: BorderRadius.circular(6),
      onTap: body == null ? null : onToggle,
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          mainAxisSize: MainAxisSize.min,
          children: [
            Row(
              children: [
                leading,
                const SizedBox(width: 6),
                Flexible(
                  child: Text(title,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: TextStyle(
                          fontSize: 12, color: summaryColor ?? theme.colorScheme.onSurface)),
                ),
                if (summary != null && summary!.isNotEmpty) ...[
                  const SizedBox(width: 6),
                  Expanded(
                    child: Text(
                      summary!,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: TextStyle(
                          fontSize: 11, color: summaryColor ?? theme.colorScheme.outline),
                    ),
                  ),
                ],
                ...trailing,
                if (body != null)
                  Icon(
                    expanded ? Icons.expand_less : Icons.expand_more,
                    size: 14,
                    color: theme.colorScheme.onSurfaceVariant,
                  ),
              ],
            ),
            if (expanded && body != null) body!,
          ],
        ),
      ),
    );
  }
}

/// 参数 JSON 美化（展开体 IN 段）。
String prettyArgsJson(Map<String, dynamic> args) {
  try {
    return const JsonEncoder.withIndent('  ').convert(args);
  } catch (_) {
    return args.toString();
  }
}
