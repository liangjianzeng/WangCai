# NPU 内部机制：真正难的地方

"在 Intel AI Boost 上跑 LLM"这件事里，那些"后端存在"并不等于"已经解决"的部分。每一节都按同一种写法：
约束是什么、违反它会看到什么症状、正确的做法是什么。

---

## 1. 静态形状把参数形状与主机绑定耦在一起

<a id="1-static-shapes-couple-the-parameter-shape-to-the-host-binding"></a>

编译后的图会把每个输入形状焊死。于是下面两段互相独立的代码，必须对每一个输入完全一致：

```
GgmlOvDecoder::get_graph_input_shape(op, input)      ← 编译进参数的形状
get_ov_input_tensor_static_{decode,prefill}(…)        ← 你实际绑定的那个 ov::Tensor
```

一旦两者不一致，NPU 插件会拒绝绑定：

```
Check 'is_dynamic || port_partial_shape == tensor_shape' failed at
  intel_npu/src/backend/src/zero_infer_request.cpp:1250: got [1,1,256,1024] expecting [1,1,256,768]
```

注意这条报错的不对称之处：它不告诉你是**哪一侧**错了，而两侧各自都有看似充分的理由坚持自己的数字。
改其中一侧，必须在同一个 commit 里改另一侧。`get_mask_ctx_size()` 的存在就是为了让它俩没法各自漂移。

---

## 2. 混合结构模型用一个 mask 张量寻址两个 KV 环

<a id="2-hybrid-models-address-two-kv-rings-with-one-mask-tensor"></a>

LFM3-1.7B 是 24 层：13 门控短卷积、5 滑动窗口@256、6 全局注意力。在静态图下它需要**两种**不同的 mask
宽度：

| Mask | 上下文 | 为什么 |
|---|---:|---|
| 全局注意力 | `1024`（= `-c`） | 对整个上下文做注意力 |
| 滑动窗口 | `768`（环长 = `3 × window`） | 只对环内做注意力 |

而 llama.cpp 实际交给后端的，实测下来两个 mask 长这样：

```
ov-mask: name=attn_inp_kq_mask ne=[256,2,1,1] is_swa=0 -> mask_kv=1024 | ctx=1024 ctx_swa=768 chunk=256
ov-mask: name=attn_inp_kq_mask ne=[256,2,1,1] is_swa=1 -> mask_kv= 768 | ctx=1024 ctx_swa=768 chunk=256
```

这两个宽度都不是来自主机张量。`256` 是 llama.cpp 的 `n_kv` 向上取整到它的占用粒度倍数；静态图需要的
宽度来自**消费该算子所读的缓存**。从张量里推导宽度就是那个 bug；从消费方缓存推导才是
`get_mask_ctx_size()`。

一路上踩到的失效模式，全部真实发生过：

| 尝试 | 结果 |
|---|---|
| 两个 mask 都用 `ctx`（最初版本） | `Check 'attention_mask_input_correctness' failed at scaled_dot_product_attention_shape_inference.hpp:92` —— mask `[1,1,256,1024]` 对 K/V `[1,16,768,128]` |
| 两个 mask 都用环长 | SDPA 接受了，绑定拒绝了：`got [1,1,256,1024] expecting [1,1,256,768]` |
| 两个 mask 都用主机宽度（256） | 现在轮到 SDPA 在**全局注意力**层失败：`{[1,16,256,128],[1,16,1024,128],[1,16,1024,128],[1,1,256,256]}` |
| 按模块给各自宽度（正确做法） | 两张图都编译通过并运行 |

两条配套规矩：

- **列切片是带跨度的，所以只能在主机上补齐、在图里切片，不能两边都做。** 对共享的主机 mask 做补齐用的是
  `pad_input()` 加 `std::min(cols, padded_cols)`，它顺带就把列截断到前 N 列——这也正是上游为它的有状态
  切片 mask 采用的约定。
