# 环境变量

所有变量都在**后端（backend）初始化时读取一次**，来源是 `ggml-openvino-extra.cpp` 中的一张注册表。
下面两条后果，各自都实际消耗过调试时间：

- 不在这张表里的变量会被读成**未设置，而且没有任何报错**。如果你新增了一个变量却看起来毫无作用，先检查注册。
- 取值无法在进程运行中途改变；请另起一个进程。

`GGML_OPENVINO_CACHE_DIR` 是编译（compile）图缓存的键。**每套配置使用一个全新目录** ——
在改动开关后沿用同一个目录，会悄悄复用按旧设置编译出的图，让一个本来可用的开关看起来失效。

## 设备选择

| 变量 | 取值 | 说明 |
|---|---|---|
| `GGML_OPENVINO_DEVICE` | `CPU`, `GPU.0`, `GPU.1`, `NPU` | 决定后端指向已注册的哪一个 `OPENVINO<n>` 设备。与命令行上的 `-dev OPENVINO<n>` 配合使用。 |
| `GGML_OPENVINO_FORCE_STATIC` | `0`/`1` | 在**任意设备上运行静态图（static graph，NPU 形状）代码路径**。本项目中最有用的一个变量：静态模式下的 bug 在 CPU 上几秒即可复现。 |
| `GGML_OPENVINO_ENABLE_CACHE` / `GGML_OPENVINO_DISABLE_CACHE` | `0`/`1` | 解码（decode）层的图缓存。 |
| `GGML_OPENVINO_COMPILED_MODEL_CACHE_DIR` / `_ONLY` | 路径 / `0`/`1` | OV 的编译模型缓存；`_ONLY` 表示不再重新编译而是直接失败，这正是证明某个图已被缓存住的办法。 |

## 执行模型

| 变量 | 取值 | 说明 |
|---|---|---|
| `GGML_OPENVINO_PREFILL_CHUNK_SIZE` | 整数，默认 `256` | 每个静态预填充（prefill）分块的 token 数；必须 ≤ `-b`。同时也是图缓存键的一部分。 |
| `GGML_OPENVINO_STATEFUL_EXECUTION` | `0`/`1` | 基于 OV `Variable` 的缓存（无需每步重新绑定）。**仅限 CPU/GPU** —— 在 NPU 上会被强制关闭。 |
| `GGML_OPENVINO_MANUAL_GQA_ATTN` | `0`/`1` | 绕过 `SDPA`，用基本算子（op）组合出 GQA 注意力。GPU 路径默认使用；**NPU 上不可行（P14c 定案，2026-11-04）**：VCL 编译器拒绝组合图（`ZE_RESULT_ERROR_INVALID_ARGUMENT`），4B A/B 四臂全灭于编译。 |
| `GGML_OPENVINO_ROPE_F16` | `0`/`1`（默认 `0`） | **由 WangCai 新增（P14d）。** 无状态且 f16 的 rope 全链路在 f16 域计算（cos/sin 表在共享链内转一次），省掉被钉在 Shave 上的 f32 往返。**A/B 已证伪（2026-11-04）**：两模型全轴持平略负（4B tg 8.6 vs 8.96），默认保持 OFF；保留开关供 rope 相关实验复现。 |
| `GGML_OPENVINO_KV_HOST_WRITE` | `0`/`1`（**默认开**，`0` 显式关闭） | **由 WangCai 新增（P14e，2026-11-05 转默认）。** 静态 NPU decode 图的 FULL-attention 层 KV 行写出图外：set_rows 摘掉 ScatterNDUpdate、attention 用 Concat 补当前列、执行器在 infer 后 memcpy 行到 cache（行号 = idx % rows）。**严格同 cache A/B 实锤（2026-11-05）**：4B tg128 8.89 → 12.26 t/s = **+38% 纯摘链增益**（vs P11 基线 6.89 = **+78%**），prefill 双向持平，1.7B 双向回归绿（混合 SWA 模型的 SWA 环写保持链式）。解码器 all-or-nothing 门控保证不合格图完全走链式。**默认翻转使 extra_cfg blob 键变化——旧编译缓存失效一次（冷编译）**。 |
| `GGML_OPENVINO_MOE_NPU` | `0`/`1`（默认 `0`） | **由 WangCai 新增（P15）。** 在 NPU 上也注册 MoE 融合 pass（FuseMoeRouter/FuseMoeCompressed）。NPUW 能编译融合图（无崩溃），但 Spark-X2.6-4B 是 dense 模型（GGUF 无 expert 键），pass 无匹配对象——**当前模型集上为 no-op**，保留给真 MoE 模型。 |
| `GGML_OPENVINO_NATIVE_SOFTPLUS` | `0`/`1` | 使用原生 `SoftPlus`，还是组合式实现。 |
| `GGML_OPENVINO_DISABLE_REMOTE_OUTPUTS` | `0`/`1` | 停止通过 remote tensor 把输出别名到 ggml 缓冲区。 |
| `GGML_OPENVINO_LOG_UNSUPPORTED_OPS` | `0`/`1` | 记录无法降级（lowering）的算子，而不是以晦涩的方式失败。 |
| `GGML_OPENVINO_REQUANT_KQUANT` | `native`, `q4_sym128[_all]`, `q4_asym64[_all]` | K-quant 权重的重量化（requant）目标。**未设置时，NPU 会把每一个权重都强制改为分组 4 bit，而 CPU 保留原生布局** —— 因此同一个 GGUF 在 NPU 上跑和在 CPU 上跑，并不是同一个模型。这里只要设了任何值，就会同时关掉 NPU 上的那项覆盖，这也正是能做 CPU/NPU 同条件对比的原因（`q4_sym128_all` 在 CPU 上复现 NPU 的策略）。`native` 并不是在 NPU 上绕开该问题的办法：原生 Q4_K 在那里编译不过（`vpux-compiler: Channels count of input tensor shape and filter shape must be the same: 0 != 64`）。 |

