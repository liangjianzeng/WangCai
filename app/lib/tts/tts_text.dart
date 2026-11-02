/// TTS 文本预处理（纯函数，可单测）。
///
/// `cleanTextForTts`：把 markdown 回答清洗成适合朗读的纯文本——
/// 代码块/图片/裸链接整体剔除（读出来毫无意义），行内代码/链接保留可读
/// 部分，标题/列表/表格符号剥离。
///
/// `segmentForTts`：按句子边界分段（单段 ≤[maxChars] 字），供逐段合成
/// 逐段播放——长回复不必等整篇合成完才出声。
library;

/// 单段合成最大字符数（中文约 1.5-2 分钟朗读量；Edge 端点单请求也有
/// 字节上限，包内部还会兜底再切）。
const int kTtsSegmentMaxChars = 600;

/// 清洗 markdown 为可朗读文本。
String cleanTextForTts(String raw) {
  var t = raw;
  // 代码块整体剔除（连同语言标注行）；保留一条提示避免上下文断裂突兀。
  t = t.replaceAll(
      RegExp(r'```[^\n]*\n?[\s\S]*?```', multiLine: true), '（代码略）');
  // 未闭合代码块（流式截尾）剥到结尾。
  t = t.replaceAll(RegExp(r'```[^\n]*\n?[\s\S]*$'), '（代码略）');
  // 行内代码去反引号保留内容。
  t = t.replaceAllMapped(RegExp(r'`([^`]*)`'), (m) => m.group(1)!);
  // 图片整体剔除；链接保留文字。
  t = t.replaceAll(RegExp(r'!\[[^\]]*\]\([^)]*\)'), '');
  t = t.replaceAllMapped(
      RegExp(r'\[([^\]]*)\]\([^)]*\)'), (m) => m.group(1)!);
  // 裸 URL 剔除（读 URL 是灾难）。
  t = t.replaceAll(RegExp(r'https?://\S+'), '');
  // 标题/引用/表格符号/强调标记。
  t = t.replaceAll(RegExp(r'^#{1,6}\s*', multiLine: true), '');
  t = t.replaceAll(RegExp(r'^>\s*', multiLine: true), '');
  t = t.replaceAll(RegExp(r'^\s*[-*+]\s+', multiLine: true), '');
  t = t.replaceAll(RegExp(r'^\s*\|[-:|\s]*\|\s*$', multiLine: true), '');
  t = t.replaceAll('|', '，');
  t = t.replaceAllMapped(RegExp(r'\*\*([^*]+)\*\*'), (m) => m.group(1)!);
  t = t.replaceAllMapped(RegExp(r'(?<!\w)\*([^*\n]+)\*(?!\w)'),
      (m) => m.group(1)!);
  // 表情符号（朗读无意义）。
  t = t.replaceAll(
      RegExp(r'[\u{1F000}-\u{1FAFF}\u{2600}-\u{27BF}\u{FE0F}]',
          unicode: true),
      '');
  // 清理残留markdown横线
  t = t.replaceAll(RegExp(r'^\s*---+\s*$', multiLine: true), '');
  // 多余空白收敛。
  t = t.replaceAll(RegExp(r'\n{3,}'), '\n\n');
  return t.trim();
}

/// 按句子边界分段（。！？；!?;\n），单段 ≤[maxChars]；超长单句硬切。
List<String> segmentForTts(String text, {int maxChars = kTtsSegmentMaxChars}) {
  final out = <String>[];
  // 在句子结束符（含其后引号/括号）处切；补一个 \n 保证末句也能匹配到。
  final pattern = RegExp(r'[\s\S]*?[。！？；!?;\n]["』」）)]?');
  final sentences =
      pattern.allMatches('$text\n').map((m) => m.group(0)!).toList();
  final buf = StringBuffer();
  var len = 0;
  void flush() {
    if (buf.toString().trim().isNotEmpty) out.add(buf.toString());
    buf.clear();
    len = 0;
  }

  for (var sentence in sentences) {
    if (sentence.trim().isEmpty) continue;
    // 超长单句（无边界符）先硬切成 ≤maxChars 的块。
    if (sentence.length > maxChars) {
      flush();
      for (var i = 0; i < sentence.length; i += maxChars) {
        final end = (i + maxChars > sentence.length)
            ? sentence.length
            : i + maxChars;
        out.add(sentence.substring(i, end));
      }
      continue;
    }
    if (len + sentence.length > maxChars && len > 0) flush();
    buf.write(sentence);
    len += sentence.length;
  }
  flush();
  // trimRight：句尾补位用的 '\n' 不外泄（对朗读无影响）。
  return out.map((s) => s.trimRight()).toList();
}
