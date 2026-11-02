/// 智能体提示词档位 —— 「API 档保持现状，本地档按模型容量瘦身」。
///
/// 真机定案（2026-10-27 K90 / M332BF / Adreno 830，Ling-3.0-tiny Q4_0 +
/// OpenCL，无线 adb 取证）：
/// - 智能体档系统提示 = **4580 token / 19507 字符**，而用户问题只有 3~20 token；
/// - 1.3B 激活的 tiny 在这种 prefill 体量下直接掉进非训练分布：**一次工具都不调**，
///   却输出「我已查询到当前天气（10月28日）」「当前文件已保存：/home/user/go.py」
///   「当前天气：南宁」这类编造执行，甚至切英文写第三人称分析（答非所问）；
/// - 同一模型、同一后端，聊天档 prompt 只有 14~70 token，回答正常；
/// - 首轮是全新会话全量 prefill（无 KV 复用）、输出通顺无乱码 → 排除 KV 前缀
///   复用与 OpenCL 数值污染，真凶就是系统提示体量。
///
/// 因此本地小模型必须走 [AgentPromptTier.compact]：**短身份 + 4 条工具纪律 +
/// 精简工具清单，不注入技能目录与 AGENTS.md**。API 档（[AgentPromptTier.full]）
/// 逐字节不变——云端大模型扛得住完整纪律，瘦身反而降低它们的工具遵循率。
library;

/// 系统提示档位。
enum AgentPromptTier {
  /// 完整档（API / 本地大模型）：11 条工具纪律 +（API 另有任务执行纪律）
  /// + 全量工具清单 + `<available_skills>` 目录 + `workspace:guidance`。
  full,

  /// 精简档（本地小模型）：短身份 + 4 条工具纪律 + 一行一名的精简工具清单；
  /// 技能目录与 AGENTS.md 不注入（常驻 prefill 收益为负）。
  compact,
}

/// 设置项 `agentPromptTierMode` 的三个取值。
const String kAgentPromptTierAuto = 'auto';
const String kAgentPromptTierCompact = 'compact';
const String kAgentPromptTierFull = 'full';

/// 精简档系统提示预算（字符）。越线即在推理日志里报红——这条线是"tiny 模型
/// 答非所问"的第一道闸，不许像以前那样无声涨到 19k 字符。
const int kAgentPromptCompactBudgetChars = 2500;

/// 自动判档的尺寸阈值（字节）：量化权重文件 ≤ 3.5GB 视为小模型。
/// 取 3.5GB ≈ Q4 下 5B 参数量级；更小的 dense（1.5~2.5GB）与 MoE 小激活
/// 模型都落在这里，Bonsai-8B 一类 ≥5GB 的仍走完整档。
const int kAgentCompactMaxSizeBytes = 3500 * 1024 * 1024;

/// 大参数命名否决：id 里出现**两位以上**参数量级（`24b`/`35b`/`27b`…）一律完整档。
/// MoE 命名是 `总参-激活`（`lfm2.5-24b-a2b` / `minicpm-v4.7-35b-a3b`），激活虽小
/// （a2b/a3b）但总参决定它不是"小模型"；单段激活命名（a1b/a2b/a3b）与单位数总量
/// （`minicpm5-2b`、`qwen3.5-1.5b`）不受此否决。
final RegExp _kAgentBigParamIdPattern = RegExp(r'[0-9]{2,}b');

/// 大模型否决线（字节）：文件 >8GB 一律走完整档，**即使 id 里有 1b/2b 这类
/// 激活参数命名**（如 `lfm2.5-24b-a2b-q4_0` = 13.5GB，激活 2B 但总参 24B）。
/// 真机定案的失败样本是 4.4GB 的 tiny；把 13.5GB 的 MoE 也削成四条纪律属于
/// 过度瘦身，反而降低它本来具备的工具遵循率。
const int kAgentFullVetoSizeBytes = 8000 * 1024 * 1024;

/// 精简档默认保留的核心工具（其余既不进系统提示、也调不到）。
///
/// 只留「真话来源」（时间/天气/搜索/计算/换算）+ 用户会明确要求落地的
/// （待办/便签/记忆/文件读写/导出）。python_exec / shell_exec / run_code /
/// edit_file / list_files / search_text / memory_get / note_list / todo_list
/// 一律排除：它们的描述最长（python_exec 295 字、shell_exec 273 字），
/// 且正是把 tiny 模型带成"假装在 Linux 上干活的编码智能体"的元凶。
const List<String> kAgentCompactCoreTools = [
  'get_time',
  'get_weather',
  'web_search',
  'calculator',
  'unit_converter',
  'todo_write',
  'note_take',
  'memory_set',
  'read_file',
  'write_file',
  'export_file',
  // 缺信息时向用户提问（P2-B2）——精简档更需要它，留着才不硬编造。
  'ask_user_question',
];

/// 模型 id 中表示"小模型"的关键字（含 MoE 的激活参数命名法 a0.5b/a1b）。
const List<String> kAgentCompactIdHints = [
  'tiny',
  'mini',
  'nano',
  'flash',
  'lite',
  'small',
  '0.5b',
  '0.6b',
  '1b',
  '1.5b',
  '1.7b',
  '2b',
  'a0.5b',
  'a0.6b',
  'a1b',
];

/// 判定系统提示档位。
///
/// 优先级：API 档恒 [AgentPromptTier.full] → 用户显式覆盖 → id 关键字 →
/// 量化文件大小 → 默认 [AgentPromptTier.full]（判不准时保守走完整档，
/// 行为与旧版一致，宁可不瘦也不悄悄改坏大模型的表现）。
///
/// [modelId] 本地模型 id 或 API 模型名；[useApi] API 路线；
/// [mode] 设置项 `agentPromptTierMode`（auto/compact/full）；
/// [sizeBytes] 已知的模型文件大小（null = 不知道，跳过尺寸判据）。
AgentPromptTier resolveAgentPromptTier({
  required String modelId,
  bool useApi = false,
  String mode = kAgentPromptTierAuto,
  int? sizeBytes,
}) {
  // API 档保持现状：大模型扛得住完整纪律，且不许被本地判档逻辑波及。
  if (useApi) return AgentPromptTier.full;
  if (mode == kAgentPromptTierCompact) return AgentPromptTier.compact;
  if (mode == kAgentPromptTierFull) return AgentPromptTier.full;

  // 大模型否决先于 id 判据：文件体量与总参命名都说明它不是"小模型"。
  final tooBig = (sizeBytes != null && sizeBytes >= kAgentFullVetoSizeBytes) ||
      _kAgentBigParamIdPattern.hasMatch(modelId.toLowerCase());
  final lower = modelId.toLowerCase();
  if (!tooBig && kAgentCompactIdHints.any(lower.contains)) {
    return AgentPromptTier.compact;
  }
  if (!tooBig && sizeBytes != null && sizeBytes > 0 &&
      sizeBytes <= kAgentCompactMaxSizeBytes) {
    return AgentPromptTier.compact;
  }
  return AgentPromptTier.full;
}
