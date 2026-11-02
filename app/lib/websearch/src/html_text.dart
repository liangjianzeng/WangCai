/// HTML/XML 文本清洗工具（解析各引擎结果页共用）。
library;

/// 去掉所有标签，保留文本内容。
String stripTags(String html) =>
    html.replaceAll(RegExp(r'<!--.*?-->', dotAll: true), '').replaceAll(RegExp(r'<[^>]+>'), '');

/// 常见命名实体 + 数字实体解码（搜索引擎结果页里高频出现的那些）。
String decodeEntities(String s) {
  var out = s
      .replaceAll('&nbsp;', ' ')
      .replaceAll('&ensp;', ' ')
      .replaceAll('&emsp;', ' ')
      .replaceAll('&amp;', '&')
      .replaceAll('&lt;', '<')
      .replaceAll('&gt;', '>')
      .replaceAll('&quot;', '"')
      .replaceAll('&#39;', "'")
      .replaceAll('&apos;', "'")
      .replaceAll('&mdash;', '—')
      .replaceAll('&ndash;', '–')
      .replaceAll('&hellip;', '…')
      .replaceAll('&middot;', '·')
      .replaceAll('&#0183;', '·')
      .replaceAll('&#183;', '·')
      .replaceAll('&#8203;', ''); // zero-width space
  // 数字实体（十进制/十六进制）兜底。
  out = out.replaceAllMapped(RegExp(r'&#(\d+);'), (m) {
    final v = int.tryParse(m.group(1)!);
    return v == null ? m.group(0)! : String.fromCharCode(v);
  });
  out = out.replaceAllMapped(RegExp(r'&#x([0-9a-fA-F]+);'), (m) {
    final v = int.tryParse(m.group(1)!, radix: 16);
    return v == null ? m.group(0)! : String.fromCharCode(v);
  });
  return out;
}

/// 折叠空白（结果页源码里摘要常带换行/多空格）。
String collapseWhitespace(String s) => s.replaceAll(RegExp(r'\s+'), ' ').trim();

/// 三连：去标签 → 解码实体 → 折叠空白。
String htmlToText(String html) => collapseWhitespace(decodeEntities(stripTags(html)));

/// 截断过长的文本，超长补省略号。
String clipText(String s, int maxChars) =>
    s.length <= maxChars ? s : '${s.substring(0, maxChars)}…';
