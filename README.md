# WangCai 旺财

> **面向 Intel® Core™ Ultra 的纯 NPU 端侧推理引擎。**
> 让被业界晾了多年的 *Intel® AI Boost* 重新产生价值。

**简体中文** · [English](README_en.md)

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

引擎源码就在仓库里：[`src/ggml-openvino/`](src/ggml-openvino/)（背景与改动清单见
[`src/ggml-openvino/WANGCAI.md`](src/ggml-openvino/WANGCAI.md)）。

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
| 长文续写：NPU 与 CPU 参照**逐字一致** | ✅ 完成（Q4_0 权重） |
| 指令跟随任务的数值一致性 | 🟡 进行中 — 当前唯一未通过项 |
| Prefill 追平 CPU | 🟡 已达参照的 73%，仍在找余量 |
| Decode 追平 CPU | 🟡 落后 6 倍，当前主攻方向 |
| LFM3 全模态（音频 / 视觉输入） | ⬜ 规划中（官方 GGUF 与 `mmproj` 已在 ModelScope） |
| **端侧多模态助手「旺财」** | 🟡 规划中 —— 把本引擎装进 TongYiLite（Flutter，安卓→Windows） |

"进行中"的具体含义：NPU 上的贪心解码在最初几个 token 与 CPU 参照一致，随后漂移。与参照 logits 的
余弦相似度为 `0.969`（prefill 结束）与 `0.73–0.87`（decode），且 logit 分布被明显"压平"。真实 chunk
上的逐层比对显示**发散从第一个 chunk 就存在**（conv 状态余弦 `l0 0.9956 → l9 0.873 → l17 0.163`），
因此嫌疑集中在单次前向的数值执行，而不是跨步的状态记账；注意力侧几乎无害——V 缓存 200 行全部精确到
`2.7e-6`，K 缓存除**第 0 行**（余弦 `0.288`、最大绝对差 `1.06e10`）外都在 `0.90–0.9998`。那个孤立异常行
是眼下最锋利的线索。

两条用血换来的测量纪律，写在 [docs/npu-internals.md](docs/npu-internals.md) 里，读转储之前先看：
`prefill_0/1`、`decode_2` 是 llama.cpp 的 **warmup 假批次**（换 prompt 后字节不变），拿它们算余弦等于
没测；**续写题不能当连贯性判据**——它在设备算错时也能逐字一致，只有指令跟随题能暴露问题。

## 实测数据

Intel Core Ultra 9 275HX · Intel AI Boost (NPU 3720) · 32 GB · OpenVINO 2026.4.1
LFM3-1.7B `Q4_K_M`（1049 MB）· 24 层（13 门控短卷积 + 5 滑动窗口@256 + 6 全局注意力）· `-fa 1 -np 1`

| 执行路径 | Prefill（`llama-bench pp512`） | Decode | 备注 |
|---|---:|---:|---|
| `ggml` 原生 CPU（`-dev none`） | 570 t/s | 54.1 t/s | 连贯性参照 |
| OpenVINO · CPU 设备，动态图 | 610 t/s | 21.7–29.2 t/s | 输出连贯 |
| **OpenVINO · NPU 设备，静态图** | **415 t/s** | **8.3–8.7 t/s** | 跑通；精度进行中 |
| OpenVINO · NPU 首次图编译（冷启动） | — | — | 一次性约 36 s，之后命中缓存 |

两点必须说清楚：

- **NPU 的 prefill 不是问题**：pp512 达到原生参照的 73%。真正的短板是 **decode**，只用到可用 TOPS
  的约 0.03。
- **别拿短 prompt 的 t/s 说事**：静态 prefill 图恒为 256 列宽，4 个 token 也要付 256 列的代价，而
  llama.cpp 按"有效 token / 秒"上报，于是同一个 0.66 s 的 chunk 会被报成 ~6 t/s。要么测 `pp512`
  及以上，要么按 prompt 长度调 `GGML_OPENVINO_PREFILL_CHUNK_SIZE`。算术细节见
  [docs/benchmarks.md](docs/benchmarks.md)。

