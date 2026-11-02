import 'dart:async';
import 'package:flutter/services.dart';

/// PDF 文本抽取原生桥（TomRoush/PdfBox-Android，`com.dgxspark.tongyilite/pdf` 通道）。
/// 替代原手搓纯 Dart 解析器（pdf_text_extractor.dart，2026-09-30 已弃用删除）。
///
/// Kotlin handler 契约：
/// - 成功：result.success({ok:true, pageCount:int, pages:[String,...]})
/// - 需密码：result.error('ENCRYPTED', 'PDF 加密且需要密码')
/// - 其它失败：result.error('PDF_ERROR', <e.message>)
class PdfExtractResult {
  final bool ok;
  final int pageCount;
  final List<String> pages;
  /// 失败原因说明（给 UI / 模型 note 用）。成功时为 null。
  final String? note;

  const PdfExtractResult({
    required this.ok,
    required this.pageCount,
    required this.pages,
    this.note,
  });

  /// 所有页拼起来。
  String get joined => pages.join('\n');
}

class NativePdfService {
  static const String _channelName = 'com.dgxspark.tongyilite/pdf';
  static final MethodChannel _channel = MethodChannel(_channelName);

  /// 抽取指定文件（绝对路径）的 PDF 各页文本。
  static Future<PdfExtractResult> extractText(String path) async {
    try {
      final dynamic raw =
          await _channel.invokeMethod<Map<String, dynamic>>(
              'extractPdfText', {'path': path});
      if (raw is! Map<String, dynamic>) {
        return PdfExtractResult(
            ok: false,
            pageCount: 0,
            pages: const [],
            note: 'PDF 解析失败（原生桥无响应），已原样保存');
      }
      final res = raw as Map<String, dynamic>;
      final pages = (res['pages'] as List<dynamic>? ?? const [])
          .map((e) => e is String ? e : '')
          .toList();
      return PdfExtractResult(
        ok: res['ok'] == true,
        pageCount: res['pageCount'] is int ? res['pageCount'] as int : 0,
        pages: pages,
      );
    } on PlatformException catch (e) {
      if (e.code == 'ENCRYPTED') {
        return PdfExtractResult(
            ok: false,
            pageCount: 0,
            pages: const [],
            note: 'PDF 加密（需密码），已原样保存');
      }
      return PdfExtractResult(
          ok: false,
          pageCount: 0,
          pages: const [],
          note: 'PDF 解析失败（${e.message ?? '未知错误'}），已原样保存');
    } on Exception catch (e) {
      return PdfExtractResult(
          ok: false,
          pageCount: 0,
          pages: const [],
          note: 'PDF 解析失败（桥接异常），已原样保存');
    }
  }
}
