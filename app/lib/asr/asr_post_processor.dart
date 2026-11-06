import 'package:flutter/foundation.dart';

import 'hotword_corrector.dart';

/// ASR 输出后处理公共层（ASR&TTS 重构专项 T1.4）。
///
/// 两路识别引擎（按住说话=流式 Zipformer、唤醒对话=SenseVoice）的输出在
/// 进入消费方（输入框/发送链）之前，统一过这一层三级流水线：
/// 1. **富转写标签剥离** —— SenseVoice 富转写模式可能产出语言/情感/音频事件
///    标签（`<|zh|>`、`|HAPPY|`、`|Speech|` 等形态，实测样本见
///    docs/M0-EVIDENCE-VOICE.md）。标签绝不许漏进用户可见文本；原始标签
///    留在 [AsrPostProcessor.lastRawText] 供调试与规则回归。
/// 2. **同音热词校正** —— 复用 [HotwordCorrector]（词表外生僻字热词的逐字
///    同音替换，幂等）。
/// 3. **指令归一化** —— 语音指令里的书写变体收敛到标准形态
///    （「16 k / 十六K → 16K」这类），映射表驱动、只增不改引擎原文语义。
///
/// 设计约束（施工计划 §1）：HotwordCorrector 原资产原样复用，本类只做编排
/// 与新增两级；纯 Dart、无 FFI，可在普通单测跑（同音校正依赖 lpinyin 字典，
/// 测试里 configure 传空热词即可跳过词表 IO）。
class AsrPostProcessor {
  AsrPostProcessor({HotwordCorrector? corrector})
      : _corrector = corrector ?? HotwordCorrector();

  final HotwordCorrector _corrector;

  /// 最近一次 [apply] 的输入原文（含标签），仅调试/回归用。
  @visibleForTesting
  String lastRawText = '';

  /// 词表内热词（透传给解码器 ContextGraph；语义同 [HotwordCorrector.decoderHotwords]）。
  List<String> get decoderHotwords => _corrector.decoderHotwords;

  /// 配置热词分流（透传 [HotwordCorrector.configure]；空热词 = 纯剥离/归一模式）。
  Future<void> configure(String modelDir, List<String> hotwords) =>
      _corrector.configure(modelDir, hotwords);

  /// 三级流水线全量应用。任何一级都不抛（识别后处理绝不让链路断）。
  String apply(String text) {
    lastRawText = text;
    if (text.isEmpty) return text;
    var out = text;
    try {
      out = stripRichTags(out);
      out = _corrector.apply(out);
      out = normalizeInstructions(out);
    } catch (e) {
      // 后处理失败退回剥标签的最小结果（再失败退回原文）——识别永不因后处理丢字。
      debugPrint('[DSH][asr] post-process error: $e');
      try {
        out = stripRichTags(text);
      } catch (_) {
        out = text;
      }
    }
    return out;
  }
}

// ---- 1) 富转写标签剥离 ----

/// SenseVoice/模型侧已知的标签词（语言、情感、音频事件）。剥离按整词匹配，
/// 未知的新标签由通用模式兜底（见 [_genericTagPattern]）。
const kRichTagWords = <String>{
  // 语言
  'zh', 'en', 'yue', 'ja', 'ko', 'auto',
  // 情感
  'NEUTRAL', 'HAPPY', 'SAD', 'ANGRY', 'FEARFUL', 'DISGUSTED', 'SURPRISED',
  'EMO_UNKNOWN',
  // 音频事件
  'Speech', 'Speech_Noise', 'Singing', 'Event_Accompanying_Speech', 'Music',
  'Sound', 'BGM', 'Sound_Effect', 'Crosstalk',
  // 反向文本归一化/杂项
  'NO_ITN', 'ITN', 'HUGGINGFACE',
};

