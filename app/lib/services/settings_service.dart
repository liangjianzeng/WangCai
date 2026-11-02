import 'dart:convert';
import 'dart:io';

import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';

import '../agent/adb/adb_targets.dart';
import '../agent/dev/ssh/ssh_credentials.dart' show SshConfig;
import '../agent/mcp/mcp_client.dart' show McpServerConfig;
import '../models/agent_persona.dart';
import '../models/api_model.dart';

/// 推理引擎相关的用户设置（GPU 加速开??+ 卸载层数 + 后端选择 + 上下文大小）??
///
/// 默认关闭 GPU 加速（用户可在设置页开启；开启后 auto 优先??OpenCL??
/// ??Vulkan ??Adreno 825 上实测等效、均无数值崩坏），卸载层数默??100
/// （全量卸载；llama.cpp 会自??clamp 到模型实际层数）??
/// 上下文大小默??4096，最??65536??
/// 端侧直连搜索引擎 id（与 lib/websearch 引擎实现一一对应）。
const List<String> kDirectEngineIds = [
  'bing_cn',
  'so360',
  'chinaso',
  'sogou',
  'baidu',
  'quark',
];

/// 高风险引擎（风控激进，默认小预算细水长流）。
const List<String> kHighRiskEngineIds = ['sogou', 'baidu', 'quark'];

/// 直连引擎开关默认值 = 全启用。
const List<String> kDefaultDirectEngines = kDirectEngineIds;

class InferenceSettings {
  final bool enableGpu;
  final int gpuLayers;
  final int contextSize;

  /// 是否允许 Qwen3 思考模式（<think> 链）。默认关??= 直接作答，响应更快??
  final bool enableThinking;

  /// GPU 后端选择??cpu' / 'vulkan' / 'opencl' / 'auto'??
  /// 默认 'auto'：优??OpenCL（Adreno 825 ??OpenCL 驱动高度优化，与 Vulkan
  /// 实测吞吐几乎等价；两者均经真机验证可正常输出，无数值崩坏）。用户可切到
  /// Vulkan 对比。llama.rn ??Android 上即??OpenCL 后端，Adreno 700+ 可用??
  final String gpuBackend;

  /// 是否启用 MTP（多 token 预测）加速，按模??id 逐个开关（默认全关）??
  /// 仅对??NextN 头的模型生效——MTP ??draft/verify/process 三次完整前向
  /// 开销在端侧通常不划算，用户可在模型列表对每个支持的模型手动开启，
  /// 互不影响??
  final Map<String, bool> mtpEnabledByModel;

  /// 全局 MTP 功能总开关（默认关闭）。用于控制整??APP ??MTP 是否
  /// 「可见可用」：
  /// - 关闭（默认）：模型卡片不显示各模型的 MTP 开关，加载模型时也强制
  ///   不启??MTP（即使某模型曾配置开启）??
  /// - 开启：模型列表卡片显示各支??MTP 模型的开关，用户可逐个配置??
  ///   加载时按 `enableMtpFeature && mtpEnabled(modelId)` 决定是否启用??
  /// 端侧 MTP 性能差收益差，故默认关闭，仅高端机用户按需打开测试??
  final bool enableMtpFeature;

  /// 是否启用 dspark 投机加速，按模??id 逐个开关（默认全关）??
  /// 仅对目录声明 dspark 草稿头（config.dspark）且草稿文件已下载完整的模型
  /// 生效——与 MTP 互斥（原生层二选一），互不影响??
  final Map<String, bool> dsparkEnabledByModel;

  /// 智能 MoE 热专家 bank（槽数）手动覆写，按模型 id 持久化（8–64）。
  /// 无条目 = 自动：按机型 MemAvailable 与 manifest slot 字节估算
  /// （见 model_provider 的 auto MoE bank 预算公式，2026-10-15）。
  final Map<String, int> moeBankOverrideByModel;

  /// 视觉投影器（mmproj）按模型开关（2026-10-15，方案 P4）。
  /// 有条目 = 用户显式配置（开→加载视觉塔，关→纯文本省 ~0.9GB）；
  /// 无条目回退全局 autoLoadMmproj，保持既有用户行为不变。
  final Map<String, bool> visionEnabledByModel;

  /// 全局 dspark 功能总开关（默认关闭）。用于控制整??APP ??dspark 是否
  /// 「可见可用」：
  /// - 关闭（默认）：模型卡片不显示各模型的 dspark 开关，加载模型时也强制
  ///   不启用（即使某模型曾配置开启）??
  /// - 开启：模型列表卡片显示声明了草稿头模型??dspark 开关，用户可逐个
  ///   配置；加载时??`enableDsparkFeature && dsparkEnabled(modelId)` 决定
  ///   是否带上草稿模型??
  /// 端侧 Q1_0 等低比特模型??dspark 收益有限（验证批摊不动权重读取，
  /// 净吞吐≈基线甚至更低），故默认关闭，按需开启??
  final bool enableDsparkFeature;

  /// 启动后自动加载的「默认模型」id。null = 未设置??
  /// 用户在模型管理页对某个已缓存模型勾选「设为默认」后持久化；
  /// 启动进入首页时若该模型已缓存则自动加载，保证开箱即用??
  final String? defaultModelId;

  /// 已配置的 OpenAI 兼容远程模型列表（可配多个，密钥明文存本地）??
  final List<ApiModelConfig> apiModels;

  /// 当前激活的 API 模型 id。null = 停用 API 接入（仅用本地模型）??
  /// 路由策略：本地模型优先，仅当本地模型未加??加载失败时才走激活的 API??
  final String? activeApiModelId;

  // ---------------------------------------------------------------
  // 智能体（Agent）配??
  // ---------------------------------------------------------------

  /// 智能体模式总开关。默认开启：无工具时一轮直答（与普通聊天一致）??
  /// 有工具调用时进入工具循环。关??= 完全走普通聊天路径??
  final bool agentEnabled;

  /// 是否启用「新智能体模式」（Phase 0 起重写的事件??ReactLoopAgent）??
  /// - 开启（默认）：走新事件日志 + 主循环（G12 派生请求、失败瀑布、取消竞跑）??
  /// - 关闭：回退到旧 `runAgent` 逻辑（保留可回退）??
  final bool useNewAgentMode;

  /// 智能体驱动模型来源：'local'（本地端侧模型）/ 'api'（API 接入模型）??
  /// null = 跟随默认路由（本地优先，API 兜底）??
  final String? agentModelSource;

  /// 智能体驱动模??id（对应本地模型目??id ??API 模型配置 id）??
  /// ??[agentModelSource] 成对使用；source ??null 时忽略??
  final String? agentModelId;

  /// 智能体模式的上下文长度（n_ctx）。独立于普通聊天的 [contextSize]??
  /// 工具循环需要额外空间容纳「工具调??+ 结果回填」历史??
  final int agentNctx;

  /// 工具循环轮次上限??~20）。默??5：端侧速度有限，轮次过多体验差??
  final int agentMaxRounds;

  /// web_search 每回合调用上限（1~10，默认 5）。对齐 DSH 服务端工具 max_uses
  /// ???壺?ﵽ???޺? web_search ?ܾ???????????????ָ??ž???????????
  final int agentMaxSearchesPerTurn;

  /// goal 无人值守续跑轮数上限（1~20，默认 8）：目标未完成时驱动器自动
  /// 续跑的最大回合数（P1-A goal-round-driver）。
  final int agentGoalMaxRounds;

  /// 远程 MCP server 列表（P2-B）：enabled 的在 API 档回合注册为
  /// `mcp_<server>_<tool>` 工具；失败 server 静默跳过不阻断回合。
  final List<McpServerConfig> mcpServers;

  /// 置顶会话 id 列表（P2 抽屉重构；存 settings 免 DB 迁移）。
  final List<String> pinnedConversationIds;

  /// 端侧 ASR 增强档（true = beam search + blankPenalty，识别更准、首字略慢）。
  final bool asrEnhancedMode;

  /// 启用的热词分类 id（空 = 全部启用）。
  final List<String> asrHotwordCategories;

  /// 自定义热词（每行一个，词表外同音后校正）。
  final String asrHotwordCustom;

  /// 热词分类差量覆盖：用户在分类默认词表上新增的词（catId → 词表）。
  final Map<String, List<String>> asrHotwordAdded;

  /// 热词分类差量覆盖：用户从分类默认词表删除的词（catId → 词表）。
  final Map<String, List<String>> asrHotwordRemoved;

  /// 并发会话槽位（1~4，默认 1）：同时允许执行回合的会话数量。
  /// 智能体/API 会话可真正并行；本地模型路线受引擎单实例约束，
  /// 同一时刻仍只允许一个本地回合（见 chat_provider 门控）。
  final int agentMaxConcurrentTurns;

  /// API 档主动压缩预算（token 估算，默认 32768）：投影历史估算超过该值
  /// 即触发确定性压缩。local 档预算仍由 agentNctx×3/4 派生，不受此项影响。
  /// 配置了端点 contextWindow 时取两者较小值（×7/8 留余量，见 chat_provider）。
  final int agentApiContextBudget;

  /// 每轮生成??token 预算。默??512：足够输出一次工具调??JSON 或一段回答??
  final int agentTokensPerRound;

  /// 单工具执行超时（毫秒）。默??15s：防止工具卡死拖住整个循环??
  final int agentToolTimeoutMs;

  /// 是否允许并行工具调用（默认关闭；开启后??[agentMaxParallel] 分批并发）??
  final bool agentAllowParallelTools;

  /// 并行工具并发上限（默??4；实际再受驱动模型能力夹紧）??
  final int agentMaxParallel;

  /// 生成温度??~2，默??0.7）。工具决策建议偏低，直答场景可偏高??
  final double agentTemperature;

