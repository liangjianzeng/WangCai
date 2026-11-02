/// 智能体附件服务（WP-A）：文件上传注入。
///
/// - 白名单格式（常用办公/文本），单会话 ≤[kMaxAttachments] 个、单个 ≤20MB；
/// - 原件复制到 `documents/uploads/<convId>/`（会话可追溯）；
/// - 解析出纯文本：txt/md/csv/json/log/代码类直接读；docx/pptx/xlsx 是 zip，
///   经 archive 解包抽 XML 文本；pdf 走 TomRoush/PdfBox-Android 原生桥
///   （MethodChannel com.dgxspark.tongyilite/pdf，见 native_pdf_service.dart）；
/// - 解析文本写入 `workspace/_uploads/<名>.txt` 供模型 read_file 阅读，
///   短文本（≤[kInlineChars]）由调用方内联进 prompt 让模型立即看到。
library;

import 'dart:convert';
import 'dart:io';

import 'package:archive/archive.dart';
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';

import 'native_pdf_service.dart';

/// 单会话附件上限。
const int kMaxAttachments = 5;

/// 单附件原始大小上限。
const int kMaxAttachmentBytes = 20 * 1024 * 1024;

/// 解析文本超过该字符数不内联（只写工作区让模型 read_file）。
const int kInlineChars = 6000;

/// 解析文本硬上限（超长截断，保护上下文预算）。
const int kMaxExtractedChars = 100000;

/// 支持的扩展名白名单。
const List<String> kSupportedExtensions = [
  '.txt', '.md', '.csv', '.tsv', '.json', '.log', '.xml', '.html', '.htm',
  '.yaml', '.yml', '.ini',
  '.py', '.js', '.ts', '.java', '.kt', '.c', '.cpp', '.h', '.sh', '.sql',
  '.docx', '.pptx', '.xlsx',
  '.pdf',
];

/// 一份已就绪的附件。
class PreparedAttachment {
  /// 原文件名（展示用）。
  final String displayName;

  /// 原件存储路径（documents/uploads/<convId>/）。
  final String storedPath;

  /// 解析文本（null = 不支持解析，如 pdf）。
  final String? extractedText;

  /// 解析文本的工作区路径（workspace/_uploads/…；模型用 read_file 阅读）。
  final String? workspaceTextPath;

  /// 给用户/模型的补充说明（截断、不支持解析等）。
  final String? note;

  /// 是否内联进 prompt（短文本）。
  bool get inline => extractedText != null && extractedText!.length <= kInlineChars;

  const PreparedAttachment({
    required this.displayName,
    required this.storedPath,
    this.extractedText,
    this.workspaceTextPath,
    this.note,
  });
}

/// 校验并准备一个附件：复制原件 + 解析文本 + 写工作区。
/// 失败返回 null 并给出原因（调用方聚合提示用户）。
Future<(PreparedAttachment?, String?)> prepareAttachment(
  String conversationId,
  String srcPath,
) async {
  final file = File(srcPath);
  if (!file.existsSync()) {
    return (null, '文件不存在：$srcPath');
  }
  final name = p.basename(srcPath);
  final ext = p.extension(name).toLowerCase();
  if (!kSupportedExtensions.contains(ext)) {
    return (null, '不支持的格式：$name（支持 ${kSupportedExtensions.join(" ")}）');
  }
  final size = file.lengthSync();
  if (size > kMaxAttachmentBytes) {
    return (null, '$name 超过 20MB 上限');
  }

  // 1) 原件入会话上传目录。
  final docs = await getApplicationDocumentsDirectory();
  final uploadDir = Directory(p.join(docs.path, 'uploads', conversationId));
  if (!uploadDir.existsSync()) uploadDir.createSync(recursive: true);
  // 重名防覆盖：前缀毫秒时间戳。
  final storedName = '${DateTime.now().millisecondsSinceEpoch}_$name';
  final storedPath = p.join(uploadDir.path, storedName);
  file.copySync(storedPath);

  // 2) 解析文本。
  String? text;
  String? note;
  if (ext == '.pdf') {
    final r = await NativePdfService.extractText(storedPath);
    if (!r.ok) {
      text = null;
      note = r.note ?? 'PDF 解析失败，已原样保存';
    } else {
      text = r.joined.trim();
      if (text.isEmpty) {
        text = null;
        note = 'PDF 无文本层（可能是扫描件/图片型），已原样保存';
      }
    }
  } else if (ext == '.docx') {
    text = docxToText(storedPath);
  } else if (ext == '.pptx') {
    text = _pptxToText(storedPath);
  } else if (ext == '.xlsx') {
    text = _xlsxToText(storedPath);
    note = 'xlsx 为近似抽取（字符串单元格），复杂公式/格式未解析';
  } else {
    try {
      text = utf8.decode(file.readAsBytesSync(), allowMalformed: true);
    } catch (e) {
      text = null;
      note = '文本读取失败：$e';
    }
  }

  if (text != null) {
    text = text.trim();
    if (text.isEmpty) {
      text = null;
      note ??= '文件内容为空';
    } else if (text.length > kMaxExtractedChars) {
      text = '${text.substring(0, kMaxExtractedChars)}\n…[已截断，全文原件见附件]';
      note ??= '内容超长已截断';
    }
  }

  // 3) 解析文本写工作区（模型 read_file 入口）。
  String? wsPath;
  if (text != null) {
    final ws = Directory(p.join(docs.path, 'workspace', '_uploads'));
    if (!ws.existsSync()) ws.createSync(recursive: true);
    final wsFile = File(p.join(
        ws.path, '${p.basenameWithoutExtension(name)}$ext.txt'));
    wsFile.writeAsStringSync(text);
    wsPath = wsFile.path;
  }

  return (
    PreparedAttachment(
      displayName: name,
      storedPath: storedPath,
      extractedText: text,
      workspaceTextPath: wsPath,
      note: note,
    ),
    null,
  );
}

