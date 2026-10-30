# 架构

一批 token 是怎么变成 `Intel(R) AI Boost` 上的工作的，以及整个栈里每一块各自负责什么。

```
┌──────────────────────────────────────────────────────────────────────┐
│ llama.cpp   tokenizer · KV/conv-cache allocation · graph builder ·   │
│             sampler · chat template                                  │
└───────────────────────────────┬──────────────────────────────────────┘
                                │  ggml_cgraph  (nodes = GGML_OP_*)
┌───────────────────────────────▼──────────────────────────────────────┐
│ ggml-backend  ·  ggml_backend_sched assigns each node a backend      │
│   └── ggml_backend_openvino  (registered as OPENVINO0..N)            │
└───────────────────────────────┬──────────────────────────────────────┘
                                │  graph_compute(cgraph)
┌───────────────────────────────▼──────────────────────────────────────┐
│ ggml/src/ggml-openvino/                                              │
│   utils.cpp              graph lifecycle, input binding, output copy │
│   ggml-decoder.{h,cpp}   ModelParams/ComputeParams, input shapes     │
│   openvino/op_table.cpp  GGML_OP_* → translate_* registry            │
│   openvino/op/*.cpp      per-op lowering into the OpenVINO frontend  │
│   openvino/translate_session.cpp  builds the Result set              │
│   model-cache.cpp        compiled-graph cache key                    │
└───────────────────────────────┬──────────────────────────────────────┘
                                │  ov::Model (static shapes on NPU)
┌───────────────────────────────▼──────────────────────────────────────┐
│ OpenVINO NPU plugin · NPUW (weight compression, on-device dequant) · │
│ LEIF compiler → execution on AI Boost                                │
└──────────────────────────────────────────────────────────────────────┘
```

## 走的是哪条路径

`ov_graph_compute()` 在两个实现之间做选择：

```cpp
const auto is_static = ggml_openvino_is_npu() || ggml_openvino_getenv_int("GGML_OPENVINO_FORCE_STATIC");
```

| | 动态路径 | 静态路径 |
|---|---|---|
| 谁在用 | CPU、GPU | **NPU**，或任何设了 `GGML_OPENVINO_FORCE_STATIC=1` 的设备 |
| 形状 | 尽量用 `-1` | 每个维度在编译期都是具体的 |
| 每个模型的图数量 | 一张，复用 | **两张**：分块 prefill（`n_tokens = chunk`）与 decode（`n_tokens = 1`） |
| KV / conv 状态 | 原地读写，或在有状态模式下作为 OV `Variable` | 每次调用都作为普通输入绑定、作为输出返回 |
| `n_seq` | 可以 > 1 | 只能是 1 |
| bf16 | 支持 | 在调度阶段被拒绝 |

值得研究的是静态路径，而 `GGML_OPENVINO_FORCE_STATIC=1` 配 `GGML_OPENVINO_DEVICE=CPU` 就能在 CPU 上跑它
——同样的代码，不用付 NPU 编译。就靠这一个开关，才能把"图构建 bug"与"插件 bug"区分开；本项目无时无刻
不在用它。

## 静态路径的生命周期

1. `compute_llm_params()` 从 cgraph 推出 `ModelParams`（上下文长度、每序列与滑动窗口的环长、头数、递归
   状态尺寸、滑动窗口层列表）与 `ComputeParams`（活跃序列数、输出长度、位置）。
2. 在*同一张* cgraph 上构造两个 `GgmlOvDecoder`——`is_prefill = true` 用配置的 chunk 尺寸，
   `is_prefill = false` 用 1 个 token。每个 decoder 对每个图输入只回答一个问题：*这个参数的形状是什么？*
3. 两张图都被编译（或从编译图缓存取出，缓存键由图拓扑、设备、静态/有状态标志与 chunk 尺寸决定——见
   `model-cache.cpp`），然后包进可复用的 `ov::InferRequest`。
4. 每次调用时，输入由 `get_ov_input_tensor_static_prefill(decoder, name, chunk)` /
   `get_ov_input_tensor_static_decode(decoder, name)` 生成；它们负责把 llama.cpp 那种即时、尺寸动态的
   缓冲区，变成编译后的图所要求的定长张量。
5. `infer()`，然后把输出拷回 `create_ov_output_tensor()` 绑定的 ggml 缓冲区。

### 绑定层必须"无中生有"造出什么

编译后的图要求每样东西都正好是 `chunk_size` 份。而 llama.cpp 交过来的是 `n_valid` 个 token。所以剩下的
都要绑定层自己造，而其中任何一处都是 bug 的藏身之地：