  // ---- API 档智能体参数（独立于 local 档平铺键；双场景档分流）----
  // local 档沿用上面 agentMaxRounds 等平铺键；API 档是云端大模型场景
  // （大生成预算/并行工具/长超时），出厂默认对齐 AgentConfig.forRoute(api)。

  /// API 档：工具循环轮次上限（1~24，默认 16）。
  final int agentApiMaxRounds;

  /// API 档：每步生成 token 预算（默认 8192，云端模型吃满思考与长回答）。
  final int agentApiTokensPerRound;

  /// API 档：生成温度（0~2，默认 0.7）。
  final double agentApiTemperature;

  /// API 档：单工具执行超时毫秒（默认 30000，联网类工具更宽裕）。
  final int agentApiToolTimeoutMs;

  /// API 档：是否允许并行工具调用（默认开）。
  final bool agentApiAllowParallelTools;

  /// API 档：并行执行上限（默认 4）。
  final int agentApiMaxParallel;

  /// 思考失控守卫阈值：按**累计**思考字数计（跨块合计，口径见
  /// [AgentStreamProcessor.thinkingRunaway]）；超限且本步还没有产出即主动停流
  /// 止损（thinkingOverflow → 抢救已产出内容 + 关思考重试一次）。默认 6000；
  /// 确实需要长推理的模型按机型调大（上限 65536）。
  final int agentThinkingMaxChars;

  /// 智能体「工具决策步」是否允许思考（默认 false = 思考失控治理）。
  ///
  /// 端侧小模型思考失控（独白不收口、动辄几万字把预算与上下文吃光）几乎
  /// 都发生在工具决策步——那一步只需产出一个工具调用，长思考纯属烧 token。
  /// 默认只在组织最终答案时允许思考；打开 = 每步都允许（行为同旧版）。
  final bool agentThinkingOnToolSteps;

  /// 对话区文字整体缩放（0.7~1.3，默认 1.0 = 当前字号）。
  /// 以 TextScaler 作用于消息列表（气泡/思考/工具卡/时间戳整体缩放）。
  final double chatTextScale;

  /// 全局 UI 缩放（2026-10-24 harness 改造）：devicePixelRatio 乘数，
  /// 0.85–1.30。1.0 = 跟随系统；整体等比放大/缩小全部 UI（图标/文字/间距）。
  final double uiScale;

  /// composer 快捷图标白名单（2026-10-25）：KV 环右侧的快捷功能图标，
  /// 默认空 = 全部关闭；在「更多 → 快捷设置」里逐个开启。
  /// 合法 id：agent/model/persona/plan/skills/plugins。
  final List<String> composerQuickActions;

  /// 自动压缩阈值（占用比例，0.5–0.95，默认 0.8）：上下文占用越过该刻度
  /// 自动触发存储级压缩（占用详情面板刻度条上可拖动调节）。
  final double autoCompactThreshold;

  /// 应用外观（2026-10-25）：`system`（跟随系统，默认）/ `light` / `dark`。
  final String themeMode;

  /// 子代理工具（subagent，spawn/fork）注册开关。默认开??
  /// 不变量固定（深度 ??2 / 子代理审批恒 never / 每层独立预算）??
  final bool agentSubagentEnabled;

  /// 子代理专用 API 模型（P3-2 按步路由最小形态）：非空且存在于 apiModels
  /// 时，子代理用这个（通常更便宜/更快）的 API 配置驱动，父回合仍用主模型。
  /// 空串 = 跟随父模型（默认，行为与旧版一致）。仅 API 档生效。
  final String agentSubagentApiModelId;

  /// 压缩摘要专用 API 模型 id（P1-B 按步模型路由的压缩分支）：非空时上下文
  /// 压缩的旧区摘要交给该（更便宜的）模型；空 = 回退子代理模型，再回退主模型。
  final String agentCompressionApiModelId;

  /// 上下文超限自动压缩（默认开；关闭后超限直接报错终止）??
  /// 智能体提示词档位（2026-10-27 K90 真机定案）：'auto' = API 恒完整档、本地按
  /// 模型 id/文件大小自动判精简档；'compact' = 强制精简；'full' = 强制完整。
  /// 精简档只给本地小模型瘦身系统提示（实测 Ling-3.0-tiny 在 4580 token 系统提示
  /// 下整回合不调工具、编造「已查询到天气」）；API 档恒完整，不受此项影响。
  final String agentPromptTierMode;

  final bool agentCompactEnabled;

  /// 超长工具输出溢写落盘（默认开；模型侧只留摘要与文件定位）??
  final bool agentSpillEnabled;

  // ---- 语音播报（Edge 在线 TTS）----

  /// Edge TTS 总开关（默认关）：开 = 回答气泡出现 🔊 按钮、允许自动播报。
  final bool edgeTtsEnabled;

  /// 回复完成后自动播报（默认关；需 edgeTtsEnabled 同时开启）。
  final bool edgeTtsAutoSpeak;

  /// 音色 ShortName（默认 zh-CN-XiaoxiaoNeural 晓晓，公认最优中文女声）。
  final String edgeTtsVoice;

  /// 语速（-50 ~ +100 → SSML "+N%"）。
  final int edgeTtsRate;

  /// 音调（-50 ~ +50 Hz → SSML "+NHz"）。
  final int edgeTtsPitch;

  /// 音量（-50 ~ +50 → SSML "+N%"）。
  final int edgeTtsVolume;

  /// 回合轨迹自动落盘（P0 轨迹导出，默认关）：每回合结束把 SessionLog
  /// 整份事件流写 `ApplicationSupport/traces/*.jsonl`（回放/评估/排障用）。
  final bool agentTraceExportEnabled;

  /// 联网搜索工具总开关（默认关闭：web_search 默认不注册，需手动开启）??
  final bool webSearchEnabled;

  /// 联网搜索 SearXNG 实例地址（用户在「设????API 接入 ??联网搜索」填写）??
  ///
  /// 默认留空 = 未配置。不要预置任何个人实例地址；空地址??provider 会返??
  /// "请先在设置里填写地址"的诊断，而不是拿 127.0.0.1 去连手机自己??
  final String webSearchSearXngBaseUrl;

  /// SearXNG 实例??API key（私有实例才需要；??= 无需密钥）??
  final String? webSearchSearXngApiKey;

  /// 单次 SearXNG 搜索最多返回来源条数（对齐 DSH 默认 8）??
  final int webSearchSearXngMaxResults;

  /// 单次 SearXNG 搜索超时毫秒??
  ///
  /// 默认 30s：SearXNG 聚合多引擎本身就慢（一台自建实例走全引擎实??21s，多??
  /// 时间耗在其访问不到的引擎上），旧??15s 默认值会让这类实??*每次都必然超??*??
  /// ??[webSearchSearXngEngines] 只留可达引擎后可降到秒级??
  final int webSearchSearXngTimeoutMs;

  /// SearXNG 搜索语言（如 "zh-CN"）；??= 不指定??
  final String? webSearchSearXngLanguage;

  /// SearXNG 搜索分类（如 "general","news"）；??= 不指定??
  final String? webSearchSearXngCategories;

  /// SearXNG 引擎白名单（逗号分隔，如 `bing,sogou`）??
  ///
  /// Ĭ????? = ??ʵ??????????Щ???档??ʵ???ϴ??ڷ??ʲ?????????ʱ???????Ӱ?????
  /// 里去掉可把搜索从二十秒级降到秒级。若白名单里有该实例不认识的引擎，SearXNG ??
  /// ??400，provider 会自动去掉该参数重试一次（??SearXNGSearchProvider.search）??
  final String? webSearchSearXngEngines;

  /// 端侧直连搜索引擎开关（SearXNG 地址为空时生效）。
  ///
  /// 保存启用的引擎 id（bing_cn/so360/chinaso/sogou/baidu/quark）。
  /// 空列表 = 直连搜索整体不可用（available() 会给出诊断）。
  final List<String> webSearchDirectEngines;

  /// 端侧直连引擎总开关（默认开）。打开时**优先级最高**：即使配置了
  /// SearXNG 地址也优先用端侧直连；关闭后回到 SearXNG 模式
  /// （未配置地址则 web_search 报"未配置"诊断）。
  final bool webSearchDirectEnabled;

  /// 低风险引擎（bing_cn/so360/chinaso）每 10 分钟窗口内的请求预算。
  /// 「细水长流」管控：预算耗尽该引擎跳过本轮（status=budget），窗口到期自动恢复。
  final int webSearchDirectLowRiskPerWindow;

  /// 高风险引擎（sogou/baidu/quark，风控激进）每 10 分钟窗口内的请求预算。
  /// 默认 2：偶尔贡献高质量结果，又不至于因连续请求被判定机器行为。
  final int webSearchDirectHighRiskPerWindow;

  /// shell 执行工具开关（默认开启：端侧能力向强扩展，不自我设限??
  /// 用户可在设置中关闭）??
  final bool agentShellEnabled;

  /// python_exec 工具开关（默认开启：嵌入??CPython，脚本能力向强扩展；
  /// 未集??Chaquopy 时工具优雅降级为明确错误）??
  final bool agentPythonEnabled;

  /// 沙箱完整文件系统授权（对??DSH danger-full-access）：开启后允许
  /// 智能体经用户逐次审批访问公共目录/完整文件系统（依??
  /// MANAGE_EXTERNAL_STORAGE / All-Files-Access）。
  final bool agentFullFileAccess;

  /// 长期记忆开关（memory_set/memory_get）。默??*关闭**：跨会话持久??
  /// 的记忆可能积累偶发错误（不同模型/情况误写），开启后由用户显式配置??
  final bool agentMemoryEnabled;

  /// 推理引擎：是否默认加载视觉投影器（mmproj）。默??true（针对有投影器的
  /// 模型）；关闭后视觉模型仅文本推理，不加载投影器??
  final bool autoLoadMmproj;

