# 补丁

WangCai 对上游代码的全部改动都集中在这里，以一组针对固定（pinned）llama.cpp commit 的补丁集
形式存在。把它们放在 vendored 目录树之外，这个 fork 才能保持为一份干净的检出（checkout），
差异（delta）也才保持可评审。

| 产物 | 基线 | 规模 |
|---|---|---|
| `0001-ggml-openvino-npu-adaptation.patch` | llama.cpp `abb76ab380c7f3f731e365a859fb4cc64e939bb8` | 7 个文件，+213 / −8 |
| `ov_opencl_shim.hpp` | 新文件 → `ggml/src/ggml-openvino/ov_opencl_shim.hpp` | 约 150 行 |

> **状态（2026-10-31）：补丁文件落后于 [`src/ggml-openvino/`](../src/ggml-openvino/) 两个修复**——
> KV 写索引的 SWA 同名冲突修复（`ggml-decoder.cpp`）与 `GGML_OPENVINO_DEBUG_NODE` 的 NPU 显式拒绝
> （`openvino/translate_session.cpp`），见 [CHANGELOG](../CHANGELOG.md)。本机直连 github.com 与
> gitee 镜像均超时，无法拉取 pristine `abb76ab` 来重新生成 diff。重新生成的命令：
>
> ```powershell
> git clone https://github.com/ggml-org/llama.cpp src\llama-pristine
> cd src\llama-pristine ; git checkout abb76ab380c7f3f731e365a859fb4cc64e939bb8 ; cd ..\..
> git diff --no-index --src-prefix=a/ --dst-prefix=b/ src\llama-pristine\ggml\src\ggml-openvino src\ggml-openvino
> # （diff 输出需按 patches/0001 现有格式整理路径前缀后整体替换）
> ```

所有 hunk 都位于 `ggml/src/ggml-openvino/` 之内。llama.cpp 核心、采样器（sampler）与
ggml-CPU 的文件一概未动。

## 本目录与 `src/ggml-openvino/` 的关系

引擎源码**就在仓库里**，位于 [`src/ggml-openvino/`](../src/ggml-openvino/) —— 那是完整的上游
后端目录，并已应用 WangCai 的改动，因此无需应用任何东西即可直接阅读与评审。
`tools/bootstrap.ps1` 会把固定的 llama.cpp 克隆到 `src/llama/`，并把该目录**覆盖（overlay）**到
`ggml/src/ggml-openvino/` 之上，随后打印 `git diff --stat`，让你看清相对于原始上游到底改了什么。

本目录是同一份改动以 diff 形式的表达 —— 用于评审、也用于回馈上游的产物。若想改用它而不是覆盖
（overlay）方式（例如验证两者仍然等价）：

```powershell
tools\bootstrap.ps1 -UsePatch
```

或手工执行：

```powershell
git clone https://github.com/ggml-org/llama.cpp src/llama
cd src/llama
git checkout abb76ab
git apply ..\..\patches\0001-ggml-openvino-npu-adaptation.patch
Copy-Item ..\..\patches\ov_opencl_shim.hpp ggml\src\ggml-openvino\
```

如果在较新的 llama.cpp 上尝试，先跑 `git apply --check`：OpenVINO 后端在各版本之间位置会漂移，
hunk 被拒意味着这批 hunk 需要重新变基（rebase），而不是你的本地树有问题。

## 各个 hunk 的作用

### `ov_opencl_shim.hpp`（新文件）与四处 include 替换

**问题。** `ggml-openvino.cpp`、`utils.cpp` 与 `ggml-openvino-extra.{h,cpp}` 都包含了
`<openvino/runtime/intel_gpu/ocl/ocl.hpp>`（`ggml-openvino-extra.h` 还包含了 `<CL/cl.h>`）。该
头文件会牵出 `<CL/cl2.hpp>`，而它既不在 OpenVINO 运行时包里，也不在 Visual Studio Build Tools
的安装中。于是纯 NPU 构建会卡死在一个它根本用不到的 GPU 头文件上：
`fatal error C1083: cannot open include file "CL/cl2.hpp"`，来自
`openvino/runtime/intel_gpu/ocl/ocl_wrapper.hpp:50`。

**修复。** 一个只声明这些文件*编译*所需内容的头文件：`cl_*` 标量 typedef、互不相同的不透明句柄
类型（`_cl_context*`、`_cl_command_queue*` 等 —— 必须互不相同，重载的 `ClContext` 构造函数才不会
变成歧义）、被引用到的那几个枚举、为 `clGet*`/`clCreate*` 入口点提供的内联抛异常桩（stub），外加
`ov::intel_gpu::ocl::ClContext` 与 `USMTensor`。其中每一条路径都只面向 GPU；NPU 绝不会调用进去。

