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
| **1.1** | **NPU 输出与 CPU 参照数值对齐** | 🟡 **未通过** | 与参照余弦：prefill `0.969`，decode `0.73–0.87` |
| 1.2 | 贪心解码与参照逐 token 一致 ≥ 64 token | 🟡 | 2–3 个 token 后发散 |
| 1.3 | CI 里有验收测试 | ⬜ | 依赖 1.1 |
| 2.1 | NPU 解码快过 OpenVINO-CPU | ⬜ | 解码 8.3–8.7 t/s，对比 21.7–29.2（CPU）/ 54.1（原生） |
| 2.1b | NPU 预填充具备竞争力 | 🟡 | `pp512` 415 t/s = 原生参照的 73%；约用了 13 TOPS 中的 1.4 |
| 2.2 | 热启动 < 5 s | ⬜ | 缓存目录有效，冷启动 36 s |
| 3.x | 模型线宽度（0.3 B–8 B、长上下文） | ⬜ | |
| 4.x | LFM3 全模态（音频输入、视觉输入） | ⬜ | |

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

### 1. NPU 的 logits 被压平（阻塞性）

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

### 3. 超出 KV 缓存的序列会把 OpenVINO 后端拖垮

只要 KV 写入索引落到缓存之外就报
`Check 'idxValue < static_cast<int64_t>(srcDimAxis) ...' failed at intel_cpu\src\nodes\scatter_update.cpp:915`。
在 `llama-perplexity`（任意设备）以及 1024 上下文下的 `llama-bench -p 1024 -n 32` 上都观察到；同样的
测试在 `-p 512` 下干净通过，这正说明问题指向越界索引而不是图形状。在 **NPU 上同样的条件会把设备拖崩**，
报的是 `ZE_RESULT_ERROR_DEVICE_LOST` 而不是一条检查失败。

后果：perplexity 目前无法用作精度指标（恰好就是缺陷 1 想要的那个指标）；而在 NPU 上，一个越界索引是
设备级失效，本身就值得单独上游上报。根因尚未确立——本文档早期"多输出图破坏了 `SET_ROWS` 降级"的说法，
**没有**得到 `-p 512` / `-p 1024` 差分实验的支持，已撤回。

### 4. `GGML_OPENVINO_DEBUG_NODE` 在 NPU 上会让进程中止

往图里追加 `Result` 节点会让插件在编译期死掉。已用 `GGML_OPENVINO_DUMP_BIN` 绕过；上游的修法要么在插件
侧，要么就是明确拒绝该请求并报错。

### 5. 缺少对照模型

到目前为止所有结论都来自同一个架构。一个上游已在 NPU 上验证过的小模型，能把"NPU 插件的行为"与
"LFM3 的行为"分开；本地那个候选后来发现是个下载不完整的文件。

## 约束与不可妥协项

| 约束 | 原因 |
|---|---|
| 只能用 `-fa 1` | `-fa 0` 时 llama.cpp 把 V 摊成每行一个元素，OpenVINO 的 scatter 写回随即拒绝该索引 |
| 只能用 `-np 1` | 静态路径是单序列的；`-np 2` 会撞上 `state is only supported with stateless` |
| 不支持 bf16 | 在 NPU 的调度阶段就被拒绝 |
| 每种配置用全新的 `GGML_OPENVINO_CACHE_DIR` | 否则一张过期的编译图会无声胜出 |
| 必须用 chat 模板 | instruct 模型被裸续写驱动，在任何后端（含原生 CPU）都会退化成重复胡话 |
| 每张图冷编译约 36 s | 使用持久缓存目录；见路线图 2.2 |

## 我们凭什么说一条论断是真的

三条值得在每个 PR 上强制执行的习惯：

1. **比对张量，不要用形容词。** 要 `compare-tensors.ps1` 的输出，不要"看起来好多了"。
2. **先对齐 pass 再比对。** 两次运行产生的图调用次数并不相同；拿第 N 个 pass 对第 N 个 pass，正是产出
   "自信且错误"结论的方法。
3. **证明设备。** `--list-devices` 加上一次转储比对——两台设备不可能逐位相同，而一次吞吐长得像 CPU 的
   "NPU 运行"，其实是跑在 CPU 上。