  /// 推理引擎：GPU/CPU 占用率监控呈现（模型状态栏底部双色线）。默认开启??
  final bool showResourceMonitor;

  /// 占用率采样周期（秒）??~30。默??0：仅推理时事件驱动采样（空闲不采样，
  /// 省电）；>0：每??N 秒周期性采样（空闲也更新线条）??
  final int resourceSampleIntervalSec;

  /// OOM 内存守卫总开关（设置→推理引擎→内存守卫）。默认开启：加载前预检
  /// 「模型体??+ 预检余量」是否超出可用内存，超出则拒绝加载，防止 UMA 手机
  /// 整机硬死机。关??= 完全跳过守卫拒绝（高级用户排障用，有死机风险）??
  final bool oomGuardEnabled;

  /// OOM 预检余量（MB，默??768）。加载前 MemAvailable 扣除该余量后再与
  /// 模型体积比较；调小更容易放过接近极限的大模型，调大更保守??
  final int oomPreHeadroomMb;

  /// OOM 加载后余量（MB，默??1536）。加载完成后 KV cache / 图计算缓冲的
  /// 内存预算 = MemAvailable - 该余量；调小可给 KV 更大空间，调大更保守??
  final int oomPostHeadroomMb;

  /// KV 缓存精度（设置→推理引擎→KV 精度）：'q4_0'（默认）或 'q8_0'。
  /// 端侧内存必须量化：默认 Q4。仅量化 K；V 恒为 F16——V 量化要求开启
  /// flash attention，本 app 保持关闭（上游会硬报错）。改后重新加载模型生效。
  final String kvCacheType;

  /// [dspark 2026-10-14] flash attention（设置→推理引擎）。默认关（历史原因：
  /// 统一 KV + FA + 每轮 seq_rm 曾在真机 turn 2 出乱码）。开启后 V 跟随 K 的
  /// 量化格式；hybrid（recurrent 层）架构原生层会强制关闭。改后重新加载生效。
  final bool flashAttn;

  /// GPU 推理时限制刷新率（防闪纹，2026-10-07 小米13 定案）：模型加载/
  /// prefill 的瞬时显存带宽会挤占显示供帧（Adreno UMA），期间临时锁 60Hz、
  /// 回合结束恢复。默认开；CPU 后端无此现象（chat_provider 侧跳过）。
  final bool inferenceLimitRefreshRate;

  /// prefill 宽度 n_ubatch：0 = 自动（统一 512，默认行为）；32~512 = 拆小单次
  /// dispatch 计算 burst，缓解 Adreno 持续满血计算触发的 GPU 挂死（代价：
  /// prefill 变慢）。2026-10-16 起对任意后端生效（CPU 恒 16 已证伪废除）。
  final int gpuNUbatch;

  /// Vulkan 禁用 subgroup 扩展（GGML_VK_NO_SUBGROUP）：turnip 在部分芯片
  /// （Adreno 740 等）的 GPU 挂死嫌疑源之一。默认关；切换后需重启 app
  /// 生效（vulkan 设备初始化每进程仅一次）。
  final bool vkNoSubgroup;

  /// 智能 MoE 加载（超大 MoE 统一架构，2026-10-14）：内存预算路由。
  /// 开启（默认）= 拆分 MoE 模型走专家 slot 动态加载（dense 常驻 + 专家按需
  /// preadv 流式读入）；关闭 = 走整包全加载（-les 剥离版主文件缺专家，会失败
  /// 并提示开启本开关）。
  final bool smartMoeEnabled;

  /// 按模型启用的工具清单：`{modelId: [toolName]}`。空 = 使用该模??
  /// 目录声明的默认工具集（agentDefaults.enabledTools）??
  final Map<String, List<String>> agentToolsByModel;

  /// 按模型的 agent 配置覆盖：`{modelId: {maxRounds, tokensPerRound, nctx}}`??
  /// 覆盖全局默认值（模型目录 agentDefaults 合并到用户设置）??
  final Map<String, Map<String, dynamic>> agentByModel;

  /// 用户自定义智能体人格列表（标准人格恒存在、不落盘，见
  /// [kStandardPersonaId]）。每个人格 = 名字 + 人设提示词，注入系统提示词。
  final List<AgentPersona> agentPersonas;

  /// 当前激活的人格 id。标准人格 = [kStandardPersonaId]（默认）；
  /// 指向的自定义人格不存在时回落标准人格。
  final String activePersonaId;

  // ---------------------------------------------------------------
  // 开发模式（Dev Agent）
  // ---------------------------------------------------------------

  /// 开发模式总开关（默认关闭 = 现有行为零回归）。
  /// 开启后：注册 Dev 工具组（git/plan/ssh/run_tests）、注入 DevContext、
  /// 文件/记忆工具跟随激活工作区。
  final bool devModeEnabled;

  /// 当前激活工作区 id（默认 'default' = app workspace 根目录）。
  /// 由 DevSessionController 持久化激活态；此处仅保存设置默认值。
  final String devWorkspaceId;

  /// SSH 开发环境配置列表（Termux / 远程电脑可各一条，按 [SshConfig.id] 区分）。
  /// 空列表 = 未配置。旧版单配置 [SshConfig] 自动迁移为列表首项。
  final List<SshConfig> sshConfigs;

  /// ADB 远程控制总开关（app 内置纯 Dart ADB 客户端，直连另一台手机）。
  ///
  /// 用户定案：**放行只看这一个开关，不做逐次审批** —— 关闭时 `adb` 工具在
  /// execute 体内直接拒绝；开启后也**只允许连 [adbTargets] 白名单里的机器**
  /// （模型无权指定任意 host，否则一次提示词注入就能把手机当跳板）。
  final bool adbEnabled;

  /// 可控制的手机白名单（ip:port）。空列表 = 一台都没配，工具会引导去设置添加。
  final List<AdbTarget> adbTargets;

  /// 危险命令策略：'deny'（默认，黑名单直接拒绝）/ 'ask'（转用户审批）。
  final String dangerousCommandPolicy;

  /// Dev 工具逐组开关（P2-D1）：组名 git/ssh/plan/task/verify；
  /// 缺省键 = 开（与旧行为一致）。
  final Map<String, bool> devToolToggles;

  bool devToolGroupEnabled(String group) => devToolToggles[group] ?? true;

  // ---- 联网搜索默认值（保持中性：不预置任何个人实例）----
  // 地址默认留空 = 未配置。真机上没有可用实例时，provider 会给??请先??
  // 设置 ??联网搜索填写地址"的明确诊断，而不是拿 127.0.0.1 去连手机自己??
  static const String kDefaultSearXngBaseUrl = '';

  // 引擎白名单默认留??= 由实例决定。实例上有不可达引擎（如墙内实例挂着
  // google cse / duckduckgo）时，用户自行填写可达引擎可显著提??
  // （实测某实例：全引擎 21s ??指定 2 个可达引??2.5s）??
  static const String kDefaultSearXngEngines = '';

  // 超时 30s：实例聚合多引擎本身就要十几到二十几秒，15s 会稳定误杀??
  static const int kDefaultSearXngTimeoutMs = 30000;