/// 生成给模型看的附件说明段（拼在用户 prompt 之后）。
String buildAttachmentPromptBlock(List<PreparedAttachment> attachments) {
  if (attachments.isEmpty) return '';
  final sb = StringBuffer()
    ..writeln()
    ..writeln()
    ..writeln('[用户上传了 ${attachments.length} 个附件，请先阅读再完成任务]');
  for (final a in attachments) {
    sb.writeln('- 附件「${a.displayName}」');
    if (a.inline) {
      sb.writeln('  内容如下：');
      sb.writeln('<<<附件内容开始');
      sb.writeln(a.extractedText);
      sb.writeln('>>>附件内容结束');
    } else if (a.workspaceTextPath != null) {
      sb.writeln('  已解析为文本：workspace/_uploads/${p.basename(a.workspaceTextPath!)}'
          '（${a.extractedText!.length} 字），请用 read_file 阅读后再分析');
    } else {
      sb.writeln('  ${a.note ?? '无法解析内容'}');
    }
  }
  return sb.toString();
}

// ---------------------------------------------------------------------------
// office 格式纯文本抽取（zip + XML 标签剥离；纯 Dart，无平台依赖）
// ---------------------------------------------------------------------------

/// docx：word/document.xml，段落 `</w:p>` 换行，剥其余标签。
String? docxToText(String path) {
  final xml = _readZipEntry(path, 'word/document.xml');
  if (xml == null) return null;
  return _xmlToText(xml, paragraphTags: ['</w:p>', '<w:br/>', '<w:br />']);
}

/// pptx：ppt/slides/slide*.xml 的 `<a:t>` 文本 run，按页分隔。
String? _pptxToText(String path) {
  final bytes = File(path).readAsBytesSync();
  final Archive? archive = tryDecodeZip(bytes);
  if (archive == null) return null;
  final slides = archive.files
      .where((f) =>
          !f.isFile ||
          RegExp(r'^ppt/slides/slide\d+\.xml$').hasMatch(f.name))
      .toList()
    ..sort((a, b) => _slideNo(a.name).compareTo(_slideNo(b.name)));
  final pages = <String>[];
  for (final f in slides) {
    if (!f.isFile) continue;
    final xml = utf8.decode(f.content as List<int>, allowMalformed: true);
    final runs =
        RegExp(r'<a:t>(.*?)</a:t>', dotAll: true).allMatches(xml);
    final page =
        runs.map((m) => _decodeEntities(m.group(1) ?? '')).join('').trim();
    if (page.isNotEmpty) pages.add('--- 第 ${_slideNo(f.name)} 页 ---\n$page');
  }
  return pages.isEmpty ? null : pages.join('\n\n');
}

/// xlsx：xl/sharedStrings.xml 的 `<t>` 字符串池（近似抽取）。
String? _xlsxToText(String path) {
  final xml = _readZipEntry(path, 'xl/sharedStrings.xml');
  if (xml == null) return null;
  final items =
      RegExp(r'<t[^>]*>(.*?)</t>', dotAll: true).allMatches(xml);
  final rows = items
      .map((m) => _decodeEntities(m.group(1) ?? '').trim())
      .where((s) => s.isNotEmpty)
      .toList();
  return rows.isEmpty ? null : rows.join('\n');
}

String? _readZipEntry(String path, String entryName) {
  final archive = tryDecodeZip(File(path).readAsBytesSync());
  if (archive == null) return null;
  for (final f in archive.files) {
    if (f.isFile && f.name == entryName) {
      return utf8.decode(f.content as List<int>, allowMalformed: true);
    }
  }
  return null;
}

/// 解 zip；损坏/非 zip 返回 null（不抛）。
Archive? tryDecodeZip(List<int> bytes) {
  try {
    return ZipDecoder().decodeBytes(bytes);
  } catch (_) {
    return null;
  }
}

int _slideNo(String name) {
  final m = RegExp(r'slide(\d+)\.xml').firstMatch(name);
  return m == null ? 0 : int.tryParse(m.group(1)!) ?? 0;
}

/// XML → 文本：段落标签换行、剥标签、解实体、压空行。
String _xmlToText(String xml, {List<String> paragraphTags = const []}) {
  var s = xml;
  for (final tag in paragraphTags) {
    s = s.replaceAll(tag, '\n');
  }
  s = s
      .replaceAllMapped(RegExp(r'<[^>]*>'), (_) => '')
      .replaceAll('&lt;', '<')
      .replaceAll('&gt;', '>')
      .replaceAll('&quot;', '"')
      .replaceAll('&apos;', "'")
      .replaceAll('&amp;', '&');
  final lines = s
      .split('\n')
      .map((l) => _collapseSpaces(l.trim()))
      .where((l) => l.isNotEmpty);
  return lines.join('\n');
}

String _collapseSpaces(String s) => s.replaceAll(RegExp(r'\s+'), ' ');

String _decodeEntities(String s) => s
    .replaceAll('&lt;', '<')
    .replaceAll('&gt;', '>')
    .replaceAll('&quot;', '"')
    .replaceAll('&apos;', "'")
    .replaceAll('&amp;', '&');