替换 include 每个文件只动一行，也让 diff 保持诚实 —— 没有任何东西被 `#ifdef` 排除在外，GPU 路径
仍然参与类型检查。

### `ggml-decoder.h` —— `get_mask_ctx_size()`

决定注意力掩码输入必须有多宽的那一个函数。

llama.cpp 交给后端的是每个注意力模块一份掩码，按模型中**最大**的 KV 缓冲区
（`llama_kv_cache::get_n_kv()`）补齐，而每一层实际只在自己的缓存上做注意力。动态图（dynamic
graph）下这一点看不出来，因为 K 会被切到掩码的宽度。静态图（static graph，即 NPU）下两个形状
都被烘进编译后的图里，所以滑动窗口注意力（SWA）层需要的是环形缓冲长度，全注意力层需要的是上下文
长度 —— 而且参数形状*和*为绑定（binding）构建的宿主张量必须一致，否则 NPU 插件会拒绝该绑定
（`input tensor size is not equal to the model input type`），或者 opset-13 SDPA 拒绝形状推断
（`attention_mask_input_correctness`）。

对 LFM3-1.7B 而言，这就是六个层的 `mask_kv = 1024` 与五个层的 `768` 之间的差别。

### `ggml-decoder.cpp` —— `get_graph_input_shape()` 的掩码分支

掩码参数改用 `get_mask_ctx_size()`，不再取全模型上下文长度，并保留一条按不同掩码各占一行的
`ov-mask:` warning。正是这行日志把猜形状变成了事实：两个掩码张量都以 `ne=[256,2,1,1]` 抵达，
也就是说两个宽度都不来自宿主张量。

### `utils.cpp` —— 两个静态绑定，外加诊断

- `get_ov_input_tensor_static_decode()` 与 `get_ov_input_tensor_static_prefill()` 现在用
  `get_mask_ctx_size()` 决定补齐后掩码的尺寸。这两处代码点与上面的参数形状必须同步改动；这种耦合
  正是该 bug 难查的全部原因。
- `GGML_OPENVINO_MASK_MODE=1`：由 token 位置而非 llama.cpp 给出的掩码来构造掩码。补齐方式让被补齐
  的行在自己那一列上保持有限值，与 `set_zero_diagonal()` 的做法一致，因此一整行被完全屏蔽时不会
  产生 `0/0 = NaN` 并泄漏进递归状态的 gather。
- `dump_ov_outputs_raw()`（`GGML_OPENVINO_DUMP_BIN`）：在静态*与*动态两条路径上按输出做原始转储
  （dump），从而可以逐元素比较两个设备。聚合的 `min/max/mean` 统计 —— 这是
  `GGML_OPENVINO_DEBUG_OUTPUT` 唯一能给你的东西 —— 会掩盖单行错误，而恰好一行错正是 chunk 位置
  选错时的表现。

### `openvino/op/flash_attn_ext.cpp` —— `trim_mask_to_kv()`

当掩码仍然比 K 操作数更宽时，从 `seq_active_start` 起把它切到 KV 的范围。这是防线（guard）而非
修复：有了 `get_mask_ctx_size()` 之后，在 LFM3 上宽度本来就一致，所以这条路径保持不生效。

### `ggml-openvino-extra.{h,cpp}` —— 环境变量接线

把三个新变量登记进已识别环境变量表（`ggml_openvino_getenv_int`/`_str` 读取的是后端（backend）
初始化时缓存的一张表，未登记的名字会被静默当作未设置 —— 这一点花掉了一个下午）、解析
`GGML_OPENVINO_NPU_COMPILE_OVERRIDES`，并把 CL include 指向该 shim。

## 重新生成补丁

在一份已打补丁的 llama.cpp 检出上执行 —— 并记住补丁与 `src/ggml-openvino/` 是同一份改动的两个
视图，两者必须同步推进：

```powershell
git diff -- ggml/src/ggml-openvino > ..\..\patches\0001-ggml-openvino-npu-adaptation.patch
Copy-Item ggml\src\ggml-openvino\ov_opencl_shim.hpp ..\..\patches\
Copy-Item ggml\src\ggml-openvino\* ..\..\src\ggml-openvino\ -Recurse -Force
```

hunk 按关注点归组，一个关注点一个文件；若某项改动是正交的（一个新的可调项、一条新的降级
（lowering）），单独立为 `0002-*.patch`，以便单独评审、单独回馈上游。

## 回馈上游

第 2–4 项（`get_mask_ctx_size`、成对的那两个绑定、`trim_mask_to_kv`）是混合模型在静态路径上的
模型正确性修复，是最自然的上游候选。shim 更像一个上游构建配置问题（把 GPU remote-context 的使用
改为可选），诊断能力也应以一等环境变量（first-class env var）的身份进入上游。