  const InferenceSettings({
    // 默认开??GPU：与 gpuLayers=100 全量卸载一致；??settingsProvider
    // 异步 _load() 完成前，UI/加载逻辑若读取默认值，仍应??GPU 路径??
    // 避免启动后首次加载模型意外落??CPU??
    this.enableGpu = true,
    this.gpuLayers = 100,
    this.contextSize = 4096,
    this.enableThinking = false,
    this.gpuBackend = 'auto',
    Map<String, bool>? mtpEnabledByModel,
    this.enableMtpFeature = false,
    Map<String, bool>? dsparkEnabledByModel,
    Map<String, int>? moeBankOverrideByModel,
    Map<String, bool>? visionEnabledByModel,
    this.enableDsparkFeature = false,
    this.defaultModelId,
    List<ApiModelConfig>? apiModels,
    this.activeApiModelId,
    // ---- 智能体（Agent??---
    this.agentEnabled = true,
    this.useNewAgentMode = true,
    this.agentModelSource,
    this.agentModelId,
    this.agentNctx = 8192,
    // 2026-09-28 调大：5 步/512 token 对真实任务太小（多步任务必撞上限、
    // 思考型模型 512 连工具调用都写不完被截断）。存量等于旧默认的值在
    // fromJson 一次性迁移到新默认。
    this.agentMaxRounds = 12,
    this.agentMaxSearchesPerTurn = 5,
    this.agentGoalMaxRounds = 8,
    this.mcpServers = const [],
    this.pinnedConversationIds = const [],
    this.asrEnhancedMode = false,
    this.asrHotwordCategories = const [],
    this.asrHotwordCustom = '',
    this.asrHotwordAdded = const {},
    this.asrHotwordRemoved = const {},
    this.agentMaxConcurrentTurns = 1,
    this.agentApiContextBudget = 32768,
    this.agentTokensPerRound = 1024,
    this.agentToolTimeoutMs = 15000,
    this.agentAllowParallelTools = false,
    this.agentMaxParallel = 4,
    this.agentTemperature = 0.7,
    this.agentApiMaxRounds = 16,
    this.agentApiTokensPerRound = 8192,
    this.agentApiTemperature = 0.7,
    this.agentApiToolTimeoutMs = 30000,
    this.agentApiAllowParallelTools = true,
    this.agentApiMaxParallel = 4,
    this.agentThinkingMaxChars = 6000,
    this.agentThinkingOnToolSteps = false,
    this.chatTextScale = 1.0,
    this.uiScale = 1.0,
    this.composerQuickActions = const [],
    this.autoCompactThreshold = 0.8,
    this.themeMode = 'system',
    this.agentSubagentEnabled = true,
    this.agentSubagentApiModelId = '',
    this.agentCompressionApiModelId = '',
    this.agentPromptTierMode = 'auto',
    this.agentCompactEnabled = true,
    this.agentSpillEnabled = true,
    this.edgeTtsEnabled = false,
    this.edgeTtsAutoSpeak = false,
    this.edgeTtsVoice = 'zh-CN-XiaoxiaoNeural',
    this.edgeTtsRate = 0,
    this.edgeTtsPitch = 0,
    this.edgeTtsVolume = 0,
    this.agentTraceExportEnabled = false,
    this.webSearchEnabled = false,
    this.webSearchSearXngBaseUrl = kDefaultSearXngBaseUrl,
    this.webSearchSearXngApiKey,
    this.webSearchSearXngMaxResults = 8,
    this.webSearchSearXngTimeoutMs = kDefaultSearXngTimeoutMs,
    this.webSearchSearXngLanguage,
    this.webSearchSearXngCategories,
    this.webSearchSearXngEngines = kDefaultSearXngEngines,
    this.webSearchDirectEngines = kDefaultDirectEngines,
    this.webSearchDirectEnabled = true,
    this.webSearchDirectLowRiskPerWindow = 10,
    this.webSearchDirectHighRiskPerWindow = 4,
    this.agentShellEnabled = true,
    this.agentPythonEnabled = true,
    this.agentFullFileAccess = false,
    // 长期记忆默认开启（2026-10-01 P1：系统提示自动注入【用户记忆】段，
    // 跨会话偏好/事实是"智能感"的核心；设置里仍可关）。
    this.agentMemoryEnabled = true,
    // ---- 推理引擎 ----
    this.autoLoadMmproj = true,
    this.showResourceMonitor = true,
    this.resourceSampleIntervalSec = 1,
    // OOM 内存守卫默认开启，余量默认与原生层常量一致（768 / 1536 MB）??
    this.oomGuardEnabled = true,
    this.inferenceLimitRefreshRate = true,
    this.gpuNUbatch = 0,
    this.vkNoSubgroup = false,
    this.smartMoeEnabled = true,
    this.oomPreHeadroomMb = 768,
    this.oomPostHeadroomMb = 1536,
    this.kvCacheType = 'q4_0',
    this.flashAttn = false,
    Map<String, List<String>>? agentToolsByModel,
    Map<String, Map<String, dynamic>>? agentByModel,
    List<AgentPersona>? agentPersonas,
    this.activePersonaId = kStandardPersonaId,
    // ---- 开发模式（Dev Agent）----
    this.devModeEnabled = false,
    this.adbEnabled = false,
    this.devWorkspaceId = 'default',
    List<SshConfig>? sshConfigs,
    List<AdbTarget>? adbTargets,
    this.dangerousCommandPolicy = 'deny',
    this.devToolToggles = const {},
  })  : sshConfigs = sshConfigs ?? const [],
        adbTargets = adbTargets ?? const [],
        mtpEnabledByModel = mtpEnabledByModel ?? const {},
        dsparkEnabledByModel = dsparkEnabledByModel ?? const {},
        moeBankOverrideByModel = moeBankOverrideByModel ?? const {},
        visionEnabledByModel = visionEnabledByModel ?? const {},
        apiModels = apiModels ?? const [],
        agentToolsByModel = agentToolsByModel ?? const {},
        agentByModel = agentByModel ?? const {},
        agentPersonas = agentPersonas ?? const [];

  /// 便捷读取：按 id 取 SSH 配置（空 id / 找不到 → null）。
  SshConfig? sshConfigFor(String? id) {
    if (id == null || id.isEmpty) return null;
    for (final c in sshConfigs) {
      if (c.id == id) return c;
    }
    return null;
  }

  /// 便捷读取：某个模型是否启??MTP（未配置视为关闭）??
  bool mtpEnabled(String modelId) => mtpEnabledByModel[modelId] ?? false;

  /// 便捷读取：某个模型是否启??dspark（未配置视为关闭）??
  bool dsparkEnabled(String modelId) => dsparkEnabledByModel[modelId] ?? false;

  /// 便捷读取：某模型的手动 MoE bank 覆写（未配置 = null = 自动分档）。
  /// 通配键 '*' 为全局覆写（设置页滑条），按模型条目优先于通配。
  int? moeBankOverride(String modelId) =>
      moeBankOverrideByModel[modelId] ?? moeBankOverrideByModel['*'];

  /// 便捷读取：视觉模型是否加载 mmproj 视觉塔。按模型显式配置优先，
  /// 未配置回退全局 autoLoadMmproj（既有默认行为不变）。
  bool visionEnabled(String modelId) =>
      visionEnabledByModel[modelId] ?? autoLoadMmproj;

  /// ??ݶ?ȡ??ĳ??ģ?????õĹ????嵥?????б? = ?????ģ??Ŀ¼??????
  /// agentDefaults.enabledTools（目录合并逻辑??agent 接入层）??
  List<String> agentToolsFor(String modelId) =>
      agentToolsByModel[modelId] ?? const [];

  /// 便捷读取：某个模型的 agent 配置覆盖（未配置返回 null）??
  Map<String, dynamic>? agentConfigFor(String modelId) => agentByModel[modelId];

  /// 便捷读取：当前激活的 API 模型配置；未激??不存在返??null??
  /// 便捷读取：当前激活的智能体人格。
  /// 标准人格返回 null（调用方按“无人格附加指令”处理）；
  /// 激活 id 指向的自定义人格不存在（已删除/损坏）时回落标准人格。
  AgentPersona? activePersona() {
    if (activePersonaId == kStandardPersonaId) return null;
    for (final persona in agentPersonas) {
      if (persona.id == activePersonaId) return persona;
    }
    return null;
  }

  ApiModelConfig? activeApiModel() {
    if (activeApiModelId == null) return null;
    for (final cfg in apiModels) {
      if (cfg.id == activeApiModelId) return cfg;
    }
    return null;
  }

  /// 双场景档生效参数视图：按驱动路线取 local 平铺键或 API 专键。
  AgentProfile agentProfileFor({required bool useApi}) => useApi
      ? AgentProfile(
          maxRounds: agentApiMaxRounds,
          tokensPerRound: agentApiTokensPerRound,
          temperature: agentApiTemperature,
          toolTimeoutMs: agentApiToolTimeoutMs,
          allowParallelTools: agentApiAllowParallelTools,
          maxParallel: agentApiMaxParallel,
        )
      : AgentProfile(
          maxRounds: agentMaxRounds,
          tokensPerRound: agentTokensPerRound,
          temperature: agentTemperature,
          toolTimeoutMs: agentToolTimeoutMs,
          allowParallelTools: agentAllowParallelTools,
          maxParallel: agentMaxParallel,
        );

