# 基准测试

以下均为实测数字，并附精确的测试条件。某个数字本身不可靠时，文中会直接写明。

## 被测机器

| | |
|---|---|
| SoC | Intel Core Ultra 9 275HX |
| NPU | Intel(R) AI Boost — `Intel(R) AI Boost (NPU 3720)`, class `ComputeAccelerator`, `PCI\VEN_8086&DEV_AD1D` |
| llama.cpp 可见线程数 | 24 |
| 内存 | 32 GB |
| 操作系统 | Windows 11 |
| OpenVINO | 2026.4.1 |
| llama.cpp | `abb76ab` + WangCai 补丁集 |

## 模型

LFM3-1.7B `Q4_K_M`，1049 MB。24 层 = 13 个门控短卷积（short conv）+ 5 个滑动窗口注意力（SWA）@256 + 6 个全局注意力。隐藏层维度 2048，16 个 query 头，4 个 KV 头，head_dim 128，词表 128000。
每个循环层的卷积状态：`6 × 2048 = 12288`。

## 命令

```powershell
$env:GGML_OPENVINO_DEVICE = 'NPU'
$env:GGML_OPENVINO_CACHE_DIR = 'D:\npu_cache'
.\build\bin\llama-cli.exe -m models\LFM3-1.7B-Q4_K_M.gguf `
    -c 1024 -n 32 --temp 0 --seed 42 -fa 1 -np 1 -dev OPENVINO3 -st -p '用一句话介绍长城。'
