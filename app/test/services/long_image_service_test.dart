/// 长截图视觉预处理单测：
/// - 纯规划函数 [planLongImageSlices]：判定/覆盖完整性/递增/块数上限；
/// - dart:ui 切片往返：真实生成超长 PNG → 切块 → 逐块解码验证宽度与数量。
import 'dart:io';
import 'dart:ui' as ui;

import 'package:flutter_test/flutter_test.dart';
import 'package:tongyi_lite/services/long_image_service.dart';

/// 断言：块 y 严格递增、每块 >0 高、并集完整覆盖 [0, height)。
void expectFullCoverage(List<List<int>> plan, int height) {
  expect(plan, isNotEmpty);
  final covered = List<bool>.filled(height, false);
  int? prevY;
  for (final s in plan) {
    final y = s[0], h = s[1];
    expect(h, greaterThan(0));
    expect(y, greaterThanOrEqualTo(0));
    expect(y + h, lessThanOrEqualTo(height));
    if (prevY != null) expect(y, greaterThan(prevY));
    prevY = y;
    for (var i = y; i < y + h; i++) covered[i] = true;
  }
  expect(covered.every((e) => e), isTrue, reason: '存在未覆盖行');
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  group('planLongImageSlices', () {
    test('非长图不切块（aspect ≤ 2）', () {
      expect(planLongImageSlices(width: 100, height: 150), isEmpty);
      expect(planLongImageSlices(width: 100, height: 200), isEmpty);
      expect(planLongImageSlices(width: 0, height: 100), isEmpty);
      expect(planLongImageSlices(width: 100, height: 0), isEmpty);
    });

    test('典型手机长截图：完整覆盖 + 块数合理', () {
      final plan = planLongImageSlices(width: 768, height: 2772);
      expect(plan.length, greaterThan(1));
      expect(plan.length, lessThanOrEqualTo(10));
      expectFullCoverage(plan, 2772);
    });

    test('极长图：块数封顶 maxSlices（+兜底块至多 1）', () {
      final plan =
          planLongImageSlices(width: 768, height: 60000, maxSlices: 10);
      expect(plan.length, lessThanOrEqualTo(11));
      expectFullCoverage(plan, 60000);
    });

    test('边界：高 201 / 宽 100 → 切块且覆盖完整', () {
      final plan = planLongImageSlices(width: 100, height: 201);
      expectFullCoverage(plan, 201);
    });

    test('多种尺寸扫描：长图恒完整覆盖，非长图恒不切', () {
      for (final w in [256, 768, 1080, 1280]) {
        for (final h in [
          (256 * 2.5).round(),
          5000,
          12345,
          99999,
        ]) {
          final plan = planLongImageSlices(width: w, height: h);
          if (h > w * 2) {
            expectFullCoverage(plan, h);
          } else {
            expect(plan, isEmpty, reason: '${w}x$h 非长图不应切块');
          }
        }
      }
    });
  });

  group('LongImageService.prepareVisionImages（dart:ui 真实切片）', () {
    test('2000px 高长图 → 多块输出、宽度封顶、逐块可解码', () async {
      // 用普通 test()（真异步）+ 已初始化的 TestWidgetsFlutterBinding：
      // dart:ui 可正常解码/编码，文件 IO 也不受 fake-async 干扰。
      final tmp = await Directory.systemTemp.createTemp('long_img_test');
      try {
        // 构造 100×2000 的 PNG（模拟长截图）。
        final recorder = ui.PictureRecorder();
        final canvas = ui.Canvas(recorder);
        canvas.drawRect(
          const ui.Rect.fromLTWH(0, 0, 100, 2000),
          ui.Paint()..color = const ui.Color(0xFF123456),
        );
        final img = recorder.endRecording().toImageSync(100, 2000);
        final data = await img.toByteData(format: ui.ImageByteFormat.png);
        img.dispose();
        final src = File('${tmp.path}/long.png');
        await src.writeAsBytes(data!.buffer.asUint8List());

        final out = await LongImageService.prepareVisionImages(
          [src.path],
          widthCap: 50,
          outputDir: tmp,
        );
        // 长图被切成多块（不放大：100 宽原图按 cap=50 降采样到 50×1000）。
        expect(out.length, greaterThan(1));
        final plan = planLongImageSlices(width: 50, height: 1000);
        expect(out.length, plan.length);

        for (var i = 0; i < out.length; i++) {
          final f = File(out[i]);
          expect(await f.exists(), isTrue, reason: '第 $i 块未落盘');
          final buffer = await ui.ImmutableBuffer.fromFilePath(out[i]);
          final desc = await ui.ImageDescriptor.encoded(buffer);
          expect(desc.width, 50, reason: '第 $i 块宽度未按封顶缩放');
          expect(desc.height, plan[i][1], reason: '第 $i 块高度与规划不符');
          desc.dispose();
          buffer.dispose();
        }
      } finally {
        await tmp.delete(recursive: true);
      }
    });

    test('普通小图原样返回（不重编码）', () async {
      final tmp = await Directory.systemTemp.createTemp('long_img_small');
      try {
        final recorder = ui.PictureRecorder();
        final canvas = ui.Canvas(recorder);
        canvas.drawRect(
          const ui.Rect.fromLTWH(0, 0, 200, 300),
          ui.Paint()..color = const ui.Color(0xFF00FF00),
        );
        final img = recorder.endRecording().toImageSync(200, 300);
        final data = await img.toByteData(format: ui.ImageByteFormat.png);
        img.dispose();
        final src = File('${tmp.path}/small.png');
        await src.writeAsBytes(data!.buffer.asUint8List());

        final out = await LongImageService.prepareVisionImages(
          [src.path],
          widthCap: 768,
          outputDir: tmp,
        );
        expect(out, [src.path]);
      } finally {
        await tmp.delete(recursive: true);
      }
    });

    test('不存在的文件：原样返回不抛异常', () async {
      final out = await LongImageService.prepareVisionImages(
        ['/nonexistent/dir/img.jpg'],
        widthCap: 768,
        outputDir: Directory.systemTemp,
      );
      expect(out, ['/nonexistent/dir/img.jpg']);
    });
  });
}
