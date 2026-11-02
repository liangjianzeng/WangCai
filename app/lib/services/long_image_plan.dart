/// 长图切块「纯规划」——无任何 dart:ui / dart:io 依赖，可被普通 dart VM 直接
/// 运行验证（tool/plan_selfcheck.dart）。由 long_image_service.dart 重导出。
library;

import 'dart:math' as math;

/// 长图判定阈值：高/宽超过此值才切块。
const double kLongImageAspectThreshold = 2.0;

/// 图块目标高宽比（h ≈ w × 1.25，接近拍照构图，模型友好）。
const double kLongImageTileAspect = 1.25;

/// 相邻图块纵向重叠比例（避免文字行被拦腰截断）。
const double kLongImageOverlapRatio = 0.08;

/// 纯规划：在「已缩放到 [width]×[height]」的坐标系里规划竖向切块。
///
/// 返回 `[]` 表示不是长图（不需要切块）；否则返回按 y 严格递增的 `[y, h]` 列表，
/// 保证：所有块并集完整覆盖 `[0, height]`（不丢内容）、相邻块严格递增、
/// 每块 ≥1 高、块数 ≤ maxSlices + 1（末尾兜底块只在极端取整场景出现）。
List<List<int>> planLongImageSlices({
  required int width,
  required int height,
  double longAspect = kLongImageAspectThreshold,
  int maxSlices = 10,
  double tileAspect = kLongImageTileAspect,
  double overlapRatio = kLongImageOverlapRatio,
}) {
  if (width <= 0 || height <= 0) return const [];
  if (height <= width * longAspect) return const [];
  if (maxSlices < 1) maxSlices = 1;

  int tileH = math.max(width, (width * tileAspect).round());
  int overlap = (tileH * overlapRatio).round();
  if (overlap >= tileH) overlap = math.max(0, tileH - 1);

  int n = ((height - overlap) / (tileH - overlap)).ceil();
  if (n < 1) n = 1;
  if (n > maxSlices) {
    // 超长图：块数封顶，反解最小块高让 n 块（含 n-1 次重叠）刚好覆盖。
    n = maxSlices;
    tileH = ((height + (n - 1) * overlap) / n).ceil();
  }

  final slices = <List<int>>[];
  final int step = math.max(1, tileH - overlap);
  for (var i = 0; i < n; i++) {
    final int y = i * step;
    if (y >= height) break;
    final int h = math.min(tileH, height - y);
    if (h <= 0) break;
    slices.add([y, h]);
    if (y + h >= height) break; // 已覆盖到底
  }
  // 取整兜底：若仍有未覆盖的底部残条，补一块（内容绝不丢失优先于块数）。
  var covered = 0;
  for (final s in slices) {
    covered = math.max(covered, s[0] + s[1]);
  }
  if (covered < height) {
    slices.add([covered, height - covered]);
  }
  return slices;
}
