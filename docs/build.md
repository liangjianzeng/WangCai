# 从源码构建

这里写的每一个字，都是当初真正用来产出 [benchmarks.md](benchmarks.md) 里那些数字的过程，包括死胡同。

## 工具链

| | 验证过的版本 |
|---|---|
| 编译器 | MSVC 19.44.35220（Visual Studio 2022 Build Tools，工具集 14.44.35207） |
| Windows SDK | 10.0.26100 |
| 生成器 | Ninja |
| CMake | 3.22.1 |
| OpenVINO | 2026.4.1（用运行时 wheel 提供头文件 + 导入库） |
| llama.cpp | `abb76ab380c7f3f731e365a859fb4cc64e939bb8` |

任何更新的 CMake/MSVC，只要能构建 llama.cpp 就能构建本项目。更要紧的是 llama.cpp 的钉住版本：OpenVINO
后端在各版本之间是会动的，而补丁集是照着它做的。

## 配置命令

`tools/configure.ps1` 在开发者命令提示符里执行的就是下面这些：

```bat
call "C:\Program Files (x86)\Microsoft Visual Studio\2022\BuildTools\VC\Auxiliary\Build\vcvars64.bat"
cmake -S src\llama -B src\llama\build -G Ninja ^
  -DCMAKE_BUILD_TYPE=Release ^
  -DGGML_OPENVINO=ON ^
  -DGGML_CUDA=OFF -DGGML_VULKAN=OFF -DGGML_SYCL=OFF -DGGML_OPENCL=OFF -DGGML_RPC=OFF ^
  -DGGML_CCACHE=OFF -DLLAMA_CURL=OFF ^
  -DOpenVINO_DIR=D:\ov\openvino\cmake
```

故意只启用 OpenVINO 后端：同一进程里注册的每个其它后端都会来抢 `ggml_backend_sched` 的算子分配，这让
"这个算子到底是不是跑在我以为的设备上？"变得没必要地难回答。

### 为什么要包一层 batch 文件

从 PowerShell 里内联调用 `vcvars64.bat`，是一种能稳定拿到误导性失败的姿势：

```powershell
cmd /c "call vcvars64.bat && cmake ..."     # → No CMAKE_C_COMPILER could be found
```

经由 PowerShell 的引号处理会把 `&&` 链吃掉，于是 CMake 在 `PATH` 里没有编译器的情况下做配置。正确做法是
把命令写进一个 `.bat`，再 `cmd.exe /c that.bat`。`tools/configure.ps1` 与 `tools/build.ps1` 就是这么干的。

## 拿到 OpenVINO 的开发文件

CMake 构建需要 `OpenVINOConfig.cmake`、`openvino.lib`、`openvino.dll` 和头文件。

**走 wheel 这条路（推荐）。** PyPI 的 wheel 里全都有：

```powershell
pip download openvino==2026.4.1 --no-deps -d .\ovdl
Expand-Archive .\ovdl\openvino-2026.4.1-*.whl -DestinationPath .\ov
```

得到 `.\ov\openvino\cmake\OpenVINOConfig.cmake` 与 `.\ov\openvino\libs\{openvino.lib,openvino.dll}`。
运行时路径里不需要 Python。

**这里走不通的路**，记下来免得你再逛一遍：该 OpenVINO 版本的 GitHub release 资产页挂了零个资产，而对象
存储、CDN 与镜像端点在本网络都不可达。如果你有正常的外网访问，官方压缩包当然没问题。

运行期必须把 `openvino.dll`（以及它旁边的插件 DLL）放进 `PATH`，否则可执行文件会以一种光秃秃的"代码
执行"风格错误直接启动失败。

## OpenCL 头文件之坑

<a id="the-opencl-header-problem"></a>

这是纯 NPU 目标独有的那一个构建障碍。

`ggml-openvino.cpp`、`utils.cpp` 与 `ggml-openvino-extra.{h,cpp}` 会 include
`<openvino/runtime/intel_gpu/ocl/ocl.hpp>`（而 `ggml-openvino-extra.h` include 了 `<CL/cl.h>`）。这条
include 链最终到达 `ocl_wrapper.hpp:50`，那里 include 了 `<CL/cl2.hpp>`：

```
fatal error C1083: cannot open include file "CL/cl2.hpp"
```

`cl2.hpp` 既不在 OpenVINO 运行时包里，也不在 Build Tools 里。去下 Khronos 头文件是显而易见的修法，也是你
可能根本做不到的修法（这里连那个头文件仓库的 git clone 都不可达）。而且它还是个错的修法：那些头文件所
服务的 GPU 远程上下文代码，在 NPU 构建里永远不会被执行。