  InferenceSettings copyWith({
    bool? enableGpu,
    int? gpuLayers,
    int? contextSize,
    bool? enableThinking,
    String? gpuBackend,
    Map<String, bool>? mtpEnabledByModel,
    bool? enableMtpFeature,
    Map<String, bool>? dsparkEnabledByModel,
    Map<String, int>? moeBankOverrideByModel,
    Map<String, bool>? visionEnabledByModel,
    bool? enableDsparkFeature,
    String? defaultModelId,
    // defaultModelId 为可??String，无法用 `?? this` 区分「未传」与「清空」，
    // 故增加显式清空标记，供取消默认模型时使用??
    bool clearDefaultModel = false,
    List<ApiModelConfig>? apiModels,
    String? activeApiModelId,
    // activeApiModelId 同样可空，需显式标记以区分「未传」与「停用」??
    bool clearActiveApiModel = false,
    // ---- 智能体（Agent??---
    bool? agentEnabled,
    bool? useNewAgentMode,
    String? agentModelSource,
    String? agentModelId,
    // agentModelSource/agentModelId 均可空，需显式标记区分「未传」与「清空」??
    bool clearAgentModel = false,
    int? agentNctx,
    int? agentMaxRounds,
    int? agentMaxSearchesPerTurn,
    int? agentGoalMaxRounds,
    List<McpServerConfig>? mcpServers,
    List<String>? pinnedConversationIds,
    bool? asrEnhancedMode,
    List<String>? asrHotwordCategories,
    String? asrHotwordCustom,
    Map<String, List<String>>? asrHotwordAdded,
    Map<String, List<String>>? asrHotwordRemoved,
    int? agentMaxConcurrentTurns,
    int? agentApiContextBudget,
    int? agentTokensPerRound,
    int? agentToolTimeoutMs,
    bool? agentAllowParallelTools,
    int? agentMaxParallel,
    double? agentTemperature,
    int? agentApiMaxRounds,
    int? agentApiTokensPerRound,
    double? agentApiTemperature,
    int? agentApiToolTimeoutMs,
    bool? agentApiAllowParallelTools,
    int? agentApiMaxParallel,
    int? agentThinkingMaxChars,
    bool? agentThinkingOnToolSteps,
    double? chatTextScale,
    double? uiScale,
    List<String>? composerQuickActions,
    double? autoCompactThreshold,
    String? themeMode,
    bool? agentSubagentEnabled,
    String? agentSubagentApiModelId,
    String? agentCompressionApiModelId,
    String? agentPromptTierMode,
    bool? agentCompactEnabled,
    bool? agentSpillEnabled,
    bool? edgeTtsEnabled,
    bool? edgeTtsAutoSpeak,
    String? edgeTtsVoice,
    int? edgeTtsRate,
    int? edgeTtsPitch,
    int? edgeTtsVolume,
    bool? agentTraceExportEnabled,
    bool? webSearchEnabled,
    String? webSearchSearXngBaseUrl,
    String? webSearchSearXngApiKey,
    int? webSearchSearXngMaxResults,
    int? webSearchSearXngTimeoutMs,
    String? webSearchSearXngLanguage,
    String? webSearchSearXngCategories,
    String? webSearchSearXngEngines,
    List<String>? webSearchDirectEngines,
    bool? webSearchDirectEnabled,
    int? webSearchDirectLowRiskPerWindow,
    int? webSearchDirectHighRiskPerWindow,
    bool? agentShellEnabled,
    bool? agentPythonEnabled,
    bool? agentFullFileAccess,
    bool? agentMemoryEnabled,
    // ---- 推理引擎 ----
    bool? autoLoadMmproj,
    bool? showResourceMonitor,
    int? resourceSampleIntervalSec,
    bool? oomGuardEnabled,
    bool? inferenceLimitRefreshRate,
    int? oomPreHeadroomMb,
    int? oomPostHeadroomMb,
    String? kvCacheType,
    bool? flashAttn,
    int? gpuNUbatch,
    bool? vkNoSubgroup,
    bool? smartMoeEnabled,
    Map<String, List<String>>? agentToolsByModel,
    Map<String, Map<String, dynamic>>? agentByModel,
    List<AgentPersona>? agentPersonas,
    String? activePersonaId,
    // ---- 开发模式（Dev Agent）----
    bool? devModeEnabled,
    bool? adbEnabled,
    String? devWorkspaceId,
    List<SshConfig>? sshConfigs,
    List<AdbTarget>? adbTargets,
    String? dangerousCommandPolicy,
    Map<String, bool>? devToolToggles,
    bool clearSshConfig = false,
  }) {
    return InferenceSettings(
      enableGpu: enableGpu ?? this.enableGpu,
      gpuLayers: gpuLayers ?? this.gpuLayers,
      contextSize: contextSize ?? this.contextSize,
      enableThinking: enableThinking ?? this.enableThinking,
      gpuBackend: gpuBackend ?? this.gpuBackend,
      mtpEnabledByModel: mtpEnabledByModel ?? this.mtpEnabledByModel,
      enableMtpFeature: enableMtpFeature ?? this.enableMtpFeature,
      dsparkEnabledByModel: dsparkEnabledByModel ?? this.dsparkEnabledByModel,
      moeBankOverrideByModel:
          moeBankOverrideByModel ?? this.moeBankOverrideByModel,
      visionEnabledByModel: visionEnabledByModel ?? this.visionEnabledByModel,
      enableDsparkFeature: enableDsparkFeature ?? this.enableDsparkFeature,
      defaultModelId:
          clearDefaultModel ? null : defaultModelId ?? this.defaultModelId,
      apiModels: apiModels ?? this.apiModels,
      activeApiModelId: clearActiveApiModel
          ? null
          : activeApiModelId ?? this.activeApiModelId,
      agentEnabled: agentEnabled ?? this.agentEnabled,
      useNewAgentMode: useNewAgentMode ?? this.useNewAgentMode,
      agentModelSource:
          clearAgentModel ? null : agentModelSource ?? this.agentModelSource,
      agentModelId: clearAgentModel ? null : agentModelId ?? this.agentModelId,
      agentNctx: agentNctx ?? this.agentNctx,
      agentMaxRounds: agentMaxRounds ?? this.agentMaxRounds,
      agentMaxSearchesPerTurn:
          agentMaxSearchesPerTurn ?? this.agentMaxSearchesPerTurn,
      agentGoalMaxRounds: agentGoalMaxRounds ?? this.agentGoalMaxRounds,
      mcpServers: mcpServers ?? this.mcpServers,
      pinnedConversationIds:
          pinnedConversationIds ?? this.pinnedConversationIds,
      asrEnhancedMode: asrEnhancedMode ?? this.asrEnhancedMode,
      asrHotwordCategories: asrHotwordCategories ?? this.asrHotwordCategories,
      asrHotwordCustom: asrHotwordCustom ?? this.asrHotwordCustom,
      asrHotwordAdded: asrHotwordAdded ?? this.asrHotwordAdded,
      asrHotwordRemoved: asrHotwordRemoved ?? this.asrHotwordRemoved,
      agentMaxConcurrentTurns:
          agentMaxConcurrentTurns ?? this.agentMaxConcurrentTurns,
      agentApiContextBudget:
          agentApiContextBudget ?? this.agentApiContextBudget,
      agentTokensPerRound: agentTokensPerRound ?? this.agentTokensPerRound,
      agentToolTimeoutMs: agentToolTimeoutMs ?? this.agentToolTimeoutMs,
      agentAllowParallelTools:
          agentAllowParallelTools ?? this.agentAllowParallelTools,
      agentMaxParallel: agentMaxParallel ?? this.agentMaxParallel,
      agentTemperature: agentTemperature ?? this.agentTemperature,
      agentApiMaxRounds: agentApiMaxRounds ?? this.agentApiMaxRounds,
      agentApiTokensPerRound:
          agentApiTokensPerRound ?? this.agentApiTokensPerRound,
      agentApiTemperature: agentApiTemperature ?? this.agentApiTemperature,
      agentApiToolTimeoutMs:
          agentApiToolTimeoutMs ?? this.agentApiToolTimeoutMs,
      agentApiAllowParallelTools:
          agentApiAllowParallelTools ?? this.agentApiAllowParallelTools,
      agentApiMaxParallel: agentApiMaxParallel ?? this.agentApiMaxParallel,
      agentThinkingMaxChars:
          agentThinkingMaxChars ?? this.agentThinkingMaxChars,
      agentThinkingOnToolSteps:
          agentThinkingOnToolSteps ?? this.agentThinkingOnToolSteps,
      chatTextScale: chatTextScale ?? this.chatTextScale,
      uiScale: uiScale ?? this.uiScale,
      composerQuickActions: composerQuickActions ?? this.composerQuickActions,
      autoCompactThreshold: autoCompactThreshold ?? this.autoCompactThreshold,
      themeMode: themeMode ?? this.themeMode,
      agentSubagentEnabled: agentSubagentEnabled ?? this.agentSubagentEnabled,
      agentSubagentApiModelId:
          agentSubagentApiModelId ?? this.agentSubagentApiModelId,
      agentCompressionApiModelId:
          agentCompressionApiModelId ?? this.agentCompressionApiModelId,
      agentPromptTierMode: agentPromptTierMode ?? this.agentPromptTierMode,
      agentCompactEnabled: agentCompactEnabled ?? this.agentCompactEnabled,
      agentSpillEnabled: agentSpillEnabled ?? this.agentSpillEnabled,
      edgeTtsEnabled: edgeTtsEnabled ?? this.edgeTtsEnabled,
      edgeTtsAutoSpeak: edgeTtsAutoSpeak ?? this.edgeTtsAutoSpeak,
      edgeTtsVoice: edgeTtsVoice ?? this.edgeTtsVoice,
      edgeTtsRate: edgeTtsRate ?? this.edgeTtsRate,
      edgeTtsPitch: edgeTtsPitch ?? this.edgeTtsPitch,
      edgeTtsVolume: edgeTtsVolume ?? this.edgeTtsVolume,
      agentTraceExportEnabled:
          agentTraceExportEnabled ?? this.agentTraceExportEnabled,
      webSearchEnabled: webSearchEnabled ?? this.webSearchEnabled,
      webSearchSearXngBaseUrl:
          webSearchSearXngBaseUrl ?? this.webSearchSearXngBaseUrl,
      webSearchSearXngApiKey:
          webSearchSearXngApiKey ?? this.webSearchSearXngApiKey,
      webSearchSearXngMaxResults:
          webSearchSearXngMaxResults ?? this.webSearchSearXngMaxResults,
      webSearchSearXngTimeoutMs:
          webSearchSearXngTimeoutMs ?? this.webSearchSearXngTimeoutMs,
      webSearchSearXngLanguage:
          webSearchSearXngLanguage ?? this.webSearchSearXngLanguage,
      webSearchSearXngCategories:
          webSearchSearXngCategories ?? this.webSearchSearXngCategories,
      webSearchSearXngEngines:
          webSearchSearXngEngines ?? this.webSearchSearXngEngines,
      webSearchDirectEngines:
          webSearchDirectEngines ?? this.webSearchDirectEngines,
      webSearchDirectEnabled:
          webSearchDirectEnabled ?? this.webSearchDirectEnabled,
      webSearchDirectLowRiskPerWindow: webSearchDirectLowRiskPerWindow ??
          this.webSearchDirectLowRiskPerWindow,
      webSearchDirectHighRiskPerWindow: webSearchDirectHighRiskPerWindow ??
          this.webSearchDirectHighRiskPerWindow,
      agentShellEnabled: agentShellEnabled ?? this.agentShellEnabled,
      agentPythonEnabled: agentPythonEnabled ?? this.agentPythonEnabled,
      agentFullFileAccess: agentFullFileAccess ?? this.agentFullFileAccess,
      agentMemoryEnabled: agentMemoryEnabled ?? this.agentMemoryEnabled,
      autoLoadMmproj: autoLoadMmproj ?? this.autoLoadMmproj,
      showResourceMonitor: showResourceMonitor ?? this.showResourceMonitor,
      resourceSampleIntervalSec:
          resourceSampleIntervalSec ?? this.resourceSampleIntervalSec,
      oomGuardEnabled: oomGuardEnabled ?? this.oomGuardEnabled,
      inferenceLimitRefreshRate:
          inferenceLimitRefreshRate ?? this.inferenceLimitRefreshRate,
      gpuNUbatch: gpuNUbatch ?? this.gpuNUbatch,
      vkNoSubgroup: vkNoSubgroup ?? this.vkNoSubgroup,
      smartMoeEnabled: smartMoeEnabled ?? this.smartMoeEnabled,
      oomPreHeadroomMb: oomPreHeadroomMb ?? this.oomPreHeadroomMb,
      oomPostHeadroomMb: oomPostHeadroomMb ?? this.oomPostHeadroomMb,
      kvCacheType: kvCacheType ?? this.kvCacheType,
      flashAttn: flashAttn ?? this.flashAttn,
      agentToolsByModel: agentToolsByModel ?? this.agentToolsByModel,
      agentByModel: agentByModel ?? this.agentByModel,
      agentPersonas: agentPersonas ?? this.agentPersonas,
      activePersonaId: activePersonaId ?? this.activePersonaId,
      devModeEnabled: devModeEnabled ?? this.devModeEnabled,
      adbEnabled: adbEnabled ?? this.adbEnabled,
      adbTargets: adbTargets ?? this.adbTargets,
      devWorkspaceId: devWorkspaceId ?? this.devWorkspaceId,
      sshConfigs: clearSshConfig ? const [] : (sshConfigs ?? this.sshConfigs),
      dangerousCommandPolicy:
          dangerousCommandPolicy ?? this.dangerousCommandPolicy,
      devToolToggles: devToolToggles ?? this.devToolToggles,
    );
  }

