/// 插件在输入区那个图标的**统一外壳**（宿主侧样式，插件不该自己搓）。
///
/// 为什么宿主管这个样式：插件作者只该说"我要一个入口、什么图标、点了干什么"；
/// 尺寸、密度、间距是**宿主输入区的规矩**。以前各插件自己 `new IconButton(...)`
/// （默认 48dp 见方、图标 24、自带 padding），和旁边的附件「+」按钮
/// （`VisualDensity.compact` + 图标 22 + 36×36 + `padding: EdgeInsets.zero`）摆在一起
/// 就是两种风格 —— 2026-10-24 用户实测原话："插件的样式不太对，应该和其他的那些功能图标
/// 类似的样式封装"。
///
/// 下面的数值与 `home_screen` 输入区那个附件按钮**逐项对齐**，
/// 并由 `test/plugins/plugin_input_icon_test.dart` 钉住：那边改了这边没跟着改，测试就红
/// （样式这种"没人报错只是难看"的东西，只有机检才守得住）。
library;

import 'package:flutter/material.dart';

/// 输入区里的插件入口图标。
class PluginInputIcon extends StatelessWidget {
  const PluginInputIcon({
    super.key,
    required this.icon,
    required this.tooltip,
    this.onPressed,
    this.badgeCount,
  });

  final IconData icon;
  final String tooltip;
  final VoidCallback? onPressed;

  /// 传 >0 时右上角挂个数字徽标（与附件按钮同一个 `Badge` 形态）。
  final int? badgeCount;

  /// 与宿主输入区一致的三个数（测试直接引这几个常量比对，不抄字面量）。
  static const double kIconSize = 22;
  static const double kBoxSize = 36;
  static const VisualDensity kDensity = VisualDensity.compact;

  @override
  Widget build(BuildContext context) {
    final Widget glyph = Icon(icon, size: kIconSize);
    return IconButton(
      visualDensity: kDensity,
      icon: (badgeCount == null || badgeCount! <= 0)
          ? glyph
          : Badge(label: Text('$badgeCount'), child: glyph),
      tooltip: tooltip,
      constraints: const BoxConstraints(minWidth: kBoxSize, minHeight: kBoxSize),
      padding: EdgeInsets.zero,
      onPressed: onPressed,
    );
  }
}