```

`-fa 1` 与 `-np 1` 在 NPU 上是硬性要求，不是可选偏好。

## 结果

### 预填充（prefill）—— 在真实 token 数下实测（`llama-bench`、`-r 1`、`-fa 1`）

| 测试 | NPU（静态图） | OpenVINO CPU（动态） | `ggml` CPU 参考 |
|---|---:|---:|---:|
| `pp32` | 54.9 t/s | 335 t/s | 447 t/s |
| `pp128` | 219 t/s | 567 t/s | 546 t/s |
| `pp512` | **415 t/s** | 610 t/s | 570 t/s |
| `pp1024` | `ZE_RESULT_ERROR_DEVICE_LOST`（见下文） | `scatter_update` 检查（见下文） | 572 t/s |
| `tg32` | 此规模下未达到 | — | 53.4 t/s |

**请以这张表为准，而不是下面那张短提示词的表。**在 `pp512` 上——两个填满的 256 token 块，也就是没有 padding 浪费——NPU 达到原生 CPU 参考的 73%、OpenVINO-on-CPU 的 68%。NPU 并*不是*不擅长预填充；本文早前那个「6–12 t/s」的数字，是固定宽度静态图下提示词吞吐量的报告方式造成的假象（见下一节）。

不过预填充的剩余空间确实存在：1.7 B 模型上的 415 t/s，相当于每个 256 token 块约 870 GFLOP，即 **~13 TOPS INT8 里只跑出 1.4 TOPS 有效算力**。某处白白丢掉了大约一个数量级的性能——候选原因见 [npu-internals.md § 6](npu-internals.md#6-performance-observations)。

### 为什么短提示词在 NPU 上报出的数字近乎为零

静态预填充图的宽度恒为 `GGML_OPENVINO_PREFILL_CHUNK_SIZE = 256` 列。一个 4 token 的提示词照样要为 256 列付费，而 llama.cpp 上报的是 `实际处理的 token 数 / 墙钟时间`：

| 样本 | 上报的提示词 t/s | 每个 256 列块的墙钟时间 | 有效 token |
|---|---:|---:|---|
| 4 token 提示词 | 5.99 | ~670 ms | 4 / 256 = 1.6% |
| 8 token 提示词 | 12.19 | ~656 ms | 8 / 256 = 3.1% |

同一张图、同样的开销，有效率 1.6% → 上报的数字比这张图自身的吞吐量（约 380 t/s 的列）低 60 倍。**绝不要在短提示词上拿 NPU 的提示词 t/s 去和 CPU 的提示词 t/s 对比**：CPU 路径没有列 padding，这种比较测的是 padding，而不是硬件。要比就比 N ≥ 块大小的 `llama-bench pp<N>`，或者比每个块的墙钟时间。

对调优的推论：如果你的负载以短提示词为主，就把 `GGML_OPENVINO_PREFILL_CHUNK_SIZE` 调低（靠近典型提示词长度）——它对短提示词延迟是一个直接的乘数。它是图缓存键的一部分，因此每个取值都要付出一次编译（compile）。

### 解码（decode）

| | t/s |
|---|---:|
| **NPU（静态图）** | **8.3 – 8.7** |
| OpenVINO CPU，动态 | 21.7 – 29.2 |
| `ggml` CPU 参考 | 54.1 |

解码才是这个项目真正的失血点，而且相对参考实现落后 6 倍。1.7 B 参数意味着约 3.4 GFLOP/token，于是有效算力只有约 0.03 TOPS——比加速器低两个数量级。这是应当攻坚的数字（路线图 Phase 2），而不是预填充。

一次性开销：

| | |
|---|---|
| NPU 图冷编译（两张图） | 36.4 s |
| 以 `NPUW_FOLD=NO` 重新编译 | 383 s |
| 带着已填充的 `GGML_OPENVINO_CACHE_DIR` 热启动 | 上述开销基本消失 |

## 这些数字*不能*证明什么

- **单个数据点。**三个后端、一台机器、一个模型、`-r 1`，没有预热协议，也没有置信区间。`llama-bench` 打印 `± 0.00`，是因为只重复了一次。只能看数量级和方向；在别处引用之前先用 `-r 3` 重跑。
- **NPU 解码这个数字是可用值，不是调优后的值。**在 1.7 B 模型上比 CPU 慢 6 倍，说明我们的静态路径或编译配置里有问题，而不是加速器已经无计可施——而预填充达到参考的 73%，证明该插件并非处处无望。见 [npu-internals.md § 6](npu-internals.md#6-performance-observations)。
- **`pp1024` 的失败不是吞吐量结果。**它们是越界的 KV 缓存（KV cache）写入索引：在 `llama-bench` 默认的 `-c -1`（模型上下文 1024）下，`-p 1024 -n 32` 需要 1056 个缓存槽位。同样的形状在 1024 上崩溃，在同一设备上 512 却跑得干净。在 CPU 插件上，它表现为 `scatter_update` 的边界检查；在 NPU 插件上，坏索引会拖着设备一起倒下，报 `ZE_RESULT_ERROR_DEVICE_LOST`——同一个 bug，故障模式严格更差，本身就值得单独向上游提 issue。`-c` 必须始终 ≥ `-p` + `-n`。
- **连贯性与吞吐量是在同一批运行里测得的，但两者互相独立**：上面的 NPU 数字是在精度缺陷仍然存在时产出的，这对计时的影响并不明显（同一张图、同样的算子数），但也意味着缺陷修好之后，两个数字都会变动。

## 复现

```powershell
tools\run-npu.ps1 -Model models\LFM3-1.7B-Q4_K_M.gguf -PromptFile prompts\zh.txt -N 32 -Ctx 1024
tools\npu-sweep.ps1 -Cases @(
    @{ Label = 'default';  Overrides = '' },
    @{ Label = 'chunk64';  Extra = @{ GGML_OPENVINO_PREFILL_CHUNK_SIZE = '64' } }
)
```

每个单元格都有自己独立的 `GGML_OPENVINO_CACHE_DIR`，打印一行结果，并且绝不会悄悄复用另一个单元格的已编译图。

吞吐量矩阵优先使用 `llama-bench`：

```powershell
.\build\bin\llama-bench.exe -m models\LFM3-1.7B-Q4_K_M.gguf -p 512 -n 128 -r 3 -fa 1 -dev OPENVINO3
```

## 报告一个数字时

需要包含：机器 + NPU 驱动版本、OpenVINO 版本、llama.cpp commit、完整命令行、`-c`、`-b`、`GGML_OPENVINO_PREFILL_CHUNK_SIZE`、提示词 token 数、生成 token 数、编译图缓存（compile cache）是冷还是热，以及输出是否连贯。少任何一项，都不能与上表比较。