  Map<String, dynamic> toJson() => {
        'enableGpu': enableGpu,
        'gpuLayers': gpuLayers,
        'contextSize': contextSize,
        'enableThinking': enableThinking,
        'gpuBackend': gpuBackend,
        'mtpEnabledByModel': mtpEnabledByModel,
        'enableMtpFeature': enableMtpFeature,
        'dsparkEnabledByModel': dsparkEnabledByModel,
        // V2（2026-10-16）：旧键里存的手动 bank 值基于已被证伪的
        // 「slot=54MB×bank」内存口径（当时被告知 64 是上限），全部失真——
        // 换新键一次性失效，让用户在新物理模型下重新覆写。
        'moeBankOverrideByModelV2': moeBankOverrideByModel,
        'visionEnabledByModel': visionEnabledByModel,
        'enableDsparkFeature': enableDsparkFeature,
        'defaultModelId': defaultModelId,
        'apiModels': apiModels.map((m) => m.toJson()).toList(),
        'activeApiModelId': activeApiModelId,
        // ---- 智能体（Agent??---
        'agentEnabled': agentEnabled,
        'useNewAgentMode': useNewAgentMode,
        'agentModelSource': agentModelSource,
        'agentModelId': agentModelId,
        'agentNctx': agentNctx,
        'agentMaxRounds': agentMaxRounds,
        'agentMaxSearchesPerTurn': agentMaxSearchesPerTurn,
        'agentGoalMaxRounds': agentGoalMaxRounds,
        'mcpServers': mcpServers.map((s) => s.toJson()).toList(),
        'pinnedConversationIds': pinnedConversationIds,
        'asrEnhancedMode': asrEnhancedMode,
        'asrHotwordCategories': asrHotwordCategories,
        'asrHotwordCustom': asrHotwordCustom,
        'asrHotwordAdded': asrHotwordAdded,
        'asrHotwordRemoved': asrHotwordRemoved,
        'agentMaxConcurrentTurns': agentMaxConcurrentTurns,
        'agentApiContextBudget': agentApiContextBudget,
        'agentTokensPerRound': agentTokensPerRound,
        'agentToolTimeoutMs': agentToolTimeoutMs,
        'agentAllowParallelTools': agentAllowParallelTools,
        'agentMaxParallel': agentMaxParallel,
        'agentTemperature': agentTemperature,
        'agentApiMaxRounds': agentApiMaxRounds,
        'agentApiTokensPerRound': agentApiTokensPerRound,
        'agentApiTemperature': agentApiTemperature,
        'agentApiToolTimeoutMs': agentApiToolTimeoutMs,
        'agentApiAllowParallelTools': agentApiAllowParallelTools,
        'agentApiMaxParallel': agentApiMaxParallel,
        'agentThinkingMaxChars': agentThinkingMaxChars,
        'agentThinkingOnToolSteps': agentThinkingOnToolSteps,
        'chatTextScale': chatTextScale,
        'uiScale': uiScale,
        'composerQuickActions': composerQuickActions,
        'autoCompactThreshold': autoCompactThreshold,
        'themeMode': themeMode,
        'agentSubagentEnabled': agentSubagentEnabled,
        'agentSubagentApiModelId': agentSubagentApiModelId,
        'agentCompressionApiModelId': agentCompressionApiModelId,
        'agentPromptTierMode': agentPromptTierMode,
        'agentCompactEnabled': agentCompactEnabled,
        'agentSpillEnabled': agentSpillEnabled,
        'edgeTtsEnabled': edgeTtsEnabled,
        'edgeTtsAutoSpeak': edgeTtsAutoSpeak,
        'edgeTtsVoice': edgeTtsVoice,
        'edgeTtsRate': edgeTtsRate,
        'edgeTtsPitch': edgeTtsPitch,
        'edgeTtsVolume': edgeTtsVolume,
        'agentTraceExportEnabled': agentTraceExportEnabled,
        'webSearchEnabled': webSearchEnabled,
        'webSearchSearXngBaseUrl': webSearchSearXngBaseUrl,
        'webSearchSearXngApiKey': webSearchSearXngApiKey,
        'webSearchSearXngMaxResults': webSearchSearXngMaxResults,
        'webSearchSearXngTimeoutMs': webSearchSearXngTimeoutMs,
        'webSearchSearXngLanguage': webSearchSearXngLanguage,
        'webSearchSearXngCategories': webSearchSearXngCategories,
        'webSearchSearXngEngines': webSearchSearXngEngines,
        'webSearchDirectEngines': webSearchDirectEngines,
        'webSearchDirectEnabled': webSearchDirectEnabled,
        'webSearchDirectLowRiskPerWindow': webSearchDirectLowRiskPerWindow,
        'webSearchDirectHighRiskPerWindow': webSearchDirectHighRiskPerWindow,
        'agentShellEnabled': agentShellEnabled,
        // 修复遗留：python_exec 与完整文件访问开关此前未写入 toJson??
        // 保存后读回会静默丢配置（默认值兜底）??
        'agentPythonEnabled': agentPythonEnabled,
        'agentFullFileAccess': agentFullFileAccess,
        'agentMemoryEnabled': agentMemoryEnabled,
        // ---- 推理引擎 ----
        'autoLoadMmproj': autoLoadMmproj,
        'showResourceMonitor': showResourceMonitor,
        'resourceSampleIntervalSec': resourceSampleIntervalSec,
        'oomGuardEnabled': oomGuardEnabled,
        'inferenceLimitRefreshRate': inferenceLimitRefreshRate,
        'gpuNUbatch': gpuNUbatch,
        'vkNoSubgroup': vkNoSubgroup,
        'smartMoeEnabled': smartMoeEnabled,
        'oomPreHeadroomMb': oomPreHeadroomMb,
        'oomPostHeadroomMb': oomPostHeadroomMb,
        'kvCacheType': kvCacheType,
        'flashAttn': flashAttn,
        'agentToolsByModel': agentToolsByModel,
        'agentByModel': agentByModel,
        'agentPersonas': agentPersonas.map((p) => p.toJson()).toList(),
        'activePersonaId': activePersonaId,
        // ---- 开发模式（Dev Agent）----
        'devModeEnabled': devModeEnabled,
        'adbEnabled': adbEnabled,
        'adbTargets': [for (final t in adbTargets) t.toJson()],
        'devWorkspaceId': devWorkspaceId,
        'sshConfigs': [for (final c in sshConfigs) c.toJson()],
        'dangerousCommandPolicy': dangerousCommandPolicy,
        'devToolToggles': devToolToggles,
      };

