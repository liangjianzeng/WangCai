// 内置驱动清单（设计 §4.1/§5/§6）。数据，不是代码；升级可被远程清单覆盖（M2）。
// M0-3 实测校正：server 端参数集 `-fa 1 -np 1 -dev OPENVINO{n} --jinja`（无 -st）。
import 'engine_manifest.dart';

const String wangcaiNpuManifestJson = '''
{
  "id": "wangcai-npu",
  "display": "汪柴 · Intel NPU",
  "kind": "llamaServer",
  "argsTemplate": ["-m","{model}","--mmproj","{mmproj?}","-c","{ctx}","--temp","0",
                   "-np","1","-fa","1","-dev","{devArg=OPENVINO3}","--jinja",
                   "--host","127.0.0.1","--port","{port}"],
  "envTemplate": {
    "GGML_OPENVINO_DEVICE": "{device=NPU}",
    "GGML_OPENVINO_CACHE_DIR": "{cacheDir}",
    "GGML_OPENVINO_PREFILL_CHUNK_SIZE": "{chunk}"
  },
  "capabilities": {"nativeToolCall": true, "vision": true, "audio": false,
                   "devices": ["NPU", "CPU(OPENVINO0)"]},
  "presets": [
    {"name": "lfm3-1.7b", "modelGlob": "LFM3-1.7B*.gguf", "ctx": 1024, "chunk": 256,
     "paramsB": 1.7, "device": "NPU"},
    {"name": "qwen3-4b", "modelGlob": "Qwen3-4B*.gguf", "ctx": 512, "chunk": 128,
     "paramsB": 4.0, "device": "NPU",
     "note": "副靶配置 chunk128（status.md 3/3）；compile overrides 串在 M2 对齐 spark-npu-accept.ps1"}
  ],
  "admission": [
    {"ifCtxGt": 512, "ifParamsBAtLeast": 3.5,
     "message": "4B 在 NPU -c>512 执行期 OUT_OF_HOST_MEMORY（status.md 缺陷5）",
     "suggestion": "ctx≤512，或改用 CUDA/Vulkan 引擎"}
  ],
  "timingHints": {"coldCompileMs": 36000, "warmMs": 9000},
  "hardFlagsHint": "-fa 1 -np 1 -dev OPENVINO3 --jinja（server 无 -st，M0-3 实测）"
}
''';

const String llamacppVulkanManifestJson = '''
{
  "id": "llamacpp-vulkan",
  "display": "llama.cpp · Vulkan（核显/N 卡）",
  "kind": "llamaServer",
  "argsTemplate": ["-m","{model}","--mmproj","{mmproj?}","-c","{ctx}","--temp","0",
                   "-ngl","{gpuLayers=99}","--device","{gpuDevice?}","--jinja",
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
                   "-ngl","{gpuLayers=99}","--jinja",
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
