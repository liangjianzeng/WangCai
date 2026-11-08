// 内置驱动清单（设计 §4.1/§5/§6）。数据，不是代码；升级可被远程清单覆盖（M2）。
// M0-3 实测校正：server 端参数集 `-fa 1 -np 1 -dev OPENVINO{n} --jinja`（无 -st）。
// P14e（GGML_OPENVINO_KV_HOST_WRITE）在 2026-11-05 引擎重建中 DLL 默认翻 ON，
// 实锤致 NPU 全线垃圾文本（Omni-2B/1.7B 复读、Spark-4B 乱码汤，CPU 干净、
// 显式 0 即愈——docs/defect-npu-p14e-kvhostwrite.md）；引擎侧根因修复前，
// 本清单以模板默认 0 钉死关闭（留 {kvHostWrite=…} 开关位供未来翻档）。
//
// ctx 口径（2026-11-06 用户拍板，替代旧 per-preset ctx）：「4096 是最基本，
// 否则狗毛都干不了」——preset 不再携带 ctx，全线走**全局单值**（默认 4096，
// 设置页滑杆 512 一档至 16K，持久化 routing.json ctx 键，见
// local_server_inference.setGlobalCtx）。preset 只保留质量臂数据：chunk、
// device、paramsB、extraEnv（DISABLE_DECODE_LEVELS 等实测必需项）。
// 旧的 16K deep preset 已删：深上下文臂（NPUW_FOLD=YES）由网关在
// ctx>4096 时自动挂载，不再是一个模型档位。
import 'engine_manifest.dart';