  factory InferenceSettings.fromJson(Map<String, dynamic> json) {
    return InferenceSettings(
      // 缺省/旧文件未存该字段时默认开??GPU：auto 后端会在??GPU 时自??
      // 回落 CPU，V0.1.5 已验??Adreno 825 OpenCL/Vulkan 均正常??
      enableGpu: json['enableGpu'] as bool? ?? true,
      gpuLayers: (json['gpuLayers'] as num?)?.toInt() ?? 100,
      contextSize: (json['contextSize'] as num?)?.toInt() ?? 4096,
      enableThinking: json['enableThinking'] as bool? ?? false,
      gpuBackend: json['gpuBackend'] as String? ?? 'auto',
      // ?ɰ汾?????ȫ?? bool enableMtp?????????????ӳ??Ϊ????֧??ģ?͵?
      // 默认值，保证老配置不丢??
      mtpEnabledByModel: _migrateLegacyMtp(json),
      // 全局 MTP 开关：旧配置无此字段时默认关闭（向后兼容）??
      enableMtpFeature: json['enableMtpFeature'] as bool? ?? false,
      // dspark：按模型 map + 全局开关，旧配置无此字段时默认全关（向后兼容）??
      dsparkEnabledByModel: _parseBoolMap(json['dsparkEnabledByModel']),
      // V2 键（2026-10-16 bank 物理模型修正后一次性迁移，旧键弃用）。
      moeBankOverrideByModel: _parseIntMap(json['moeBankOverrideByModelV2']),
      visionEnabledByModel: _parseBoolMap(json['visionEnabledByModel']),
      enableDsparkFeature: json['enableDsparkFeature'] as bool? ?? false,
      defaultModelId: json['defaultModelId'] as String?,
      // 旧配置缺这两个字段时默认空列??+ 停用，向后兼容??
      apiModels: _parseApiModels(json['apiModels']),
      activeApiModelId: json['activeApiModelId'] as String?,
      // 智能体（Agent）：旧配置缺字段时用默认值，向后兼容??
      agentEnabled: json['agentEnabled'] as bool? ?? true,
      // 旧配置无此字段时默认开启新智能体模式（向后兼容）??
      useNewAgentMode: json['useNewAgentMode'] as bool? ?? true,
      agentModelSource: json['agentModelSource'] as String?,
      agentModelId: json['agentModelId'] as String?,
      agentNctx: (json['agentNctx'] as num?)?.toInt() ?? 8192,
      agentMaxRounds: _migrateOldDefault(
          (json['agentMaxRounds'] as num?)?.toInt(),
          oldDefault: 5,
          newDefault: 12),
      agentMaxSearchesPerTurn:
          (json['agentMaxSearchesPerTurn'] as num?)?.toInt() ?? 5,
      agentGoalMaxRounds: (json['agentGoalMaxRounds'] as num?)?.toInt() ?? 8,
      mcpServers: (json['mcpServers'] as List<dynamic>?)
              ?.map((e) =>
                  McpServerConfig.fromJson((e as Map).cast<String, dynamic>()))
              .where((c) => c.id.isNotEmpty && c.url.isNotEmpty)
              .toList() ??
          const [],
      pinnedConversationIds: (json['pinnedConversationIds'] as List<dynamic>?)
              ?.map((e) => '$e')
              .toList() ??
          const [],
      asrEnhancedMode: json['asrEnhancedMode'] as bool? ?? false,
      asrHotwordCategories: (json['asrHotwordCategories'] as List<dynamic>?)
              ?.map((e) => '$e')
              .toList() ??
          const [],
      asrHotwordCustom: json['asrHotwordCustom'] as String? ?? '',
      asrHotwordAdded: _parseStringListMap(json['asrHotwordAdded']),
      asrHotwordRemoved: _parseStringListMap(json['asrHotwordRemoved']),
      agentMaxConcurrentTurns:
          ((json['agentMaxConcurrentTurns'] as num?)?.toInt() ?? 1).clamp(1, 4),
      agentApiContextBudget:
          ((json['agentApiContextBudget'] as num?)?.toInt() ?? 32768)
              .clamp(4096, 200000),
      agentTokensPerRound: _migrateOldDefault(
          (json['agentTokensPerRound'] as num?)?.toInt(),
          oldDefault: 512,
          newDefault: 1024),
      agentToolTimeoutMs:
          (json['agentToolTimeoutMs'] as num?)?.toInt() ?? 15000,
      agentAllowParallelTools:
          json['agentAllowParallelTools'] as bool? ?? false,
      agentMaxParallel: json['agentMaxParallel'] as int? ?? 4,
      agentTemperature: (json['agentTemperature'] as num?)?.toDouble() ?? 0.7,
      agentApiMaxRounds: (json['agentApiMaxRounds'] as num?)?.toInt() ?? 16,
      agentApiTokensPerRound:
          (json['agentApiTokensPerRound'] as num?)?.toInt() ?? 8192,
      agentApiTemperature:
          (json['agentApiTemperature'] as num?)?.toDouble() ?? 0.7,
      agentApiToolTimeoutMs:
          (json['agentApiToolTimeoutMs'] as num?)?.toInt() ?? 30000,
      agentApiAllowParallelTools:
          json['agentApiAllowParallelTools'] as bool? ?? true,
      agentApiMaxParallel: (json['agentApiMaxParallel'] as num?)?.toInt() ?? 4,
      agentThinkingMaxChars:
          (json['agentThinkingMaxChars'] as num?)?.toInt() ?? 6000,
      agentThinkingOnToolSteps:
          json['agentThinkingOnToolSteps'] as bool? ?? false,
      chatTextScale:
          ((json['chatTextScale'] as num?)?.toDouble() ?? 1.0).clamp(0.7, 1.3),
      uiScale: ((json['uiScale'] as num?)?.toDouble() ?? 1.0).clamp(0.85, 1.30),
      composerQuickActions: (() {
        const known = {
          'agent', 'model', 'persona', 'plan', 'skills', 'plugins',
        };
        final raw = json['composerQuickActions'];
        final list = raw is List ? raw.whereType<String>() : const <String>[];
        return list.where(known.contains).toSet().toList();
      })(),
      autoCompactThreshold:
          ((json['autoCompactThreshold'] as num?)?.toDouble() ?? 0.8)
              .clamp(0.5, 0.95),
      themeMode: () {
        const known = {'system', 'light', 'dark'};
        final raw = json['themeMode'];
        return raw is String && known.contains(raw) ? raw : 'system';
      }(),
      agentSubagentEnabled: json['agentSubagentEnabled'] as bool? ?? true,
      agentSubagentApiModelId: json['agentSubagentApiModelId'] as String? ?? '',
      agentCompressionApiModelId:
          json['agentCompressionApiModelId'] as String? ?? '',
      agentPromptTierMode: const ['auto', 'compact', 'full']
              .contains(json['agentPromptTierMode'])
          ? json['agentPromptTierMode'] as String
          : 'auto',
      agentCompactEnabled: json['agentCompactEnabled'] as bool? ?? true,
      agentSpillEnabled: json['agentSpillEnabled'] as bool? ?? true,
      edgeTtsEnabled: json['edgeTtsEnabled'] as bool? ?? false,
      edgeTtsAutoSpeak: json['edgeTtsAutoSpeak'] as bool? ?? false,
      edgeTtsVoice: json['edgeTtsVoice'] as String? ?? 'zh-CN-XiaoxiaoNeural',
      edgeTtsRate: ((json['edgeTtsRate'] as num?) ?? 0).clamp(-50, 100).toInt(),
      edgeTtsPitch:
          ((json['edgeTtsPitch'] as num?) ?? 0).clamp(-50, 50).toInt(),
      edgeTtsVolume:
          ((json['edgeTtsVolume'] as num?) ?? 0).clamp(-50, 50).toInt(),
      agentTraceExportEnabled:
          json['agentTraceExportEnabled'] as bool? ?? false,
      webSearchEnabled: json['webSearchEnabled'] as bool? ?? false,
      // 联网搜索 SearXNG 配置：旧配置缺字段时用默认值（向后兼容）??
      // 空地址 = 未配置，此时联网搜索工具会给??请先在设置里填地址"的诊断??
      webSearchSearXngBaseUrl:
          json['webSearchSearXngBaseUrl'] as String? ?? kDefaultSearXngBaseUrl,
      webSearchSearXngApiKey: json['webSearchSearXngApiKey'] as String?,
      webSearchSearXngMaxResults:
          (json['webSearchSearXngMaxResults'] as num?)?.toInt() ?? 8,
      webSearchSearXngTimeoutMs:
          (json['webSearchSearXngTimeoutMs'] as num?)?.toInt() ??
              kDefaultSearXngTimeoutMs,
      webSearchSearXngLanguage: json['webSearchSearXngLanguage'] as String?,
      webSearchSearXngCategories: json['webSearchSearXngCategories'] as String?,
      webSearchSearXngEngines:
          json['webSearchSearXngEngines'] as String? ?? kDefaultSearXngEngines,
      webSearchDirectEngines:
          _parseDirectEngines(json['webSearchDirectEngines']),
      webSearchDirectEnabled: json['webSearchDirectEnabled'] as bool? ?? true,
      webSearchDirectLowRiskPerWindow:
          _clampInt(json['webSearchDirectLowRiskPerWindow'], 1, 20, 10),
      webSearchDirectHighRiskPerWindow:
          _clampInt(json['webSearchDirectHighRiskPerWindow'], 1, 6, 4),
      agentShellEnabled: json['agentShellEnabled'] as bool? ?? true,
      agentPythonEnabled: json['agentPythonEnabled'] as bool? ?? true,
      agentFullFileAccess: json['agentFullFileAccess'] as bool? ?? false,
      // 记忆默认开；曾显式存过 false 的用户保持 false（fromJson 只兜缺字段）。
      agentMemoryEnabled: json['agentMemoryEnabled'] as bool? ?? true,
      // 推理引擎扩展：旧配置缺字段时用默认值（投影器默认加载、监控默认开启）??
      autoLoadMmproj: json['autoLoadMmproj'] as bool? ?? true,
      showResourceMonitor: json['showResourceMonitor'] as bool? ?? true,
      resourceSampleIntervalSec:
          (json['resourceSampleIntervalSec'] as num?)?.toInt() ?? 1,
      // OOM 内存守卫：旧配置缺字段时默认开??+ 原生层默认余量（向后兼容）??
      oomGuardEnabled: json['oomGuardEnabled'] as bool? ?? true,
      inferenceLimitRefreshRate:
          json['inferenceLimitRefreshRate'] as bool? ?? true,
      gpuNUbatch: (json['gpuNUbatch'] as num?)?.toInt() ?? 0,
      vkNoSubgroup: json['vkNoSubgroup'] as bool? ?? false,
      smartMoeEnabled: json['smartMoeEnabled'] as bool? ?? true,
      oomPreHeadroomMb: (json['oomPreHeadroomMb'] as num?)?.toInt() ?? 768,
      oomPostHeadroomMb: (json['oomPostHeadroomMb'] as num?)?.toInt() ?? 1536,
      kvCacheType: (const ['q8_0', 'f16']).contains(json['kvCacheType'])
          ? json['kvCacheType'] as String
          : 'q4_0',
      flashAttn: (json['flashAttn'] as bool?) ?? false,
      agentToolsByModel: _parseAgentTools(json['agentToolsByModel']),
      agentByModel: _parseAgentByModel(json['agentByModel']),
      agentPersonas: _parsePersonas(json['agentPersonas']),
      activePersonaId: json['activePersonaId'] as String? ?? kStandardPersonaId,
      // ---- 开发模式（Dev Agent）：旧配置缺字段时默认关闭（向后兼容）----
      devModeEnabled: json['devModeEnabled'] as bool? ?? false,
      adbEnabled: json['adbEnabled'] as bool? ?? false,
      adbTargets: parseAdbTargets(json['adbTargets']),
      devWorkspaceId: json['devWorkspaceId'] as String? ?? 'default',
      // 新版列表优先；旧版单配置自动迁移为列表首项。
      sshConfigs: _parseSshConfigs(json['sshConfigs'], json['sshConfig']),
      dangerousCommandPolicy:
          json['dangerousCommandPolicy'] as String? ?? 'deny',
      devToolToggles: (json['devToolToggles'] as Map<String, dynamic>?)
              ?.map((k, v) => MapEntry(k, v as bool? ?? true)) ??
          const {},
    );
  }