## NPU 插件配置

当设备为 NPU 时，由后端设置的默认值：

```
NPU_COMPILER_DYNAMIC_QUANTIZATION = YES      NPUW_FOLD          = NO（2026-11-04 起，见下）
NPU_USE_NPUW                      = YES      NPUW_WEIGHTS_BANK  = shared
NPUW_DEVICES                      = NPU      NPUW_FUNCALL_FOR_ALL = YES
NPUW_DQ                           = YES      NPUW_FUNCALL_ASYNC = YES
NPUW_DQ_FULL                      = NO       NPUW_CACHE_DIR     = <GGML_OPENVINO_CACHE_DIR>
```

`NPUW_FOLD=NO`（2026-11-04 性能轮定案）：权重折叠在 NPU 上把 decode/prefill 步序列化成
eltwise/concat 算子汤——关掉后 1.7B `pp512 406→778 t/s / tg 14.1→22.5`、4B
`pp2048(chunk256) 42.8→86 / tg 6.9→8.9`，三问验收两模型全绿。代价是冷编译慢 ~10×
（blob 缓存吸收）；用 `GGML_OPENVINO_NPU_COMPILE_OVERRIDES=NPUW_FOLD=YES` 可恢复旧行为。

| 变量 | 取值 | 说明 |
|---|---|---|
| `GGML_OPENVINO_NPU_COMPILE_OVERRIDES` | `KEY=VALUE,KEY=VALUE` | **由 WangCai 新增。** 在运行时增补或替换上面这些条目。每条覆盖都会在启动时写入日志。务必与一个全新的缓存目录配套使用。 |
| `GGML_OPENVINO_NPU_COMPILE_CONFIG` | 字符串 | 原样转发为 `NPU_COMPILATION_MODE_PARAMS`（只涉及编译器内部的旋钮 —— 它无法触及顶层的 NPUW 键，这正是上面那个变量存在的理由）。 |

文中这些开关的效果记录在
[npu-internals.md § NPUW 扫描](npu-internals.md#the-npuw--quantization-lever-sweep)。

## 诊断

| 变量 | 取值 | 说明 |
|---|---|---|
| `GGML_OPENVINO_DUMP_BIN` | 目录 | **由 WangCai 新增。** 逐输出转储（dump）原始数据（`<tag>_<seq>_<name>.bin`，外加一个带 shape/type 的 sidecar 文件），静态与动态两条路径都支持。读取的是已有输出，因此在 NPU 上安全。用 `tools/compare-tensors.ps1` 做比对，用 `tools/top-token.ps1` 对齐各遍输出。 |
| `GGML_OPENVINO_MASK_MODE` | `0`/`1` | **由 WangCai 新增。** 静态预填充改为按 token 位置构造掩码，而不是用 llama.cpp 给出的掩码。用于把掩码内容的 bug 与执行的 bug 区分开。 |
| `GGML_OPENVINO_DEBUG_OUTPUT` | `0`/`1` | 为每个输出打印 `First/Min/Max/Mean`。适合当作指纹使用；**对行级错误有误导性** —— 见 npu-internals。 |
| `GGML_OPENVINO_DEBUG_INPUT` | `0`/`1` | 针对绑定输入同上；这是证明两个设备收到完全相同张量的手段。 |
| `GGML_OPENVINO_DEBUG_NODE` | `name1,name2` | 为中间张量追加 `Result` 节点。**在 NPU 上会中止进程** —— 请改用 `DUMP_BIN`。 |
| `GGML_OPENVINO_DUMP_CGRAPH` | `0`/`1` | 把 `cgraph_ov.txt`（带 shape 与后端分配的 ggml 图）写入当前目录。 |
| `GGML_OPENVINO_DUMP_IR` | `0`/`1` | 序列化 naive 路径的 OpenVINO IR。 |
| `GGML_OPENVINO_PROFILING` | `0`/`1`/`2` | 分阶段耗时；`2` 还会启用 OV 的逐层 profiling。 |
| `GGML_OPENVINO_PRINT_CGRAPH_TENSOR_ADDRESS` | `0`/`1` | 张量地址，用于别名（aliasing）排查。 |

## 完整示例：比较两个设备

```powershell
foreach ($cfg in @(
        @{ n = 'cpu'; dev = 'OPENVINO0'; ov = 'CPU'; st = '1' },   # static path on CPU
        @{ n = 'npu'; dev = 'OPENVINO3'; ov = 'NPU'; st = '' })) {
    Get-ChildItem Env:GGML_OPENVINO_* | ForEach-Object { Remove-Item "Env:$($_.Name)" }
    $env:GGML_OPENVINO_DEVICE     = $cfg.ov
    $env:GGML_OPENVINO_CACHE_DIR  = "D:\cache\$($cfg.n)"          # fresh per config
    $env:GGML_OPENVINO_DUMP_BIN   = "D:\dumps\$($cfg.n)"
    if ($cfg.st) { $env:GGML_OPENVINO_FORCE_STATIC = '1' }
    .\build\bin\llama-cli.exe -m models\LFM3-1.7B-Q4_K_M.gguf -c 1024 -n 5 --temp 0 --seed 42 `
        -fa 1 -dev $cfg.dev -st -p '用一句话介绍长城。'
}
tools\compare-tensors.ps1 -A D:\dumps\cpu -B D:\dumps\npu
```

在任何数字可信之前，先逐遍比对 —— 见 `tools/top-token.ps1`。
