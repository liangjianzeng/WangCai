# 快速上手

目标：在约 30 分钟内让 LFM3-1.7B 在 `Intel(R) AI Boost` 上跑起来并产出文本，其中包含下载 OpenVINO
的时间。

## 前置条件

| 组件 | 安装内容 | 验证环境 |
|---|---|---|
| CPU/NPU | Intel Core Ultra，带 `Intel(R) AI Boost` | Core Ultra 9 275HX，NPU 3720 |
| NPU 驱动 | 与所用 OpenVINO 匹配的 Intel NPU 驱动 | 随平台驱动一同分发 |
| 编译器 | Visual Studio 2022 Build Tools，"Desktop development with C++"（使用 C++ 的桌面开发） | MSVC 19.44.35220（toolset 14.44.35207） |
| Windows SDK | 10.x | 10.0.26100 |
| CMake + Ninja | 任意较新的 CMake ≥ 3.22 | 3.22.1（Android SDK 内置的 `cmake/3.22.1/bin`） |
| OpenVINO 运行时 + 开发文件 | wheel 或安装包，见下文 | 2026.4.1 |

在做其他事情之前，先确认 NPU 已被枚举：

```powershell
Get-PnpDevice -Class ComputeAccelerator | Format-Table FriendlyName, Status, InstanceId
# expect: Intel(R) AI Boost ... PCI\VEN_8086&DEV_AD1D
```

## 获取 OpenVINO 开发文件

构建过程需要 `OpenVINOConfig.cmake`、`openvino.lib`、`openvino.dll` 以及头文件。最简单可靠的来源是
PyPI 上的 wheel——它包含上述全部内容，且运行时不依赖 Python：

```powershell
cd D:\
pip download openvino==2026.4.1 --no-deps -d .\ovdl    # ~81 MB
Expand-Archive .\ovdl\openvino-2026.4.1-*.whl -DestinationPath .\ov
# → D:\ov\openvino\cmake\OpenVINOConfig.cmake
# → D:\ov\openvino\libs\openvino.lib, openvino.dll   (511 headers)
```

如果你的网络访问不了 PyPI，可改用官方安装包，或从源码构建 OpenVINO；凡能提供 `cmake/` 配置包的都行。
[docs/build.md](build.md) 介绍了替代方案与坑点。

## 初始化代码树

```powershell
git clone https://github.com/liangjianzeng/WangCai
cd WangCai
tools\bootstrap.ps1                                  # clone + checkout + apply patches
tools\configure.ps1 -OpenVinoDir D:\ov\openvino\cmake
tools\build.ps1
```

`configure.ps1` 封装了 CMake 调用（Release、Ninja、仅启用 OpenVINO 后端、不用 ccache、不用 curl），
并且必须在 Visual Studio 开发人员环境中运行——脚本自己会调用 `vcvars64.bat`。完整参数列表，以及为什么
要用批处理文件来封装，见 [docs/build.md](build.md)。

`src/llama/build/bin/` 下应有的产物：`llama-cli.exe`、`llama-completion.exe`、`llama-bench.exe`、
`llama-server.exe`、`llama-perplexity.exe`。

## 获取模型

当前目标模型是 LFM3-1.7B：

| 文件 | 大小 | 说明 |
|---|---:|---|
| `LFM3-1.7B-Q4_K_M.gguf` | 1049 MB | 24 层 = 13 个门控短卷积 + 5 个滑动窗口注意力（SWA）@256 + 6 个全局注意力，hidden 2048，16 Q 头 / 4 KV 头，head_dim 128，词表 128000 |

