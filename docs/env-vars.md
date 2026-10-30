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
| `GGML_OPENVINO_MANUAL_GQA_ATTN` | `0`/`1` | 绕过 `SDPA`，用基本算子（op）组合出 GQA 注意力。 |
| `GGML_OPENVINO_NATIVE_SOFTPLUS` | `0`/`1` | 使用原生 `SoftPlus`，还是组合式实现。 |
| `GGML_OPENVINO_DISABLE_REMOTE_OUTPUTS` | `0`/`1` | 停止通过 remote tensor 把输出别名到 ggml 缓冲区。 |
| `GGML_OPENVINO_LOG_UNSUPPORTED_OPS` | `0`/`1` | 记录无法降级（lowering）的算子，而不是以晦涩的方式失败。 |
| `GGML_OPENVINO_REQUANT_KQUANT` | `native`, `q4_sym128[_all]`, `q4_asym64[_all]` | K-quant 权重的重量化（requant）目标。**未设置时，NPU 会把每一个权重都强制改为分组 4 bit，而 CPU 保留原生布局** —— 因此同一个 GGUF 在 NPU 上跑和在 CPU 上跑，并不是同一个模型。这里只要设了任何值，就会同时关掉 NPU 上的那项覆盖，这也正是能做 CPU/NPU 同条件对比的原因（`q4_sym128_all` 在 CPU 上复现 NPU 的策略）。`native` 并不是在 NPU 上绕开该问题的办法：原生 Q4_K 在那里编译不过（`vpux-compiler: Channels count of input tensor shape and filter shape must be the same: 0 != 64`）。 |

## NPU 插件配置

当设备为 NPU 时，由后端设置的默认值：

```
NPU_COMPILER_DYNAMIC_QUANTIZATION = YES      NPUW_FOLD          = YES
NPU_USE_NPUW                      = YES      NPUW_WEIGHTS_BANK  = shared
NPUW_DEVICES                      = NPU      NPUW_FUNCALL_FOR_ALL = YES
NPUW_DQ                           = YES      NPUW_FUNCALL_ASYNC = YES
NPUW_DQ_FULL                      = NO       NPUW_CACHE_DIR     = <GGML_OPENVINO_CACHE_DIR>
```

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