- **补齐出来的行必须是有限值。** `set_zero_diagonal()` 的存在是为了让一个被全遮住的补齐行不会把 `softmax`
  算成 `0/0`。补齐行里出现 NaN 绝不是无害的：递归状态的 gather 读的是最后一个有效 token **之后**的那些列，
  而那里恰好就是补齐区域。

---

## 3. 递归（conv）状态是一条流，不是一个缓冲区

<a id="3-the-recurrent-conv-state-is-a-stream-not-a-buffer"></a>

LFM3 的短卷积 `d_conv = 7`，所以每层状态是 `6 × 2048 = 12288` 个元素（`cache_r_l*`，绑定成
`[1,1,1,12288]`）。该算子消费的流按如下方式排布：

```
[ 上一轮状态：6 列 │ 本 chunk 的 token：chunk_size 列 ]
```

而写回必须取走**以最后一个有效 token 结尾的那 6 列**，即流上的列区间 `[v, v+6)`，其中
`chunk_valid_len = v`。Prefill 用一个位于 `chunk_valid_len` 的 `Gather` 来做这件事（用 Gather 而不是
Slice，是为了让输出形状保持静态）；decode 则用位于 `rs_src_begin_*` 的 `Slice`。同一个概念操作有两条
不同的代码路径——当其中一条出错时，记住这一点很有用。

把 conv 路径（大概率）摘干净的证据是：**单 token prompt 在 NPU 上是连贯的**，而且它执行的是同一张被补到
256 列的 prefill 图，随后 40 个解码步每步都读写 conv 状态。所以多列卷积与逐步状态接续都是通的。

---

## 4. 精度差距

<a id="4-the-accuracy-gap"></a>
<a id="the-accuracy-gap"></a>

**状态：已解决（2026-10-31，v0.0.1 收官）。** 根因 = **静态 decode 图 RoPE 的 cos/sin 头轴隐式广播**
（`[1,1,1,128]` → `[1,1,4,128]`）在 NPUW 的 1-token（GEMV）形状降级下错误 tile，K 缓存每行只剩偶数
128 块正确；prefill 同构广播在 `[1,256,4,128]` 上正确，故 prefill 无恙。修复 = `rope.cpp` 显式
Concat tile；三问验收 3/3。完整证据链、被证伪假设清单与教训见
[defect1-rootcause.md 终章](defect1-rootcause.md)。本节其余内容保留为排查过程的历史记录——包括
"K 缓存第 0 行范数爆炸"等当时最锋利、但最终被推翻或被更精确解释收编的线索。

### 它是怎样被定位的

贪心解码、同样的 prompt/seed、三条执行路径，然后比对**原始输出张量**（`GGML_OPENVINO_DUMP_BIN`）而不是
文本。按 top-1 token id 对齐 pass：

| Pass | CPU 动态 | CPU 静态 | NPU 静态 |
|---|---|---|---|
| prompt batch 1 | id229 · 12.639 | id229 · 12.639 | id12942 · 10.555 |
| prompt batch 2 | id0 · 19.015 | id0 · 19.015 | id7 · 16.141 |
| **prefill（生成中）** | id2083 · 18.98 | id2083 · 19.58 | id2083 · 17.53 |
| decode 1 | id1094 · 23.14 | id1094 · 20.27 | id1094 · 13.51 |
| decode 2 | id310 · 27.07 | id310 · 25.87 | id310 · 15.81 |
| decode 3 | id5141 · 20.90 | id5141 · 22.29 | **id342** · 14.91 |
| decode 4 | id278 · 25.82 | id278 · 26.06 | **id711** · 11.32 |

由此得到的事实：

- **CPU 动态 ≡ CPU 静态。** top-1 id 相同、量级基本一致，所以静态模式的图构建以及 mask / 环那部分工作
  不是误差来源。
- **Prefill 很接近**：与 CPU 参照余弦 `0.969`，top-1 相同、top-5 集合也相同。
- **Decode 不行**：余弦 `0.73–0.87`，而且分布被压平——L2 范数相同、峰值更低（`25.87 → 15.81`）。贪心
  与参照一致 2–3 个 token，然后脱轨。