复现方式见 [`tools/`](tools/README.md)。

## 快速开始

```powershell
# 1. 工具链：VS 2022 BuildTools（MSVC）、CMake + Ninja、OpenVINO 运行时（可用 PyPI wheel 解包）
pip download openvino==2026.4.1 --no-deps -d .\ovdl
Expand-Archive .\ovdl\openvino-2026.4.1-*.whl -DestinationPath .\ov     # → .\ov\openvino\cmake

# 2. 取引擎源码：克隆固定版本的 llama.cpp 到 src/llama，并把 src/ggml-openvino 覆盖上去
git clone https://github.com/liangjianzeng/WangCai
cd WangCai
tools\bootstrap.ps1

# 3. 配置 + 构建（Release，仅启用 OpenVINO 后端）
tools\configure.ps1 -OpenVinoDir ..\ov\openvino\cmake
tools\build.ps1

# 4. 在 NPU 上跑
$env:GGML_OPENVINO_DEVICE = 'NPU'
$env:GGML_OPENVINO_CACHE_DIR = 'D:\npu_cache'
src\llama\build\bin\llama-cli.exe -m models\LFM3-1.7B-Q4_K_M.gguf -c 1024 -fa 1 -dev OPENVINO3 -st -p '用一句话介绍长城。'
```

细节见 [docs/getting-started.md](docs/getting-started.md) 与 [docs/build.md](docs/build.md)。

## 路线图：端侧多模态助手「旺财」

一句话：**旺财 = 端侧多模态 AI 助手，NPU 引擎是它的低功耗心脏。**

本仓库（WangCai）现在只做一件事：让大模型**完整跑在 Intel NPU 上**。这是"引擎"。但引擎不是终点——
把它装进一个会说话、会看、会听、会推理的助手里，才是"旺财"。

### 三层结构

| 层 | 组件 | 职责 |
|---|---|---|
| 应用层 | **TongYiLite**（Flutter） | 用户界面、Agent 主循环、工具调用、记忆、语音管线、视觉输入管线 |
| 服务层 | **推理核心**（可插拔后端） | 一个平台无关的 C ABI；后端可切换：CPU（`ggml-cpu`）/ GPU（`ggml-vulkan`）/ **NPU（`ggml-openvino` / WangCai）** |
| 引擎层 | **WangCai** | 纯 NPU 推理：把 `ggml_cgraph` 翻译成静态 OpenVINO 图，在 `AI Boost` 上执行 |

### 安卓 → Windows 移植

TongYiLite 现在是 **Flutter（不是 Kotlin）应用**：Dart 约 54k 行，Kotlin 宿主壳只有 6 个文件、2k 行。
真正重量级的代码在 C++——唯一的 `tongyilite_jni.cpp`（3887 行）负责模型加载、逐 token 回调、MTP 投机
解码、mtmd 视觉编码。移植的关键判断（已有**本机实物证据**，见仓库内
`Windows移植_CPU_GPU_NPU_实施方案_2026-10-30.md`）：

- **Dart 侧约 90% 可原样复用**到 Flutter Windows：Agent、工具、记忆、语音管线都不依赖 Android API。
- **真正的工作量集中在 C++ 核心**：把那个 3887 行的 JNI 壳抽成平台无关的 **C ABI**，重写日志 / OOM
  探测 / 路径部分，把 MainActivity 的 8 个 MethodChannel 换成 Dart 的 FFI 桥。
- **后端组合重写**：去掉 KleidiAI（ARM）、OpenCL-stub、NDK Vulkan stub，换 MSVC + Ninja +
  **`ggml-openvino`（NPU）**。