  /// 解析 SSH 配置列表；缺列表时回退旧版单配置（迁移为列表首项）。
  ///
  /// 旧配置（无 `id` 字段）迁移后 id 为空 → 编辑/删除会失效（空 id 删除被
  /// 忽略、upsert 变追加），此处一次性补稳定 id（补完即持久化，下次幂等）。
  static List<SshConfig> _parseSshConfigs(Object? raw, Object? legacy) {
    List<SshConfig>? parsed;
    if (raw is List) {
      parsed = <SshConfig>[];
      for (final e in raw) {
        if (e is Map<String, dynamic>) {
          final c = SshConfig.fromJson(e);
          if (c != null) parsed.add(c);
        } else if (e is Map) {
          final c = SshConfig.fromJson(Map<String, dynamic>.from(e));
          if (c != null) parsed.add(c);
        }
      }
    } else if (legacy is Map<String, dynamic>) {
      final c = SshConfig.fromJson(legacy);
      if (c != null) parsed = [c];
    } else if (legacy is Map) {
      final c = SshConfig.fromJson(Map<String, dynamic>.from(legacy));
      if (c != null) parsed = [c];
    } else {
      return const [];
    }
    // 空 id → 分配稳定 id（时间戳 + 序号），幂等：补完持久化后不再补。
    final list = parsed ?? const <SshConfig>[];
    for (var i = 0; i < list.length; i++) {
      final c = list[i];
      if (c.id.trim().isEmpty) {
        list[i] = c.copyWith(
          id: 'ssh_legacy_${DateTime.now().millisecondsSinceEpoch}_$i',
          name: c.name.trim().isEmpty ? '${c.host}:${c.port}' : c.name,
        );
      }
    }
    return list;
  }

  /// 解析自定义人格列表；格式非法时返回空列表（不崩，回落标准人格）。
  static List<AgentPersona> _parsePersonas(Object? raw) {
    if (raw is! List) return const [];
    final list = <AgentPersona>[];
    for (final e in raw) {
      if (e is Map<String, dynamic>) {
        final persona = AgentPersona.fromJson(e);
        if (persona.id.isNotEmpty && persona.name.isNotEmpty) {
          list.add(persona);
        }
      } else if (e is Map) {
        final persona = AgentPersona.fromJson(Map<String, dynamic>.from(e));
        if (persona.id.isNotEmpty && persona.name.isNotEmpty) {
          list.add(persona);
        }
      }
    }
    return list;
  }

  /// 解析按模型工具清单：`{modelId: [toolName]}`。格式非法时返回??map（不崩）??
  static Map<String, List<String>> _parseAgentTools(Object? raw) {
    if (raw is! Map) return const {};
    final result = <String, List<String>>{};
    raw.forEach((k, v) {
      if (v is List) {
        result[k.toString()] =
            v.map((e) => e.toString()).where((s) => s.isNotEmpty).toList();
      }
    });
    return result;
  }

  /// 解析按模??agent 配置：`{modelId: {maxRounds, tokensPerRound, nctx}}`??
  /// 格式非法时返回空 map（不崩）??
  static Map<String, Map<String, dynamic>> _parseAgentByModel(Object? raw) {
    if (raw is! Map) return const {};
    final result = <String, Map<String, dynamic>>{};
    raw.forEach((k, v) {
      if (v is Map) {
        result[k.toString()] = Map<String, dynamic>.from(v);
      }
    });
    return result;
  }

  /// 解析 API 模型列表；缺字段/格式非法时返回空列表（不崩）??
  static List<ApiModelConfig> _parseApiModels(Object? raw) {
    if (raw is! List) return const [];
    final list = <ApiModelConfig>[];
    for (final e in raw) {
      if (e is Map<String, dynamic>) {
        list.add(ApiModelConfig.fromJson(e));
      } else if (e is Map) {
        list.add(ApiModelConfig.fromJson(Map<String, dynamic>.from(e)));
      }
    }
    return list;
  }

  /// 旧默认值一次性迁移：存量设置里等于旧默认的值抬到新默认（幂等）。
  ///
  /// 用户显式设置过的非默认值不动；旧默认值与"从未改过"不可区分，
  /// 一并抬升（2026-09-28 智能体预算调大：maxRounds 5→12、tokens 512→1024）。
  static int _migrateOldDefault(int? stored,
      {required int oldDefault, required int newDefault}) {
    if (stored == null) return newDefault;
    return stored == oldDefault ? newDefault : stored;
  }

  /// 兼容旧配置：旧字段 `enableMtp`（全局 bool）→ 新的按模型 map。
  ///
  /// 关键修复：文件里若已存在 `mtpEnabledByModel`（当前版本标准格式）??
  /// **必须原样采用**，不能因为缺少顶??`enableMtp` 字段就整体丢弃—??
  /// 否则每次 reload 都会把用户按模型开启的 MTP 开关清空，导致 MTP 永远不生效??
  /// 仅当 `mtpEnabledByModel` 缺失（老版本只有全局 `enableMtp:true`）时??
  /// 因无法定位具体模型而保持默认全关，由用户重新按模型开启??
  /// 解析按模??bool map（如 dsparkEnabledByModel）；格式非法时返回空 map??
  static Map<String, bool> _parseBoolMap(Object? raw) {
    if (raw is! Map) return const {};
    return raw.map((k, v) => MapEntry(k.toString(), v as bool? ?? false));
  }

  /// 解析按模型 int map（如 moeBankOverrideByModel）；非法条目丢弃，空返回空 map。
  static Map<String, int> _parseIntMap(Object? raw) {
    if (raw is! Map) return const {};
    final out = <String, int>{};
    raw.forEach((k, v) {
      final iv = v is int ? v : int.tryParse(v?.toString() ?? '');
      if (iv != null) out[k.toString()] = iv;
    });
    return out;
  }

  static Map<String, bool> _migrateLegacyMtp(Map<String, dynamic> json) {
    final map = json['mtpEnabledByModel'] as Map<String, dynamic>?;
    if (map != null) {
      return map.map((k, v) => MapEntry(k, v as bool? ?? false));
    }
    // 仅有旧版全局 enableMtp 时保持默认全关：无法定位具体模型（不迁移为开??
    // ??AGENTS.md 约定），由用户在模型列表重新逐个开启??
    return const {};
  }

  /// Map<String, List<String>> 容错解析（热词差量覆盖等字段共用）。
  static Map<String, List<String>> _parseStringListMap(Object? raw) {
    if (raw is! Map) return const {};
    final out = <String, List<String>>{};
    raw.forEach((k, v) {
      out['$k'] = v is List<dynamic> ? v.map((e) => '$e').toList() : <String>[];
    });
    return out;
  }
}

/// 智能体双场景档生效参数视图（[InferenceSettings.agentProfileFor] 返回）。
///
/// 把 local 平铺键与 API 专键归一成同一口径，供 AgentConfig 构建消费。
class AgentProfile {
  final int maxRounds;
  final int tokensPerRound;
  final double temperature;
  final int toolTimeoutMs;
  final bool allowParallelTools;
  final int maxParallel;

  const AgentProfile({
    required this.maxRounds,
    required this.tokensPerRound,
    required this.temperature,
    required this.toolTimeoutMs,
    required this.allowParallelTools,
    required this.maxParallel,
  });
}

/// 基于本地 JSON 文件的轻量设置持久化（不引入额外依赖，复??path_provider）??
///
/// 文件位于应用文档目录下的 `inference_settings.json`??
class SettingsService {
  static const _fileName = 'inference_settings.json';

  Future<String> _resolvePath() async {
    final dir = await getApplicationDocumentsDirectory();
    return p.join(dir.path, _fileName);
  }

  /// 读取设置；文件不存在或损坏时返回默认值??
  Future<InferenceSettings> load() async {
    try {
      final path = await _resolvePath();
      final file = File(path);
      if (!await file.exists()) return const InferenceSettings();
      final content = await file.readAsString();
      if (content.trim().isEmpty) return const InferenceSettings();
      final json = jsonDecode(content) as Map<String, dynamic>;
      return InferenceSettings.fromJson(json);
    } catch (e) {
      // 任何解析错误都回落到默认值，避免影响主流程??
      return const InferenceSettings();
    }
  }

  /// 写入设置。失败时抛出异常由调用方处理??
  ///
  /// 原子写入：先??`.tmp` ??rename。此前直??writeAsString，崩??断电??
  /// 可能留下半截 JSON——load 全部回落默认值，用户配置静默丢失。rename ??
  /// 同目录上是原子操作，损坏面收敛为「完整旧文件或完整新文件」??
  Future<void> save(InferenceSettings settings) async {
    final path = await _resolvePath();
    final tmp = File('$path.tmp');
    await tmp.writeAsString(jsonEncode(settings.toJson()));
    await tmp.rename(path);
  }
}

/// 解析直连引擎开关列表：丢弃未知 id；缺失 = 默认全启用；空列表 = 用户全关。
List<String> _parseDirectEngines(dynamic raw) {
  if (raw == null) return List<String>.of(kDefaultDirectEngines);
  if (raw is! List) return List<String>.of(kDefaultDirectEngines);
  return raw.whereType<String>().where(kDirectEngineIds.contains).toList();
}

/// JSON 数值夹紧（缺省/越界回默认）。
int _clampInt(dynamic raw, int min, int max, int fallback) {
  final v = raw is int ? raw : int.tryParse('$raw');
  if (v == null) return fallback;
  return v < min ? min : (v > max ? max : v);
}
