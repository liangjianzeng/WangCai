# Benchmarks

Numbers as measured, with the exact conditions. Where a number is shaky, it says so.

## Machine under test

| | |
|---|---|
| SoC | Intel Core Ultra 9 275HX |
| NPU | Intel(R) AI Boost — `Intel(R) AI Boost (NPU 3720)`, class `ComputeAccelerator`, `PCI\VEN_8086&DEV_AD1D` |
| Threads visible to llama.cpp | 24 |
| Memory | 32 GB |
| OS | Windows 11 |
| OpenVINO | 2026.4.1 |
| llama.cpp | `abb76ab` + WangCai patch set |

## Model

LFM3-1.7B `Q4_K_M`, 1049 MB. 24 layers = 13 gated short-conv + 5 sliding-window@256 + 6 global
attention. Hidden 2048, 16 query heads, 4 KV heads, head_dim 128, vocab 128000.
Conv state per recurrent layer: `6 × 2048 = 12288`.

## Command

```powershell
$env:GGML_OPENVINO_DEVICE = 'NPU'
$env:GGML_OPENVINO_CACHE_DIR = 'D:\npu_cache'
.\build\bin\llama-cli.exe -m models\LFM3-1.7B-Q4_K_M.gguf `
    -c 1024 -n 32 --temp 0 --seed 42 -fa 1 -np 1 -dev OPENVINO3 -st -p '用一句话介绍长城。'
```

`-fa 1` and `-np 1` are requirements on the NPU, not preferences.

## Results

| Execution path | Prompt eval | Decode | Coherence |
|---|---:|---:|---|
| `ggml` CPU reference (`-dev none`) | 164.4 t/s | 54.1 t/s | coherent |
| OpenVINO · CPU, dynamic graphs | 94.2 – 130 t/s | 21.7 – 29.2 t/s | coherent |
| OpenVINO · **NPU, static graphs** | 6.0 – 12.2 t/s | **8.3 – 8.7 t/s** | diverges after ~3 tokens |
| OpenVINO · CPU, static (`FORCE_STATIC`) | — | ~same as dynamic | coherent |

Sample of the individual measurements behind the ranges:

| Run | Prompt | Decode |
|---|---:|---:|
| NPU, 8-token prompt, 8 generated | 12.19 t/s (82.0 ms/tok) | 8.32 t/s (120.2 ms/tok) |
| NPU, 4-token prompt, 31 generated | 5.99 t/s (167.0 ms/tok) | 8.67 t/s (115.3 ms/tok) |
| OV-CPU, 4-token prompt, 31 generated | 94.22 t/s | 29.15 t/s |
| CPU reference, same | 164.41 t/s | 54.05 t/s |

One-off costs:

| | |
|---|---|
| Cold NPU graph compilation (both graphs) | 36.4 s |
| Recompile with `NPUW_FOLD=NO` | 383 s |
| Warm start with a populated `GGML_OPENVINO_CACHE_DIR` | most of the above disappears |

## What these numbers do *not* prove

- **They are not a speed comparison and definitely not a competitive one.** Three backends on one
  machine, one model, prompts of 4–8 tokens, 8–31 generated tokens, single run each, no warm-up
  protocol, no confidence interval. Treat the ranges as "order of magnitude, directionally useful".
- **The NPU decode figure is a working number, not a tuned one.** Losing to OpenVINO-CPU on a 1.7 B
  model means something is wrong in our static path or in the compile configuration, not that the
  accelerator is out of ideas. See
  [npu-internals.md § performance observations](npu-internals.md#6-performance-observations).
- **Prompt-eval t/s is not comparable across prompt lengths.** The two NPU rows above differ by 2×
  purely because of 8 vs 4 input tokens: the static graph always processes a full 256-token chunk, so
  short prompts pay fixed cost. Any comparison must fix `-b`, prompt length and chunk size.
- **Coherence and throughput were measured in the same runs but are independent**: the NPU numbers
  above were produced while the accuracy defect is present, which does not affect their timing
  meaningfully (same graph, same op count) but does mean both numbers will move when the defect is
  fixed.

## Reproducing

```powershell
tools\run-npu.ps1 -Model models\LFM3-1.7B-Q4_K_M.gguf -PromptFile prompts\zh.txt -N 32 -Ctx 1024
tools\npu-sweep.ps1 -Cases @(
    @{ Label = 'default';  Overrides = '' },
    @{ Label = 'chunk64';  Extra = @{ GGML_OPENVINO_PREFILL_CHUNK_SIZE = '64' } }
)
```

Each cell gets its own `GGML_OPENVINO_CACHE_DIR`, prints one line, and never silently reuses a
compiled graph from another cell.

For throughput matrices prefer `llama-bench`:

```powershell
.\build\bin\llama-bench.exe -m models\LFM3-1.7B-Q4_K_M.gguf -p 512 -n 128 -r 3 -fa 1 -dev OPENVINO3
```

## Reporting a number

Include: machine + NPU driver version, OpenVINO version, llama.cpp commit, exact command line, `-c`,
`-b`, `GGML_OPENVINO_PREFILL_CHUNK_SIZE`, prompt token count, generated token count, whether the
compiled-graph cache was cold, and whether the output was coherent. Anything less is not comparable to
the table above.
