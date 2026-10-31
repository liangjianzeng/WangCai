# 故障排查

我们真正踩过的每一个报错，按它们通常出现的顺序排列，附解决办法。如果你的报错不在这里，请带上
[../CONTRIBUTING.md](../CONTRIBUTING.md) 里要求的材料开一个 issue。

## 构建

### `fatal error C1083: cannot open include file "CL/cl2.hpp"`

来自 `openvino/runtime/intel_gpu/ocl/ocl_wrapper.hpp:50`，由 OpenVINO 后端牵引进来。NPU 构建并不需要 GPU
远程上下文的头文件，但它们是无条件被 include 的。

**解法：** 通过 `tools/bootstrap.ps1` 构建，它会把 [`src/ggml-openvino/`](../src/ggml-openvino/)（含
`ov_opencl_shim.hpp`）安装到钉住版本的 llama.cpp 上——见
[build.md](build.md#the-opencl-header-problem)。如果你能访问那个头文件仓库，直接下 Khronos 头文件也行。

### `ClContext` 构造处 `C2668: ambiguous call to overloaded function`

有人把 `cl_context` 和 `cl_command_queue` 都 typedef 成了 `void*`。而 `ClContext` 的构造函数正是对它们做
重载的。**解法：** 用互不相同的不透明类型（`struct _cl_context *`、`struct _cl_command_queue *`）。shim
里已经这么做了；手写改写 shim 时会踩到。

### `vcvars64.bat` 明明成功了，紧接着却报 `No CMAKE_C_COMPILER could be found`

PowerShell 在 `cmd /c "call vcvars64.bat && cmake ..."` 上把引号内容吃了。**解法：** 把命令放进一个 `.bat`
文件，然后跑 `cmd.exe /c that.bat`。`tools/configure.ps1` 就是这么做的。

### `-- UI: download dist.tar.gz.sha256 ... Timeout was reached` / `HF download failed`

噪音。那是 `llama-server` 的内嵌 web UI 资产，CDN 不可达。构建是成功的，产物可用。以退出码为准，不要看到
"failed" 这个词就当失败。

### `error: invalid argument: -cnv`（或 `-d`）

这个 llama.cpp 版本没有 `-cnv`（chat 是默认行为，`-st` 是单轮），`-d` 也不是一个 flag——设备选择用
`-dev` / `--device`。

### `ninja: build stopped: subcommand failed`，但日志里没有编译错误

多半不是代码问题：你在**跑测还没结束的时候做了构建**。`llama-*.exe` / `llama-*.dll` 被运行中的进程占着，
链接步写不进去。**解法：** 等跑测结束再构建，或者换一条产物输出路径。本项目为此白重建过一次。

## 模型加载

### `tensor 'blk.NN.xxx.weight' data is not within the file bounds, model is corrupted or incomplete`

下载不完整。在调试任何别的东西之前，先把文件大小与来源核对一遍——一个坏掉的 GGUF 能惟妙惟肖地模仿后端
缺陷。

## 设备选择

### `Available devices` 里看不到 NPU

NPU 驱动缺失，或者相对已安装的 OpenVINO 太旧。检查：

```powershell
Get-PnpDevice -Class ComputeAccelerator | Format-Table FriendlyName, Status, InstanceId
```

你要看到 `Intel(R) AI Boost` 处于 `OK` 状态。然后确认 OpenVINO 版本落在驱动支持的范围内，并且运行期
`openvino.dll` 与插件 DLL 都在 `PATH` 上。

### 能跑，但数字长得像 CPU

它其实跑在 CPU 上。用 `--list-devices`、日志里的 backend 那行、以及一次 `GGML_OPENVINO_DUMP_BIN` 比对来
确认——来自两台设备的张量不可能逐位相同。

### 某个 flag 看起来毫无作用

编译图缓存过期了。每种配置都要用一个**全新**的 `GGML_OPENVINO_CACHE_DIR`。第二嫌疑：该变量没有登记进
`ggml-openvino-extra.cpp` 的环境变量表，于是它被读成"未设置"且没有任何警告。

## 图编译

### `Check 'attention_mask_input_correctness' failed at ... scaled_dot_product_attention_shape_inference.hpp:92`

mask 宽度与 K/V 不一致——例如 mask 是 `[1,1,256,1024]` 而 K/V 是 `[1,16,768,128]`。在滑动窗口 + 全局注意力的
混合结构模型上很典型。**解法：** `get_mask_ctx_size()`
（[npu-internals § 2](npu-internals.md#2-hybrid-models-address-two-kv-rings-with-one-mask-tensor)）。

### `Check 'is_dynamic || port_partial_shape == tensor_shape' failed at ... zero_infer_request.cpp:1250: got [1,1,256,1024] expecting [1,1,256,768]`

编译进参数的形状与被绑定的张量不一致。两侧必须由同一个 helper 推导；只改一侧会得到**上面**那条另一个方向
的报错——这个 bug 正是这样被误当成"有进展"的。

### `Check 'idxValue < static_cast<int64_t>(srcDimAxis) && ...' failed at intel_cpu\src\nodes\scatter_update.cpp:915`

一个 KV 写入索引落到了缓存之外。**已于 2026-10-31 修复**：interleaved-SWA 模型的两个同名 KV 写索引输入
（`attn_inp_k_idxs`）在解码器里被按名字合并成一个参数，窗口层于是拿到全量缓存的 cell id（线性长到
`-c`），散射进只有 `n_swa` 大小的环；一旦序列总长超过环长（LFM3 上是 3×256=768）就越界。原生后端没事是
因为它按张量指针而非名字绑定。若看到同样报错而引擎不含本修复，机制与证据见
[status.md 缺陷 3](status.md#3-超出-kv-缓存的序列会把-openvino-后端拖垮--根因已找到并修复2026-10-31)。

### `ZE_RESULT_ERROR_DEVICE_LOST`（`zeCommandQueueExecuteCommandLists`，code `0x70000001`）

同一次越界 KV 写入在 NPU 侧的签名：CPU 插件会失败一条边界检查，而 NPU 插件直接把设备干掉。修复后
`-p 1024 -n 32` 已三设备通过。若仍遇到，先检查 `-c` 与 prompt + 生成长度的关系。

### `ZE_RESULT_ERROR_OUT_OF_HOST_MEMORY` 之后，NPU 转储全 NaN（但文本正常）—— **驱动状态污染**

一次执行期的 `OUT_OF_HOST_MEMORY`（本机：Qwen3-4B 的 prefill 图在 `-c 1024` 下放不下）会把 NPU 驱动
带进一种跨进程存活的状态：之后**所有进程**里，`get_output_tensor()` 式的原始输出回读一律返回 NaN，而
绑定输出缓冲的正常路径（llama.cpp 采样器实际使用的）完全正确。外在表现：生成文本连贯、benchmark 正常，
但 `GGML_OPENVINO_DUMP_BIN` 的 `result_output` 转储全是 NaN，逐设备张量比对全部失真。换引擎 DLL 版本
（旧/新）无效；清 `%LOCALAPPDATA%\Intel\NPU` blob 缓存无效；`pnputil /restart-device`（管理员）能恢复
计算路径，本机上回读路径直到记录时仍未复原，**待重启验证**。处理原则：

1. 怀疑转储时，先看生成文本是否正常——文本正常 + 转储 NaN = 这个状态，转储不可信；
2. `pnputil /restart-device "PCI\VEN_8086&DEV_AD1D*"`（管理员 PowerShell）；
3. 还不行就重启机器。避免在同一驱动状态下跑会触发 OOM 的大模型大上下文组合。

### 编译/执行一夜之间慢了几十倍、随机 `L0 UNINITIALIZED`——**先查主机内存被谁吃了（2026-10-31 教训）**

症状：同一个模型同一个 ctx，昨晚编译 20–40 s、解码 14 t/s；今天编译 30+ 分钟、解码 4 s/token，偶发
`L0 pfnAppendGraphExecute: ZE_RESULT_ERROR_UNINITIALIZED`。排查时的弯路值得记录：设备禁用/启用（D3→D0）、
`pnputil /remove-device` + 重扫描、内核驱动服务重启——**全部无效**；微型 NPU 图（单个 matmul）编译
0.2 s、单次 infer 1 ms，完全健康；原生 CPU 路径 55 t/s，机器不缺算力。真凶：**另一个进程（本机是
iGPU 上的 llama-server，常驻 ~23 GB）把主机内存吃掉，NPU 驱动的主机内存预算随之收缩**——大 ctx 的
编译工作区与 KV 状态落在预算线之下，进入病态慢路径或直接失败。判别方法：把 `-c` 调小（512），
一切恢复正常速度 = 预算问题，不是驱动坏。**不要急着重启机器**，先看 `Get-Process` 的内存大户。

本机的复位工具（免管理员、免重启）：计划任务 `WangCaiNpuReset`（一次性授权创建）+ `D:\llm\npu\npu-reset.bat`
（设备禁用/启用，**只报告不杀进程**）+ `D:\llm\npu\ctrl\npu-probe.ps1`（60 s 探针：缓存图出 1 token，
`WEDGED/SLOW` 即异常）。NPU 侧实验前先跑探针；进程崩溃后先复位再继续，不要在坏状态下做精度测量。


### `-fa 0` 会在同一条 scatter 路径上崩溃

这是 llama.cpp 那边的有意行为：关掉 flash attention 后它把 V 摊成每行一个元素，因为写回只需要一列。不要
去"修"scatter，跑 `-fa 1`。

### 用 `-np 2` 时报 `state is only supported with stateless`

静态路径是单序列的。用 `-np 1`；要在 NPU 上做多序列，得把缓存契约整体重做。

## 执行

### `ZE_RESULT_ERROR_OUT_OF_HOST_MEMORY`（`pfnAppendGraphExecute`，code `0x70000002`）

设在 `NPU_COMPILER_DYNAMIC_QUANTIZATION=NO` 时出现：未量化的图放不进 NPU 的主机侧预算。要么保持动态量化
开启，要么缩小模型 / 上下文。

### 编译期 `core.cpp:120` 抛 `ov::Exception`

插件拒绝了你请求的配置。`NPU_USE_NPUW=NO` 和 `NPUW_DQ=NO,NPUW_DQ_FULL=YES` 都会落到这里——对这个模型而言
压缩权重那条路径是必需的。

### 用 `GGML_OPENVINO_DEBUG_NODE` 时进程在编译期中止

NPU 插件不接受追加的 `Result` 节点。**解法：** 用 `GGML_OPENVINO_DUMP_BIN`，它读的是图本来就产出的输出。

### 崩溃之后日志文件是空的

PowerShell 里内联的 `2>&1 >` 会把 OpenVINO 的异常文本截断。改为经由 `cmd.exe /c "llama-cli ... > log 2>&1"`
重定向。

### NPU 上的 prompt 吞吐看起来惨不忍睹（个位数 t/s）

几乎可以肯定是测量假象，不是结果。静态 prefill 图永远是 `GGML_OPENVINO_PREFILL_CHUNK_SIZE`（256）列宽，
所以 4 个 token 也要付 256 列的钱，而 llama.cpp 上报的是*有效* token 每秒——同样一个 0.66 s 的 chunk 会被
读成约 6 t/s。请用 `llama-bench -p 512`（此时 chunk 才是真的满）来测；对于确实很短的 prompt 场景，把 chunk
调小。绝不要在短 prompt 上比较 NPU 与 CPU 的 prompt t/s：你比的是"有填充"对"无填充"。

### 生成无限重复同一个 token（`>>>>>>>>>>>>>`）

这是权重 / 执行失效的特征，不是采样问题。每次禁用 NPUW 反量化（`NPUW_DQ=NO`、`NPUW_DQ_FULL=YES`、
`NPUW_FOLD=NO`）时它都会出现。恢复默认值。

### CPU 上连贯、NPU 上是垃圾，且不抛异常

就是那个未解决的缺陷——见 [npu-internals § 4](npu-internals.md#4-the-accuracy-gap)。诊断顺序：先确认设备，
然后两台设备都转储并逐 pass 比对（`tools/compare-tensors.ps1`、`tools/top-token.ps1`），最后在 CPU 上用
`GGML_OPENVINO_FORCE_STATIC=1` 做二分。

### **每台**设备（包括原生 CPU）上都是垃圾

你在用裸续写驱动一个 instruct 模型。请用 `llama-cli -st`，让 chat 模板生效。这个一模一样的误报曾经引出
过一次"模型坏了"的弯路。

## 脚本

### 运行 `.ps1` 时出现 `Missing ')' in function call` 或乱码

Windows PowerShell 按 ANSI 解析 `.ps1` 文件，所以非 ASCII 字面量（中文文本、`…`）会把解析器搞坏。脚本请
保持纯 ASCII，非 ASCII 的 prompt 通过 UTF-8 文件用 `-f` 传进去。

### `Cannot overwrite variable IsWindows because it is read-only or constant`

PowerShell 7 把 `$IsWindows`、`$IsLinux`、`$IsMacOS`、`$PSScriptRoot` 等定义为**只读自动变量**，而
PowerShell 是大小写不敏感的，于是一个再普通不过的

```powershell
$isWindows = ($env:OS -eq 'Windows_NT')     # 在 5.1 上能用，在 7 上抛异常
```

能干净解析、在 Windows PowerShell 5.1 上跑得好好的，然后在 `pwsh` 7 下执行的那一瞬间死掉。以
`pwsh -File tools/configure.ps1` 调用时，它表现为一个失败的 CI 步骤，而唯一可见的信息只有
"Process completed with exit code 1"——真正那行被子进程吞掉了。

两条规矩，都由 `scripts` 这个 CI job 强制：

1. 不要用只读自动变量的名字命名变量。用 `$onWindows`，不要 `$isWindows`。
2. CI 要跑的每个脚本都必须在**两个宿主**下都做过冒烟测试——5.1 接受的东西 7 可能拒绝，反之亦然。失败步骤
   会把子进程输出 tee 出来并重新以 `::error::` annotation 抛出，正是这件事让上面这个错误变得可查。

### `Cannot convert value "--parallel" to type "System.Int32"`

同一类坑，但更阴险：**局部变量与参数同名**（大小写不敏感）。

```powershell
param([int]$Parallel)
$parallel = if ($Parallel -gt 0) { "--parallel $Parallel" } else { '--parallel' }   # 给 [int] 参数赋字符串
```

它在解析期就报 MetadataError，一行代码都还没执行。`tools/build.ps1` 曾同时中两次（`$parallel` 与 `$clean`，
对应 `[int]$Parallel` 与 `[switch]$Clean`），于是 CI 在任何一次编译发生之前就死了。规矩同上：局部变量改名
（`$parallelArg`），并且 `scripts` job 会 grep 这类冲突。
