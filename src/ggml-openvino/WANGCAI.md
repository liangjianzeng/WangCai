# `src/ggml-openvino` —— 引擎本体源码

这个目录**就是旺财自己的代码**：ggml 的 OpenVINO 后端，把 `ggml_cgraph` 翻译成静态 OpenVINO 图，
放到 `Intel(R) AI Boost` 上执行。它被纳入版本管理，是为了让引擎可以被直接阅读和评审，不必先应用
任何补丁。

上游 README（[README.md](README.md)）仍然按 llama.cpp 原样描述这个后端，未被改动；本文件描述的是
我们那部分差异。

## 来源

| | |
|---|---|
| 上游 | llama.cpp `abb76ab380c7f3f731e365a859fb4cc64e939bb8` 的 `ggml/src/ggml-openvino/` |
| 内容 | 完整的上游目录（95 个文件，约 900 KB）**加上**旺财自己的改动 |
| 安装方式 | `tools/bootstrap.ps1` 把钉住版本的 llama.cpp 克隆到 `src/llama/`（被 git 忽略），再用本目录覆盖到 `ggml/src/ggml-openvino/` |
| 历史形态 | [../../patches/0001-ggml-openvino-npu-adaptation.patch](../../patches/0001-ggml-openvino-npu-adaptation.patch) 是同一份改动的可评审 diff；`bootstrap.ps1 -UsePatch` 走打补丁而不是覆盖 |
| 许可 | Apache-2.0（上游是 MIT，见 [../../LICENSE](../../LICENSE)） |

`bootstrap.ps1` 在安装完成后会打印这个目录的 `git diff --stat`，所以"引擎代码到底落进去没有"是由
工具回答的，不是靠假设。

## 与上游的差异

分三组，细节与理由见 [../../patches/README.md](../../patches/README.md) 与
[../../docs/npu-internals.md](../../docs/npu-internals.md)。

| 文件 | 改动 |
|---|---|
| `ov_opencl_shim.hpp` *（新增）* + `ggml-openvino.cpp`、`utils.cpp`、`ggml-openvino-extra.{h,cpp}` 的 include 替换 | 让纯 NPU 构建不必依赖 GPU 远程上下文路径顺带拖进来的 Khronos CL 头文件 / GPU SDK |
| `ggml-decoder.h` 的 `get_mask_ctx_size()`、它在 `ggml-decoder.cpp` 中的使用，以及 `utils.cpp` 里的两个静态绑定器 | 混合结构模型（短卷积 + 滑动窗口 + 全局注意力）按各自模块寻址自己的 KV 环，而不是整模上下文；编译进参数的形状与被绑定的主机张量不再各走各路 |
| `openvino/op/flash_attn_ext.cpp` 的 `trim_mask_to_kv()` | 把比 K 更宽的 mask 裁到 KV 范围，并遵守 `seq_active_start` |
| `utils.cpp` 的 `dump_ov_outputs_raw()` + `GGML_OPENVINO_DUMP_BIN` | 静态与动态路径都能逐输出转储原始张量，用于设备间逐元素比对——不需要追加 `Result` 节点（追加会让 NPU 插件直接崩） |
| `utils.cpp` + `GGML_OPENVINO_MASK_MODE` | 给静态 prefill 路径提供按位置推导的因果 mask，用于把"mask 内容 bug"与"执行 bug"分开 |
| `ggml-openvino-extra.{h,cpp}` | 在环境变量表里登记上述新变量，并解析 `GGML_OPENVINO_NPU_COMPILE_OVERRIDES`，在运行期替换顶层的 NPU 编译配置项 |

## 改动规矩

- 这个目录是**真正参与编译的那份代码的镜像**。在这里改，构建就变；不要去改 `src/llama/` 下的那份
  拷贝——它被 git 忽略，而且下一次 bootstrap 会把它覆盖掉。
- 保持对钉住上游版本的 diff 可读：那是拿去上游化的东西；而且 `patches/` 必须能由它复现
  （`git diff -- ggml/src/ggml-openvino > ../../patches/0001-….patch`，然后把改过的文件拷回这里）。
  生成补丁请用 cmd 重定向而不是 PowerShell 的 `Out-File -Encoding ASCII`——后者会把上游的非 ASCII
  字符变成 `?`，我们真的被这个坑过一次（补丁少了 464 字节）。
- 新行为一律放在环境变量后面，变量要登记进 `ggml-openvino-extra.cpp` 的表，并写进
  [../../docs/env-vars.md](../../docs/env-vars.md)。没进表的变量读出来就是"未设置"且没有任何警告
  ——这件事已经消耗过真实的调试时间。
- 代码风格跟随 llama.cpp：4 空格缩进、120 列、`snake_case`、成员用 `m_` 前缀，注释写的是**约束**而
  不是复述代码。
