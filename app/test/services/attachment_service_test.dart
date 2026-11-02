import 'dart:convert';
import 'dart:io';

import 'package:archive/archive.dart';
import 'package:tongyi_lite/services/attachment_service.dart';
import 'package:flutter_test/flutter_test.dart';

// ---------------------------------------------------------------------------
// WP-A：智能体附件解析（纯函数部分——zip 抽取与 prompt 注入块）
// ---------------------------------------------------------------------------

/// 造一个 docx 形状的 zip（word/document.xml）。
File _makeFakeDocx(String path, String documentXml) {
  final bytes = utf8.encode(documentXml);
  final archive = Archive()
    ..addFile(ArchiveFile('word/document.xml', bytes.length, bytes));
  File(path).writeAsBytesSync(ZipEncoder().encode(archive)!);
  return File(path);
}

void main() {
  test('docxToText：段落换行 + 剥标签 + 实体解码', () {
    final dir = Directory.systemTemp.createTempSync('att-test');
    addTearDown(() => dir.deleteSync(recursive: true));
    final docx = _makeFakeDocx(
      '${dir.path}${Platform.pathSeparator}a.docx',
      '<?xml version="1.0"?><w:document><w:body>'
      '<w:p><w:r><w:t>第一段：摘要 &amp; 结论</w:t></w:r></w:p>'
      '<w:p><w:r><w:t>第二段&lt;数据&gt;</w:t></w:r></w:p>'
      '</w:body></w:document>',
    );
    final text = docxToText(docx.path);
    expect(text, isNotNull);
    expect(text, contains('第一段：摘要 & 结论'));
    expect(text, contains('第二段<数据>'));
    expect(text!.split('\n').length, 2);
  });

  test('docxToText：损坏 zip → null（不抛）', () {
    final dir = Directory.systemTemp.createTempSync('att-test2');
    addTearDown(() => dir.deleteSync(recursive: true));
    final bad = File('${dir.path}${Platform.pathSeparator}b.docx')
      ..writeAsBytesSync([1, 2, 3, 4]);
    expect(docxToText(bad.path), isNull);
  });

  test('buildAttachmentPromptBlock：短文本内联 / 长文本指引 read_file / 不解析说明',
      () {
    final inline = PreparedAttachment(
      displayName: 'note.txt',
      storedPath: '/x/note.txt',
      extractedText: '今天买咖啡',
      workspaceTextPath: '/ws/_uploads/note.txt.txt',
    );
    final inlineBlock = buildAttachmentPromptBlock([inline]);
    expect(inlineBlock, contains('[用户上传了 1 个附件'));
    expect(inlineBlock, contains('<<<附件内容开始'));
    expect(inlineBlock, contains('今天买咖啡'));

    final big = PreparedAttachment(
      displayName: 'report.docx',
      storedPath: '/x/report.docx',
      extractedText: 'x' * 8000,
      workspaceTextPath: '/ws/_uploads/report.docx.txt',
    );
    final bigBlock = buildAttachmentPromptBlock([big]);
    expect(bigBlock, contains('read_file'));
    expect(bigBlock, contains('workspace/_uploads/report.docx.txt'));
    expect(bigBlock, isNot(contains('<<<附件内容开始')));

    final pdf = PreparedAttachment(
      displayName: 'scan.pdf',
      storedPath: '/x/scan.pdf',
      note: 'PDF 无文本层（可能是扫描件/图片型），已原样保存',
    );
    expect(buildAttachmentPromptBlock([pdf]), contains('已原样保存'));

    expect(buildAttachmentPromptBlock(const []), isEmpty);
  });

  test('白名单：办公/文本格式在列，exe/doc 不在', () {
    expect(kSupportedExtensions, contains('.docx'));
    expect(kSupportedExtensions, contains('.xlsx'));
    expect(kSupportedExtensions, contains('.pptx'));
    expect(kSupportedExtensions, contains('.pdf'));
    expect(kSupportedExtensions, contains('.md'));
    expect(kSupportedExtensions, isNot(contains('.exe')));
    expect(kSupportedExtensions, isNot(contains('.doc')));
  });
}