- 缓存写入（K、V、conv 状态）在两设备间的 min/max/mean 很接近；但错一行在这些聚合量里是隐形的——这正
  是要做原始转储的原因。

logit 分布"被压平但保住了范数"，是精度的特征而不是寻址的特征：错一行或者窗口切错会产生一个**不同的**
分布，而不是一个缩放的分布。

### 预热陷阱——在相信任何转储比对之前先读这一节

<a id="the-warmup-trap"></a>

`GGML_OPENVINO_DUMP_BIN` 按执行顺序给 pass 编号，而**最靠前的那些 pass 不是 prompt**。llama.cpp 会在第一
个真实 token 之前预热后端，所以 `prefill_0`、`prefill_1`、`decode_2` 在"同一模型、两个不同 prompt"的两次
运行之间**逐字节相同**，而 `prefill_3..6`、`decode_7..11` 不同。在预热 pass 上算统计量，看着干净，其实
什么都没测。

下面那节的第一个版本就犯了这个错，报出了一条在合成预热输入上算出的逐层曲线。它已被删除并重新测量。
判定 pass 归属要靠机械手段而不是靠编号——同一模型用两个不同 prompt 各跑一次，比对哈希；凡名字哈希相同的
就是预热 pass：

```powershell
foreach ($f in Get-ChildItem dbg\runA -Filter *.bin) {
    $b = Join-Path dbg\runB $f.Name
    if (Test-Path $b) {
        $same = (Get-FileHash $f.FullName).Hash -eq (Get-FileHash $b).Hash
        '{0}  {1}' -f $(if ($same) { 'WARMUP' } else { 'REAL  ' }), $f.Name
    }
}
```

### 逐层发散（真实 pass）

<a id="per-layer-divergence"></a>

`LFM3-1.7B-Q4_K_M`，约 220 token 的 prompt（正好一个完整的 256 列 chunk），NPU 对 CPU 静态参照，各自使用
默认的量化方式——也就是会输出错东西的那个配置。递归 conv 状态（`cache_r_l*`，每层 6 × 2048）是最有信息量
的输出，因为每一层的状态都是它以下所有部分的函数：

| 层 | `prefill_3` | `prefill_4` | `decode_7` | | 层 | `prefill_3` | `prefill_4` | `decode_7` |
|---|---:|---:|---:|---|---|---:|---:|---:|
| `l0` | 0.9956 | 0.9939 | 0.9985 | | `l13` | 0.5343 | 0.9068 | 0.8275 |
| `l1` | 0.9856 | 0.9832 | 0.9930 | | `l15` | 0.3684 | 0.8903 | 0.7809 |
| `l3` | 0.9711 | 0.9185 | 0.9490 | | `l17` | **0.1627** | 0.8315 | 0.7243 |
| `l5` | 0.9562 | 0.9107 | 0.9434 | | `l19` | 0.2849 | 0.8967 | 0.7705 |
| `l7` | 0.9296 | 0.8376 | 0.8353 | | `l21` | 0.2420 | 0.9136 | 0.6947 |
| `l9` | 0.8728 | 0.8390 | 0.7865 | | `l23` | 0.6455 | 0.9450 | 0.8721 |
| `l11` | 0.8290 | 0.8691 | 0.7800 | | | | | |

由此得到四点：

1. **第 0 层就已经不同**（`0.9956`，在量级为 1 的值上最大绝对差 `0.064`）。没有任何一层是坏掉的；每层
   贡献一点小误差，残差流把它复利放大。这是算术的特征而非寻址的特征，也与上面测到的 logits 压平一致。
2. **它在第一个真实 prefill chunk 里就存在**——早于任何解码步、也早于任何状态复用——所以跨步状态接续那
   一整块（conv 状态 gather、`chunk_valid_len`、decode 切片）在本缺陷上是被排除的。它仍然必须正确，但
   不是让输出变错的那个东西。
