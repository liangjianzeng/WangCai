/// 长截图视觉预处理 —— 把「又长又窄」的截图竖切成多张宽度封顶的近似方块图块。
///
/// 背景（2026-10 定案）：选图此前用 image_picker 的 maxWidth/maxHeight=768
/// 把**两边**都压进 768——1280×2772 的长截图被挤成 ~354×768 的糊图，任何视觉
/// 模型都会反馈「分辨率太低无法识别」。正确做法是**按宽度封顶、竖向切块**：
/// 每张图块保持封顶宽度（文字可读），高度 ≈ 宽度 × tileAspect，块间留少量
/// 重叠避免拦腰截断文字行。发送端把图块当多张图片一起送（本地/API 均已支持）。
///
/// 纯规划函数 [planLongImageSlices] 与 dart:ui 解码/编码分离，前者可直接单测。
library;

import 'dart:io';
import 'dart:math' as math;
import 'dart:ui' as ui;

import 'package:flutter/foundation.dart';
import 'package:path_provider/path_provider.dart';

import 'long_image_plan.dart';

export 'long_image_plan.dart'
    show
        kLongImageAspectThreshold,
        kLongImageTileAspect,
        kLongImageOverlapRatio,
        planLongImageSlices;

/// 单次解码像素上限（RGBA ≈ 4×该字节；36M px ≈ 144MB，防止超长图整解 OOM）。
const int kLongImageMaxDecodePixels = 36 * 1000 * 1000;

/// 长图/大图视觉预处理服务。
class LongImageService {
  LongImageService._();

  /// 批量预处理：对每个路径判断是否长图，长图切块、普通大图缩放到上限，
  /// 返回实际可发给视觉模型的路径列表（可能比输入多——长图变多块）。
  ///
  /// [widthCap] 宽度封顶（本地视觉建议 768，API 视觉可用 1280）。
  /// [outputDir] 图块输出目录（测试注入；缺省 `ApplicationSupport/vision_slices`）。
  /// 单张处理失败不阻断整体：该张回退原路径（至少发得出图）。
  static Future<List<String>> prepareVisionImages(
    List<String> paths, {
    required int widthCap,
    int maxSlices = 10,
    Directory? outputDir,
  }) async {
    if (paths.isEmpty) return const [];
    final outDir = outputDir ?? await _defaultSlicesDir();
    final result = <String>[];
    for (final path in paths) {
      try {
        result.addAll(await _prepareOne(
          path,
          outDir,
          widthCap: widthCap,
          maxSlices: maxSlices,
        ));
      } catch (e, st) {
        // 解码/编码失败 → 原样返回（普通照片本就能用；长图则退回旧行为）。
        // 留一条 debug 日志便于排障（不炸 UI）。
        debugPrint('[LongImageService] 预处理失败($path): $e\n$st');
        result.add(path);
      }
    }
    return result;
  }

  static Future<List<String>> _prepareOne(
    String path,
    Directory outDir, {
    required int widthCap,
    required int maxSlices,
  }) async {
    final file = File(path);
    if (!await file.exists()) return [path];
    final buffer = await ui.ImmutableBuffer.fromFilePath(path);
    // 只读元数据拿原始宽高（ImageDescriptor 不解码像素）。
    final desc = await ui.ImageDescriptor.encoded(buffer);
    buffer.dispose();
    final int w0 = desc.width;
    final int h0 = desc.height;
    if (w0 <= 0 || h0 <= 0) {
      desc.dispose();
      return [path];
    }

    final stamp = DateTime.now().millisecondsSinceEpoch;
    final stem = _basename(path).replaceAll(RegExp(r'[^A-Za-z0-9_-]'), '_');

    if (h0 <= w0 * kLongImageAspectThreshold) {
      // 普通图：仅当超出尺寸上限时整图缩到上限内（保持纵横比），否则原样用。
      if (w0 <= widthCap && h0 <= widthCap) {
        desc.dispose();
        return [path];
      }
      final scale = math.min(widthCap / w0, widthCap / h0);
      final tw = math.max(1, (w0 * scale).round());
      final th = math.max(1, (h0 * scale).round());
      final img = await _decodeScaled(desc, tw, th);
      try {
        final bytes = await img.toByteData(format: ui.ImageByteFormat.png);
        if (bytes == null) return [path];
        final out =
            '${outDir.path}/${stem}_${stamp}_${tw}x$th.png';
        await File(out).writeAsBytes(bytes.buffer.asUint8List(), flush: true);
        return [out];
      } finally {
        img.dispose();
      }
    }

    // 长图：宽度封顶，纵向切块（小长图按原宽处理，不放大——codec 不会
    // 放大解码，请求放大尺寸会直接报解码失败）。
    final int Wt = math.min(widthCap, w0);
    final int Ht = math.max(1, (h0 * Wt / w0).round());
    // 解码像素守卫：整解一次内存超限 → 按可承受尺寸降档解码，
    // 切块画布再映射回目标坐标（只影响画质不影响结构）。
    int decW = Wt, decH = Ht;
    if (Wt * Ht > kLongImageMaxDecodePixels) {
      final shrink = math.sqrt(kLongImageMaxDecodePixels / (Wt * Ht));
      decW = math.max(64, (Wt * shrink).round());
      decH = math.max(1, (h0 * decW / w0).round());
    }
    return _sliceDecoded(desc, decW, decH, Wt, Ht,
        outDir, '$stem-$stamp', maxSlices);
  }

