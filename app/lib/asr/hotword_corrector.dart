import 'dart:io';

import 'package:characters/characters.dart';
import 'package:flutter/foundation.dart';
import 'package:lpinyin/lpinyin.dart';

/// 热词分流与同音后校正。
///
/// 背景（sherpa-onnx 1.13.8 源码与词表实测）：
/// - ContextGraph 热词按 **token 级匹配**：热词每个字都必须在模型 tokens.txt
///   词表内，否则解码器根本打不出那个字，加多大权重都无效（当前中文模型
///   词表仅 2002 条，「彤」「熠」这类名字用字不在其中）；
/// - 热词仅在 `modified_beam_search` 解码下生效（greedy 静默忽略）；
/// - 热词串需以 `modeling_unit=cjkchar` 编码才会逐字切分。
/// 因此热词表分两路处理：
/// ① 词表内热词 → 传解码器 ContextGraph 偏置（流式实时生效）；
/// ② 含词表外生僻字的热词 → **同音后校正**：识别文本中某片段与热词逐字
///   同音（无声调拼音、多音字取读音集合求交）时替换为热词。
class HotwordCorrector {
  /// 交给解码器 ContextGraph 的热词（整词字符均在模型词表内）。
  List<String> decoderHotwords = const [];

  List<_PinyinFix> _fixes = const [];

  /// 模型词表（tokens.txt 每行第一列），按 modelDir 缓存一次。
  static Set<String>? _vocab;
  static String? _vocabDir;

  static Future<Set<String>?> _loadVocab(String modelDir) async {
    if (_vocab != null && _vocabDir == modelDir) return _vocab;
    try {
      final lines = await File('$modelDir/tokens.txt').readAsLines();
      final set = <String>{};
      for (final l in lines) {
        final t = l.trim();
        if (t.isEmpty) continue;
        // tokens.txt 格式："<token> <id>"（token 不含空格）
        set.add(t.split(' ').first);
      }
      _vocab = set;
      _vocabDir = modelDir;
      debugPrint('[DSH][asr] hotword vocab loaded: ${set.length} tokens');
      return set;
    } catch (e) {
      debugPrint('[DSH][asr] hotword vocab load failed: $e');
      return null;
    }
  }

  /// 分流热词表：词表内 → 解码器；词表外纯中文 → 同音校正；其余 → 丢弃。
  Future<void> configure(String modelDir, List<String> hotwords) async {
    final vocab = await _loadVocab(modelDir);
    final inVocab = <String>[];
    final fixes = <_PinyinFix>[];
    for (final w in hotwords) {
      final chars = w.characters.toList();
      if (chars.any(_isHan) &&
          vocab != null &&
          chars.every((c) => vocab.contains(c))) {
        inVocab.add(w);
      } else {
        final fix = _PinyinFix.tryBuild(w);
        if (fix != null) fixes.add(fix);
      }
    }
    // 长词优先：并存「张熠」与「张熠然」时先配长词，避免被短词切碎
    fixes.sort((a, b) => b.charCount.compareTo(a.charCount));
    decoderHotwords = inVocab;
    _fixes = fixes;
    if (fixes.isNotEmpty) {
      debugPrint('[DSH][asr] homophone fixes: ${fixes.map((f) => f.word).join(', ')}');
    }
  }

  /// 对识别文本应用同音后校正（幂等：替换出的热词仍与自身同音，二次调用
  /// 结果不变）。partial 与 final 输出均可安全过一遍。
  String apply(String text) {
    if (_fixes.isEmpty || text.isEmpty) return text;
    var out = text;
    for (final f in _fixes) {
      final n = f.charCount;
      final src = out.characters.toList();
      if (src.length < n) continue;
      final buf = StringBuffer();
      var i = 0;
      var changed = false;
      while (i < src.length) {
        if (i + n <= src.length &&
            f.matches(src.sublist(i, i + n).join())) {
          buf.write(f.word);
          i += n;
          changed = true;
        } else {
          buf.write(src.elementAt(i));
          i++;
        }
      }
      if (changed) out = buf.toString();
    }
    return out;
  }
}

/// 汉字（含扩展 A 区与兼容表意文字）。
bool _isHan(String c) {
  if (c.isEmpty) return false;
  final r = c.runes.first;
  return (r >= 0x3400 && r <= 0x9fff) || (r >= 0xf900 && r <= 0xfaff);
}

/// 单个词表外热词的同音匹配规则：逐字保存无声调拼音读音集合
/// （lpinyin 字典远大于模型词表，生僻字也能查到读音）。
class _PinyinFix {
  _PinyinFix._(this.word, this._readings);

  final String word;

  /// 每个字的读音集合（空集合 = 该字查不到拼音，规则不会命中）。
  final List<Set<String>> _readings;

  /// 单字读音缓存（partial 高频调用，逐字查表也做成 O(1)）。
  static final Map<String, Set<String>> _readingCache = {};

  int get charCount => _readings.length;

  static _PinyinFix? tryBuild(String word) {
    final chars = word.characters.toList();
    // 仅纯中文热词做同音校正（混非中文字符时同音比较无意义）
    if (chars.isEmpty || !chars.every(_isHan)) return null;
    final readings = <Set<String>>[];
    for (final c in chars) {
      final r = _readingsOf(c);
      if (r.isEmpty) return null; // lpinyin 字典也没有此字，无法建立映射
      readings.add(r);
    }
    return _PinyinFix._(word, readings);
  }

  /// 窗口文本是否与热词逐字同音（任一读音相交即算同音）。
  bool matches(String window) {
    final chars = window.characters;
    if (chars.length != _readings.length) return false;
    for (var i = 0; i < _readings.length; i++) {
      final c = chars.elementAt(i);
      if (!_readingsOf(c).any(_readings[i].contains)) return false;
    }
    return true;
  }

  static Set<String> _readingsOf(String c) {
    final cached = _readingCache[c];
    if (cached != null) return cached;
    var set = <String>{};
    try {
      set = PinyinHelper.convertToPinyinArray(c, PinyinFormat.WITHOUT_TONE)
          .map((p) => p.trim())
          .where((p) => p.isNotEmpty)
          .toSet();
    } catch (_) {
      set = <String>{};
    }
    _readingCache[c] = set;
    return set;
  }
}