3. 塌缩是**依赖数据、而不是依赖步数**的：最差情况出现在*第一个* chunk 的深层（l17 处 `0.16`），而同一
   prompt 的第二个 chunk 保持在 ≥ 0.83，decode 大约在 0.7–0.9 之间。
4. 它集中在**短卷积路径**上。注意力写入讲的是相反的故事：

| KV 张量（行模式，`-RowSize 512` = 一个位置 = 4 个 KV 头 × 128） | 解读 |
|---|---|
| `cache_v_*`，全部 200 个已写行 | 最大绝对差 `1.5e-9`–`2.7e-6`，`leading-clean=200` → **V 是精确写入的** |
| `cache_k_l2` 第 1–7 行 | 余弦 0.95–0.9998 → 相对误差很小 |
| `cache_k_l12` 第 1–7 行 | 余弦 0.90–0.99 → 同一量级 |
| **每个 K 层的第 0 行** | 余弦 **0.2876**，最大绝对差 **1.06e10** → 位置 0 在某一侧严重错误 |

V 精确意味着"反量化 → 归一化 → 投影"这条链大体是对的，下面那个重量化对照实验也指向同一结论。
**K 的第 0 行是整个比对中唯一一个结构性异常**，也是眼下最锋利的线索：那个写第一个位置的东西
（第 0 行的 prefill 写入索引，或者写到那里的值），它的行为跟第 1..n 行不一样。

对一个 chunk 根本没写过的行做整缓冲区统计，不叫测量：两侧在那儿都是零，读出来就是
`cosine 0.135, maxDiff 0.0000`。请用行模式——见 [`tools/README.md`](../tools/README.md)。

### 已经排除掉的

<a id="what-has-been-ruled-out"></a>

| 假设 | 检验方法 | 结论 |
|---|---|---|
| mask 内容错 | `GGML_OPENVINO_MASK_MODE=1`（按位置推导的因果 mask） | CPU 静态仍连贯，NPU 依旧错 → mask 内容被排除 |
| 多列卷积 | `PREFILL_CHUNK_SIZE` = 1/2/7/32/128/256 | 无变化 → 与 chunk 形状无关 |
| conv 算子本身 | 单 token prompt，40 个解码步 | 连贯 → conv 与逐步状态接续没问题 |
| 绑定的输入不同 | 两侧都开 `GGML_OPENVINO_DEBUG_INPUT` | 绑定输入完全相同（token、位置、索引、mask） |
| 静态路径本身 | CPU 上 `GGML_OPENVINO_FORCE_STATIC=1` | 连贯 → 静态翻译是正确的 |
| 重量化成 `Q4_0_128` | 在 CPU 上强制同样的重量化 | 仍然连贯 → 单靠它不足以解释 |
| 算子降级缺失（`SSM_CONV`） | 读代码 | 已实现为 depthwise `GroupConvolution` |
| GQA/SDPA 降级 | `GGML_OPENVINO_MANUAL_GQA_ATTN=1`、`LOG_UNSUPPORTED_OPS=1` | 没有记录到不支持算子的回退；也无改善 |
| `-fa 0` | 任意设备 | 设计上就是死路（见 [troubleshooting](troubleshooting.md)） |

### NPUW / 量化开关扫描

<a id="the-npuw--quantization-lever-sweep"></a>

后端为 NPU 插件设置的每一项，都通过 `GGML_OPENVINO_NPU_COMPILE_OVERRIDES` 在运行期逐个翻转（每格一个全新
的 `GGML_OPENVINO_CACHE_DIR`）：

