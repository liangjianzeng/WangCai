# 当前状态

按时间点记录、来自实测、可被证伪。每一条论断都附上能证实或推翻它的命令。

**基线：** llama.cpp `abb76ab380c7f3f731e365a859fb4cc64e939bb8` + [patches/](../patches/README.md)
**运行时：** OpenVINO 2026.4.1 · **机器：** Intel Core Ultra 9 275HX、Intel AI Boost (NPU 3720)、32 GB
**在研模型：** LFM3-1.7B `Q4_K_M`，1049 MB，24 层
（13 门控短卷积 + 5 滑动窗口@256 + 6 全局注意力）

## 里程碑

| # | 里程碑 | 状态 | 证据 |
|---|---|---|---|
| 0.1 | 不装 GPU/OpenCL SDK 也能构建 OpenVINO 后端 | ✅ | 在 Build Tools + OpenVINO wheel 安装环境上跑 `tools\build.ps1` |
| 0.2 | NPU 设备被枚举且可选中 | ✅ | `llama-cli --list-devices` → `OPENVINO3: ... Intel(R) AI Boost (NPU 3720)` |
| 0.3 | 两张静态图都能在 NPU 上编译 | ✅ | 运行进入生成阶段；冷编译 36.4 s 被记进加载耗时 |
| 0.4 | 混合 KV 环寻址正确 | ✅ | `ov-mask:` 显示 `is_swa=1 -> mask_kv=768`、`is_swa=0 -> mask_kv=1024` |
| 0.5 | 短卷积状态能跨解码步接续 | ✅ | 单 token prompt 在 NPU 上连续 40 个解码步仍连贯 |
| 0.6 | 静态路径在设备外被证明数值可信 | ✅ | `-Backend static`（CPU）输出连贯，早期 pass 与动态图逐位一致 |
| **1.1** | **NPU 输出与 CPU 参照数值对齐** | ✅（2026-10-31） | 根因定案并修复：静态 decode 图 RoPE 的 cos/sin 头轴隐式广播在 NPUW 降级下错误 tile（[defect1-rootcause.md](defect1-rootcause.md) 终章）。修复后缓存 row0 四头 cos 0.997+、范数逐位一致 |
| 1.2 | 贪心解码与参照逐 token 一致 ≥ 64 token | ✅（2026-10-31） | 修复后复测：p220 续写 CPU-static 与 NPU **64 token 逐字节一致**（修复前同等判据即通过、修复中断、现已恢复）；三问验收 3/3；zh 指令生成的 NPU 文本 72 token 连贯无坍塌。注意：自由生成的 top-1 与 f32 参照在第 5 步起分歧（f16 噪声复利，cos 维持 0.5–0.9，无修复前的 0.25 平台期）——判据按"逐 token 一致"以续写路径为准 |
| 1.3 | CI 里有验收测试 | ✅（2026-10-31） | `tools/accept-smoke.ps1`：三问贪心验收跑在 CPU 静态路径（覆盖 rope tile/rank align/set_rows 等设备无关翻译，requant 对齐 NPU 默认）；CI build job（windows）下载 Q4_K_M 并执行，缓存 1 GB 模型。NPU 专属闸门仍是本地 accept.ps1 |
| 2.1 | NPU 解码快过 OpenVINO-CPU | ⬜ | `llama-cli` 解码 8.3–8.7 t/s，对比 21.7–29.2（CPU）/ 54.1（原生）。`llama-bench tg32 @ -p 1024`：NPU 15.3 对 OV-CPU 30.5。**ctx 线性代价实测：-c 8192 下 decode 0.9 t/s**（KV 状态进出随 ctx 线性放大，正是缺陷 2 的状态流量项） |
| 2.1b | NPU 预填充具备竞争力 | 🟡 | `pp512` 415 t/s = 原生参照的 73%；`pp1024`：NPU 368 对 OV-CPU 626 / 原生 605；**8K prompt 实测 prefill 122.6 t/s** |
| 2.2 | 热启动 < 5 s | ⬜ | 缓存目录有效，冷启动 36 s（-c 16384 为 61 s） |
| 3.x | 模型线宽度（0.3 B–8 B、长上下文） | 🟡 | **长上下文打通：-c 8192（7K prompt 端到端）与 -c 16384（图级）在 NPU 通过**。Q8_0 被驱动主机内存预算阻塞（见缺陷 7） |
| 4.x | LFM3 全模态（音频输入、视觉输入） | 🟡 | **LFM3-Omni-2B-Q4_0 文本链路在 NPU 端到端跑通**（8.3 t/s，含编译 48 s）；音频输入待 mtmd 接入 NPU |

