// 汪柴品牌 Logo（2026-11-06 用户定案）：替换 TongYi-Lite 时代遗留的
// Material `auto_awesome` 紫星占位。唯一出处 = assets/wangchai_logo.png
// （源图 assets/wangchai_blue_id_square_295.png，蓝底方版）；所有需要
// 品牌标识的界面一律走本组件，避免尺寸/圆角各处漂移。
import 'package:flutter/widgets.dart';

class WangCaiLogo extends StatelessWidget {
  const WangCaiLogo({super.key, this.size = 30, this.radius = 10});

  /// 边长（正方形）。
  final double size;

  /// 圆角半径（跟随宿主卡片/磁贴风格）。
  final double radius;

  static const String asset = 'assets/wangchai_logo.png';

  @override
  Widget build(BuildContext context) => ClipRRect(
        borderRadius: BorderRadius.all(Radius.circular(radius)),
        child: Image.asset(
          asset,
          width: size,
          height: size,
          fit: BoxFit.cover,
        ),
      );
}