| 覆盖项 | 结果 |
|---|---|
| *（无——默认）* | 能跑，logits 被压平，约 3 个 token 之后开始出垃圾 |
| `NPU_COMPILER_DYNAMIC_QUANTIZATION=NO` | `ZE_RESULT_ERROR_OUT_OF_HOST_MEMORY`（`pfnAppendGraphExecute`，code `0x70000002`）——未量化的图放不下 |
| `NPU_USE_NPUW=NO` | 编译期 `core.cpp:120` 抛 `ov::Exception`；不支持的配置 |
| `NPUW_DQ=NO` | 能编译，生成退化成 `>>>>>>>>>>>>>>>>>` |
| `NPUW_DQ=NO,NPUW_DQ_FULL=YES` | `ov::Exception`，编译失败 |
| `NPUW_DQ_FULL=YES` | 退化成 `>>>>>>>>>>>>>>>>>` |
| `NPUW_FOLD=NO` | 退化成 `>>>>>>>>>>>>>>>>>`，编译耗时 383 s |
| `NPUW_WEIGHTS_BANK=none` | 无变化 |

怎么读这张表：压缩权重 + 设备内反量化这条路径在这里不只是"一个优化"——把它关掉只会更糟（塌成单 token
输出是*权重坏了*的特征）。而精度缺陷在所有有文档记载的开关下都存活。这两件事合起来，指向的不是"挑个更好
的 flag"，而是这个模型的图在设备上执行方式里某个结构性问题。

### 重量化对照实验，以及它解决了什么

<a id="the-requant-control"></a>

拿 NPU 和 CPU 比，只有两边加载同一份权重才有意义；而默认情况下它们加载的**不是**同一份：NPU 会对每个
权重强制分组 4 bit（见 `docs/env-vars.md`）。把两侧策略对齐后测量（CPU 侧
`GGML_OPENVINO_REQUANT_KQUANT=q4_sym128_all`，并设 `GGML_OPENVINO_FORCE_STATIC=1`
让 CPU 走 NPU 的静态代码路径）：

| 比对 | 最差 conv 状态 | 最差 K 行 | logits |
|---|---:|---:|---|
| NPU（强制重量化） 对 CPU（原生 Q4_K） | `0.215` | `0.31` | 被压平，约 3 个 token 后出垃圾 |
| NPU 对 CPU，**两侧都**重量化成 `Q4_0_128` | `0.9589` | `0.9994`–`1.0000` | 6 个 pass 里 4 个 top-1 一致 |

三分之二的差距来自"两台设备跑的是*不同的量化*"，而不是 NPU 算得差。剩下的那部分是真实存在的，但小得多，
并且与之前的结论一致：conv 路径里逐层的舍入误差在复利放大。

一份原生 Q4_0 权重（`LFM3-1.7B-QAD-Q4_0.gguf`）把这件事推得更远，并把最后一对被混淆的行为分开：在
220 token 的**续写**上，它在原生 CPU、OpenVINO-CPU 静态和 NPU 上逐字节一致；而在 64 token 的中文**指令**
任务上，只有 NPU 退化，conv 状态逐步发散为 `decode_2 0.989 → decode_9 0.51 → 平台期 ≈0.25`。
**低熵任务会把这个缺陷完全藏起来**；它们只配当通路检查用，别的什么都证明不了。

### 接下来往哪儿走

<a id="where-to-take-it-next"></a>

> **（2026-10-31 收尾注：缺陷 1 已按下面的路径走完并修复，本清单归档。）** 最终不是"第 0 行没被写"
> 也不是 RMS 分母错轴，而是 **decode 图 RoPE cos/sin 头轴广播的 NPUW 降级错误**——条目 0 观察到的
> "16 元素段周期 / 奇数头 {1,3} 损坏"正是 cos/sin 广播 tile 坏掉的直接投影；"conv 状态写回垃圾"
> 是量化未对齐 + pass 错位比较叠加出的假象。定案与修复见
> [defect1-rootcause.md](defect1-rootcause.md)。

