# tools

本项目里有两件事要反复做：在 Visual Studio 环境下构建，以及在受控环境下把模型跑在 NPU 上。这些脚本
把两者封装起来，另外还包括精度工作所依赖的比对工具（comparison harness）。

Windows PowerShell 5.1 与 PowerShell 7 均可使用。**这些文件必须保持纯 ASCII**：PowerShell 5.1 按
ANSI 解析 `.ps1`，源码里只要出现中文字符串字面量或长破折号，解析器就会失败，并给出误导性的
`Missing ')' in function call`。

| 脚本 | 用途 |
|---|---|
| `bootstrap.ps1` | 按钉住的 commit 克隆 llama.cpp，应用 `patches/`，放入 shim |
| `configure.ps1` | 在 `vcvars64` 环境内执行 CMake 配置（Release、Ninja，仅 OpenVINO 后端（backend）） |
| `build.ps1` | 增量构建 `llama-cli llama-completion llama-bench llama-server` |
| `run-npu.ps1` | 在 NPU / OpenVINO-CPU / CPU-static / native CPU 上执行一次受控运行，各自使用独立的缓存目录与日志 |
| `npu-sweep.ps1` | NPU 编译（compile）配置开关的矩阵扫描，每格输出一行 |
| `compare-tensors.ps1` | 对两次 `GGML_OPENVINO_DUMP_BIN` 转储（dump）做逐元素比对 |
| `top-token.ps1` | 每个 pass（一次图执行）的 top-1 token / norm / min / max，用于在不同次运行之间对齐 pass |

所有产物都落在 `tmp/`（已被 git 忽略）下：日志、缓存、转储。

## 首次构建

```powershell
tools\bootstrap.ps1
tools\configure.ps1 -OpenVinoDir D:\ov\openvino\cmake
tools\build.ps1
```

`configure.ps1` 通过 `vswhere` 找到 `vcvars64.bat`，并把真正要执行的命令写进 `tmp\configure.bat`——
在 PowerShell 里内联调用 `vcvars64.bat` 会丢掉 `&&` 链，最终报 "No CMAKE_C_COMPILER could be found"。
如果你的 `ninja.exe` 不在 `PATH` 上，用 `-Ninja` 指向它。

`build.ps1` 写出 `tmp\build.log`，终端只打印错误行，外加那些无害的 embedded-UI 警告。

## 运行

```powershell
# on the NPU
tools\run-npu.ps1 -Model models\LFM3-1.7B-Q4_K_M.gguf -PromptFile prompts\zh.txt -N 32 -Ctx 1024

# the same graph, static path, on the CPU (seconds instead of a 36 s NPU compile)
tools\run-npu.ps1 -Model models\LFM3-1.7B-Q4_K_M.gguf -PromptFile prompts\zh.txt -Backend static

# reference: ggml CPU, no OpenVINO at all
tools\run-npu.ps1 -Model models\LFM3-1.7B-Q4_K_M.gguf -PromptFile prompts\zh.txt -Backend native

# a compile-flag experiment, with its own cache dir and dump directory
tools\run-npu.ps1 -Model models\LFM3-1.7B-Q4_K_M.gguf -PromptFile prompts\zh.txt `
    -Overrides 'NPUW_FOLD=NO' -CacheTag nofold -DumpBin tmp\dumps\nofold
```

每次运行打印一个块：

```
### [npu] backend=npu overrides='' elapsed=51s   log=tmp\run_npu_npu.log
    MASK W ov-mask: name=attn_inp_kq_mask ne=[256,2,1,1] is_swa=1 -> mask_kv=768 | ctx=1024 ctx_swa=768 chunk=256
    TEXT 用一句话介绍长城。 万里长城是中国古代的军事防御工程…
    PERF eval time = 0.86 seconds / 7 tokens | 8.14 tokens per second
```

`-Backend` 是最关键的维度：`npu`（静态图路径，NPU 插件）、`ovcpu`（动态图路径，结果自洽的参考基准）、
`static`（在 CPU 上走静态图路径——图转换缺陷会在这里复现，插件缺陷不会）、`native`（完全不使用
OpenVINO）。

## 扫描 NPU 编译开关

```powershell
tools\npu-sweep.ps1 -Model models\LFM3-1.7B-Q4_K_M.gguf -PromptFile prompts\zh.txt
# or your own matrix
tools\npu-sweep.ps1 -Model models\LFM3-1.7B-Q4_K_M.gguf -Cases @(
    @{ Label = 'base';    Overrides = '' },
    @{ Label = 'chunk128'; Extra = @{ GGML_OPENVINO_PREFILL_CHUNK_SIZE = '128' } },
    @{ Label = 'nofold';  Overrides = 'NPUW_FOLD=NO' }
)
```

每个格子都使用相互隔离的 `GGML_OPENVINO_CACHE_DIR`。这不是为了好看：复用编译缓存会让一个本来有效的
开关看起来毫无作用。

## 对比两个设备

```powershell
tools\run-npu.ps1 -Model ... -Backend static -DumpBin tmp\dumps\cpu -Label cpu
tools\run-npu.ps1 -Model ... -Backend npu    -DumpBin tmp\dumps\npu -Label npu

# 1. align the passes first
tools\top-token.ps1 -Dir tmp\dumps\cpu
tools\top-token.ps1 -Dir tmp\dumps\npu

# 2. then compare
tools\compare-tensors.ps1 -A tmp\dumps\cpu -B tmp\dumps\npu
tools\compare-tensors.ps1 -A tmp\dumps\cpu -B tmp\dumps\npu -OnlyMismatched -Top 8
```

在第 2 步之前务必先做第 1 步。不同次运行的 pass 数量并不同，拿一个设备的第 N 个 pass 去和另一个设备的
第 N 个 pass 比对，得到的只是看似确凿的谬误。`compare-tensors.ps1` 读取每个转储文件旁同名的 `.txt`
旁文件来确定元素类型（支持 f32 与 f16；其他类型按文件名跳过，而不会被悄悄读错）。

### 按行模式，以及整块 KV 对比为何是个陷阱

KV 缓存（KV cache）张量的形状是 `[1,1,ctx,heads*head_dim]`：行对应位置，而一个分块（chunk）只写入它
被分配到的那些行。最后一个已写入位置之后的所有内容，保留的都是缓冲区里原本残留的值——新分配的内存上
两侧往往都是零值。对这一区域做整张量统计并不构成测量：

```
cache_v_l20   cosine=0.135  maxDiff=0.0000      # both sides zero: "0.135" is 0/0, not divergence
cache_k_l2    cosine=0.998  maxDiff=45091        # one row disagrees, the rest is padding
```

`-RowSize` 改为逐行比对——一行 = 一个位置 = `n_kv_heads × head_dim`（LFM3-1.7B 为 512），并打印每行的
cosine、最大绝对差，以及 `leading-clean`：从首行起有多少行在 `-RowTol`（默认 0.05）之内一致。

```powershell
# rows 0..25 of the K cache written by the first prefill chunk
tools\compare-tensors.ps1 -A dbg\cpu\prefill_0_cache_k_l2.bin -B dbg\npu\prefill_0_cache_k_l2.bin `
    -RowSize 512 -MaxRows 26
```

先看 `leading-clean`：如果该分块写入了 N 行，那才是唯一值得读的区域；一个张量若干净行恰好止步于写入
边界，它说明的是写入问题，而不是算术问题。配合 `-MaxElements` 使用，可让扫描（以及 f16 解码（decode））
的开销保持在有界范围内。