// `<|zh|><|HAPPY|>` 形态（sense-voice 原始输出）。
final _angleTagPattern = RegExp(r'<\|[^|>]{1,32}\|>');
// `|HAPPY|` 竖线夹注形态（sherpa 富转写透出形态）。词表内整词 + 全大写/首大写
// 的未知词兜底；刻意要求词表或形态像标签，避免误伤「a|b」这类普通文本。
final _pipeTagPattern = RegExp(
    r'\|(?=[A-Z][A-Za-z_]{1,31}\|)[A-Z][A-Za-z_]{1,31}\|');

/// 剥离富转写标签（幂等：输出不含标签形态，二次调用不变）。
@visibleForTesting
String stripRichTags(String text) {
  var out = text.replaceAllMapped(_angleTagPattern, (m) {
    // `<|word|>`：词在已知表内直接删；未知词也删（整对尖竖线就是标签形态）。
    return '';
  });
  out = out.replaceAllMapped(_pipeTagPattern, (m) {
    final word = m.group(0)!.substring(1, m.group(0)!.length - 1);
    // 已知标签删；未知但形如标签的（全大写或首字母大写驼峰）也删——
    // 中文识别结果里出现这类裸词的概率极低，宁可多剥不误漏。
    if (kRichTagWords.contains(word) ||
        word == word.toUpperCase() ||
        RegExp(r'^[A-Z][a-z_]+$').hasMatch(word)) {
      return '';
    }
    return m.group(0)!;
  });
  // 标签剥离可能留下多余空白（标签紧贴正文时常见）。
  out = out.replaceAll(RegExp(r'[ \t]{2,}'), ' ').trim();
  return out;
}

// ---- 3) 指令归一化 ----

/// 一条归一化规则：[pattern] 命中即替换为 [replacement]。
@immutable
class InstructionNormalization {
  const InstructionNormalization(this.pattern, this.replacement, {this.label});
  final RegExp pattern;
  final String replacement;
  final String? label;
}

/// 内置归一化表（施工计划 T1.4 口径「十六 K/16 k → 16K」的落地）。
///
/// 原则：**只收敛书写形态，不改语义、不吞内容**——表短、规则彼此独立、
/// 全部可单测；新增规则必须带用例进 asr_post_processor_test。
final kInstructionNormalizations = <InstructionNormalization>[
  // 「16 k」「16k」「16  K」→「16K」：数字与单位间空白收敛 + 大小写归一
  // （语音停顿被转写成空格、ASR 常产出小写单位）。只处理邻接数字的单个单位
  // 字母，后随字母则不动（「3 K 个」→「3K 个」，「20 kHz」整串不碰）。
  InstructionNormalization(RegExp(r'(?<=[0-9])\s*[kK](?![a-zA-Z])'), 'K',
      label: 'number-K'),
  InstructionNormalization(RegExp(r'(?<=[0-9])\s*[gG](?![a-zA-Z])'), 'G',
      label: 'number-G'),
  // M 只收敛空白、保留原大小写（「带宽 20 M」→「20M」），避免把普通
  // 「20 m」强改形态。
  InstructionNormalization(RegExp(r'(?<=[0-9])\s+(?=[mM](?![a-zA-Z]))'), '',
      label: 'number-m space'),
  // 「100 hz」「100 HZ」→「100Hz」规范写法（大小写混写一并吸收）。
  InstructionNormalization(
      RegExp(r'(?<=[0-9])\s*[hH][zZ](?![a-zA-Z])'), 'Hz',
      label: 'number-Hz'),
  // 「285 H」→「285H」（芯片型号口述形态；必须排在 Hz 之后，避免拆散 Hz）。
  InstructionNormalization(RegExp(r'(?<=[0-9])\s*[hH](?![a-zA-Z])'), 'H',
      label: 'number-H'),
];

/// 应用指令归一化表（幂等：替换结果不再命中规则）。
@visibleForTesting
String normalizeInstructions(String text) {
  var out = text;
  for (final r in kInstructionNormalizations) {
    out = out.replaceAll(r.pattern, r.replacement);
  }
  return out;
}