0. **缺陷签名已锐化到"K 缓存第 0 行、范数爆炸"（2026-10-31 下午，健康栈重测）。** 在干净的对齐
   基准上（LFM3-1.7B-QAD-Q4_0、`-c 512`、44-token Great-Wall prompt、两侧 `REQUANT_KQUANT=native`
   之外的注意点见下、CPU = FORCE_STATIC 参照、`GGML_OPENVINO_DUMP_BIN` 逐 pass 转储）：
   - **只有第 0 行的 K 与 CPU 发散**：范数 **4.8 倍**（68.4 对 14.3；l02 也一样 65.5 对 30.3），
     方向部分相关（行余弦 -0.51/0.29/0.51，逐层不同）。**position 1 起的每一行都是 0.98–1.00**。
   - **V 全域正常**（0.92–0.996，量化噪声级）——共享的隐状态输入没坏，坏的只是 K 专属的
     k_norm/RoPE 链，且只在 position 0。
   - 第 0 行内部呈 16 元素段周期：与 CPU 完全一致（±1.00）、完全正交（0.00）、反相关（-1.00）的段
     交替——RoPE 的 (i, i+head_dim/2) 配对结构清晰可见。
   - prefill_3 与 prefill_4 数字**逐位一致**（确定性缺陷，不是未初始化内存）。
   - 量级解读：4.8 倍 ≈ 分母错轴/错切片的 RMS 类错误（sqrt(2048/64)≈5.7 与 sqrt(512/64)=2.8 之间），
     指向 **k_norm（per-head RMS）在 position 0 的归一化分母**，或 position 0 的 K 输入被换成了
     别的东西（范数大 4–5 倍的量恰好是隐状态对 K 投影的典型比例）。
   - **头粒度（2026-10-31 晚间补充）：head_dim=128、每行只有 4 个 KV 头；损坏只落在奇数头 {1,3}**，
     偶数头（0/2）逐位完好（cos +1.000，范数相等）。损坏头的结构：`attn_k_norm.weight` 的
     近零区（w≈0 的通道）里 NPU 输出比 CPU 再小 ~30 倍（~0.002 对 ~0.05），而 **w 尖峰通道
     （w[121]=-0.695）上 NPU 的归一化值反号且放大 ~6 倍**（归一化后 +46.8 对 CPU 的 -7.45）——
     即 NPU 的 pre-norm K 投影在该头的能量集中到一个反号的分量上，其余通道塌缩。这不是
     RMS 标量错误（纯标量不可能反号），更像 pre-norm K 投影（W_k·cur）在 position 0 的
     奇数头切片被替换成了一个单分量向量。V 在同一输入、同一 position 完好——分离点在
     K 分支的输入或权重切片，而非共享隐状态。
   - 位置 0 特异性 + 奇数头特异性的组合指向图翻译里的切片/视图偏移类问题（view/offset 在
     第 0 行的边界情形），而非数值精度——**f32 二分之前应先做小图 naive 路径对照**：
     构一个 <20 节点的 K 链小图（MUL_MAT→RMS_NORM→ROPE→SET_ROWS），它走 naive 路径
     （无 NPUW），在 NPU 上可以直接对照 CPU 逐算子定位；这绕开了"DEBUG_NODE 在 NPUW
     下会崩"的限制。
   - 该测量用的是 NPU 默认 Q4_0_128 对 CPU 原生 Q4_0（量化不同，双方都有 ~0.95 的量化噪声底），
     **但第 0 行 4.8 倍的范数爆炸远高于噪声底**，且 V 同噪声底下完好——结论对量化差异稳健。
   - 旧叙事"第 0 行根本没被真实 prompt 写过"来自预热污染的转储；现在的第 0 行**被写了，但写的是
     错的**。
1. **native Q4_0 的 extract 路径在 NPU 上是坏的（新发现，独立缺陷）。** `REQUANT_KQUANT=native`
   让 NPU 走原生 Q4_0 提取（此前 NPU 从未走过这条路径，一直强制 Q4_0_128 重打包）——结果
   **l4 起所有注意力层的 K 缓存整片 NaN**（写入区域全 NaN），l2 的 K 也有 21 个 NaN 元素，
   生成退化为单 token 重复。Q4_0_128 重打包路径一切正常（0 NaN）。CPU 上 extract 路径是常态，
   所以这是 NPU 专属的 extract 路径缺陷，优先级低于主缺陷但要在文档里钉住。