| 输入 | 静态形状（LFM3-1.7B，chunk 256） | 填充规则 |
|---|---|---|
| `inp_tokens` | `[1,1,1,256]` | 取 chunk 切片；有效长度记在 `chunk_valid_len` |
| `inp_pos` | `[1,1,1,256]`（mRoPE 时按平面 ×） | 取 chunk 切片，然后**用 `last+1, last+2, …` 补齐** |
| `attn_inp_k_idxs` / `v_idxs`（KV 写索引） | `[1,1,1,256]` | 逐元素 `cache_idx % chunk_size` |
| `attn_inp_kq_mask` | `[1,1,256,ctx]` = `[1,1,256,1024]` | llama.cpp 的 mask 右侧补 −∞；对角线自己那格清零 |
| `attn_inp_kq_mask_swa` | `[1,1,256,ctx_swa]` = `[1,1,256,768]` | 同上，但按**环**宽度 |
| `cache_r_l*`（conv 状态） | `[1,1,1,12288]` | 状态流 `[前 6 列 │ token]`，在 `chunk_valid_len` 处 gather 窗口 |
| `chunk_valid_len` | `[1]` i64 | `min(chunk, input_len − chunk·i)` |
| `cache_rs_reset_len` | `[1]` | 第一个 chunk 之后强制为 0，否则后面的 chunk 会把已累计的状态抹掉 |

用 `last+1` 补齐位置、以及让补齐行的 softmax 保持有限值，这两条都是"承重墙"：一个被全遮住的补齐行会把
`softmax` 算成 `0/0`，而那个 NaN 会顺着递归状态的 gather 一路带进之后的每一步。

## 算子降级

`openvino/op_table.cpp` 把每个 `GGML_OP_*` 映射到一个翻译器；未注册的算子会在图构建期直接失败，而不是
悄悄放过。对混合结构模型要紧的是这些：

| ggml 算子 | 降级为 | 说明 |
|---|---|---|
| `GGML_OP_SSM_CONV` | `ov::op::v1::GroupConvolution`（depthwise） | 因果左补齐，kernel = `d_conv`（LFM3：7 → 状态宽度 6），groups = 通道数 |
| `GGML_OP_FLASH_ATTN_EXT` | `ov::op::v1::SDPA`（opset 13） | mask 宽度必须与 K 一致；见 `trim_mask_to_kv()`；`GGML_OPENVINO_MANUAL_GQA_ATTN` 可绕开 SDPA |
| `GGML_OP_SET_ROWS` | `ScatterUpdate` / `ScatterElementsUpdate` | KV 写入路径；对关闭 SDPA 时 llama.cpp 选定的 V 布局很敏感 |
| `GGML_OP_CPY` | gather/slice/concat 方案 | 同时充当递归状态的写回；由内部 `op_case` 分类（单槽赋值、切片赋值、conv 窗口） |
| `GGML_OP_RMS_NORM` | `Multiply/ReduceMean/Sqrt/Divide` 链 | `GGML_OPENVINO_*` 没有把它提升到 f32 |
| `GGML_OP_MUL_MAT` | `MatMul`（NPUW 下走 weights-bank 路径） | 重量化权重那条路径就在这里 |

`GGML_OP_SSM_CONV` 的支持上游早就有了——这一点值得明说，因为"NPU 后端没有 conv 状态算子"这个想当然的
假设，足够让一个项目白烧一周。它就是以 depthwise 分组卷积实现的，并没有缺。

## 权重

`create_weight_nodes()` 遍历图，把权重实体化为 OpenVINO 的常量或参数，并可能做重量化。策略按设备而不同：

| 权重 | CPU / GPU | **NPU** |
|---|---|---|
| `token_embd.weight` | Q8_0_C | 若为 Q6_K 则 F16，否则 Q8_0_C |
| `output.weight` | Q8_0_C | Q8_0_C |
| 其余全部 | 原生 `Q4_K`（group 32，f16 scale + zero point） | **`Q4_0_128`**（group 128，对称，无 zero point） |

再叠加 NPUW 把权重以压缩形态留在设备内（`NPUW_DQ`、`NPUW_WEIGHTS_BANK=shared`），以及 NPU 编译器对激活
做量化（`NPU_COMPILER_DYNAMIC_QUANTIZATION=YES`）。这些就是精度/吞吐的权衡旋钮，也正是当前的主攻方向：
[npu-internals.md](npu-internals.md#the-accuracy-gap)。

## 值得背下来的约束

| 约束 | 后果 |
|---|---|
| 只支持静态形状 | 每个可变维度都必须由绑定层造出来 |
| NPU 上缓存无状态 | 缓存每次调用既是输入又是输出 → 每步都有带宽代价 |
| `n_seq = 1` | `-np 1`；多槽位在编译之前就被拒绝 |
| 没有 bf16 | bf16 权重/激活在调度阶段就被拒绝 |
| 追加图输出会让插件中止 | 用 `GGML_OPENVINO_DUMP_BIN`，不要用 `GGML_OPENVINO_DEBUG_NODE` |
| 每图冷编译约 36 s | 一定要配缓存目录；每个实验留一个独立目录 |

## 接下来读什么

- 那些难啃的部分，附测量：[npu-internals.md](npu-internals.md)
- 每一个可调开关：[env-vars.md](env-vars.md)
- 按报错文本查失效模式：[troubleshooting.md](troubleshooting.md)
