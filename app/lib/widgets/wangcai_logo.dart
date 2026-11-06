// 汪柴品牌 Logo（2026-11-06 用户定案）：替换 TongYi-Lite 时代遗留的
// Material `auto_awesome` 紫星占位。唯一出处 = 本组件；所有需要品牌标识的
// 界面一律走本组件，避免尺寸/圆角/形态各处漂移。
//
// 两个形态（源图 repo assets/ 存档）：
// - [WangCaiLogoVariant.square]：蓝底方版（assets/wangchai_logo.png），
//   侧栏 / 关于卡等需要"实心磁贴"感的场合。
// - [WangCaiLogoVariant.cutout]：透明底抠图（assets/wangchai_logo_cutout.png），
//   消息界面空会话占位等需要融入背景的场合。
import 'package:flutter/widgets.dart';

enum WangCaiLogoVariant { square, cutout }

class WangCaiLogo extends StatelessWidget {
  const WangCaiLogo({
    super.key,
    this.size = 30,
    this.radius = 10,
    this.variant = WangCaiLogoVariant.square,
  });

  /// 边长（正方形）。
  final double size;

  /// 圆角半径（跟随宿主卡片/磁贴风格）。
  final double radius;

  /// 形态：蓝底方版 / 透明底抠图。
  final WangCaiLogoVariant variant;

  static const String squareAsset = 'assets/wangchai_logo.png';
  static const String cutoutAsset = 'assets/wangchai_logo_cutout.png';

  @override
  Widget build(BuildContext context) => ClipRRect(
        borderRadius: BorderRadius.all(Radius.circular(radius)),
        child: Image.asset(
          variant == WangCaiLogoVariant.cutout ? cutoutAsset : squareAsset,
          width: size,
          height: size,
          fit: BoxFit.cover,
        ),
      );
}