## 今天能用的部分

- **CPU 上的参照质量输出。** `-Backend native` 与 `-Backend ovcpu` 都能通过 chat 模板产出连贯的中英文
  回答。所有关于 NPU 的论断都以它为基准真值。
- **NPU 端到端跑完整模型**，包括递归的短卷积层、滑动窗口注意力和全局注意力层，开启 flash attention
  （`-fa 1`）且单序列。
- **静态路径在设备外可信。** CPU 上的 `GGML_OPENVINO_FORCE_STATIC=1` 复现 NPU 的代码路径，于是大部分
  调试变成秒级循环。
- **诊断手段已经足够定位缺陷**——精度差距正是这样被缩小到插件而不是图上的：原始输出转储、逐 pass 的
  top-token 对齐、逐元素比对、以及运行期的 NPU 编译配置覆盖。

## 未解决的缺陷

### 1. NPU 的 logits 被压平 —— **已修复（2026-10-31 根因定案 + 验收）**

> **结论（commit `63179ef`）：** 缺陷是**静态 decode 图 RoPE 的 cos/sin 头轴隐式广播**——
> `[1,1,1,128]` 广播到 `[1,1,4,128]` 在 NPUW 的 1-token（GEMV）形状降级下错误 tile，K 缓存
> 每行只剩偶数 128 块正确；prefill 同构广播在 `[1,1,256,4,128]` 上正确，故 prefill 无恙。
> 修复 = `rope.cpp` 显式 Concat tile + `translate_session.cpp` 注册门扩到 NPU；三问验收
> **3/3 首次全对**。完整证据链、被证伪的假设清单与当日方法论教训见
> [defect1-rootcause.md 终章](defect1-rootcause.md#2026-10-31-定案根因--静态-decode-图-rope-的-cossin-头轴广播在-npuw-降级下坏掉已修复并验收)。
> 下文保留为历史记录。

NPU 上的贪心解码与 CPU 参照一致 2–3 个 token，随后开始胡言乱语。

| Pass | CPU 参照 | NPU |
|---|---|---|
| prefill（生成中） | id2083 · 19.58 | id2083 · 17.53（余弦 `0.969`） |
| decode 1 | id1094 · 20.27 | id1094 · 13.51（余弦 `0.786`） |
| decode 2 | id310 · 25.87 | id310 · 15.81（余弦 `0.804`） |
| decode 3 | id5141 · 22.29 | **id342** · 14.91（余弦 `0.870`） |
| decode 4 | id278 · 26.06 | **id711** · 11.32（余弦 `0.726`） |

范数相同、峰值更低 → 这是精度的特征，不是寻址的特征。对一个约 220 token prompt 的**真实** prefill
chunk 做的逐层测量（conv 状态输出）显示：栈底就有一个小误差，并向上复利放大——`l0 0.9956`、`l9 0.873`、
`l13 0.534`、**`l17 0.163`**——而且在第一个 chunk 就已经存在，早于任何解码步与状态复用。退化集中在 conv
路径；注意力写入基本无辜：V 精确写入（200 行全部，最大绝对差 `2.7e-6`），K 稳定在 `0.90–0.9998`
**唯独第 0 行**错了八个数量级（余弦 `0.288`、最大绝对差 `1.06e10`）。那一行是整个调查中目前最具体的
线索。已排除项与仍然成立的结论列在
[npu-internals.md § 4](npu-internals.md#4-the-accuracy-gap)，包括完整的 NPUW / 动态量化开关扫描
（没有任何开关能修好它；关掉这些路径只会更糟）。

**在读任何比对结果之前，先把 pass 分类。** `prefill_0`、`prefill_1`、`decode_2` 是 llama.cpp 的预热：
同一模型换 prompt 重跑，它们逐字节不变。上面这张表的早期版本就是在预热数据上量的，只能重做；区分两者的
哈希比对方法写在 [npu-internals.md § 4](npu-internals.md#4-the-accuracy-gap)。

**一份原生 Q4_0 权重把两个被混为一谈的误差分开了。** 换用 `LFM3-1.7B-QAD-Q4_0.gguf`（ModelScope，
QAD = 量化感知蒸馏）之后，重量化造成的不对称基本消失，剩下两种行为按任务干净地劈开：220 token 的**续写**
在原生 CPU、OV-CPU 静态、NPU 三条路径上**逐字节一致**；而 64 token 的中文**指令跟随**仍然只在 NPU 上退化
（conv 状态余弦 `decode_2 0.989` → `decode_9 0.51` → 平台期 `≈0.25`，top-1 从第 10 步起发散）。
**续写是通路测试，不是连贯性测试**——设备算错时它照样一致。

复现：

```powershell
tools\run-npu.ps1 -Model models\LFM3-1.7B-Q4_K_M.gguf -PromptFile prompts\zh.txt -Backend static -Label cpu -DumpBin tmp\dumps\cpu
tools\run-npu.ps1 -Model models\LFM3-1.7B-Q4_K_M.gguf -PromptFile prompts\zh.txt -Backend npu    -Label npu -DumpBin tmp\dumps\npu
tools\top-token.ps1 -Dir tmp\dumps\cpu ; tools\top-token.ps1 -Dir tmp\dumps\npu
tools\compare-tensors.ps1 -A tmp\dumps\cpu -B tmp\dumps\npu
```

### 2. NPU 解码比 CPU 参照慢 6 倍（对核心主张是阻塞性的）

同一模型同一台机器上：8.3–8.7 t/s，对比原生 54.1 t/s、OpenVINO-CPU 21.7–29.2 t/s——大约是**可用
TOPS 的 0.03**。用 NPU 的全部理由就是每瓦性能；绝对吞吐输給 CPU 而 CPU 还全程空闲，这件事至今没有
解释。注意它**只发生在解码**：`pp512` 的预填充是有竞争力的（415 对 570 t/s），所以插件并不是整体配置
错了。嫌疑按序：每步重绑无状态缓存、激活量化的开销、解码形状图的编译提示、以及按运行期索引的
conv 状态 `Gather`。

### 3. 超出 KV 缓存的序列会把 OpenVINO 后端拖垮 —— **根因已找到并修复（2026-10-31）**

只要序列长度越过 SWA 环（`-p 1024 -n 32 -c 1024`），KV 写入索引就落到缓存之外：CPU 插件报
`Check 'idxValue < static_cast<int64_t>(srcDimAxis) ...' failed at intel_cpu\src\nodes\scatter_update.cpp:915`，
NPU 插件则报 `ZE_RESULT_ERROR_DEVICE_LOST`。在 `llama-perplexity`（任意设备）与 `llama-bench -p 1024` 上
复现；`-p 512` 干净通过。

**机制**（`GGML_OPENVINO_DEBUG_INPUT` + `GGML_OPENVINO_DUMP_CGRAPH` 钉死）：llama.cpp 的
interleaved-SWA 缓存为**全量缓存**与 **SWA 子缓存**各建一个写索引输入张量，而 `build_input_k_idxs()`
把两者都命名为 `attn_inp_k_idxs` / `attn_inp_v_idxs`。解码器的参数表按名字注册（先到先得），SWA 的
索引张量被全量缓存的同名张量**覆盖**——窗口层于是拿着全量缓存的 cell id（线性增长到 ctx）散射进
只有 `n_swa` 大小的环。原生 ggml 后端各自绑定各自的张量指针，所以 `-dev none` 一直没事。这与
注意力 mask 的同名冲突是同一类失败——mask 那次已经在
`get_tensor_graph_input_ov_name()` 里按张量身份区分过，索引张量当时被漏掉了。

**修复**（2026-10-31，两轮迭代后的最终形态）：同一个函数里按 `SET_ROWS` 目的缓存所在层的 SWA 归属给
索引参数追加 `_swa` 后缀——但**只对 prefill 图与动态路径**。静态 decode 图必须保持单一合并参数：
NPUW 对它的参数表结构敏感，多出一个（环长以内数值完全相同的）参数，编译出的设备图每个 decode 步都
输出 NaN——同样的改名在 prefill 图上则逐字节惰性。decode 图的越界改由图内的 `Mod(索引, 环行数)` 解决：
环内恒等（数值与修复前一致），越环回绕（有界、不崩，与 prefill 同一近似口径）。改名还要求
**每相位各自的 decoder 对象**：`ptr` 与 `ptr_prefill` 若在首 pass 是 prefill 时别名到同一对象，
下一个 decode pass 会经 `update_io` 把它重注册成 decode 命名，再下一个 prefill pass 就会绑到不存在的
名字上（`utils.h` 的 `ptr_prefill` 注释）。

修复后 `-p 1024 -n 32 -fa 1` 三条路径全部通过：

| 执行路径 | pp1024 | tg32 |
|---|---:|---:|
| 原生 ggml CPU（参照） | 605 t/s | 56.7 t/s |
| OpenVINO · CPU 动态 | 626 t/s | 30.5 t/s |
| OpenVINO · NPU 静态 | 368 t/s | 14.5 t/s |

`llama-perplexity` 因此解锁，可以重新用作精度指标。附带说明：在环长以内（如 670 token 的 p220），
两套索引张量的数值相同，修复不改变任何数值——修复前后 NPU prefill 的 K/V 转储中，**第 1 行起逐位
相同（余弦 1.0000），唯独第 0 行不同**——见 [npu-internals.md § 4](npu-internals.md#4-the-accuracy-gap)
的新发现：第 0 行根本没被真实 prompt 写过。

### 4. `GGML_OPENVINO_DEBUG_NODE` 在 NPU 上让进程中止 —— 已改为显式拒绝（2026-10-31）

往图里追加 `Result` 节点会让 NPUW 在编译期死掉。现在 `translate_session.cpp` 在 NPU 上直接拒绝该
请求并给出指向 `GGML_OPENVINO_DUMP_BIN` 的提示（拒绝警告走 `GGML_LOG_WARN`，在早期日志汇上不一定
可见；判据是带 `GGML_OPENVINO_DEBUG_NODE` 的运行不再产生 `__debug_*` 输出）。附带的新测量：在
OpenVINO 2026.4.1 上，硬中止不再复现，但**带附加 Result 编译出的 NPU 图 logits 全 NaN**——拒绝它
同时防止了一种静默劣化。

### 5. 缺少对照模型 —— 已补上（2026-10-31）

Qwen3（纯 transformer，与 LFM3 的混合结构完全不同）作为对照：

| 模型 | 原生 / OV-CPU | NPU |
|---|---|---|
| `Qwen3-4B-Q4_K_M`，`-c 1024` | 两者输出一致且连贯 | **`ZE_RESULT_ERROR_OUT_OF_HOST_MEMORY`**（`pfnAppendGraphExecute`，编译能过、执行放不下） |
| `Qwen3-4B-Q4_K_M`，`-c 512` | 连贯 | 跑通但**从第一步就是单 token 塌缩**（`GGGG…`） |
| `Qwen3-1.7B-Q4_K_M`，`-c 1024` | 连贯（16.3 t/s） | 跑通但输出退化（0.9 t/s，响应为空） |

结论：数值缺陷**不是 LFM3 特有的**——它跟着"NPU 静态路径"走，而不是跟着混合架构走。同时 4B 在
`-c 1024` 下连图都放不下，给 Phase 3 的"实用上限在 1–3 B"猜想提供了第一个数据点。

**健康栈复测（2026-10-31 下午）：** 在排除内存预算干扰的 `-c 512` 下重测，Qwen3-1.7B 依旧是
从第一步起的单 token 塌缩（`GGGG…`，3.5 t/s）——上表的 NPU 列在健康栈上**成立**，缺陷 1 与
混合架构无关这一点也有了自己当时的证据链。同轮 QAD-Q4_0 的三问验收（贪心解码）：**0/3**——
每条回答开头 10–15 个 token 连贯、随后漂移，与缺陷 1 的"逐步发散"特征一致。

### 6. 一次 OOM 会把 NPU 驱动带进坏状态（2026-10-31，**叙述已修正两次**）

Qwen3-4B 的执行期 `OUT_OF_HOST_MEMORY`（`pfnAppendGraphExecute`）之后，当晚所有 NPU 转储都是 NaN。
当时判定为"驱动回读被楔住、跨进程跨 DLL 存活"。**这个叙述与后续证据冲突**：重启后用 `7b796fc`
构建重测，全部转储恢复正常——而重启前的 NaN 与该构建给 decode 图引入的多余参数（缺陷 3 的第一轮
修复，已被 `7b796fc` 改正）在时间线上重合。因此"OOM 楔住回读"与"NPUW 对参数表敏感导致 NaN"两个
因素当时被混在一起，无法事后分离。保留的教训：**(a)** 执行期 OOM 之后不要在同一驱动状态下做精度
测量（`pnputil /restart-device` 或重启）；**(b)** "文本正常 + 转储 NaN"首先应当怀疑当次的图变更，
而不是驱动状态——本仓库同时改动两者的概率不低。

**第二次修正（同日晚间）：** 当天下午又出现一轮"崩溃后一切变慢 + `UNINITIALIZED`"，用了一整轮
设备电源循环、驱动重绑定仍无法恢复，几乎再次得出"驱动楔住"——最后证明真凶是**主机内存被另一
进程吃掉**（见缺陷 7 的重框），与驱动状态无关。教训升级：异常退出后的性能异常，**先做微型图
基准（1 个 matmul 的编译与 infer 计时）和内存占用排查**，两者都正常才能谈驱动状态；
不要在没跑基准的情况下重启机器或复位设备。

### 7. Q8_0 模型被 NPU 驱动的主机内存预算阻塞（新发现，2026-10-31；**当晚重框**）

LFM3-1.7B 与 Omni-2B 的 Q8_0 checkpoint（源文件均 1.85 GB）在 NPU 上编译成功但在首次执行时死于
`L0 pfnAppendGraphExecute: ZE_RESULT_ERROR_UNINITIALIZED`（DQ 关闭时为显式
`OUT_OF_HOST_MEMORY`）。已排除：NaN scale（打包权重有校验，零命中）、驱动楔住（之后 Q4_K_M 立即
正常）、IR 结构差异（两模型直方图一致）、重量化配置（强制 Q4_0_128 与 `q4_sym128_all` 同样失败）、
内存开关（`REDUCE_COMPILE_MEM`/`RELEASE_WEIGHTS` 无效——后者被 `is_gpu()` 门住，且 NPU 零拷贝读
重打包权重，源缓冲无法像 GPU 那样丢弃）。**尺寸边界已钉准：源 ≤ 1.26 GB（Q4_K_M/QAD-Q4_0/Q5_K_M/
Omni-Q4_0）全部通过，1.85 GB 必失败。** 修复方向：NPU 路径在重量化完成后释放 ggml 源权重缓冲
（Windows 上需 VirtualFree(MEM_DECOMMIT) 等价物 + 失败快速路径），需要谨慎处理张量生命周期。

**当晚追加重框（2026-10-31 下午）：** 这个"边界"不是模型尺寸的固有属性，而是
**(模型 + ctx KV + 编译工作区) 对比当刻可用的主机内存**。本机 iGPU 上一个常驻 ~23 GB 的
llama-server 把可用内存吃掉后，**0.98 GB 的 Omni-Q4_0 在 `-c 4096` 下也复现了完全相同的
`UNINITIALIZED`**，且编译跌进病态慢路径（20 s → 30+ min）、解码 60 倍变慢；`-c 512` 则一切
恢复正常（13.8 t/s）。曾据此误判为"驱动楔住"——设备电源循环、驱动重绑定、微型图基准
（0.2 s 编译 / 1 ms infer，全程健康）三重证据把楔住论推翻。经验：**NPU 异常先查内存大户
（`Get-Process`），再怀疑驱动**；预算边界必须标注测量时的可用内存，否则不可复现。
另见 [troubleshooting](troubleshooting.md) 的"编译/执行一夜之间慢了几十倍"条目与本机复位工具。

## 约束与不可妥协项

| 约束 | 原因 |
|---|---|
| 只能用 `-fa 1` | `-fa 0` 时 llama.cpp 把 V 摊成每行一个元素，OpenVINO 的 scatter 写回随即拒绝该索引 |
| 只能用 `-np 1` | 静态路径是单序列的；`-np 2` 会撞上 `state is only supported with stateless` |
| 不支持 bf16 | 在 NPU 的调度阶段就被拒绝 |
| 每种配置用全新的 `GGML_OPENVINO_CACHE_DIR` | 否则一张过期的编译图会无声胜出 |
| 一次执行期 OOM 之后不要信 NPU 转储 | 驱动回读路径被楔住，文本正常但转储全 NaN；见缺陷 6 与 [troubleshooting](troubleshooting.md) |
| 必须用 chat 模板 | instruct 模型被裸续写驱动，在任何后端（含原生 CPU）都会退化成重复胡话 |
| 每张图冷编译约 36 s | 使用持久缓存目录；见路线图 2.2 |

## 我们凭什么说一条论断是真的

三条值得在每个 PR 上强制执行的习惯：

1. **比对张量，不要用形容词。** 要 `compare-tensors.ps1` 的输出，不要"看起来好多了"。
2. **先对齐 pass 再比对。** 两次运行产生的图调用次数并不相同；拿第 N 个 pass 对第 N 个 pass，正是产出
   "自信且错误"结论的方法。
3. **证明设备。** `--list-devices` 加上一次转储比对——两台设备不可能逐位相同，而一次吞吐长得像 CPU 的
   "NPU 运行"，其实是跑在 CPU 上。
