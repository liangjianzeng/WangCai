// ============================================================
// 回合"产出计数器"（观测用，纯函数，可单测）。
//
// 背景（用户 2026-10-23 反馈）：输入框上方那行只有「生成中」+ 停止键，
// "一点卵用都没有"——看不出模型此刻在产出还是在空转、烧了多少 token。
// 本文件把"看到什么"定成一条读数：本步产出 / 本步预算 / 本回合累计 /
// 累计思考字数 / 步数 / 工具数，并给出**无用功**判据（思考字数暴涨而
// 可见产出为零 = 正在空烧）。
//
// 为什么用估算而不是真实 token：本地路线（llama.cpp JNI）流式过程中
// 没有逐 token 计数出口，原生 getInferenceStats 只在一次 generate 结束后
// 才有 n_gen；API 路线虽有 usage 但同样只在末块。所以流式期间**只能估**，
// 完成后如拿到服务端 usage 由调用方覆盖（[fromServerUsage] 标记）。
// 估算口径刻意保守（见 [estimateTokens]），宁可显示偏小也不虚高。
// ============================================================

/// 粗略 token 估算：中日韩一字记 1，其余按 4 字符记 1（向上取整）。
///
/// 与主流 BPE 的实际比值大致吻合（中文约 1~1.5 字/token，英文约 3.5~4
/// 字符/token）。这里只用于"看趋势"，不当账本用。
int estimateTokens(String s) {
  if (s.isEmpty) return 0;
  var cjk = 0;
  var other = 0;
  for (final r in s.runes) {
    if (_isCjk(r)) {
      cjk++;
    } else if (r != 0x20 && r != 0x0a && r != 0x0d && r != 0x09) {
      other++;
    }
  }
  return cjk + (other ~/ 4) + (other % 4 == 0 ? 0 : 1);
}

bool _isCjk(int r) =>
    (r >= 0x4e00 && r <= 0x9fff) || // 汉字
    (r >= 0x3400 && r <= 0x4dbf) || // 扩展 A
    (r >= 0x3040 && r <= 0x30ff) || // 日文假名
    (r >= 0xac00 && r <= 0xd7af) || // 谚文
    (r >= 0x3000 && r <= 0x303f) || // 中日韩标点
    (r >= 0xff00 && r <= 0xffef); // 全角字符

/// 一次读数（全部由调用方从既有 UI 状态喂进来，本文件不持状态、不订阅流）。
final class TurnMeter {
  TurnMeter({
    this.step = 0,
    this.stepBudget,
    this.answer = '',
    this.liveThinking = '',
    this.archivedThinking = const [],
    this.toolArgumentJson = const [],
    this.toolGenChars = 0,
    this.toolCount = 0,
    this.retryAttempt = 0,
    this.fromServerUsage = false,
    this.serverCompletionTokens,
  });

  /// 当前步序号（1 起；0 = 未知）。
  final int step;

  /// 本步 token 预算（本地档 agentTokensPerRound / API 档 agentApiTokensPerRound）。
  final int? stepBudget;

  /// 本步可见产出（答案流快照，已剔除思考块）。
  final String answer;

  /// 本步正在流式输出的思考（未落档）。
  final String liveThinking;

  /// 已落档的各步思考。
  final List<String> archivedThinking;

  /// 各工具调用参数的 JSON 串（参数也是模型生成的 token，必须计入产出）。
  final List<String> toolArgumentJson;

  /// 工具调用块生成中已生成字符数（WP5：此时 answer 与思考都为空）。
  final int toolGenChars;

  final int toolCount;
  final int retryAttempt;

  /// true = [totalTokens] 用服务端 usage，不是估算。
  final bool fromServerUsage;
  final int? serverCompletionTokens;

  /// 本步可见产出 token 估算（答案 + 工具参数 + 工具参数生成中）。
  int get producedTokens {
    var n = estimateTokens(answer);
    for (final a in toolArgumentJson) {
      n += estimateTokens(a);
    }
    if (toolGenChars > 0) n += (toolGenChars / 4).ceil();
    return n;
  }

  /// 本回合累计生成 token（产出 + 思考）。
  int get totalTokens {
    final usage = serverCompletionTokens;
    if (fromServerUsage && usage != null) return usage;
    return producedTokens + thinkingTokens;
  }

  /// 本回合累计思考 token 估算。
  int get thinkingTokens {
    var n = estimateTokens(liveThinking);
    for (final t in archivedThinking) {
      n += estimateTokens(t);
    }
    return n;
  }

  /// 累计思考**字数**（用户视角更直观，且与守卫阈值同口径用字数）。
  int get thinkingChars {
    var n = liveThinking.length;
    for (final t in archivedThinking) {
      n += t.length;
    }
    return n;
  }

  /// **无用功判据**：思考已经烧了不少，但可见产出（含工具参数）为零/近零。
  ///
  /// 阈值取得保守（思考 ≥600 tok 且产出 <5%），避免把"刚开始想"误判成空转。
  /// 这正是用户最想看见的一种状态：思考在狂涨、正文一个字没出。
  bool get looksWasteful =>
      thinkingTokens >= 600 &&
      producedTokens < (thinkingTokens * 0.05).ceil() &&
      retryAttempt == 0;

  /// 一行读数（细条用，控制在 ~40 字内，超长由 UI 省略号截断）。
  /// 「第 X 步」计数已删（2026-10-25 用户指令）：步数本身没有行动价值，
  /// 产出/预算/思考才值得占这行。
  String get label {
    final parts = <String>[];
    final tok = fromServerUsage ? '$totalTokens tok' : '约 $totalTokens tok';
    parts.add(fromServerUsage
        ? '产出 $tok'
        : '产出 $tok${stepBudget != null ? '/$stepBudget' : ''}');
    if (thinkingChars > 0) parts.add('思考 $thinkingChars 字');
    if (toolCount > 0) parts.add('工具 $toolCount');
    if (retryAttempt > 0) parts.add('重试 $retryAttempt');
    if (looksWasteful) parts.add('⚠️只想不写');
    return parts.join(' · ');
  }
}
