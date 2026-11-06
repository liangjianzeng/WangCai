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
    {"name": "spark-x2.6-4b", "modelGlob": "Spark-X2.6-4B*.gguf", "chunk": 128,
     "paramsB": 4.0, "device": "NPU",
     "extraEnv": {"GGML_OPENVINO_DISABLE_DECODE_LEVELS": "1"},
     "note": "副靶（讯飞 Spark-X2.6-4B Q4_K_M）：chunk128 + 关 decode level 必需（spark-npu-accept.ps1 3/3、HANDOFF 2026-11-01）"},
    {"name": "lfm3-omni-2b", "modelGlob": "LFM3-Omni-2B*.gguf", "chunk": 128,
     "paramsB": 2.0, "device": "NPU",
     "note": "Omni-2B 文本线（chunk128 实测口径）；视觉塔走 cuda/vulkan —— NPU mtmd 有缺陷，见 defect-npu-mtmd.md。2026-11-06 矩阵实锤：DISABLE_DECODE_LEVELS=1 是 Omni 深层 decode 崩溃元凶（4096 档 1.7 vs 19.8 t/s、8192 档 0.8 vs 15.2 t/s，512 档无恙故旧配方未暴露），本 preset 已摘除该 env；超 4096 的 FOLD=YES 由网关自动挂（8192 无 FOLD 会塌到 0.3 t/s，勿关）"},
    {"name": "minicpm5-2b", "modelGlob": "MiniCPM5-2B*.gguf", "chunk": 256,
     "paramsB": 2.6, "device": "NPU",
     "note": "副靶（OpenBMB MiniCPM5-2B Q4_K_M，llama-arch thinking 模型，ModelScope）：默认臂 1.7B-like chunk256+decode levels；OOM 回落 spark 臂（chunk128+DISABLE_DECODE_LEVELS）——tools/minicpm5-npu-accept.ps1；thinking 模型 CoT 预算 n≥192"}
  ],
  "admission": [
    {"ifCtxGt": 4096, "ifParamsBAtLeast": 3.5,
     "message": "4B 在 NPU 超 4096 上下文执行期 OUT_OF_HOST_MEMORY（status.md 缺陷5 外推；4096 默认档实测放行）",
     "suggestion": "全局上下文调回 ≤4096，或改用 CUDA/Vulkan 引擎"}
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
     "paramsB": 4.0, "gpuLayers": 99}
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
     "paramsB": 4.0, "gpuLayers": 99}
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
