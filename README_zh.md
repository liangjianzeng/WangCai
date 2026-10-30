# WangCai 旺财

> **面向 Intel® Core™ Ultra 的纯 NPU 端侧推理引擎。**
> 让被业界晾了多年的 *Intel® AI Boost* 重新产生价值。

[English](README.md) · **简体中文**

---

WangCai 让量化后的大模型**完整跑在 Intel NPU（`Intel(R) AI Boost`）上**：Transformer 主干不回退
CPU，也不依赖任何独立显卡。token 进来之后，prefill 与 decode 都被一次性编译成静态 OpenVINO 图，
在 NPU 上执行。

当前的模型线是 Liquid AI 的 **[LFM3](https://www.liquid.ai)**：一套"短卷积 + 滑动窗口注意力 +
全局注意力"混合结构的全模态（omni-modal）模型族。第一个里程碑是其中的**文本（LLM）链路**，也是本
仓库目前的全部工作内容。

```
prompt ──► llama.cpp（分词、构建 ggml cgraph）
                    │
                    ▼
        ggml-openvino ── 把 cgraph 翻译成 OpenVINO 算子图
                    │      （op_table + 逐算子降级，静态形状模式）
                    ▼
        OpenVINO NPU 插件（NPUW）── 编译为 LEIF 图，在 AI Boost 上执行
                    │
                    ▼
        logits ──► llama.cpp 采样器 ──► token
```

---

## 为什么做这件事

每一台 Intel Core Ultra 笔记本里都有一颗几十 TOPS 的 NPU，但在过去几代产品里，它在开源 LLM 生态
中的存在感约等于零——典型的 "AI PC" 叙事最后都变成：NPU 拿去做人像虚化，LLM 在 CPU 上硬扛。

这颗芯片对这类负载其实非常合适：decode 是访存瓶颈型工作，NPU 有自己的高带宽通路和定式计算阵列，
功耗极低，还能把 CPU 核心完整留给系统其它部分。难的不是"要不要用"，而是它要求**静态形状、单
序列、无动态控制流**——这恰好是常规 LLM 运行时的反面。

WangCai 的判断是：这是一道**工程**鸿沟，不是硬件鸿沟。

## 当前状态

诚实、可复现，明细见 [docs/status.md](docs/status.md)。

| 里程碑 | 状态 |
|---|---|
| 不装 GPU/OpenCL SDK 也能编出 OpenVINO 后端 | ✅ 完成 |
| LFM3-1.7B 在 **NPU 上端到端跑通** | ✅ 完成 |
| 混合结构（短卷积 + SWA + 全局注意力）在静态图下正确寻址 KV 环 | ✅ 完成 |
| NPU 与 CPU 参照的数值一致性 | 🟡 进行中 |
| 在首个可用数字之上继续调吞吐 | ⬜ 下一步 |
| LFM3 全模态（音频输入 / 视觉输入） | ⬜ 规划中 |

"进行中"的具体含义：NPU 上的贪心解码在最初几个 token 与 CPU 参照一致，随后开始漂移。与参照
logits 的余弦相似度在 prefill 结束时为 `0.969`，decode 阶段为 `0.73–0.87`，且 logit 分布被明显
"压平"。定位过程与目前已被排除/怀疑的因素见
[docs/npu-internals.md](docs/npu-internals.md)。

## 实测数据

Intel Core Ultra 9 275HX · Intel AI Boost (NPU 3720) · 32 GB · OpenVINO 2026.4.1
LFM3-1.7B `Q4_K_M`（1049 MB）· 24 层（13 门控短卷积 + 5 滑动窗口@256 + 6 全局注意力）·
`-c 1024 -fa 1 -np 1 --temp 0`

| 执行路径 | Prompt | Decode | 备注 |
|---|---:|---:|---|
| `ggml` 原生 CPU（`-dev none`） | 164.4 t/s | 54.1 t/s | 连贯性参照 |
| OpenVINO · CPU 设备，动态图 | 94–130 t/s | 21.7–29.2 t/s | 输出连贯 |
| **OpenVINO · NPU 设备，静态图** | 6.0–12.2 t/s | **8.3–8.7 t/s** | 跑通；精度进行中 |
| OpenVINO · NPU 首次图编译（冷启动） | — | — | 一次性约 36 s，之后命中缓存 |

复现方式见 [`tools/`](tools/README.md)。测量口径与"这些数字不能说明什么"：
[docs/benchmarks.md](docs/benchmarks.md)。

## 快速开始

```powershell
# 1. 工具链：VS 2022 BuildTools（MSVC）、CMake + Ninja、OpenVINO 运行时
git clone https://github.com/ggml-org/llama.cpp src/llama
cd src/llama; git checkout abb76ab
git apply ..\..\patches\0001-ggml-openvino-npu-adaptation.patch
copy ..\..\patches\ov_opencl_shim.hpp ggml\src\ggml-openvino\

# 2. 配置 + 构建（Release，仅启用 OpenVINO 后端）
..\..\tools\configure.ps1 -OpenVinoDir C:\openvino\openvino\cmake
..\..\tools\build.ps1

# 3. 在 NPU 上运行
$env:GGML_OPENVINO_DEVICE = 'NPU'
$env:GGML_OPENVINO_CACHE_DIR = 'D:\npu_cache'
.\build\bin\llama-cli.exe -m models\LFM3-1.7B-Q4_K_M.gguf -c 1024 -fa 1 -dev OPENVINO3 -st -p '你好'
```

细节见 [docs/getting-started.md](docs/getting-started.md) 与 [docs/build.md](docs/build.md)。

## 文档

| 文档 | 回答什么 |
|---|---|
| [快速上手](docs/getting-started.md) | 硬件、模型文件、第一次 NPU 运行 |
| [源码构建](docs/build.md) | 工具链、OpenVINO 开发包、CL 头文件之坑 |
| [架构](docs/architecture.md) | 一张 ggml cgraph 如何变成静态 NPU 图 |
| [NPU 内部机制](docs/npu-internals.md) | 硬骨头：静态形状、KV 环、conv 状态、NPUW |
| [环境变量](docs/env-vars.md) | 上游开关 + WangCai 新增的开关 |
| [基准测试](docs/benchmarks.md) | 数字、取数口径、以及它们不能证明什么 |
| [故障排查](docs/troubleshooting.md) | 我们踩过的每一个报错及解法 |
| [路线图](docs/roadmap.md) | 先精度、再吞吐、然后全模态 |

## WangCai 到底改了什么

两件事，都不大到读不完：

1. **`ggml/src/ggml-openvino/` 的补丁**——基于 llama.cpp `abb76ab`，7 个文件、+213 行
   （[补丁](patches/0001-ggml-openvino-npu-adaptation.patch)、[说明](patches/README.md)）：
   让后端在"只面向 NPU"的配置下可编译；让混合（滑动窗口 + 全局）注意力模型在静态形状下正确寻址
   各自的 KV 环；补上用于跨设备比对的插桩（裸张量转储、按位置构造 mask、NPU 编译配置覆盖）。
2. **`tools/`**——构建/运行/诊断脚本，以及使精度定位成为可能的逐元素张量比对工具。

其余全部来自上游 [llama.cpp](https://github.com/ggml-org/llama.cpp) 与
[OpenVINO](https://github.com/openvinotoolkit/openvino)。

## 硬件要求

| | |
|---|---|
| SoC | 带 `Intel(R) AI Boost` 的 Intel Core Ultra（Series 1/2），设备类 `PCI\VEN_8086&DEV_AD1D` |
| 驱动 | 与所装 OpenVINO 版本匹配的 Intel NPU 驱动 |
| 系统 | Windows 11（Linux 路径上游支持，本机未验证） |
| 内存 | 每 2 GB 模型至少 8 GB 空闲；1–4 B 模型 16 GB 舒适 |

## 参与贡献

见 [CONTRIBUTING.md](CONTRIBUTING.md)。一份带 `GGML_OPENVINO_DUMP_BIN` 转储与
`tools/compare-tensors.ps1` 输出的复现材料，比一千句"跑不通"更有价值。

## 许可

Apache-2.0，见 [LICENSE](LICENSE)。上游 llama.cpp（MIT）与 OpenVINO（Apache-2.0）各自的条款继续适用。

## 致谢

llama.cpp 的 ggml-org 维护者，以及 OpenVINO NPU 团队——llama.cpp 里的 OpenVINO 后端，是这个项目
能只是一组补丁而不是一次重写的原因。
