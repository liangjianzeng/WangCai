<p align="center">
  <img src="assets/wangchai.png" width="180" alt="汪柴：doge 风格的柴犬吉祥物，本引擎的拟人化身">
</p>

# WangCai 汪柴

> **面向 Intel® Core™ Ultra 的纯 NPU 端侧推理引擎。**
> 让被业界晾了多年的 *Intel® AI Boost* 重新产生价值。
>
> **v0.0.1 · 2026-10-31 引擎收官** —— NPU 端到端跑通 LFM3，精度主缺陷已定案修复（三问验收 3/3）。
> **v0.0.2 · 2026-11-02/03 助手落地** —— Windows 桌面壳 M1–M4：NPU / CUDA / Vulkan / 远端四线路由、
> 托盘驻留、Agent 回归、便携包 + Inno Setup 安装器。
> **v0.0.6 · 2026-11-08** —— 装机版引擎根因修复、NPU 世代自适应（Ultra 一/二/三代）、语音
> ASR&TTS 重构、4B 包线墙实测收口。
> **2026-11-10 · 生图整合** —— 聊天区 🎨 chip /「/图」直连 Unsloth Studio 文生图
> （Qwen-Image-2.1-Turbo，1024² 实测 17–29 s），智能体 `generate_image` 自主配图；
> Windows 本机/局域网/Tailscale、Linux 远端两端同一入口（方案
> [docs/image-gen-integration-plan.md](docs/image-gen-integration-plan.md)）。
> **2026-11-12 · 生图主线升级「8899 壳一实例三角色」** —— 提示词**扩写确认流**上线：
> 🎨/「/图」发送后先由 Qwen3-VL 把口语扩写成出图友好提示词，确认卡上过目/编辑/
> 「用原话」「重扩」后再生图（扩写不可用/失败自动直发，永不阻塞）；扩写走
> `tools/imagegen-server` 新增的 `/v1/chat/completions`（与生图共用同一份常驻
> Qwen3-VL），8899 转主推链路、unsloth 8888 保留可选（其 TE 拆头不可扩写）。
> **2026-11-13 实测收口（全档）**：TE（Qwen3-VL-8B）bf16 实测 **17G**，16GB 卡 bf16 上卡
> 不可行（此前 ~9G 假设作废）→ **生图档主配方 `QI_TE_INT4=1`：TE nf4 4bit 上卡 6.3G 常驻
> + DiT GGUF 5.4G + VAE ≈ 13.9G 峰值**——1024² 连续出图 **37~39s/张**（赛博朋克机械猫/
> 吉卜力柴犬两张实测），chat/扩写走 int4 TE **2.0s/80 token**；辅档 `QI_TE_DEVICE=cpu`
> （显存 0 占用）与 `QI_SKIP_DIT=1`。工程链与实测数字详见
> [tools/imagegen-server/README](tools/imagegen-server/README.md) 收口记录节。
> **2026-11-10 · Linux 桌面入库**（11-11 升级兼容基线）—— **Debian 10 (glibc 2.28) chroot 基线**
> deb + tar.gz 双产物（WSLg 实跑验证，UOS/Deepin 等老发行版兼容，readelf 版本闸把关）、
> DGX Spark（ARM64）原生构建链。**Linux 端是远端客户壳形态**：本地 NPU 推理不可用，
> 模型引擎/生图走局域网 HTTP——能力边界见 [Linux 桌面形态与限制](#linux-桌面形态与限制)。
> 变更全文见 [CHANGELOG.md](CHANGELOG.md)。**直接用？→ [下载安装包](#下载安装windows--linux)**
> 模型哪些能用、哪些不能用 → [NPU 模型支持现状](#npu-模型支持现状)（坦白版）。

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
| **副靶：跨模型验证（Spark-X2.6-4B + Qwen3-4B）** | 🟡 **2026-11-01 两个外部模型家族端到端跑通（三问 3/3）→ 2026-11-07/08 实测收窄：4B 线 NPU 包线墙钉在 ctx≤512**（Spark@4096 非确定性塌方 0.42 t/s、Qwen3-4B>512 首执行 UNINITIALIZED），Qwen3.5/MiniCPM5 禁入；「历史 1.3 t/s」已翻案（bench 8.15）——明细与出路见 [NPU 模型支持现状](#npu-模型支持现状) |
| **NPU decode 性能（4B）** | 🟡 **生产口径 ctx≤512：Spark 8.89 / Qwen3-4B 8.15 t/s（KV_HOST_WRITE=0）**；P14e 摘链杠杆（KVH=1）A/B 实锤 +33–38%（Spark 12.26 / Qwen3-4B 10.82，2026-11-08 跨模型迁移实锤）**但文本闸未过前禁入生产**（复读缺陷，defect-npu-p14e-kvhostwrite——根因修复是当前最大性能杠杆）。>512 是包线墙非性能问题（首执行 UNINITIALIZED）。1.7B 线不受影响（tg 22.6 全 ctx） |
| **端侧多模态助手「汪柴」（v0.0.2）** | ✅ **M1–M4 全部完成（2026-11-02/03 开发机验证）**：`app/` Flutter Windows 壳（TongYi-Lite Dart 同路径 vendored，分叉清单 `app/UPSTREAM.md`）+ llama-server 子进程网关；三引擎齐——引擎商店钉官方 llama.cpp b12034（Vulkan+CUDA，sha256 白名单）+ OpenAI 远端 + 绑定表实测 t/s 回写 + 路由三档（速度优先 / NPU 优先 / 自动·拔电 NPU 加权），**DoD 四线真机 5/5**（NPU 1.7B / CUDA 4B 117.6 t/s / Vulkan 双卡 / 远端协议）；托盘驻留 + 电源感知 + HKCU 自启；**识图 DoD 达成**（SmolVLM2-500M + 商店 CUDA 引擎，壳网关 20 s 出准确语义描述；NPU 视觉当时归档缺陷，**2026-11-07 引擎修复后 NPU 带图三线 E2E 全绿**，见 [docs/defect-npu-mtmd.md](docs/defect-npu-mtmd.md)）；Agent `--jinja` 工具链全链路回归（tools 200，agent c4096）；便携包 + Inno Setup 脚本。⬜ 干净机装机验证待人工（`packaging/README.md`） |
| **App 模型清单扩容：2B/4B 线（2026-11-07）** | ✅ **NPU 预置区扩到 8 条 preset + 目录补齐下载地址**：manifest 新增 `neohorse-1-4b`（TokenRhythm NeoHorse-1 4B Q4_K_M 2.5GB，262k ctx，留位未实测，通用 4B admission 自动接管：ctx≤512 放行、>512 拦）与 `qwen3.5-2b`（unsloth MTP UD-Q4_K_XL 1.29GB，同 qwen35 混合架构——GatedDeltaNet opset 风险与 4B 实锤同源 [defect-npu-qwen35-b12034](docs/defect-npu-qwen35-b12034.md)，2B 不预设结论、按「错放危害<错拦」不加家族禁入）；catalog 补 `Qwen3-4B-Q4_K_M` 下载条目（官方 Qwen 仓三镜像，sha256=本机已验证文件实测且与官方 HF LFS oid 逐位一致——此前 NPU 预置区缺文件却无处可下，用户只能手动放文件）；qwen3.5-2b 条目同步修到下载契约（魔搭置首 / `resolve/master` / 钉 sha，原 hf-mirror 置首+裸下载）。下载契约测试扩到 6 预置（落盘名命中 glob / 三镜像分支 / ±2% 字节带），全锦 1434/23/0 |
| **生图整合（2026-11-10）** | ✅ **Win/Linux 双端可用，同一份 Dart**：聊天区两入口——🎨 chip /「/图 提示词」确定性直调（不经 LLM，简单聊天模式可用、零 token）+ 智能体 `generate_image` 工具（LLM 判断该配图时自主调用，未启用/断连不注册、不幻觉）。服务端 = Unsloth Studio OpenAI 兼容 `POST /v1/images/generations`（Qwen-Image-2.1-Turbo Q5_K_M 8 步 Turbo；1024² 实测 17–29 s、2048² ≈105 s，n≤4 单飞队列串行），seed/尺寸/耗时随消息落库可溯源复现；设置「API 接入 → 图像生成」测连接绿灯，断连 chip 置灰带原因；图片复制/另存三处入口（动作行 / 右键 / 全屏预览）。Windows 本机 `127.0.0.1:8888` 或 Tailscale 远端均可（tailnet 内填 **http** 方案） |
| **生图主线升级「8899 壳一实例三角色」+ 扩写确认流（2026-11-12/13）** | ✅ **扩写流全链路实测交付**：`tools/imagegen-server` 8899 壳新增 `/v1/chat/completions`——扩写、轻量聊天（与生图共用同一份常驻 Qwen3-VL），主推链路，unsloth 8888 保留可选（其 TE 拆头不可扩写，源码实证在壳 README）。🎨/「/图」两态化：口语先经 `ImagePromptRewriter` 扩写 → **确认卡**（可编辑/🎨 生图/用原话/重扩）→ 确认才出图；扩写不可用/超时自动直发**永不阻塞**；开关与扩写模型档在设置「图像生成」节；智能体 `generate_image` 不过确认流（自主回合不卡人机）。**实测**：chat 真端点非流式/流式绿（**int4 TE 上卡 2.0s/80token**；CPU 档 20.8s、显存 0 MiB）、壳契约 25/25、app 新用例 21/21 + 全量回归绿；TE bf16 17G 实证 16GB 卡 bf16 上卡不可行 → **生图档已收口**：`QI_TE_INT4=1`（TE nf4 6.3G 常驻）+ DiT GGUF 5.4G + VAE，**1024² 连续两张 37~39s/张、显存峰值 13.9G 无增长**（壳 README 收口记录节） |

精度主缺陷的完整攻坚记录是这个仓库最有价值的资产之一：从"logits 被压平、K 缓存第 0 行错八个
数量级"出发，历经 scatter / conv 算子 / DQ / RMS 池化 / 广播 tile 一连串被证伪的假设，最终钉死在
**静态 decode 图 RoPE 的 cos/sin 头轴隐式广播在 NPUW 1-token 形状降级下错误 tile**，修复是
`rope.cpp` 里一处显式 Concat tile。证据链、被排除项与方法论教训见
[docs/defect1-rootcause.md](docs/defect1-rootcause.md)。当前仅存的精度未决项：≥64 token 的逐
token 严格判据待复测（48 token 三问验收已全对）。

两条用血换来的测量纪律，写在 [docs/npu-internals.md](docs/npu-internals.md) 里，读转储之前先看：
`prefill_0/1`、`decode_2` 是 llama.cpp 的 **warmup 假批次**（换 prompt 后字节不变），拿它们算余弦等于
没测；**续写题不能当连贯性判据**——它在设备算错时也能逐字一致，只有指令跟随题能暴露问题。

## NPU 模型支持现状

坦白版：App 内置 NPU 预置区 8 条模型，**当前能健康用的只有 LFM3 两条主打线**。下表每行都是本机
（Ultra 9 275HX · NPU 3720 · driver 32.0.100.4512 · OpenVINO 2026.4.1 · llama.cpp b12034 栈）的实测
口径，出处是各缺陷单与 [docs/HANDOFF.md](docs/HANDOFF.md)，不形容词化：

| 模型 | NPU 现状 | 实测口径 | 出路 |
|---|---|---|---|
| **LFM3-1.7B** Q4_K_M | ✅ **主打，全 ctx 健康** | tg 22.6 t/s（与 ctx 无关）、pp512 779 t/s；ctx≤8192 实测、16K 图级通过 | 默认推荐起步 |
| **LFM3-Omni-2B** Q4_0 | ✅ 文本全 ctx + **带图可用**（2026-11-07 引擎修复） | 文本 21.9 t/s；带图 10.15 t/s；遗留：大图首编 ≈7 min、视觉尾段无编译缓存、4096+mmproj 编译管线待复验 | 视觉线主力；音频输入 NPU 亦端到端 |
| Spark-X2.6-4B | 🟡 **仅 ctx≤512** | @512 warm ≈4.7–6 t/s；**@4096 非确定性塌方 0.42 t/s**（[defect-npu-spark-b12034](docs/defect-npu-spark-b12034.md)） | App 自动兜底到 512；长上下文用 CUDA（实测 99.2 t/s） |
| Qwen3-4B | 🟡 **仅 ctx≤512** | tg 8.15 t/s（KV_HOST_WRITE=1 达 10.82、+33%，但文本闸未过前禁入生产）；**>512 首执行 UNINITIALIZED**——2026-11-08 bench：ctx2176 编译 39 s 过、执行放不下 | 同上 |
| NeoHorse-1 4B | ⬜ **留位未实测** | 无实测数字，不预设结论；按通用 4B admission 接管 | 实测后补注 |
| Qwen3.5-4B / 2B | ❌ **禁入** | GatedDeltaNet 融合算子以自定义 opset 序列化，driver VCL 反序列化即编译期死；5540 驱动 decode DEVICE_LOST 终审 driver/硬件级（[defect-npu-qwen35-b12034](docs/defect-npu-qwen35-b12034.md)） | CUDA/Vulkan（qwen3.5-4b-gpu preset 真机首验通过） |
| MiniCPM5-2B | ❌ **禁入** | 全矩阵 6 配方点仅 1 点功能完整（ctx512 @ 2.0 t/s = 健康线的 1/10，thinking 模型一轮 CoT 96 s 起；DDL 回落臂亦作废；[defect-npu-minicpm5-b12034](docs/defect-npu-minicpm5-b12034.md)） | CUDA/Vulkan |

**4B 线的「先能用」兜底（2026-11-09）**：全局 ctx 默认 4096、可拖 16K，但 4B 在 NPU 上的实测包线是
512。App 现在对此**不再拒载**——网关自动把请求 ctx 收敛到实测安全档继续加载（未曾实测的机器收敛到
512；该机实测跑通过更高档位则按实测档收敛），ℹ️ 日志留痕，模型先能用。要更长上下文，装 CUDA/Vulkan
引擎（设置 → 引擎管理，4B 实测 88–99 t/s）。无实测安全档的模型（Qwen3.5 / MiniCPM5）维持硬拒载 +
改道建议，不假装能用。

**世代口径**：以上全部数字来自 NPU 3720（Ultra 一代）**一台实机**；Ultra 二代（3820）/ 三代（4000 系）
**没有实机、未实测**——App 按「保守起步 + 该机实测上探」自适应（[docs/npu-adaptation.md](docs/npu-adaptation.md)），
拿到二/三代实机之前，别把这张表外推到别的机器上。

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

## 下载安装（Windows / Linux）

从 [GitHub Releases](https://github.com/liangjianzeng/WangCai/releases/latest) 获取（当前 **0.0.6**，
2026-11-11 重出包——含生图整合、Linux 产物、**全新数据首启转圈修复**与 **Debian 10 (glibc 2.28)
兼容基线**（UOS/Deepin 老发行版可跑），Windows/Linux 共六件；11-10 首发包不含这些修复，请更新）：

| 产物 | 适合 | 说明 |
|---|---|---|
| **[Setup.exe 安装包](https://github.com/liangjianzeng/WangCai/releases/download/v0.0.6/WangCai-0.0.6-win-x64-Setup.exe)**（68 MB，sha256 `67177a85…`）· Windows 推荐 | 大多数人 | 标准 Windows 安装向导：每用户安装**无需管理员**，可选桌面图标 / 开机自启；壳 + **汪柴 NPU 引擎 + OpenVINO 运行时**一体安装；卸载保留会话库/模型/编译缓存 |
| **[portable.zip 便携包](https://github.com/liangjianzeng/WangCai/releases/download/v0.0.6/WangCai-0.0.6-win-x64-portable.zip)**（109 MB，sha256 `0ba8aeaa…`） | Windows 免安装 / U 盘 | 解压即用，跑 `App\WangCai.exe`（布局同安装器） |
| **[linux-amd64.deb](https://github.com/liangjianzeng/WangCai/releases/download/v0.0.6/WangCai-0.0.6-linux-amd64.deb)**（20 MB，sha256 `fa29de2c…`）· Linux x64 推荐 | Ubuntu 22.04/24.04、UOS/Deepin 等老发行版 | `sudo apt install ./WangCai-*.deb`：`/opt/wangcai` + `/usr/bin/wangcai` 符号链 + 桌面条目 + 图标；CJK/emoji 字体、xclip 等依赖 apt 自动带入；**Debian 10 (glibc 2.28) chroot 基线构建**（readelf 版本闸把关，UOS Desktop 20 实案驱动）|
| **[linux-amd64.tar.gz](https://github.com/liangjianzeng/WangCai/releases/download/v0.0.6/WangCai-0.0.6-linux-amd64.tar.gz)**（24 MB，sha256 `bc7e1c86…`） | x64 免安装 | 解压跑 `wangcai`，依赖清单随包 README |
| **[linux-arm64.deb](https://github.com/liangjianzeng/WangCai/releases/download/v0.0.6/WangCai-0.0.6-linux-arm64.deb)**（21 MB，sha256 `8376b99e…`）· ARM64 推荐 | DGX Spark 等 ARM64 | 同 deb 口径；`Depends` 用 22.04/24.04 兼容语法（`libgtk-3-0 \| libgtk-3-0t64` 等）；DGX Spark 原生构建（Flutter 3.29.0 arm64——官方不发 linux-arm64 SDK，如实记录） |
| **[linux-arm64.tar.gz](https://github.com/liangjianzeng/WangCai/releases/download/v0.0.6/WangCai-0.0.6-linux-arm64.tar.gz)**（26 MB，sha256 `7983ca2e…`） | ARM64 免安装 | 解压跑 `wangcai` |

装完第一件事（Windows）：设置页 → 模型 → 下载 **LFM3-1.7B** 起步（NPU 主打线，全 ctx 健康）。想跑 4B 智能体模型
也可以——NPU 上它们只有 ctx≤512 的实测包线，App 会自动兜底收敛（见 [NPU 模型支持现状](#npu-模型支持现状)）。
引擎管理确认 NPU 就绪。想试试生图（主推 8899 壳）：`tools\imagegen-server\start.ps1 -DitGguf <本地
DiT GGUF>` 起服 → 设置「API 接入 → 图像生成」填 `http://127.0.0.1:8899` → 「模型服务」加一档
baseUrl `http://127.0.0.1:8899/v1` 的 API 模型并在「扩写模型」下拉选中，🎨/「/图」即走
扩写→确认卡→出图（见 [tools/imagegen-server/README](tools/imagegen-server/README.md)；
unsloth 8888 可选链路见 [生图整合方案](docs/image-gen-integration-plan.md)）。硬件门槛见[硬件要求](#硬件要求)。

> CUDA / Vulkan 外挂引擎不随安装器分发，在 App 内「引擎商店」按需下载；NPU 引擎与 OpenVINO 运行时始终随包。

**Linux 包是远端客户壳**（不含 NPU 引擎，能力边界见下节）：装完第一件事把设置页的模型引擎指向
局域网/远端的 llama.cpp / vLLM / OpenAI 兼容 HTTP，生图指向 Windows 侧 Unsloth Studio（LAN 地址或
`http://<host>.ts.net:8888`——tailnet 流量端到端加密，端上填 **http** 方案）。想自构建（WSL 一条
脚本 / DGX Spark 原生）见 [packaging/README](packaging/README.md)，产物口径
`WangCai-<ver>-linux-<amd64|arm64>.{deb,tar.gz}`。

## Linux 桌面形态与限制

Linux 端与 Windows 端**同一份 Dart 代码**，差异全部来自平台守卫——与其让你对着"加载不了模型"
猜原因，这里把边界一次说清（2026-11-10 Ubuntu 22.04/WSLg 首轮验证）：

| 能力 | Linux 状态 | 说明 |
|---|---|---|
| 本地 NPU 推理（主打线） | ❌ 不可用 | `llama-server`（ggml-openvino/NPU 后端）是 Windows 构建，Intel AI Boost 插件仅 Windows 提供。**Linux 没有"本地加载 GGUF 跑 NPU"这条路** |
| 本地 CUDA / Vulkan 引擎 | ❌ 不可用 | 随包/商店的本地引擎同样是 Windows 二进制 |
| **远端引擎（主方案）** | ✅ | 设置页填局域网/远端的 llama.cpp / vLLM / OpenAI 兼容 HTTP 地址（含 SSH 隧道形态） |
| 联网搜索（端侧直连） | ✅ | Bing/360/搜狗等直连抓取，纯 Dart |
| 生图（客户侧） | ✅ | 连局域网 Windows 侧 Unsloth Studio（设置页填其 LAN 地址；与 Windows 端同一入口：🎨 chip /「/图」） |
| 智能体工具/会话/待办/计划 | ✅ | 纯 Dart，与 Windows 同行为 |
| 语音 TTS（Edge） | ✅ | 网络服务，跨平台 |
| 本地 ASR（sherpa-onnx） | ⚠️ 未实测 | Linux 预编译库存在，本轮未专门验证 |
| 系统托盘 / 关窗驻留 | ❌ | `tray_manager` Windows-only，守卫降级：关窗即退出，无常驻图标 |
| API 密钥安全存储 | 🟡 | Linux 走 libsecret——需要桌面提供 secret service（GNOME Keyring / KWallet）；没有时回退明文文件（fail-open 设计使然，公共机器注意） |
| 图片复制到剪贴板 | ✅ | 需 `xclip`（X11）或 `wl-clipboard`（Wayland）——deb 已声明依赖自动带入 |
| 开机自启 / 桌面集成 | 🟡 | deb 安装带 `.desktop` 项；注册表类"开机自启"为 Windows 特性，Linux 未提供 |

**一句话定位**：Windows 上汪柴是"纯 NPU 端侧推理引擎 + 智能体"；Linux 上是**接入你局域网
AI 算力的桌面智能体壳**——UI、会话、智能体、搜索、生图体验两端一致，缺的是本地大模型推理。

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
| `-c`（1.7B 线）≤ 8192 实测通过、16K 图级通过 | 多跨度 decode 图组落地后 decode 速度与 ctx 无关（c=8192 实测 14.1 t/s）；**4B 线另有限制：ctx≤512 是包线墙**（>512 首执行 UNINITIALIZED，与 chunk 无关），见 [NPU 模型支持现状](#npu-模型支持现状) |
| 4B 模型（NPU）：`GGML_OPENVINO_PREFILL_CHUNK_SIZE=64`（短 prompt）/ `128`（长 prompt） | 4B 预算规则（BUDGET-TRACE 定案，HANDOFF 2026-11-02 深夜）：**prefill 图(chunk) + 最大 decode 图（级别 = KV 行跨度）联合驻留**。chunk256 只容 decode 级别 ≤512（**ctx≤512 实测可用，pp +55–59%**）；ctx≥1024 时 decode 需级别 ≥1024 → 超预算（首 execute ZE append 失败），chat/server 用 64/128。llama-bench 离线流 decode mask 从不超 256，chunk256 随便用；1.7B 任意 ctx 可 chunk256。短 prompt 首 token 延迟 chunk64 比 128 好 ~17%，32 以下固定开销反噬。**P18 自动升档（2026-11-05）**：钉 128 时，129–512 token 的 prefill 自动改走 chunk256 图（bench pp200 184.8 t/s vs chunk128 模型值 ~127 = **+46%**），>512 保持 128、unset 保持 256 缺省——用户不再需要手调。**App 侧（2026-11-09）按包线墙自动兜底**：4B 请求 ctx>512 时网关自动收敛到实测安全档 512 加载（ℹ️ 留痕），不再拒载 |

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
CUDA 引擎，壳网关全链路 20 s 出准确语义描述（`app/test/platform/vision_official_test.dart`）。
**NPU 线视觉也已打通（2026-11-07 引擎修复）**：`clip_encode failed -1` 的根因链定案并修复后，NPU
带图三线 E2E 全绿（mtmd-cli 128px / 1920×1200 壁纸 / llama-server OpenAI 格式带图 10.15 t/s），
引擎声明 `vision=true` 回填——遗留：大图首次编译 ≈7 分钟、视觉尾段无编译缓存、4096+mmproj 编译管线
待复验（[docs/defect-npu-mtmd.md](docs/defect-npu-mtmd.md)）。引擎侧音频输入 NPU 已端到端（与
native Q8_0 参照逐字一致，见上表）。语音输入/输出管线（sherpa ASR / TTS）随壳 vendored 并于 v0.0.6
完成 M0–M3 重构（唤醒双引擎仲裁 + offline TTS 链）。

**生图线（2026-11-10 整合 · 2026-11-12 主线升级）**：一个实现双入口——聊天区 🎨 chip /
「/图 提示词」确定性直调（不经主聊天 LLM，简单聊天模式与离线可用、零 token），智能体模式则由
LLM 自主调用 `generate_image` 工具配图。共同底座 `image_gen_service.dart` 是纯 Dart HTTP
（零原生依赖）：OpenAI 兼容 `POST /v1/images/generations`（Qwen-Image-2.1-Turbo Q5_K_M，8 步
Turbo，1024² 实测 17–29 s），n≤4 客户端单飞队列串行，图片落盘 `文档/imagegen/日期/` 并以
`imagePaths` 入库（seed/尺寸/耗时随消息留存，同 seed 可复现）。配置在设置「API 接入 → 图像生成」，
测连接绿灯；未启用/断连 chip 置灰带原因、工具不注册。图片的复制进剪贴板 / 另存在动作行、右键菜单、
全屏预览三处都有入口。

**主推链路 = `tools/imagegen-server` 8899 壳「一实例三角色」**（2026-11-12 用户拍板）：独立
FastAPI + diffusers 直调 Qwen-Image-2.1-Turbo，同构 OpenAI 协议 + **`/v1/chat/completions`
对话端点**——生图、**提示词扩写**、轻量聊天共用同一份常驻 Qwen3-VL text_encoder（完整
`Qwen3VLForConditionalGeneration` 带 lm_head 能 generate；16GB 单卡口径 2026-11-13 实测修正：
TE bf16 17G → 生图档 **TE nf4 int4 上卡 6.3G 常驻 + DiT GGUF 5.4G + VAE**（13.9G 峰值，
1024² 37~39s/张实测），辅档 `QI_TE_DEVICE=cpu` / `QI_SKIP_DIT=1`，**零双份零频繁换载**，
与本地 24B/27B 聊天模型互斥）。扩写确认流：
🎨/「/图」发送后 `ImagePromptRewriter` 先让模型把一两句口语扩写成 diffusion 友好提示词，
**确认卡**上过目——可编辑、「🎨 生图」、「用原话」、「重扩」——确认才起 job；扩写模型不可用/
超时/空回复自动直发，**永不阻塞**（上下文压缩同款降级纪律）。扩写模型在设置里选（推荐指 8899
chat 档；unsloth 8888 的 TE 被拆头 `NoLogitsHead`，物理上不能承担扩写——源码实证见壳 README）。
`.\start.ps1 -DitGguf …` 一键起服：[tools/imagegen-server/README](tools/imagegen-server/README.md)。
**unsloth Studio 8888 保留为可选链路**（日常出图/flux 系；客户端设置页换地址即切）：
Windows 可本机或 Tailscale 远端、Linux 端连同一服务即得同等体验（"零原生依赖"换来的双端一致）。
完整方案与验收 [docs/image-gen-integration-plan.md](docs/image-gen-integration-plan.md)。

### 分期

- **Phase 0（本仓库）**：纯 NPU 引擎，LFM3 文本链路。✅ 完成（v0.0.1 收官；音频/视觉见上表）。
- **Phase 1**：引擎进入服务层。🟡 v0.0.2 实际以 **llama-server 子进程网关**落地（平台分支唯一化）；
  C ABI 直链为并行线，成熟后替换传输层、壳无感。
- **Phase 2**：App 在 Windows 跑通。✅ **v0.0.2 M1–M4 完成**：NPU/CUDA/Vulkan/远端四线 DoD、
  托盘驻留、路由三档、Agent 回归、便携包 + Inno Setup 安装器（⬜ 干净机验证待人工）。
- **Phase 3**：多模态端到端。🟡 识图 DoD 已在官方引擎线达成；**NPU 视觉 2026-11-07 引擎修复后带图
  三线 E2E 全绿**（遗留：大图首编 ≈7 min，见 defect-npu-mtmd）；语音管线 vendored，v0.0.6 M0–M3
  重构合流。
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
| [生图整合方案](docs/image-gen-integration-plan.md) | Unsloth Studio 客户侧：双入口、落盘/seed 口径、远程接入与验收 |

## 硬件要求

| | |
|---|---|
| SoC | 带 `Intel(R) AI Boost` 的 Intel Core Ultra（Series 1/2），设备类 `PCI\VEN_8086&DEV_AD1D` |
| 驱动 | 与所装 OpenVINO 版本匹配的 Intel NPU 驱动 |
| 系统 | Windows 10/11（下表约束为**本地 NPU 推理线**；Linux 桌面壳不受这些约束——它是远端形态，Ubuntu 22.04 系 x64/ARM64，见 [Linux 桌面形态与限制](#linux-桌面形态与限制)） |
| 内存 | 每 2 GB 模型至少 8 GB 空闲；1–4 B 模型 16 GB 舒适；**NPU 重度冷编译需 ≥25 GB 物理内存空闲**（空闲不足表现为编译无声挂起，P14 教训） |
| 磁盘 | 图编译缓存按"模型 × ctx 形状"计，4B 实测 ~19 GB/份：打包/部署**每个模型每个 ctx 预留 ≥20 GB** |

## 版本更新历史

逐条明细与取证链接见 [CHANGELOG.md](CHANGELOG.md)（Keep a Changelog 格式；
Unreleased 段的日期是"该改动在硬件上被验证的日期"）。

| 版本 | 日期 | 要点 |
|---|---|---|
| Unreleased | 2026-11-09 → 11-12 | **生图整合**（🎨 chip /「/图」+ 智能体 `generate_image`，Unsloth Studio 直连，Win/Linux 双端）、**Linux 打包链**（deb + tar.gz，x64/ARM64，CJK/emoji 字体与窗口图标补漏）、**4B 兜底准入**（问题模型自动收敛到实测安全档，先保可用）、SearXNG 配置折叠化、**首启转圈三层修复 + Linux 数据家 XDG 化**、**Debian 10/UOS 兼容构建通道**（buster chroot + readelf 版本闸）；**2026-11-11 六件重出包**——以上改动全部并入 0.0.6 产物（Windows 双件 + Linux 四件，链接见[下载安装](#下载安装windows--linux)段）；**2026-11-12 生图主线升级**——8899 壳「一实例三角色」（`/v1/chat/completions` 与生图共用一份常驻 Qwen3-VL）+ **提示词扩写确认流**（确认卡可编辑/用原话/重扩，失败自动直发永不阻塞）。逐条见 [CHANGELOG.md](CHANGELOG.md) Unreleased 段 |
| [0.0.6](CHANGELOG.md) | 2026-11-07 → 11-08 | **装机版引擎根因修复**（engines.json「缓存不夺权」+ PATH 前置重建修「NPU 引擎不可用」、退出 c000041d/WER 卡顿修复、`app.log` 黑匣子日志）；**4B 重估轮**（Qwen3-4B「1.3 t/s」翻案为 bench 口径 8.15/10.82、ctx>512 包线墙实测钉准、P14e 杠杆跨模型迁移 +33%）；并入 2026-11-05→07 批次：**NPU 世代自适应**（一/二/三代探测 + clamp 链 + 实测上探闭环）、**语音 ASR&TTS 重构 M0–M3**、**路由两档制**、**NPU 视觉引擎修复**、**4B admission 收紧族**（Spark 深上下文拦 / Qwen3.5 编译禁入 / MiniCPM5 禁入）、**模型清单扩容**（neohorse-1-4b / qwen3.5-2b + 下载契约 6 预置） |
| [0.0.5](CHANGELOG.md) | 2026-11-05（tag 11-06） | 引擎线合流收官：P15–P20 入册（`KV_HOST_WRITE` 翻转修复、chunk 自动升档）、16K 深上下文预设、引擎按需安装改 **zip 流式解包**（修 CUDA 800MB+ 包下载完成即崩）；侧边栏常显收窄 |
| 0.0.4 | 2026-11-05 | **数据家统一**四家并一家进 `%APPDATA%\WangCai`（搬迁语义 6 用例）；路由定调 **NPU 主打**；JSONL 真相源通电（write-through + fast path）；窗口几何记忆/单实例/快捷键等桌面基本件；交互去手机化 |
| 0.0.3 | 2026-11-04 | **桌面独立化 Phase 0–4**：脱离上游 TongYi-Lite 独立演进（品牌全线换装汪柴）、项目 × 工作空间层级 + SQLite v7、引擎管理重写（本地登记 + 参数优先级链 + cuda/vulkan 按需下载）、`local_exec` 桌面执行层 |
| 0.0.2 | 2026-11-03 | **汪柴助手壳 M1–M4**：Flutter 壳 + llama-server 子进程网关、三引擎齐（NPU/CUDA/Vulkan + 远端）+ 绑定表实测 t/s + 路由三档、托盘驻留 + HKCU 自启、识图 DoD（SmolVLM2）；**副靶** Spark-X2.6-4B + Qwen3-4B 端到端 3/3（顺带修 u4 权重与 f16 零点两个横切缺陷） |
| 0.0.1 | 2026-10-31 | 首个版本：**NPU 精度主缺陷定案收官**——静态 decode 图 RoPE cos/sin 头轴广播在 NPUW 1-token 降级下错误 tile，修复 `rope.cpp` 显式 Concat tile，指令跟随三问 3/3（攻坚全记录见 [docs/defect1-rootcause.md](docs/defect1-rootcause.md)） |

## 参与贡献

见 [CONTRIBUTING.md](CONTRIBUTING.md)。一份带 `GGML_OPENVINO_DUMP_BIN` 转储与
`tools/compare-tensors.ps1` 输出的复现材料，比一千句"跑不通"更有价值。

被推翻的假设同样欢迎——它们进 [CHANGELOG.md](CHANGELOG.md)，很多时候比修复更省后来人的时间。

## 许可

Apache-2.0，见 [LICENSE](LICENSE)。上游 llama.cpp（MIT）与 OpenVINO（Apache-2.0）各自的条款继续适用。

## 致谢

llama.cpp 的 ggml-org 维护者，以及 OpenVINO NPU 团队——llama.cpp 里的 OpenVINO 后端，是这个项目
能只是一组补丁而不是一次重写的原因。
