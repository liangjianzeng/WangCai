/// 模型输出 → 结构化条目（抽词/生字/算式…都复用这一份容错）。
///
/// 为什么要提到 SDK：声明式 flow 的 `llm_extract` 与手写插件（英语听写）需要**完全一样**的
/// 兜底口径，两边各写一份必然漂移（一边能救回单引号 JSON、另一边不能，用户就会说"同一个模型
/// 时好时坏"）。所以：解析逻辑只此一份，测试也只此一份。
library;

import 'dart:convert';

/// 一个抽取到的条目。[text] 必填，其余可空。
final class ExtractedItem {
  const ExtractedItem({required this.text, this.note = '', this.unit = '', this.extra = const {}});

  final String text;
  final String note;
  final String unit;

  /// 模型多给的字段（词性、页码…），原样留着，插件想用就用。
  final Map<String, Object?> extra;

  @override
  String toString() => note.isEmpty ? text : '$text($note)';
}

const List<String> kTextKeys = ['text', 'word', 'en', 'item', '内容', '单词'];
const List<String> kNoteKeys = ['note', 'zh', 'cn', 'meaning', 'translation', '释义', '中文'];
const List<String> kUnitKeys = ['unit', 'lesson', '课', '单元'];

/// 从模型自由输出里抽出条目列表；**认不出来就返回空表，绝不编数据**。
///
/// 端侧小模型的脏输出形态（都在测试里钉着）：
/// ```text
/// ① {"items":[{"text":"apple","note":"苹果"}]}
/// ② ```json … ``` 围栏 + 前后解释文字
/// ③ 裸数组 [ {…}, {…} ]
/// ④ 单引号 / 尾逗号 / 键名漂移（word/zh）
/// ⑤ 干脆一行一个词（"apple\nbanana"）—— 只有前四种都失败时才退化成按行切
/// ```
List<ExtractedItem> extractItems(
  String modelOutput, {
  List<String> textKeys = kTextKeys,
  List<String> noteKeys = kNoteKeys,
  List<String> unitKeys = kUnitKeys,

  /// 关掉"按行兜底"（有些场景宁可空表也不要误认整段散文为条目）。
  bool allowLineFallback = true,
}) {
  final raw = modelOutput.trim();
  if (raw.isEmpty) return const [];

  String body = raw;
  final fence = RegExp(r'```(?:json)?\s*([\s\S]*?)```').firstMatch(body);
  if (fence != null) body = fence.group(1)!.trim();

  // 1) 先找对象（最常见的 {"items":[…]} 形态）。
  final obj = _slice(body, '{', '}');
  if (obj != null) {
    final decoded = _tryJson(obj);
    if (decoded is Map) {
      for (final key in const ['items', 'words', 'list', 'entries', 'data', 'rows']) {
        final items = _fromList(decoded[key], textKeys, noteKeys, unitKeys);
        if (items.isNotEmpty) return items;
      }
      // 单个对象也算一条：{"text":"apple","note":"苹果"}
      final single = _fromList([decoded], textKeys, noteKeys, unitKeys);
      if (single.isNotEmpty) return single;
    }
  }

  // 2) 再试裸数组（键名/引号脏数据在这一步被 _tryJson 救）。
  final arr = _slice(body, '[', ']');
  if (arr != null) {
    final items = _fromList(_tryJson(arr), textKeys, noteKeys, unitKeys);
    if (items.isNotEmpty) return items;
  }

  // 3) 最后兜底：一行一条（只在显式允许时；且要求"每行都短"，避免把散文当条目）。
  if (!allowLineFallback) return const [];
  final lines = body
      .split(RegExp(r'[\n；;]'))
      .map((l) => l.replaceAll(RegExp(r'^\s*[-•*\d.、\s]+'), '').trim())
      .where((l) => l.isNotEmpty && l.length <= 40)
      .toList();
  if (lines.length >= 2 && lines.every((l) => !l.contains('{'))) {
    return [for (final l in lines) ExtractedItem(text: l)];
  }
  return const [];
}

String? _slice(String s, String open, String close) {
  final start = s.indexOf(open);
  final end = s.lastIndexOf(close);
  if (start < 0 || end <= start) return null;
  return s.substring(start, end + 1);
}

List<ExtractedItem> _fromList(
  Object? raw,
  List<String> textKeys,
  List<String> noteKeys,
  List<String> unitKeys,
) {
  if (raw is! List) return const [];
  final out = <ExtractedItem>[];
  for (final e in raw) {
    if (e is Map) {
      final norm = <String, Object?>{
        for (final entry in e.entries) '${entry.key}'.trim().toLowerCase(): entry.value,
      };
      String pick(List<String> keys) {
        for (final k in keys) {
          final v = norm[k.toLowerCase()];
          if (v == null) continue;
          final s = '$v'.trim();
          if (s.isNotEmpty) return s;
        }
        return '';
      }

      final text = pick(textKeys);
      if (text.isEmpty) continue;
      final used = {...textKeys.map((k) => k.toLowerCase()), ...noteKeys.map((k) => k.toLowerCase()), ...unitKeys.map((k) => k.toLowerCase())};
      final extra = {for (final entry in norm.entries) if (!used.contains(entry.key)) entry.key: entry.value};
      out.add(ExtractedItem(text: text, note: pick(noteKeys), unit: pick(unitKeys), extra: extra));
    } else if (e is String) {
      final s = e.trim();
      if (s.isNotEmpty) out.add(ExtractedItem(text: s));
    }
  }
  return out;
}

Object? _tryJson(String s) {
  try {
    return jsonDecode(s);
  } catch (_) {
    // 常见脏数据：尾逗号、单引号。各修一次再试；还不行就交回上层。
    // 注意：Dart 的字符串替换**不做编号反向引用**（`r'$1'` 是字面量），必须 replaceAllMapped。
    final cleaned = s
        .replaceAllMapped(RegExp(r",\s*([}\]])"), (m) => m.group(1)!)
        .replaceAll("'", '"');
    try {
      return jsonDecode(cleaned);
    } catch (_) {
      return null;
    }
  }
}

/// 给人看的数字：`5.0` → `5`、`2.5` → `2.5`。
///
/// 配置里的数字都是 `double`，直接插进文案就是"每条 5.0 秒""只做 8.0 张卡"——
/// 用户会以为设置坏了。凡是要进 `message`/`summary`/提示词的数都过这道。
String formatCount(num value) =>
    value == value.roundToDouble() ? value.round().toString() : value.toString();
