# Build from source

Everything here is what was actually used to produce the numbers in
[benchmarks.md](benchmarks.md), including the dead ends.

## Toolchain

| | Verified version |
|---|---|
| Compiler | MSVC 19.44.35220 (Visual Studio 2022 Build Tools, toolset 14.44.35207) |
| Windows SDK | 10.0.26100 |
| Generator | Ninja |
| CMake | 3.22.1 |
| OpenVINO | 2026.4.1 (runtime wheel used for headers + import library) |
| llama.cpp | `abb76ab380c7f3f731e365a859fb4cc64e939bb8` |

Any newer CMake/MSVC that builds llama.cpp will build this. The pinned llama.cpp commit matters more:
the OpenVINO backend moves between releases, and the patch set is keyed to it.

## The configure command

`tools/configure.ps1` runs exactly this, inside a developer command prompt:

```bat
call "C:\Program Files (x86)\Microsoft Visual Studio\2022\BuildTools\VC\Auxiliary\Build\vcvars64.bat"
cmake -S src\llama -B src\llama\build -G Ninja ^
  -DCMAKE_BUILD_TYPE=Release ^
  -DGGML_OPENVINO=ON ^
  -DGGML_CUDA=OFF -DGGML_VULKAN=OFF -DGGML_SYCL=OFF -DGGML_OPENCL=OFF -DGGML_RPC=OFF ^
  -DGGML_CCACHE=OFF -DLLAMA_CURL=OFF ^
  -DOpenVINO_DIR=D:\ov\openvino\cmake
```

Only the OpenVINO backend is enabled on purpose: every other backend registered in the same process
competes for op assignment in `ggml_backend_sched`, which makes "did this op run where I think it
ran?" needlessly hard to answer.

### Why it is wrapped in a batch file

Calling `vcvars64.bat` inline from PowerShell is a reliable way to get a misleading failure:

```powershell
cmd /c "call vcvars64.bat && cmake ..."     # → No CMAKE_C_COMPILER could be found
```

Quoting through PowerShell eats the `&&` chain and CMake configures with no compiler in `PATH`. Write
the commands into a `.bat` and invoke `cmd.exe /c that.bat`. `tools/configure.ps1` and
`tools/build.ps1` do exactly that.

## Getting OpenVINO's development files

The CMake build needs `OpenVINOConfig.cmake`, `openvino.lib`, `openvino.dll` and the headers.

**The wheel path (recommended).** The PyPI wheel ships all of it:

```powershell
pip download openvino==2026.4.1 --no-deps -d .\ovdl
Expand-Archive .\ovdl\openvino-2026.4.1-*.whl -DestinationPath .\ov
```

giving `.\ov\openvino\cmake\OpenVINOConfig.cmake` and `.\ov\openvino\libs\{openvino.lib,openvino.dll}`.
Nothing in the runtime path needs Python.

**What did not work here**, recorded so you don't repeat the tour: the GitHub release assets page for
this OpenVINO version had zero assets attached, and the object-storage, CDN and mirror endpoints are
unreachable from this network. If you have ordinary internet access, the official archive is
obviously fine.

At run time, `openvino.dll` (and the plugin DLLs next to it) must be on `PATH`, otherwise the
executables fail to start with a bare "code execution" style error.

## The OpenCL header problem

This is the one build obstacle specific to an NPU-only target.

`ggml-openvino.cpp`, `utils.cpp` and `ggml-openvino-extra.{h,cpp}` include
`<openvino/runtime/intel_gpu/ocl/ocl.hpp>` (and `ggml-openvino-extra.h` included `<CL/cl.h>`). That
chain reaches `ocl_wrapper.hpp:50`, which includes `<CL/cl2.hpp>`:

```
fatal error C1083: cannot open include file "CL/cl2.hpp"
```

`cl2.hpp` is not part of the OpenVINO runtime package and not part of Build Tools. Downloading the
Khronos headers is the obvious fix and the one you may not be able to take (git clone of the headers
repo was unreachable here). It is also the wrong fix: the GPU remote-context code those headers serve
is never executed on an NPU build.

