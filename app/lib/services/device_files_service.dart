import 'package:flutter/services.dart';

/// 文件产物桥（WP6）：Dart → Kotlin MethodChannel。
///
/// - [exportFile]：工作区文件复制到公共下载目录 `Download/TongYi-Lite/`
///   （targetSdk 33+ 走 MediaStore），返回 content:// URI；
/// - [openFile]：系统查看器打开（content URI 或应用内绝对路径）。
class DeviceFilesService {
  DeviceFilesService._();

  static final DeviceFilesService instance = DeviceFilesService._();

  static const MethodChannel _channel =
      MethodChannel('com.dgxspark.tongyilite/files');

  /// 导出文件到下载目录，成功返回 content:// URI。
  Future<String> exportFile({required String src, String? name}) async {
    final uri = await _channel.invokeMethod<String>(
      'exportFile',
      {'src': src, if (name != null && name.isNotEmpty) 'name': name},
    );
    // Kotlin 侧 `insert` 失败时返回 null（存储权限被拒、下载提供程序异常、ROM 抽风）。
    // 以前这里 `?? ''` 把"没成功"折算成"成功，只是位置是空串"，两个调用方都把空串当 URI 用了出去：
    // 插件流程报"导出完成"、智能体回一句"已导出："后面什么都没有。
    // **空串不是 URI** —— 交付与否只能由"拿得到位置"来证明，宁可抛给调用方去报错。
    if (uri == null || uri.trim().isEmpty) {
      throw PlatformException(
        code: 'export_no_uri',
        message: '下载目录没有给回文件位置（${name ?? src}）—— 文件没交到用户手上',
      );
    }
    return uri;
  }

  /// 另存产物到用户指定目录（2026-10-25）：系统文件选择器（SAF）选目录
  /// +文件名，流式写入。源二选一：[srcPath]（工作区文件，优先）或
  /// [srcUri]（Download 里已导出的 content URI）。用户取消抛 code=CANCELLED。
  Future<String> saveAs({
    String? srcPath,
    String? srcUri,
    required String name,
  }) async {
    final uri = await _channel.invokeMethod<String>('saveAs', {
      if (srcPath != null && srcPath.isNotEmpty) 'srcPath': srcPath,
      if (srcUri != null && srcUri.isNotEmpty) 'srcUri': srcUri,
      'name': name,
    });
    if (uri == null || uri.trim().isEmpty) {
      throw PlatformException(
        code: 'save_no_uri',
        message: '另存没有返回目标位置（$name）—— 文件可能没有写进去',
      );
    }
    return uri;
  }

  /// 用系统应用打开（html/png/pdf/md 等）。失败抛 PlatformException。
  /// [fallbackPath]：content URI 被拒时改用的工作区源文件路径
  ///（Kotlin 侧 FileProvider 分层回退；应用自有文件授权必成功）。
  Future<void> openFile(String path, {String? fallbackPath}) async {
    await _channel.invokeMethod<void>('openFile', {
      'path': path,
      if (fallbackPath != null && fallbackPath.isNotEmpty)
        'fallbackPath': fallbackPath,
    });
  }
}