// vision=true（2026-11-07 第二幕回填）：defect-npu-mtmd 引擎修复后 NPU
// 带图三线 E2E 全绿（mtmd-cli 128px / 1920×1200 + llama-server OpenAI 格式
// 带图）。注意：这是**引擎**能力声明——具体模型能不能读图由带图前置门按
// 「本次启动是否挂 mmproj」per-model 判定（local_server_inference.
// _visionGateErrorIfAny），没挂视觉塔的模型发图仍明确报错不改道。
const String wangcaiNpuManifestJson = '''
{
  "id": "wangcai-npu",
  "display": "汪柴 · Intel NPU",
  "kind": "llamaServer",
  "argsTemplate": ["-m","{model}","--mmproj","{mmproj?}","-c","{ctx}","--temp","0",
                   "-np","1","-fa","1","-dev","{devArg=OPENVINO3}","--jinja","--no-warmup",
                   "--host","127.0.0.1","--port","{port}"],
  "envTemplate": {
    "GGML_OPENVINO_DEVICE": "{device=NPU}",
    "GGML_OPENVINO_CACHE_DIR": "{cacheDir}",
    "GGML_OPENVINO_PREFILL_CHUNK_SIZE": "{chunk}",
    "GGML_OPENVINO_KV_HOST_WRITE": "{kvHostWrite=0}"
  },
  "capabilities": {"nativeToolCall": true, "vision": true, "audio": false,
                   "devices": ["NPU", "CPU(OPENVINO0)"]},
  "presets": [
    {"name": "lfm3-1.7b", "modelGlob": "LFM3-1.7B*.gguf", "chunk": 256,
     "paramsB": 1.7, "device": "NPU"},
    {"name": "qwen3-4b", "modelGlob": "Qwen3-4B*.gguf", "chunk": 128,
     "paramsB": 4.0, "device": "NPU",
     "note": "副靶配置 chunk128（status.md 3/3）；compile overrides 串在 M2 对齐 spark-npu-accept.ps1"},
    {"name": "qwen3.5-4b", "modelGlob": "Qwen3.5-4B*.gguf", "chunk": 128,
     "paramsB": 4.0, "device": "NPU",
     "note": "副靶（Qwen3.5-4B，unsloth Q4_K_M，qwen35 混合 SSM/attention 架构、248k 填充词表）：preset 留位但当前准入被 admission 拦截——GatedDeltaNet 融合算子以自定义 opset 序列化，NPU driver VCL（32.0.100.4512）反序列化即失败，graph 编译期死（2026-11-07 三路收口实锤：ref 分解死于 phase-padded 图形状、CPU 分段死于打包边界 reshape、naive 分段死于 NPUW 断言；引擎代码已回滚 pristine，driver 升级支持该 opset 后零改动复验）。chunk128 对齐 4B 级先例；embed 表 248k×2560 比 Qwen3-4B 大 64%，host 预算风险更高，ctx>4096 的 OUT_OF_HOST_MEMORY 禁入规则照常生效"},
    {"name": "qwen3.5-2b", "modelGlob": "Qwen3.5-2B*.gguf", "chunk": 128,
     "paramsB": 2.0, "device": "NPU",
     "note": "副靶（unsloth Qwen3.5-2B-MTP-GGUF，UD-Q4_K_XL 1.29GB，目录已在架）：preset 留位，2026-11-07 尚未本机实测——同 qwen35 混合 SSM/attention 架构，GatedDeltaNet opset 风险与 4B 同源（defect-npu-qwen35-b12034：4B 编译期死，driver VCL 不支持该 opset），2B 不预设结论、暂不加家族级禁入（错拦方向违背「错放危害<错拦」语义），实测后按结果补注或立规则；chunk128 对齐 2B 先例（Omni 同款）；MTP 头在 llama.cpp/NPU 侧同样未验证"},
    {"name": "spark-x2.6-4b", "modelGlob": "Spark-X2.6-4B*.gguf", "chunk": 128,
     "paramsB": 4.0, "device": "NPU",
     "note": "副靶（讯飞 Spark-X2.6-4B Q4_K_M）：chunk128。2026-11-06 换机矩阵把 DDL env 摘了（defect-npu-spark-b12034）：b12034 引擎上 DDL=1 对 4B Spark 直接 ZE_RESULT_ERROR_UNINITIALIZED（Compute error 500，两跑复现）；摘掉后 4096 档 0.42 t/s 引擎地板（不崩不 OOM，按 HANDOFF §4 条款拍板摘除，保守可跑）。历史「DDL 必需」口径属旧引擎（spark-npu-accept.ps1 3/3、HANDOFF 2026-11-01），引擎/驱动更新后按缺陷单复验"},
    {"name": "lfm3-omni-2b", "modelGlob": "LFM3-Omni-2B*.gguf", "chunk": 128,
     "paramsB": 2.0, "device": "NPU",
     "note": "Omni-2B 主打线（chunk128 实测口径），挂 mmproj 视觉塔后 NPU 直接读图（2026-11-07 引擎修复，defect-npu-mtmd；带图首图/新尺寸有编译成本）。2026-11-06 矩阵实锤：DISABLE_DECODE_LEVELS=1 是 Omni 深层 decode 崩溃元凶（4096 档 1.7 vs 19.8 t/s、8192 档 0.8 vs 15.2 t/s，512 档无恙故旧配方未暴露），本 preset 已摘除该 env；超 4096 的 FOLD=YES 由网关自动挂（8192 无 FOLD 会塌到 0.3 t/s，勿关）"},
    {"name": "minicpm5-2b", "modelGlob": "MiniCPM5-2B*.gguf", "chunk": 256,
     "paramsB": 2.6, "device": "NPU",
     "note": "副靶（OpenBMB MiniCPM5-2B Q4_K_M，llama-arch thinking 模型，ModelScope）：preset 留位但当前 admission 禁入——4096 基本档两种配方双死（chunk256 首执行 DEVICE_LOST 挂设备、chunk128 编译静默崩，2026-11-07 本机实锤；旧机验收仅 ctx 512），详见 defect-npu-minicpm5-b12034；thinking 模型 CoT 预算 n≥192"},
    {"name": "neohorse-1-4b", "modelGlob": "NeoHorse-1-4B*.gguf", "chunk": 128,
     "paramsB": 4.0, "device": "NPU",
     "note": "副靶（TokenRhythm NeoHorse-1 4B Q4_K_M，2.5GB，262k ctx，原生工具调用，下载目录已在架）：preset 留位，2026-11-07 尚未本机实测——不预设性能/稳定性结论；chunk128 对齐 4B 家族先例（qwen3-4b/qwen3.5-4b/spark 同款），paramsB 4.0 自动落入通用 4B admission（ctx≤512 放行、>512 前置拦+改道建议），实测后按结果补注"}
  ],
  "admission": [
    {"ifModelGlob": "Spark-X2.6-4B*.gguf", "ifCtxGt": 512,
     "message": "Spark-X2.6-4B 在 NPU 上深上下文必塌：对话深度到 level 1024 档图即撞设备预算，全局回退后 0.42 t/s 地板（defect-npu-spark-b12034，2026-11-07 智能体场景实锤）；ctx≤512 档 level 图实测健康（2026-11-07 复测 warm ≈6 t/s，零预算异常）",
     "suggestion": "模型级 ctx 调到 ≤512 即可在 NPU 保守使用（聊天可用，智能体不建议）；长上下文/智能体改用 LFM3-1.7B / Omni-2B（21.6/21.9 t/s）"},
    {"ifModelGlob": "Qwen3.5-4B*.gguf",
     "message": "Qwen3.5-4B 在 NPU 引擎上编译即失败：GatedDeltaNet 融合算子（qwen35 混合 SSM/attention 架构独有）以自定义 opset 序列化，NPU driver VCL 反序列化不支持（「Cannot create GatedDeltaNet layer ... unsupported opset: extension」，driver 32.0.100.4512，2026-11-07 实锤；引擎侧 ref 分解/CPU 分段/naive 分段三路收口均不可行，详见 defect-npu-qwen35-b12034）",
     "suggestion": "改用 CUDA/Vulkan 引擎跑 Qwen3.5-4B（unsloth Q4_K_M 已就位），或 NPU 档配 LFM3-1.7B / Omni-2B；NPU driver 升级后按 defect 文档复验条件重测"},
    {"ifCtxGt": 512, "ifParamsBAtLeast": 3.5,
     "message": "4B 级模型在 NPU 上超 512 上下文不可用（2026-11-07 本机实锤：Qwen3-4B@4096 首请求即 L0 UNINITIALIZED 500 Compute error；Spark@4096 预算非确定性塌方 0.42 t/s——bindings 旧档已按 stable 语义收回；2026-11-08 bench 复核：Qwen3-4B@ctx2176 编译 39s 过、首执行同样 UNINITIALIZED——包线墙实测钉在 512 上方）；ctx≤512 确定可用（Spark warm ≈6 t/s、Qwen3-4B bench 口径 tg 8.15 t/s——「历史 1.3 t/s」系旧引擎时代遗留口径，已翻案，详见 docs/HANDOFF.md 2026-11-08 节）",
     "suggestion": "模型级 ctx 调到 ≤512，或 NPU 档配 LFM3-1.7B / Omni-2B（全 ctx 健康 21.6/21.9 t/s）"},
    {"ifModelGlob": "MiniCPM5-2B*.gguf",
     "message": "MiniCPM5-2B 在 NPU 引擎上过不了 4096 基本档（2026-11-07 本机实锤两种配方双死：preset 现配方 chunk256 编译过但首执行 ZE_RESULT_ERROR_DEVICE_LOST 设备挂死 server 随之崩；4B 家族先例 chunk128 编译管线卡死 >8min 后进程静默崩溃无任何错误行；旧机验收脚本 minicpm5-npu-accept.ps1 只验过 ctx 512——4096 从未被任何配方验证；对照组 Omni 同 ctx 同 DLL 全天健康，MiniCPM5 arch 特异性，详见 defect-npu-minicpm5-b12034）",
     "suggestion": "改用 CUDA/Vulkan 引擎跑 MiniCPM5-2B，或 NPU 档配 LFM3-1.7B / Omni-2B（Omni 已支持 NPU 读图）；NPU driver/引擎更新后按 defect 文档复验条件重测"}
  ],
  "timingHints": {"coldCompileMs": 600000, "warmMs": 15000},
  "hardFlagsHint": "-fa 1 -np 1 -dev OPENVINO3 --jinja（server 无 -st，M0-3 实测）"
}
''';

