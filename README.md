<p align="center">
  <img src="assets/wangchai.png" width="180" alt="汪柴：doge 风格的柴犬吉祥物，本引擎的拟人化身">
</p>

# WangCai 汪柴

> **面向 Intel® Core™ Ultra 的纯 NPU 端侧推理引擎。**
> 让被业界晾了多年的 *Intel® AI Boost* 重新产生价值。
>
> **v0.0.1 · 2026-10-31 引擎收官** —— NPU 端到端跑通 LFM3，精度主缺陷已定案修复（三问验收 3/3）。
> **v0.0.2 · 2026-11-02/03 助手落地** —— Windows 桌面壳 M1–M4 完成：NPU / CUDA / Vulkan / 远端
> 四线路由、托盘驻留、识图 DoD（官方引擎线）、Agent 回归、便携包 + Inno Setup 安装器。
> 变更全文见 [CHANGELOG.md](CHANGELOG.md)。

**简体中文** · [English](README_en.md)

---

WangCai 让量化后的大模型**完整跑在 Intel NPU（`Intel(R) AI Boost`）上**：Transformer 主干不回退
CPU，也不依赖任何独立显卡。token 进来之后，prefill 与 decode 都被一次性编译成静态 OpenVINO 图，
在 NPU 上执行。

当前的模型线是 Liquid AI 的 **[LFM3](https://www.liquid.ai)**：一套"短卷积 + 滑动窗口注意力 +
全局注意力"混合结构的全模态（omni-modal）模型族。第一个里程碑是其中的**文本（LLM）链路**；
v0.0.2 起，仓库还包含把引擎装进端侧助手的 Windows 壳（见[路线图](#wangcai-assistant)）。

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
| 指令跟随任务的数值一致性 | ✅ **完成（v0.0.1 收官修复）** — 根因定案：decode 图 RoPE cos/sin 头轴广播；三问验收 3/3 |
| Prefill 追平 CPU | ✅ **反超（2026-11-04 性能轮）**：`NPUW_FOLD=NO` 成为 NPU 默认（P12）+ 每图共享重复小链（P14a/b）后，pp512 406→**779 t/s**（+92%）、pp2048 284→**433 t/s**（+52%，均 vs P11 基线，暖 blob `-r 3`），已越过原生 CPU 参照（570 t/s）与 OV-CPU 动态图（610 t/s）|
| Decode 追平 CPU | 🟡 **P11 证伪"带宽界"定案后 decode 攻坚重启（2026-11-04）**：Q8_0 权重字节 +67% 步时不变，逐节点剖析显示 MatMul 仅占步时 18–23%，其余是 eltwise/state 算子汤。FOLD=NO + P14a/b 后 1.7B tg **22.6 t/s**（+61% vs 基线 14.07，三轴全部 ≥+50% 达标），已入 OV-CPU 参照带（21.7–29.2）下沿；早前"decode 攻坚收官"结论已被本轮取代 |
| LFM3 全模态（音频 / 视觉输入） | 🟡 **音频与视觉输入 NPU 均端到端（2026-11-01）**：音频与 native Q8_0 参照逐字一致；视觉两根因定案修复（cacheless `input_len=-1` 平面越界 + NPUW `FOLD×FUNCALL_FOR_ALL` 配置交互损坏 clip 图），NPU 描述与 native 一致、文本三问 3/3；视觉吞吐（2026-11-02）warm encode 12.6 s → **亚秒级（542 ms 稳态 / 896 ms FS 冷）**（vs native 435 ms），根因：NPU 分支补 `ov::cache_dir` 插件 blob 缓存，权重烤成 Constants 的 clip 图此前每进程全量重编译 |
| **副靶：跨模型验证（Spark-X2.6-4B + Qwen3-4B）** | ✅ **两个外部模型家族端到端跑通（2026-11-01）**：讯飞 Spark-X2.6-4B 与 Qwen3-4B（均为标准稠密 Transformer，与 LFM3 混合架构不同系）在 NPU 三问验收全 3/3；副靶顺带修好两个横切缺陷——u4 权重无法包宿主内存（曾阻塞所有非对称 4-bit 路径）与整数零点舍入（曾让静态图精度退化），Q4_K_M checkpoint 现在 OV-CPU 开箱即用。4B 在 llama-cli/server 流需 `PREFILL_CHUNK_SIZE=128`（预算规则：chunk + 最大 decode 图联合驻留，见 HANDOFF 2026-11-02 深夜；ctx≤512 的短对话实测 chunk256 可用且 pp +55–59%）；llama-bench 离线流 chunk256 随便用 |
| **NPU decode 性能（4B）** | 🟡 **6.9 → 8.96 t/s（+30%），4B 三轴 +24–42%，继续攻坚（2026-11-04 性能轮）**：P3 时代"~6 t/s 贴带宽下限 85%"的收官论断已被 P11 证伪（Q8_0 权重 +67% 步时不变）。FOLD=NO + P14a/b 后 tg **8.96**、pp2048(ck128) **53.1**、pp512(ck256) **192.3 t/s**。4B decode 步时构成（P14 剖析）：kv-scatter 族 25% + MatMul 23% + rope Add 族 22%（launch-bound）+ 残余 Add 22%；f16-rope A/B 已证伪（全轴持平略负，默认 OFF）、MANUAL_GQA 在 NPU 不可行（VCL 拒编）；剩余主攻 P14e（host 侧 KV 行写出），见 HANDOFF P14 |
| **端侧多模态助手「汪柴」（v0.0.2）** | ✅ **M1–M4 全部完成（2026-11-02/03 开发机验证）**：`app/` Flutter Windows 壳（TongYi-Lite Dart 同路径 vendored，分叉清单 `app/UPSTREAM.md`）+ llama-server 子进程网关；三引擎齐——引擎商店钉官方 llama.cpp b12034（Vulkan+CUDA，sha256 白名单）+ OpenAI 远端 + 绑定表实测 t/s 回写 + 路由三档（速度优先 / NPU 优先 / 自动·拔电 NPU 加权），**DoD 四线真机 5/5**（NPU 1.7B / CUDA 4B 117.6 t/s / Vulkan 双卡 / 远端协议）；托盘驻留 + 电源感知 + HKCU 自启；**识图 DoD 达成**（SmolVLM2-500M + 商店 CUDA 引擎，壳网关 20 s 出准确语义描述；NPU 视觉编码缺陷归档 [docs/defect-npu-mtmd.md](docs/defect-npu-mtmd.md)，NPU 线做纯文本）；Agent `--jinja` 工具链全链路回归（tools 200，agent c4096）；便携包 `WangCai-0.0.2-win-x64-portable.zip`（干净进程自测 DLL 闭合）+ Inno Setup 脚本。⬜ 干净机装机验证待人工（`packaging/README.md`） |

精度主缺陷的完整攻坚记录是这个仓库最有价值的资产之一：从"logits 被压平、K 缓存第 0 行错八个
数量级"出发，历经 scatter / conv 算子 / DQ / RMS 池化 / 广播 tile 一连串被证伪的假设，最终钉死在
**静态 decode 图 RoPE 的 cos/sin 头轴隐式广播在 NPUW 1-token 形状降级下错误 tile**，修复是
`rope.cpp` 里一处显式 Concat tile。证据链、被排除项与方法论教训见
[docs/defect1-rootcause.md](docs/defect1-rootcause.md)。当前仅存的精度未决项：≥64 token 的逐
token 严格判据待复测（48 token 三问验收已全对）。

两条用血换来的测量纪律，写在 [docs/npu-internals.md](docs/npu-internals.md) 里，读转储之前先看：
`prefill_0/1`、`decode_2` 是 llama.cpp 的 **warmup 假批次**（换 prompt 后字节不变），拿它们算余弦等于
没测；**续写题不能当连贯性判据**——它在设备算错时也能逐字一致，只有指令跟随题能暴露问题。

## 实测数据

Intel Core Ultra 9 275HX · Intel AI Boost (NPU 3720) · 32 GB · OpenVINO 2026.4.1
LFM3-1.7B `Q4_K_M`（1049 MB）· 24 层（13 门控短卷积 + 5 滑动窗口@256 + 6 全局注意力）· `-fa 1 -np 1`

| 执行路径 | Prefill（`llama-bench pp512`） | Decode | 备注 |
|---|---:|---:|---|
| `ggml` 原生 CPU（`-dev none`） | 570 t/s | 54.1 t/s | 连贯性参照（早期 `-r 1` 轮次所测，未在新协议下复测） |
| OpenVINO · CPU 设备，动态图 | 610 t/s | 21.7–29.2 t/s | 输出连贯（同上） |
| **OpenVINO · NPU 设备，静态图** | **779 t/s** | **22.6 t/s（与 ctx 无关）** | 2026-11-04 性能轮（`NPUW_FOLD=NO` 默认 + P14a/b 共享小链）：pp512 +92%、pp2048 433 t/s（+52%）、tg +61% vs P11 基线；暖 blob、`-r 3`，见 [docs/benchmarks.md](docs/benchmarks.md) |
| OpenVINO · NPU 首次图编译（冷启动） | — | — | `FOLD=NO` 下冷编译约为旧配置 10×（blob 缓存吸收）；编译缓存磁盘 **4B 实测 ~19 GB/模型/ctx 形状**，预留 ≥20 GB；重编译需 ≥25 GB 物理内存空闲 |

两点必须说清楚：

- **NPU 的 prefill 已从追平变成反超**：pp512 779 t/s 已越过两个参照（原生 570 / OV-CPU 610，
  参照为早期单轮测量，同协议复测待补）；decode 22.6 t/s 落进 OV-CPU 参照带（21.7–29.2）下沿。
  P11 的逐节点剖析（MatMul 仅占步时 18–23%）定案瓶颈是算子汤而非权重带宽——P3 的
  "带宽界、decode 关死"结论已被证伪，攻坚沿剖析继续（P14 系列，HANDOFF 2026-11-04）。
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

# 4. 取模型权重（不随 git 分发，直接用官方 GGUF，详见 docs/getting-started.md）
hf download LiquidAI/LFM3-1.7B-GGUF --local-dir models   # 或 modelscope download

# 5. 在 NPU 上跑（一次性提问，用于验证）
$env:GGML_OPENVINO_DEVICE = 'NPU'
$env:GGML_OPENVINO_CACHE_DIR = 'D:\npu_cache'
src\llama\build\bin\llama-cli.exe -m models\LFM3-1.7B-Q4_K_M.gguf -c 1024 -fa 1 -dev OPENVINO3 -st -p '用一句话介绍长城。'

# 6. 交互式终端聊天（0.0.1 式文本交互，日常使用走这个）
tools\chat-npu.ps1 -Model models\LFM3-1.7B-Q4_K_M.gguf
#   进入 > 对话循环；/exit 退出、/clear 清空、/regen 重生成、/read 文件入上下文
```

动手前先确认 NPU 在位：`Get-PnpDevice -Class ComputeAccelerator` 应列出
`Intel(R) AI Boost ... PCI\VEN_8086&DEV_AD1D`（硬件/驱动要求见下方[硬件要求](#硬件要求)）。

### 运行参数里哪些是硬约束

| 参数 / 环境变量 | 为什么必须 |
|---|---|
| `-dev OPENVINO3` | OpenVINO 后端在 llama.cpp 里的设备编号（`--list-devices` 可确认） |
| `-fa 1` | `-fa 0` 的 V 写回形状会被 OpenVINO 的 scatter 降级拒绝 |
| `-np 1` | 静态路径是单序列的，`-np 2` 直接报错 |
| `-st`（对话模板） | instruct 模型走裸续写会退化成重复胡话，任何后端都一样 |
| `GGML_OPENVINO_DEVICE=NPU` | 选 NPU 而不是 OpenVINO-CPU |
| `GGML_OPENVINO_CACHE_DIR` | 持久化图编译缓存（`FOLD=NO` 下冷编译约为旧配置 10×，靠 blob 缓存吸收）；**每种配置用独立目录**，否则过期编译图会无声胜出；4B 每个 ctx 形状 ~19 GB，预留 ≥20 GB |
| `-c` ≤ 8192 实测通过 | 多跨度 decode 图组落地后 decode 速度与 ctx 无关（c=8192 实测 14.1 t/s）；更高 ctx 未验证 |
| 4B 模型（NPU）：`GGML_OPENVINO_PREFILL_CHUNK_SIZE=64`（短 prompt）/ `128`（长 prompt） | 4B 预算规则（BUDGET-TRACE 定案，HANDOFF 2026-11-02 深夜）：**prefill 图(chunk) + 最大 decode 图（级别 = KV 行跨度）联合驻留**。chunk256 只容 decode 级别 ≤512（**ctx≤512 实测可用，pp +55–59%**）；ctx≥1024 时 decode 需级别 ≥1024 → 超预算（首 execute ZE append 失败），chat/server 用 64/128。llama-bench 离线流 decode mask 从不超 256，chunk256 随便用；1.7B 任意 ctx 可 chunk256。短 prompt 首 token 延迟 chunk64 比 128 好 ~17%，32 以下固定开销反噬 |

`llama-server.exe` 也一并构建，可用同样的环境变量提供 OpenAI 兼容 HTTP 服务；`-c`/-fa/-np 约束相同。
**`llama-server` 必须加 `--no-warmup`（P16 硬性要求，2026-11-04）**：启动期 warmup eval 会毒化其后的
NPUW 编译（`Model0_1` 级联失败，FOLD=NO 默认下两模型全绿只在带 `--no-warmup` 时成立），且它并不预热
decode 图、A/B 实测总到首答还更快 2.7 s（HANDOFF 2026-11-03 P1 / 2026-11-04 P16）；跑分与验收的
llama-cli 同样统一带 `--no-warmup` 以免污染测量。llama-cli 交互式不加亦可（warmup 藏在用户打字时间里）。**网关/应用侧再加一发预热请求**：服务就绪后立刻
发一个 `max_tokens=1` 的 chat completion（自带上下文任意短句），把首执行 + decode 图编译 + 模板路径
焐热（~5 s，一次性）——此后用户的第一个真实问题直接落到 ~4 s 的热路径（否则首问 ~13 s，其中 ~6 s
为 llama/driver 层固有成本，HANDOFF 2026-11-03 P9）。
完整参数说明、首次运行的预期日志与三个最容易踩的坑见
[docs/getting-started.md](docs/getting-started.md)，全部环境变量见 [docs/env-vars.md](docs/env-vars.md)。

模型**不随本仓库分发**（GGUF 普遍 1–2 GB，远超 git 与 LFS 的合理边界）：直接下载官方 GGUF
（Hugging Face / ModelScope `LiquidAI/LFM3-1.7B-GGUF`）即可，无需转换；自生成 GGUF 仅在需要非官方
量化时才值得做。下载方式、量化选择（Q8_0 当前会被 NPU 主机内存预算挡住）与核对方法见
[docs/getting-started.md](docs/getting-started.md)；构建细节见 [docs/build.md](docs/build.md)。

## 路线图：端侧多模态助手「汪柴」

<a id="wangcai-assistant"></a>

一句话：**汪柴 = 端侧多模态 AI 助手，NPU 引擎是它的低功耗心脏。**

本仓库（WangCai）的引擎线让大模型**完整跑在 Intel NPU 上**。引擎不是终点——把它装进一个会说话、会看、
会听、会推理的助手里，才是"汪柴"。**这一步已经在 v0.0.2 落地**：`app/` 是 Flutter Windows 桌面壳
（TongYi-Lite Dart 同路径 vendored，分叉清单 `app/UPSTREAM.md`），设计全文见
[docs/assistant-v0.0.2-design.md](docs/assistant-v0.0.2-design.md)，M1–M4 验收记录见
[CHANGELOG.md](CHANGELOG.md)。

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
- **落地状态（v0.0.2）**：M1 起按"同路径 vendored + 分叉清单 `app/UPSTREAM.md`"完成移植；传输层走
  **llama-server 子进程网关**（平台分支唯一化），C ABI 直链留作并行线、成熟后替换传输层壳无感
  （设计稿 §0"明确不做"）。

### 为什么是 NPU（低功耗驱动）

NPU 是访存瓶颈型负载里的优等生：**功耗极低、把 CPU 核心完整留给系统**。在 WangCai 里，NPU 端到端跑
LFM3 时 prefill 已达 **779 t/s**（高于原生 CPU 参照的 570，2026-11-04 性能轮），CPU 全程空闲。decode
经多跨度图组 + `FOLD=NO` 默认 + 共享小链已到 **22.6 t/s 且与上下文长度无关**；1.7B 三轴对基线全部
≥+50% 达标，4B（+24–42%）沿 P14 剖析继续攻坚（精度已在 v0.0.1 修复，[docs/status.md](docs/status.md)）。

> 诚实声明：**本机目前没有 NPU 计数器、没有电池、电源方案是"高性能"**，所以"每瓦性能"还没测出来。
> 路线图里写的是可复现的替代证据（CPU 占用、温度、降频事件），精确瓦特需要外部功率计或电池模式补测。

### 多模态

助手线**识图 DoD 已达成（2026-11-03，官方引擎线）**：SmolVLM2-500M（商店下载入模型库）+ 引擎商店
CUDA 引擎，壳网关全链路 20 s 出准确语义描述（`app/test/platform/vision_official_test.dart`）。NPU 侧
视觉编码在 OV 后端 `graph_compute` 返 -1，缺陷归档 [docs/defect-npu-mtmd.md](docs/defect-npu-mtmd.md)
——**NPU 线当前做纯文本**，识图由路由派给官方引擎。引擎侧音频输入 NPU 已端到端（与 native Q8_0
参照逐字一致，见上表）。语音输入/输出管线（sherpa ASR / TTS）随壳 vendored，未列入 M1–M4 验收面。

### 分期

- **Phase 0（本仓库）**：纯 NPU 引擎，LFM3 文本链路。✅ 完成（v0.0.1 收官；音频/视觉见上表）。
- **Phase 1**：引擎进入服务层。🟡 v0.0.2 实际以 **llama-server 子进程网关**落地（平台分支唯一化）；
  C ABI 直链为并行线，成熟后替换传输层、壳无感。
- **Phase 2**：App 在 Windows 跑通。✅ **v0.0.2 M1–M4 完成**：NPU/CUDA/Vulkan/远端四线 DoD、
  托盘驻留、路由三档、Agent 回归、便携包 + Inno Setup 安装器（⬜ 干净机验证待人工）。
- **Phase 3**：多模态端到端。🟡 识图 DoD 已在官方引擎线达成；NPU 视觉编码缺陷归档（NPU 线纯文本）；
  语音管线 vendored、未列入已验收面。
- **Phase 4**：低功耗实测 + 功耗感知的调度策略。⬜ 未启动（前置：电池机或外置功率计）。

出包与安装：`packaging/build-installer.ps1`（便携 zip 无需 Inno 即可产出；装 Inno Setup 6 后自动附出
`Setup.exe`），包内容与干净机验证清单见 [packaging/README.md](packaging/README.md)。

## 仓库结构

```
src/ggml-openvino/    引擎本体：ggml OpenVINO 后端（上游 + WangCai 改动），可直接阅读
app/                  汪柴助手 Flutter Windows 壳（v0.0.2 M1–M4；分叉清单 app/UPSTREAM.md）
packaging/            打包：build-installer.ps1（便携 zip + Inno Setup 脚本）+ 包内容说明
patches/              同一份改动的补丁形式（评审与上游化用）+ 逐 hunk 说明
tools/                bootstrap / configure / build / run-npu / npu-sweep / compare-tensors / top-token
docs/                 上手、构建、架构、NPU 内部机制、环境变量、基准、状态、排障、路线图、助手设计
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
| [助手 v0.0.2 设计](docs/assistant-v0.0.2-design.md) | 壳架构、引擎注册表、路由策略、M1–M4 DoD |

## 硬件要求

| | |
|---|---|
| SoC | 带 `Intel(R) AI Boost` 的 Intel Core Ultra（Series 1/2），设备类 `PCI\VEN_8086&DEV_AD1D` |
| 驱动 | 与所装 OpenVINO 版本匹配的 Intel NPU 驱动 |
| 系统 | Windows 11（Linux 路径上游支持，本机未验证） |
| 内存 | 每 2 GB 模型至少 8 GB 空闲；1–4 B 模型 16 GB 舒适；**NPU 重度冷编译需 ≥25 GB 物理内存空闲**（空闲不足表现为编译无声挂起，P14 教训） |
| 磁盘 | 图编译缓存按"模型 × ctx 形状"计，4B 实测 ~19 GB/份：打包/部署**每个模型每个 ctx 预留 ≥20 GB** |

## 参与贡献

见 [CONTRIBUTING.md](CONTRIBUTING.md)。一份带 `GGML_OPENVINO_DUMP_BIN` 转储与
`tools/compare-tensors.ps1` 输出的复现材料，比一千句"跑不通"更有价值。

被推翻的假设同样欢迎——它们进 [CHANGELOG.md](CHANGELOG.md)，很多时候比修复更省后来人的时间。

## 许可

Apache-2.0，见 [LICENSE](LICENSE)。上游 llama.cpp（MIT）与 OpenVINO（Apache-2.0）各自的条款继续适用。

## 致谢

llama.cpp 的 ggml-org 维护者，以及 OpenVINO NPU 团队——llama.cpp 里的 OpenVINO 后端，是这个项目
能只是一组补丁而不是一次重写的原因。