  /// 整解到 [decW]×[decH] 后按规划切块（规划坐标系 [W]×[H]，正常时两者相等；
  /// 像素守卫降档时 dec < 画布，drawImageRect 顺带放大回目标坐标）。
  /// 每块落一张 PNG。接收 [desc] 所有权。
  static Future<List<String>> _sliceDecoded(
    ui.ImageDescriptor desc,
    int decW,
    int decH,
    int W,
    int H,
    Directory outDir,
    String stem,
    int maxSlices,
  ) async {
    final slices = planLongImageSlices(
      width: W,
      height: H,
      maxSlices: maxSlices,
    );
    if (slices.isEmpty) {
      desc.dispose();
      return const []; // 不应到达（调用方已判长图）
    }
    final img = await _decodeScaled(desc, decW, decH);
    // 源→画布纵向映射：以**实际解码尺寸**为准（codec 对目标尺寸可能有一两
    // 像素取整），正常时为 1。
    final sy = img.height / H;
    final outPaths = <String>[];
    try {
      for (var i = 0; i < slices.length; i++) {
        final y = slices[i][0];
        final sh = slices[i][1];
        final recorder = ui.PictureRecorder();
        final canvas = ui.Canvas(recorder);
        // 整块拷贝（无二次失真；守卫降档时才有轻度放大）。
        canvas.drawImageRect(
          img,
          ui.Rect.fromLTWH(
              0, y * sy, img.width.toDouble(), (sh > 0 ? sh : 1) * sy),
          ui.Rect.fromLTWH(0, 0, W.toDouble(), sh.toDouble()),
          ui.Paint(),
        );
        // 同步出图（toImageSync）：绕开异步 Picture.toImage 在 flutter_tester
        // 下不回调的坑，App 内语义完全一致且更快。
        final sliceImg = recorder.endRecording().toImageSync(W, sh);
        final bytes =
            await sliceImg.toByteData(format: ui.ImageByteFormat.png);
        sliceImg.dispose();
        if (bytes == null) continue;
        final out = '${outDir.path}/${stem}_${i}_${W}x$sh.png';
        await File(out).writeAsBytes(bytes.buffer.asUint8List(), flush: true);
        outPaths.add(out);
      }
    } finally {
      img.dispose();
    }
    if (outPaths.isEmpty) return const [];
    return outPaths;
  }

  static Future<ui.Image> _decodeScaled(
    ui.ImageDescriptor desc,
    int targetWidth,
    int targetHeight,
  ) async {
    // 解码期缩放（targetWidth/Height 按比例传入 → 无畸变），比全尺寸解码省内存。
    // ⚠️ Codec 解码期间借用 desc 的原生资源：desc 必须在 getNextFrame 之后
    // 才能释放（实测提前 dispose → "Codec failed to produce an image"）。
    try {
      final codec = await desc.instantiateCodec(
        targetWidth: targetWidth,
        targetHeight: targetHeight,
      );
      final frame = await codec.getNextFrame();
      codec.dispose();
      return frame.image;
    } finally {
      desc.dispose();
    }
  }

  static Future<Directory> _defaultSlicesDir() async {
    final base = await getApplicationSupportDirectory();
    final dir = Directory('${base.path}/vision_slices');
    if (!await dir.exists()) {
      await dir.create(recursive: true);
    }
    // 尽力清理 7 天前的旧图块（失败静默）。
    try {
      final cutoff = DateTime.now().subtract(const Duration(days: 7));
      await for (final e in dir.list()) {
        if (e is! File) continue;
        try {
          final st = await e.stat();
          if (st.modified.isBefore(cutoff)) await e.delete();
        } catch (_) {}
      }
    } catch (_) {}
    return dir;
  }

  static String _basename(String p) {
    final i = p.replaceAll('\\', '/').lastIndexOf('/');
    var name = i >= 0 ? p.substring(i + 1) : p;
    final dot = name.lastIndexOf('.');
    if (dot > 0) name = name.substring(0, dot);
    return name.isEmpty ? 'img' : name;
  }
}