const String llamacppVulkanManifestJson = '''
{
  "id": "llamacpp-vulkan",
  "display": "llama.cpp · Vulkan（核显/N 卡）",
  "kind": "llamaServer",
  "argsTemplate": ["-m","{model}","--mmproj","{mmproj?}","-c","{ctx}","--temp","0",
                   "-ngl","{gpuLayers=99}","--device","{gpuDevice?}","--jinja","--no-warmup",
                   "--host","127.0.0.1","--port","{port}"],
  "envTemplate": {},
  "capabilities": {"nativeToolCall": true, "vision": true, "audio": false,
                   "devices": ["Vulkan"]},
  "presets": [
    {"name": "4b-gpu", "modelGlob": "Qwen3-4B*.gguf", "ctx": 4096,
     "paramsB": 4.0, "gpuLayers": 99},
    {"name": "qwen3.5-4b-gpu", "modelGlob": "Qwen3.5-4B*.gguf", "ctx": 4096,
     "paramsB": 4.0, "gpuLayers": 99,
     "note": "Qwen3.5-4B（qwen35 混合架构）：GATED_DELTA_NET/SSM_CONV 无 CUDA kernel 时 llama.cpp 调度器自动 CPU 回退该算子，其余层全量 -ngl 99；2026-11-07 真机首验通过"}
  ],
  "admission": [],
  "timingHints": {"coldCompileMs": 15000, "warmMs": 3000},
  "hardFlagsHint": "-ngl 99 全量 offload；--device 选卡（官方 release）"
}
''';