- 本机已证明可行性：`.upgrade-tmp/host-mingw/bin/llama-mtmd-cli.exe` —— llama.cpp 已在 MinGW GCC 下
  原生构建成功。

### 为什么是 NPU（低功耗驱动）

NPU 是访存瓶颈型负载里的优等生：**功耗极低、把 CPU 核心完整留给系统**。在 WangCai 里，NPU 端到端跑
LFM3 时 prefill 已达 **415 t/s**（CPU 参照的 73%），CPU 全程空闲。代价是：decode 还在 **8.3–8.7 t/s**，
精度也未达标（[docs/status.md](docs/status.md)）——这两条正是下一步要攻的。

> 诚实声明：**本机目前没有 NPU 计数器、没有电池、电源方案是"高性能"**，所以"每瓦性能"还没测出来。
> 路线图里写的是可复现的替代证据（CPU 占用、温度、降频事件），精确瓦特需要外部功率计或电池模式补测。

### 多模态

TongYiLite 已经具备：文本✅、视觉✅（mtmd + mmproj）、语音输入✅（sherpa ASR）、语音输出✅
（Edge TTS + sherpa VITS）。模型目录里 `LFM3-VL-2B QAD-Q4_0` 已带 mmproj——**文本链路打通后，多模态
是同一套后端的事**。

### 分期

- **Phase 0（本仓库）**：纯 NPU 引擎，LFM3 文本链路。🟡 进行中。
- **Phase 1**：引擎移植进 TongYiLite 服务层，C ABI 抽取 + 后端可插拔。
- **Phase 2**：App 在 Windows 跑通，CPU 后端先可用，再切 NPU。
- **Phase 3**：多模态（视觉 / 语音）在 NPU 上端到端。
- **Phase 4**：低功耗实测 + 功耗感知的调度策略。

## 仓库结构

```
src/ggml-openvino/    引擎本体：ggml OpenVINO 后端（上游 + WangCai 改动），可直接阅读
patches/              同一份改动的补丁形式（评审与上游化用）+ 逐 hunk 说明
tools/                bootstrap / configure / build / run-npu / npu-sweep / compare-tensors / top-token
docs/                 上手、构建、架构、NPU 内部机制、环境变量、基准、状态、排障、路线图
prompts/              中英样例 prompt（UTF-8）
src/llama/            vendored 的 llama.cpp（.gitignore 排除，由 bootstrap 生成）
```

## 文档

| 文档 | 回答什么 |
|---|---|
| [快速上手](docs/getting-started.md) | 硬件、模型文件、第一次 NPU 运行 |
| [源码构建](docs/build.md) | 工具链、OpenVINO 开发包、CL 头文件之坑 |
| [架构](docs/architecture.md) | 一张 ggml cgraph 如何变成静态 NPU 图 |
| [NPU 内部机制](docs/npu-internals.md) | 硬骨头：静态形状、KV 环、conv 状态、NPUW |
| [环境变量](docs/env-vars.md) | 上游开关 + WangCai 新增的开关 |
| [基准测试](docs/benchmarks.md) | 数字、取数口径、以及它们不能证明什么 |
| [当前状态](docs/status.md) | 今天到底什么能用，附验证命令 |
| [故障排查](docs/troubleshooting.md) | 我们踩过的每一个报错及解法 |
| [路线图](docs/roadmap.md) | 先精度、再吞吐、然后全模态 |

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

被推翻的假设同样欢迎——它们进 [CHANGELOG.md](CHANGELOG.md)，很多时候比修复更省后来人的时间。

## 许可

Apache-2.0，见 [LICENSE](LICENSE)。上游 llama.cpp（MIT）与 OpenVINO（Apache-2.0）各自的条款继续适用。

## 致谢

llama.cpp 的 ggml-org 维护者，以及 OpenVINO NPU 团队——llama.cpp 里的 OpenVINO 后端，是这个项目
能只是一组补丁而不是一次重写的原因。