汪柴的修法是 `patches/ov_opencl_shim.hpp`，放在那四个文件旁边、取代 GPU 头文件被 include。它声明了用到的
标量 typedef、**互不相同**的不透明句柄类型、被引用的枚举、所用到 OpenCL 入口点的内联桩，以及
`ov::intel_gpu::ocl::ClContext` / `USMTensor`。细节与两个坑：

- `cl_context` 与 `cl_command_queue` **不能**都是 `void*`。`ClContext` 的构造函数对它们做了重载，typedef
  成同一种类型会报 `C2668 ambiguous call`。改成互不相同的 `struct _cl_context *` / `struct _cl_command_queue *`
  就好了。
- `USMTensor::get() const` 从 `ov::Tensor::data()` 返回 `void*` 需要一个 `const_cast`，并且头文件需要
  `<string>`。

### ……以及它的 CMake 那一半

把头文件修好只完成了一半。后端的 `CMakeLists.txt` 里还带着

```cmake
find_package(OpenCL REQUIRED)
target_link_libraries(ggml-openvino PRIVATE … OpenCL::OpenCL)
```

于是任何没装 OpenCL SDK 的机器连配置都过不去——`Could NOT find OpenCL (missing: OpenCL_LIBRARY
OpenCL_INCLUDE_DIR)`——而这正是每一台纯 NPU 机器的情况。本地开发时它没被发现，是因为 `PATH` 上某个 CUDA
工具包留下了一份 `OpenCL.lib`，恰好被 `find_package` 捡到；直到失败被作为 annotation 上报，CI 才把它揪出来。

shim 让这个依赖变成了虚构的：后端调用的每一个 `cl*` 入口点（`clGetContextInfo`、`clGetDeviceInfo`、
`clGetExtensionFunctionAddressForPlatform`、`clCreateCommandQueueWithProperties`、`clReleaseCommandQueue`、
`clFinish`）都有一个抛 `gpu_path_unavailable` 的内联桩，所以根本没有东西需要链接。因此上游的 `REQUIRED`
在 [`src/ggml-openvino/CMakeLists.txt`](../src/ggml-openvino/CMakeLists.txt) 里已经改成可选：找得到更好
（恢复了真实 Khronos 头文件的构建会链接真实库），找不到也行，而且配置步骤会明确说出来：

```
-- OpenCL host library not found - building the OpenVINO backend without it (the GPU
   remote-context path is stubbed; NPU and CPU builds are unaffected)
```

## 构建

```powershell
tools\build.ps1                       # 目标：llama-completion、llama-bench、llama-server
tools\build.ps1 -Target 'llama-cli llama-perplexity'
```

只重编后端大约 1–2 分钟。

有两条构建期消息是**噪音**，不是失败：

```
-- UI: download dist.tar.gz.sha256 from latest failed: "Timeout was reached"
-- UI: HF download failed
CMake Warning at scripts/ui-assets.cmake: ... UI: no assets available - building without an embedded UI
```

那是 `llama-server` 的内嵌 web UI 在试图从 Hugging Face 拉资产。构建是成功的，产物也没问题。请以
`EXITCODE=0` 那行为准，而不是去 grep "failed" 这个词。

## 我们保留在构建里的目标

| 目标 | 为什么 |
|---|---|
| `llama-cli` | 走 chat 模板的生成——驱动 instruct 模型的唯一正确方式 |
| `llama-completion` | 裸 token 续写，用于 mask / 位置实验 |
| `llama-bench` | 吞吐矩阵 |
| `llama-server` | 服务路径的一致性 |
| `llama-perplexity` | 本意是当精度指标用；**目前被阻塞**，任何 OpenVINO 设备上的 `SET_ROWS` scatter 失败——见 [troubleshooting.md](troubleshooting.md) |

## 交叉核对一次构建

如果同一个二进制表现出的数字与这里不同，从最便宜的判别手段开始：

```powershell
.\build\bin\llama-cli.exe --list-devices        # NPU 到底有没有被注册？
$env:GGML_OPENVINO_DEVICE='NPU'
$env:GGML_OPENVINO_FORCE_STATIC=''              # 默认：按设备决定走静态路径
$env:GGML_OPENVINO_DEVICE='CPU'; $env:GGML_OPENVINO_FORCE_STATIC='1'   # 在 CPU 上走静态路径
```

若 CPU 静态与 NPU 结果不一致，那么差异在插件里，而不在图构建里——这正是本项目反复利用的那道切口。
