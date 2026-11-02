/// 上下文 token 估算（KV 预算 / 主动压缩共用口径）。
///
/// 为什么不用 `chars ~/ 4`：那是英文经验值。中文对话（本项目主力场景）
/// qwen/deepseek 系 tokenizer 每 CJK 字约 0.6~1 token，chars/4 会**低估
/// 约 3 倍**——主动压缩迟迟不触发，直到撞服务端硬墙才被动压缩。
///
/// 口径：ASCII ≈ 4 字符/token；非 ASCII（CJK 为主）按 3/4 token/字
/// （0.6~1 的折中，宁略高不略低——早压一次比撞墙便宜）。
/// tool_calls 无法精确计（每 call 的 JSON 骨架 ~40 tok 经验值）。
library;

/// 估算一批 model messages 的 token 数。
int estimateContextTokens(List<Map<String, dynamic>> messages) {
  var ascii = 0;
  var cjk = 0;
  var toolCallCount = 0;
  for (final m in messages) {
    final c = m['content'];
    if (c is String) {
      for (final r in c.runes) {
        if (r < 0x80) {
          ascii++;
        } else {
          cjk++;
        }
      }
    }
    final tc = m['tool_calls'];
    if (tc is List) toolCallCount += tc.length;
  }
  // tool_calls 的 40 tok/call 是最终经验值，不参与 ASCII 除 4。
  return ascii ~/ 4 + cjk * 3 ~/ 4 + toolCallCount * 40;
}
