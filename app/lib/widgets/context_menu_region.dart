// v0.0.4 Phase 3：右键/长按上下文菜单。
// Flutter 3.27 尚无 widgets.ContextMenuRegion（上游后来才加），仓内自实现
// 等价件：PopupRoute（透明 barrier，点外即关）+ AdaptiveTextSelectionToolbar
// 定位。API 形态对齐上游（enabled / contextMenuBuilder(ctx, offset)），
// SDK 具备后可直接替换 import。
import 'package:flutter/material.dart';

class ContextMenuRegion extends StatelessWidget {
  const ContextMenuRegion({
    super.key,
    required this.child,
    required this.contextMenuBuilder,
    this.enabled = true,
  });

  final Widget child;

  /// 返回菜单本体（一般用 AdaptiveTextSelectionToolbar.buttonItems；
  /// 按钮的 onPressed 里 Navigator.pop 关闭本菜单）。
  final Widget Function(BuildContext context, Offset position)
      contextMenuBuilder;

  final bool enabled;

  void _show(BuildContext context, Offset position) {
    Navigator.of(context, rootNavigator: true).push(_ContextMenuRoute(
      position: position,
      contextMenuBuilder: contextMenuBuilder,
    ));
  }

  @override
  Widget build(BuildContext context) {
    if (!enabled) return child;
    return GestureDetector(
      behavior: HitTestBehavior.opaque,
      onSecondaryTapUp: (d) => _show(context, d.globalPosition),
      // 长按也弹（触屏习惯）；桌面主路径是右键。
      onLongPressStart: (d) => _show(context, d.globalPosition),
      child: child,
    );
  }
}

class _ContextMenuRoute extends PopupRoute<void> {
  _ContextMenuRoute({
    required this.position,
    required this.contextMenuBuilder,
  });

  final Offset position;
  final Widget Function(BuildContext, Offset) contextMenuBuilder;

  @override
  Color? get barrierColor => null;

  @override
  bool get barrierDismissible => true;

  @override
  String? get barrierLabel => '关闭菜单';

  @override
  Duration get transitionDuration => Duration.zero;

  @override
  Widget buildPage(BuildContext context, Animation<double> animation,
      Animation<double> secondaryAnimation) {
    return Stack(children: [
      // 点外关闭（透明 barrier；PopupRoute 自带 modal barrier 已拦指针，
      // 这里再兜一层保证任何指针路径都可关闭）。
      Positioned.fill(
        child: GestureDetector(
          behavior: HitTestBehavior.translucent,
          onTap: () => Navigator.of(context).pop(),
          child: const SizedBox.expand(),
        ),
      ),
      contextMenuBuilder(context, position),
    ]);
  }
}