const String llamacppCudaManifestJson = '''
{
  "id": "llamacpp-cuda",
  "display": "llama.cpp · CUDA（RTX 快速通道）",
  "kind": "llamaServer",
  "argsTemplate": ["-m","{model}","--mmproj","{mmproj?}","-c","{ctx}","--temp","0",
                   "-ngl","{gpuLayers=99}","--jinja","--no-warmup",
                   "--host","127.0.0.1","--port","{port}"],
  "envTemplate": {},
  "capabilities": {"nativeToolCall": true, "vision": true, "audio": false,
                   "devices": ["CUDA"]},
  "presets": [
    {"name": "4b-gpu", "modelGlob": "Qwen3-4B*.gguf", "ctx": 4096,
     "paramsB": 4.0, "gpuLayers": 99},
    {"name": "qwen3.5-4b-gpu", "modelGlob": "Qwen3.5-4B*.gguf", "ctx": 4096,
     "paramsB": 4.0, "gpuLayers": 99,
     "note": "Qwen3.5-4B（qwen35 混合架构）：GATED_DELTA_NET/SSM_CONV 无 CUDA kernel 时调度器自动 CPU 回退，其余层全量 -ngl 99；2026-11-07 真机首验通过"}
  ],
  "admission": [],
  "timingHints": {"coldCompileMs": 20000, "warmMs": 4000},
  "hardFlagsHint": "Blackwell(sm_120) 需新版 + CUDA≥12.8；探测失败置灰退 Vulkan（§5.2）"
}
''';

const String openaiRemoteManifestJson = '''
{
  "id": "openai-remote",
  "display": "OpenAI 兼容远端（兜底）",
  "kind": "remote",
  "argsTemplate": [],
  "envTemplate": {},
  "capabilities": {"nativeToolCall": true, "vision": true, "audio": false,
                   "devices": ["remote"]},
  "presets": [],
  "admission": [],
  "timingHints": {"coldCompileMs": 5000, "warmMs": 1000},
  "hardFlagsHint": ""
}
''';

Map<String, EngineManifest> bundledManifests() => {
      'wangcai-npu': EngineManifest.parse(wangcaiNpuManifestJson),
      'llamacpp-vulkan': EngineManifest.parse(llamacppVulkanManifestJson),
      'llamacpp-cuda': EngineManifest.parse(llamacppCudaManifestJson),
      'openai-remote': EngineManifest.parse(openaiRemoteManifestJson),
    };
