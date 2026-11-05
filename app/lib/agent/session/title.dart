/// 会话标题推导 —— 对照 DSH `session-title` 包的 normalize 语义。
///
/// DSH 的三层策略（确定性回退 → 可选 LLM → 改名钉住）里，确定性回退是
/// 永远可用的地板；本模块只做这一层（纯函数、零依赖、可单测）。
/// LLM 层在本地 NPU 主打的产品形态下默认不启用（旁路请求会污染 KV /
/// 挤占并发槽），见计划书评估记录。
library;

/// CJK 判定（汉字 + 假名）：主导语言启发。
final RegExp _cjkRe = RegExp(r'[\u4e00-\u9fff\u3040-\u30ff\uac00-\ud7af]');

/// 从首条用户输入推导会话标题（DSH first-prompt 确定性策略）。
///
/// 规则（对照 DSH normalize.ts）：
/// - 拍平空白：换行/制表/连续空白 → 单空格（标题必须是单行）；
/// - 剥正文行首的 markdown 结构标记（`#` `>` `*` `-` 列表符，仅行首）；
/// - CJK 主导（≥6 个 CJK 字符）→ 按字符截断，目标 ≤16 字；
/// - 西文主导 → 按词截断，目标 ≤8 词、≤48 个 UTF-16 单元；
/// - 截断处补 `…`；**码点安全**——绝不劈开代理对（emoji 常见于用户输入）。
String deriveSessionTitle(String prompt) {
  var t = prompt.replaceAll(RegExp(r'\s+'), ' ').trim();
  if (t.isEmpty) return '';
  // 行首 markdown 结构标记逐个剥（'#'/'>' 成串也剥干净；'*'/'-' 仅 "x " 形态）。
  var changed = true;
  while (changed && t.isNotEmpty) {
    changed = false;
    if (t.startsWith('#') || t.startsWith('>')) {
      t = t.substring(1).trimLeft();
      changed = true;
    } else if ((t.startsWith('- ') || t.startsWith('* ')) && t.length > 2) {
      t = t.substring(2).trimLeft();
      changed = true;
    }
  }
  if (t.isEmpty) return '';

  if (_cjkRe.allMatches(t).length >= 6) {
    // CJK 主导：rune 级截断（天然码点安全），目标 16 字。
    final runes = t.runes.toList();
    if (runes.length <= 16) return t;
    return '${String.fromCharCodes(runes.take(16))}…';
  }

  // 西文主导：词数目标 8，再对长度兜底 48。
  final words = t.split(' ');
  var title = words.length <= 8 ? t : '${words.take(8).join(' ')}…';
  if (title.length > 48) title = '${_safeSliceUtf16(title, 47)}…';
  return title.trim();
}

/// UTF-16 码点安全切片：回退避开孤立的代理项。
String _safeSliceUtf16(String s, int maxUnits) {
  if (s.length <= maxUnits) return s;
  var end = maxUnits;
  // 高代理项落在截断点前一格 → 整对舍掉。
  final code = s.codeUnitAt(end - 1);
  if (code >= 0xD800 && code <= 0xDBFF) end--;
  return s.substring(0, end);
}