2. **K 路径 + conv 状态写回——两个并行的缺陷现场（2026-10-31 深夜测量）。** 在重量化对齐对（CPU
   `q4_sym128_all` + FORCE_STATIC 对 NPU 默认，同一 670-token prompt、相同 ubatch 结构）上：
   - **chunk 1**（`prefill_3`，写 155 行）：V 逐元素接近（差 1–2 f16 ulp 级）；**K 整行发散**（按 128 维
     分段余弦 0.27–0.63，头部排列已用互相关排除）。
   - **chunk 2 起**（`prefill_4` 行 155+）与**所有 decode 步**：K 和 V **全部**不相关（余弦 ~0，含 ±2 行
     的对齐扫描）。
   - **conv 状态**（`cache_r_l1/l3`，不含 k_norm/RoPE 的层）：从 chunk 1 起就完全发散（非零交叠元素上
     余弦 0.0000，且 NPU 侧比 CPU 少 ~1500 个非零值——有整段被写成零）。
   自洽解释：**conv 状态写回在 NPU 上是坏的**——chunk 1 的 conv 输出正常（所以 chunk 1 的 V 对齐），
   但写给 chunk 2 的状态是垃圾；chunk 2/decode 消费垃圾状态后全链路发散，聊天从第二个 chunk/几步后就
   乱掉。K 的 chunk-1 发散是另一条独立线索（K = RoPE(k_norm(W_k·x))，V 无此两级；角度本身看起来是对的
   ——最低频的元素对反而匹配）。这两个现场都需要"中间量转储"来定案：临时把 pre-RoPE 的 Kcur 和
   conv 写回前的状态加为图输出做一次 DEBUG 构建（`GGML_OPENVINO_DEBUG_NODE` 会崩，须硬编码）。
   注意：早先"逐层 conv 发散 l0 0.9956 → l17 0.163"的表格出自未对齐 pass，方向成立、量值作废；
   本节所有数字都来自对齐对。**（2026-10-31 下午注：条目 0 的"第 0 行范数爆炸"很可能就是本条
   "chunk-1 K 发散"的真身——深夜测量的分段余弦 0.27–0.63 是把坏的第 0 行与好的后续行混在一
   个段里平均出来的。）**
2. **为什么 conv 路径退化而 V 不退化。** 两者消费同样的重量化权重和同样的隐状态；一个复利放大，一个精确到
   `1e-8`。差别在于算子本身（`d_conv=7` 的门控因果卷积 + 它的状态切片）与状态布局——f32 二分应该从这里开始。
   注意：早先的逐层 conv 发散表（l0 0.9956 → l17 0.163）出自未对齐 pass 的转储对，数字方向仍成立
   （conv 状态确实随层发散），但量值要在对齐对上重测。
3. **隔离输出投影。** `output.weight` 被重量化成 Q8_0_C，投影规模是 128000×2048。`result_norm` 转储不出来
   （追加 `Result` 节点会让 NPU 插件中止），所以这需要一个不同于 `GGML_OPENVINO_DUMP_BIN` 的挂钩。
4. **单个算子升到 f32。** 一次只把一个算子升到 f32（k_norm、RoPE、短卷积、最后的 `MatMul`），盯余弦变化。
5. **换一个架构做对照。** 已完成（2026-10-31）：Qwen3 复现同类缺陷，见 [status.md 缺陷 5](status.md)。

---

## 5. 属于引擎一部分的工具链

<a id="5-tooling-that-is-part-of-the-engine"></a>

这些东西的存在，是因为"读代码"不够用：