模型权重**不随本仓库分发**（GGUF 普遍 1–2 GB，超出 git 与 LFS 的合理边界），直接下载官方 GGUF 即用
——WangCai 走 llama.cpp 的加载路径，消费 GGUF，**不需要任何转换**。官方仓库：Hugging Face
[`LiquidAI/LFM3-1.7B-GGUF`](https://huggingface.co/LiquidAI/LFM3-1.7B-GGUF)，ModelScope 同名镜像；
多模态备料是 `LiquidAI/LFM3-Omni-2B-GGUF`（权重 + `mmproj` 投影器）。

```powershell
# 能直连 HF：
hf download LiquidAI/LFM3-1.7B-GGUF --local-dir models      # pip install "huggingface_hub[cli]"
# 国内网络更快：
modelscope download --model LiquidAI/LFM3-1.7B-GGUF --local_dir models   # pip install modelscope
```

只需挑一个量化文件，不必整仓拉回。**NPU 上的量化选择有实测约束**（详见
[status.md 缺陷 7](status.md)）：`Q4_K_M`（1049 MB，本项目基准）与 `QAD-Q4_0`（ModelScope）已验证
通过；**实用边界约 1.26 GB 源文件**——`Q8_0`（1.85 GB）会被 NPU 驱动的主机内存预算挡住
（`UNINITIALIZED` / `OUT_OF_HOST_MEMORY`）。1–3 B 的 Q4/Q5 是当前甜点区。

只有在需要官方没发布的量化档位时才自己生成：`tools/bootstrap.ps1` 克隆的钉住版本 llama.cpp 已支持
LFM3 架构——`python src\llama\convert_hf_to_gguf.py <HF目录> --outfile models\LFM3-1.7B-F16.gguf`
出母版，再 `llama-quantize` 量化即可。换量化即换实验：用全新的 `GGML_OPENVINO_CACHE_DIR`，并把
量化文件名与字节数记进实验记录。

把它放到 `models/` 下（已在 `.gitignore` 里）。**下载完成后核对文件大小。** 被静默截断的 GGUF 要到
加载时才失败，而且报错很容易被误判成后端缺陷：

```
E llama_model_load: error loading model: tensor 'blk.32.ffn_down.weight' data is not within the
  file bounds, model is corrupted or incomplete
```

## 首次在 NPU 上运行

```powershell
$env:PATH = "$PWD\src\llama\build\bin;D:\ov\openvino\libs;$env:PATH"
$env:GGML_OPENVINO_DEVICE  = 'NPU'
$env:GGML_OPENVINO_CACHE_DIR = 'D:\npu_cache'

.\src\llama\build\bin\llama-cli.exe `
    -m models\LFM3-1.7B-Q4_K_M.gguf `
    -c 1024 -n 64 --temp 0 --seed 42 -fa 1 -np 1 `
    -dev OPENVINO3 -st -p '用一句话介绍长城。'
```

输出中可作标记的内容：

```
Available devices:
  OPENVINO0: GGML_OPENVINO_DEVICE=CPU  (selected) - Intel(R) Core(TM) Ultra 9 275HX
  OPENVINO3: GGML_OPENVINO_DEVICE=NPU              - Intel(R) AI Boost (NPU 3720)

W ov-mask: name=attn_inp_kq_mask ne=[256,2,1,1] is_swa=0 -> mask_kv=1024 | ctx=1024 ctx_swa=768 chunk=256
W ov-mask: name=attn_inp_kq_mask ne=[256,2,1,1] is_swa=1 -> mask_kv= 768 | ctx=1024 ctx_swa=768 chunk=256

common_perf_print: prompt eval time = ... tokens per second
common_perf_print:        eval time = ... tokens per second
common_perf_print:        load time = 36374 ms        ← cold NPU graph compilation, one-off
```

这两行 `ov-mask:` 是最快的证据：它说明混合 KV 环形缓冲逻辑已经生效，并且滑动窗口层拿到的是环宽（768）
而不是上下文宽度（1024）。

使用同一个 `GGML_OPENVINO_CACHE_DIR` 的第二次运行，会跳过 36 s 编译中的大部分工作。

## 三个容易踩的坑

**1. 用对话模式，不要用裸续写。** LFM3 经过指令微调。让 `llama-completion` 对一段裸提示词做续写，会让它
无限重复 token（`中国的首都是都是都是…`），即便在作为参照的 CPU 后端上也是如此——这是模型在分布外提示词下
的糟糕表现，不是后端缺陷。改用 `llama-cli -st`（Jinja 对话模板），在 CPU 上的输出是连贯的。拿裸续写提示词
去诊断精度，只会让你去追一个并不存在的 bug。

**2. 在 NPU 上 `-fa 1` 是必须的。** 用 `-fa 0` 时，llama.cpp 会为走非 SDPA 写回路径而刻意把 V 压平成每行
一个元素，OpenVINO 的 `SET_ROWS` 降级（lowering）随后在 scatter 中崩溃。这是上游的设计意图，不是需要在
scatter 里修掉的缺陷。

**3. 每种配置一个缓存目录。** `GGML_OPENVINO_CACHE_DIR` 是编译缓存（compile cache）的键。把它复用到 env
覆盖各不相同的多次实验上，你只会看到一个开关“什么都不做”。

## 确认确实跑在 NPU 上

三项相互独立的检查：

1. `--list-devices` 显示出你以为选中的那个设备，并且运行日志里点明了后端。
2. 对 `GGML_OPENVINO_DUMP_BIN` 转储（dump）出来的结果跑 `tools/top-token.ps1`：如果两个设备的张量完全
   一致，说明其中一方在说谎。它们从来不会一致，NPU 的转储结果也确实不同。
3. 就当前情况，这个模型在 NPU 上的吞吐*明显更慢*，慢于 OpenVINO-CPU（解码（decode）≈8 t/s，对比
   ≈22–29 t/s）。如果你的“NPU”运行报出的是 CPU 量级的数字，那它其实跑在 CPU 上。

## 后续

- 实测数字就是这些：[docs/benchmarks.md](benchmarks.md)。
- 精度差距（accuracy gap）以及如何排查：[docs/npu-internals.md](npu-internals.md)。
- 所有能用环境变量拨动的开关：[docs/env-vars.md](env-vars.md)。
