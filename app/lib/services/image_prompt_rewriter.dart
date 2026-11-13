/// 生图提示词扩写（2026-11-12「一实例三角色」方案客户端前置）。
///
/// 用户口语一两句直进 Qwen-Image DiT 出图差：发送后先经模型把意图扩写成
/// diffusion 友好的结构化提示词，**用户在确认卡上过目/编辑后才真正生图**。
///
/// 模型来源 = [ApiModelConfig]（设置里 apiModels 的一档；本机推荐指向
/// tools/imagegen-server `:8899/v1` 的 chat id——生图壳内 TE（Qwen3-VL，
/// 完整 ForConditionalGeneration）同一份常驻实例兼做扩写，零新增加载。
/// unsloth 8888 链路的 TE 被拆头（NoLogitsHead）不可用作此途，实证见壳
/// README 与 CHANGELOG。
///
/// 降级纪律照抄上下文压缩（agent/context_eng/compaction.dart）：模型失败/
/// 超时/空回复一律回退原文，**扩写永不阻塞生图**；确认卡上用户始终可
/// 「用原话」。
library;

import 'dart:async';

import 'package:flutter/foundation.dart' show debugPrint;

import '../models/api_model.dart';
import 'openai_service.dart';

/// 一次扩写的结果：原文与扩写文并存（确认卡两者都要展示）。
class ImageRewriteResult {
  final String original;

  /// 扩写产物；[failed] 时等于 [original]（降级即原文直通）。
  final String rewritten;

  /// true = 模型不可用/超时/空回复，rewritten 即原文。
  final bool failed;

  const ImageRewriteResult(
      {required this.original, required this.rewritten, this.failed = false});

  bool get changed => !failed && rewritten.trim() != original.trim();
}

/// 单次、非流式语义的扩写器（内部走 SSE 流再 join——复用仓库唯一成熟的
/// OpenAI 兼容通道 [OpenAiService.chatCompletion]，不另起 HTTP 栈）。
class ImagePromptRewriter {
  ImagePromptRewriter({OpenAiService? openAi, Duration? timeout})
      : _openAi = openAi ?? OpenAiService(),
        timeout = timeout ?? const Duration(seconds: 30);

  final OpenAiService _openAi;

  /// 扩写超时预算独立于生图（ImageGenService.timeoutForSize 只管出图段）。
  final Duration timeout;

  /// 扩写 system 模板（内联，照 compaction 摘要器模板惯例；仓库无模板机制
  /// 故不新造）。要点：保用户主体不改写、只补维度、纯文本输出。
  static const String systemPrompt = '''
你是生图服务的提示词工程师。用户会给出简短的画图需求，请把它扩写成 diffusion 生图模型友好的中文提示词。
要求：
1. 保留用户明确给出的主体与意图，不改写、不替换、不新增用户未提及的人物或专有名词；
2. 视需要补全这些维度：主体外观与细节、场景与环境、构图与视角、光影、色调、艺术风格、质感与画质词（如"高细节、超高清"）；
3. 用户点名的风格（如"宫崎骏风""赛博朋克""写实摄影"）为最高优先级，不得被其他描述稀释；
4. 只输出最终提示词本身：不要解释、不要编号、不要引号，也不要"提示词："之类的前缀；
5. 长度 40~160 字，中文。''';

  /// 清洗模型常见包裹：markdown 围栏、首尾引号、「提示词：」前缀、多余空行。
  static String sanitize(String raw) {
    var s = raw.trim();
    final fence = RegExp(r'^```[a-zA-Z]*\s*([\s\S]*?)\s*```$');
    final m = fence.firstMatch(s);
    if (m != null) s = m.group(1)!.trim();
    s = s.replaceFirst(RegExp(r'^(提示词|改写后的提示词|优化后的提示词)\s*[:：]\s*'), '');
    s = s.replaceAll(RegExp(r'^["“「『]+|["”」』]+$'), '');
    return s.trim();
  }

  /// 扩写一次。任何异常折叠为 failed 结果（调用方无需 try/catch 决定是否阻塞）。
  ///
  /// 传输走**非流式**（chatCompletionOnce，2026-11-13 用户实测 SSE 扩写
  /// 「输出到一半断开」频繁复现——扩写是短平快单发，非流式整包 JSON 没有
  /// 中途断连面）；超时预算 [timeout] 独立（30s 默认）。
  Future<ImageRewriteResult> rewrite({
    required ApiModelConfig model,
    required String userPrompt,
  }) async {
    final original = userPrompt.trim();
    if (original.isEmpty) {
      return ImageRewriteResult(original: original, rewritten: original);
    }
    try {
      final raw = await _openAi.chatCompletionOnce(
        config: model,
        messages: const [
          {'role': 'system', 'content': systemPrompt},
        ] +
            [
              {'role': 'user', 'content': original}
            ],
        temperature: 0.7,
        maxTokens: 256,
        timeout: timeout,
      );
      final out = sanitize(raw);
      if (out.isEmpty) {
        debugPrint('[ImageRewrite] 扩写空回复，降级用原文');
        return ImageRewriteResult(original: original, rewritten: original, failed: true);
      }
      return ImageRewriteResult(original: original, rewritten: out);
    } catch (e) {
      debugPrint('[ImageRewrite] 扩写失败，降级用原文: $e');
      return ImageRewriteResult(original: original, rewritten: original, failed: true);
    }
  }
}
