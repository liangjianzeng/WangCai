# Getting started

Target: get LFM3-1.7B generating on `Intel(R) AI Boost` in about 30 minutes, including the OpenVINO
download.

## Prerequisites

| Component | What to install | Verified with |
|---|---|---|
| CPU/NPU | Intel Core Ultra with `Intel(R) AI Boost` | Core Ultra 9 275HX, NPU 3720 |
| NPU driver | Intel NPU driver matching your OpenVINO | bundled with the platform driver |
| Compiler | Visual Studio 2022 Build Tools, "Desktop development with C++" | MSVC 19.44.35220 (toolset 14.44.35207) |
| Windows SDK | 10.x | 10.0.26100 |
| CMake + Ninja | any recent CMake ≥ 3.22 | 3.22.1 (the one shipped in the Android SDK `cmake/3.22.1/bin`) |
| OpenVINO runtime + dev files | wheel or package, see below | 2026.4.1 |

Check the NPU is enumerated before anything else:

```powershell
Get-PnpDevice -Class ComputeAccelerator | Format-Table FriendlyName, Status, InstanceId
# expect: Intel(R) AI Boost ... PCI\VEN_8086&DEV_AD1D
```

## Get OpenVINO development files

The build needs `OpenVINOConfig.cmake`, `openvino.lib`, `openvino.dll` and the headers. The simplest
reliable source is the PyPI wheel — it contains all of them and does not require Python at run time:

```powershell
cd D:\
pip download openvino==2026.4.1 --no-deps -d .\ovdl    # ~81 MB
Expand-Archive .\ovdl\openvino-2026.4.1-*.whl -DestinationPath .\ov
# → D:\ov\openvino\cmake\OpenVINOConfig.cmake
# → D:\ov\openvino\libs\openvino.lib, openvino.dll   (511 headers)
```

If your network blocks PyPI, use the official package or build OpenVINO from source; anything that
provides a `cmake/` config package works. [docs/build.md](build.md) covers alternatives and pitfalls.

## Bootstrap the tree

```powershell
git clone https://github.com/liangjianzeng/WangCai
cd WangCai
tools\bootstrap.ps1                                  # clone + checkout + apply patches
tools\configure.ps1 -OpenVinoDir D:\ov\openvino\cmake
tools\build.ps1
```

`configure.ps1` wraps the CMake invocation (Release, Ninja, OpenVINO backend only, no ccache, no
curl) and must run inside a Visual Studio developer environment — the script calls `vcvars64.bat`
itself. See [docs/build.md](build.md) for the exact flag list and the reason it is wrapped in a
batch file.

Expected artifacts in `src/llama/build/bin/`: `llama-cli.exe`, `llama-completion.exe`,
`llama-bench.exe`, `llama-server.exe`, `llama-perplexity.exe`.

## Get a model

The current target is LFM3-1.7B:

| File | Size | Notes |
|---|---:|---|
| `LFM3-1.7B-Q4_K_M.gguf` | 1049 MB | 24 layers = 13 gated short-conv + 5 sliding-window@256 + 6 global attention, hidden 2048, 16 Q heads / 4 KV heads, head_dim 128, vocab 128000 |

Put it under `models/`. **Verify the size after download.** A silently truncated GGUF does not fail
cleanly until load time, and the error is easy to mistake for a backend bug:

```
E llama_model_load: error loading model: tensor 'blk.32.ffn_down.weight' data is not within the
  file bounds, model is corrupted or incomplete
```

## First run on the NPU

```powershell
$env:PATH = "$PWD\src\llama\build\bin;D:\ov\openvino\libs;$env:PATH"
$env:GGML_OPENVINO_DEVICE  = 'NPU'
$env:GGML_OPENVINO_CACHE_DIR = 'D:\npu_cache'

.\src\llama\build\bin\llama-cli.exe `
    -m models\LFM3-1.7B-Q4_K_M.gguf `
    -c 1024 -n 64 --temp 0 --seed 42 -fa 1 -np 1 `
    -dev OPENVINO3 -st -p '用一句话介绍长城。'
```

Landmarks in the output:

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

The two `ov-mask:` lines are the quickest proof that the hybrid KV-ring logic is active and that the
sliding-window layers got their ring width (768) rather than the context width (1024).

The second run with the same `GGML_OPENVINO_CACHE_DIR` skips most of the 36 s compile.

## Three things that will bite you

**1. Use chat mode, not raw completion.** LFM3 is instruction-tuned. Asking `llama-completion` to
continue a bare prompt makes it repeat tokens forever (`中国的首都是都是都是…`) even on the reference
CPU backend — that is the model behaving badly on an out-of-distribution prompt, not a backend bug.
Use `llama-cli -st` (Jinja chat template) and the output is coherent on CPU. Diagnosing accuracy with
a raw-completion prompt will send you chasing a nonexistent bug.

**2. `-fa 1` is mandatory on the NPU.** With `-fa 0` llama.cpp deliberately flattens V to one element
per row for the non-SDPA write-back path, and the OpenVINO `SET_ROWS` lowering then dies in the
scatter. This is upstream intent, not a defect to fix in the scatter.

**3. One cache dir per configuration.** `GGML_OPENVINO_CACHE_DIR` keys the compiled-graph cache.
Reuse it across experiments with different env overrides and you will watch a flag "do nothing".

## Confirming it is really on the NPU

Three independent checks:

1. `--list-devices` shows the device you think you selected, and the run log names the backend.
2. `tools/top-token.ps1` on a `GGML_OPENVINO_DUMP_BIN` capture: identical tensors between two devices
   would mean one of them is lying. They are never identical, and the NPU capture differs.
3. NPU throughput is *distinctively slower* than OpenVINO-CPU for this model today
   (≈8 t/s decode vs ≈22–29 t/s). If your "NPU" run reports CPU-like numbers, it ran on the CPU.

## Next

- Numbers are what they are: [docs/benchmarks.md](benchmarks.md).
- The accuracy gap and how to investigate it: [docs/npu-internals.md](npu-internals.md).
- Everything you can turn with an env var: [docs/env-vars.md](env-vars.md).