| 工具 | 它为什么存在 |
|---|---|
| `GGML_OPENVINO_DUMP_BIN` + `tools/compare-tensors.ps1` | `min/max/mean` 这类聚合统计会藏住单行错误；逐元素余弦不会 |
| `tools/top-token.ps1` | 按 top-1 token id 对齐两次运行的 pass——没有它，你会拿每次运行的错误 pass 相比，然后得出自信且错误的结论 |
| `GGML_OPENVINO_MASK_MODE` | 把"mask 内容"与"图执行"分开 |
| `GGML_OPENVINO_NPU_COMPILE_OVERRIDES` | 把一整夜的 flag 扫描压成五分钟 |
| CPU 上的 `GGML_OPENVINO_FORCE_STATIC` | 同一个代码路径，每个实验从约 36 s 变成几秒 |

`GGML_OPENVINO_DEBUG_NODE`（追加图输出）在 NPU 上会**让进程中止**——插件不接受追加的 result。本代码树里
所有诊断手段读的都是图本来就产出的输出。

---

## 6. 性能观察

<a id="6-performance-observations"></a>

两件事，它们值得被分开对待——本文档早期版本把它们混在一起，得出过一个严重错误的结论。

**Prefill 没问题。** 在 `pp512`（两个完整的 256 token chunk，没有填充浪费）下 NPU 达到 **415 t/s**，
对比 OpenVINO-CPU 的 610 与原生 CPU 参照的 570——68%/73%。在负载中计算密集的那一半上，加速器干了它该
干的事。

尚未解释的是绝对效率：1.7 B 模型跑出 415 t/s，约合每个 256 token chunk 870 GFLOP ≈ **约 13 TOPS INT8 里
的 1.4 TOPS 有效算力**。有一个数量级不知去向。

**Decode 才是问题。** NPU `8.3–8.7 t/s`，对比 OpenVINO-CPU 的 `21.7–29.2` 与原生 CPU 参照的 `54.1`：
**比它本该替代的 CPU 慢 6 倍**。按约 3.4 GFLOP/token 折算就是约 0.03 TOPS——比硬件低两个数量级。
不管错的是什么，错就错在这里。

**而 NPU 上短 prompt 的数字毫无意义。** 静态 prefill 图固定为 `GGML_OPENVINO_PREFILL_CHUNK_SIZE` 列
（默认 256），所以 4 个 token 也要付满 256 列的代价，而 llama.cpp 上报的是"有效 token / 墙钟时间"：同样
一个 0.66 s 的 chunk，4 token 时被读成 6 t/s，8 token 时被读成 12 t/s。任何基于短 prompt 的 NPU 对 CPU
比较，测的都是填充。用 `llama-bench -p 512` 或更大；做短 prompt 场景时把 chunk 调小——它是一个直接的
乘数（同时也是图缓存键的一部分，所以每个取值都要预算一次编译）。

decode 差距的候选原因，按怀疑程度排列：

1. 无状态缓存契约——每一步都为 11 层重新绑定并重写 K/V，外加 13 个 conv 状态，进出都作为图的输入输出，
2. 每步的激活量化开销（`NPU_COMPILER_DYNAMIC_QUANTIZATION`），对单个 token 而言，相对极少的算术它是纯开销，
3. 解码形状的图没有设 `optimization-level` / 编译提示，以及 NPUW funcall 粒度——约 1000 节点的图每 token
   执行一次，且每次调用都有提交开销，
4. conv 状态写回被表达成按运行期索引的 `Gather`（形状静态、索引动态 → 设备上没有任何东西能把它优化掉）。

冷编译每图约 36 s；热启动（命中缓存目录）时其中大部分消失，这就是为什么持久的
`GGML_OPENVINO_CACHE_DIR` 是强制要求而不是建议。

**相关的健壮性发现：** 一个越界的 KV 写入索引——例如对 1024 上下文跑 `-p 1024 -n 32`——会让 CPU 插件在
`scatter_update` 的边界检查上失败，而在 NPU 插件上会直接把设备打掉，报 `ZE_RESULT_ERROR_DEVICE_LOST`。
同一个 bug，而在 NPU 上是两种失效模式里更糟的那一种。