WangCai's fix is `patches/ov_opencl_shim.hpp`, dropped next to the four files and included instead of
the GPU headers. It declares the scalar typedefs, **distinct** opaque handle types, the enums
referenced, inline stubs for the OpenCL entry points used, and `ov::intel_gpu::ocl::ClContext` /
`USMTensor`. Details and the two traps:

- `cl_context` and `cl_command_queue` must **not** both be `void*`. The `ClContext` constructor is
  overloaded on them, and identical typedefs produce `C2668 ambiguous call`. Distinct
  `struct _cl_context *` / `struct _cl_command_queue *` typedefs fix it.
- `USMTensor::get() const` returning `void*` from `ov::Tensor::data()` needs a `const_cast`, and the
  header needs `<string>`.

### …and its CMake half

Fixing the headers is only half of it. The backend's `CMakeLists.txt` also carried

```cmake
find_package(OpenCL REQUIRED)
target_link_libraries(ggml-openvino PRIVATE … OpenCL::OpenCL)
```

so configuring failed on any machine without an OpenCL SDK — `Could NOT find OpenCL (missing:
OpenCL_LIBRARY OpenCL_INCLUDE_DIR)` — which is every NPU-only machine. It went unnoticed during local
development because a CUDA toolkit on the PATH had left an `OpenCL.lib` where `find_package` could
trip over it, and CI only found it once the failure was reported as an annotation.

The shim makes this dependency fictional: every `cl*` entry point the backend calls
(`clGetContextInfo`, `clGetDeviceInfo`, `clGetExtensionFunctionAddressForPlatform`,
`clCreateCommandQueueWithProperties`, `clReleaseCommandQueue`, `clFinish`) has an inline stub that
throws `gpu_path_unavailable`, so there is nothing to link against. Upstream's `REQUIRED` is therefore
now optional in [`src/ggml-openvino/CMakeLists.txt`](../src/ggml-openvino/CMakeLists.txt): found is
preferred (a build that restores the real Khronos headers links the real library), absent is fine, and
the configure step says so:

```
-- OpenCL host library not found - building the OpenVINO backend without it (the GPU
   remote-context path is stubbed; NPU and CPU builds are unaffected)
```

## Building

```powershell
tools\build.ps1                       # targets: llama-completion, llama-bench, llama-server
tools\build.ps1 -Target 'llama-cli llama-perplexity'
```

Backend-only rebuilds are ~1–2 minutes.

Two build-time messages are **noise**, not failures:

```
-- UI: download dist.tar.gz.sha256 from latest failed: "Timeout was reached"
-- UI: HF download failed
CMake Warning at scripts/ui-assets.cmake: ... UI: no assets available - building without an embedded UI
```

That is `llama-server`'s embedded web UI trying to fetch assets from Hugging Face. The build succeeds
and the binaries are fine. Confirm with the `EXITCODE=0` line, not by grepping for the word "failed".

## Targets we keep in the build

| Target | Why |
|---|---|
| `llama-cli` | chat-template generation — the only correct way to drive an instruct model |
| `llama-completion` | raw token continuation, for mask/position experiments |
| `llama-bench` | throughput matrix |
| `llama-server` | serve path parity |
| `llama-perplexity` | intended as an accuracy metric; **currently blocked** by the `SET_ROWS` scatter failure on any OpenVINO device — see [troubleshooting.md](troubleshooting.md) |

## Cross-checking a build

If the same binary behaves differently from the numbers here, start with the cheapest discriminator:

```powershell
.\build\bin\llama-cli.exe --list-devices        # is the NPU registered at all?
$env:GGML_OPENVINO_DEVICE='NPU'
$env:GGML_OPENVINO_FORCE_STATIC=''              # default: static path chosen from the device
$env:GGML_OPENVINO_DEVICE='CPU'; $env:GGML_OPENVINO_FORCE_STATIC='1'   # static path on CPU
```

If CPU-static and NPU disagree, the difference is in the plugin, not in graph construction — which is
precisely the split this project keeps exploiting.
