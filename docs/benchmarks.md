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

### Prefill — measured at real token counts (`llama-bench`, `-r 1`, `-fa 1`)

| Test | NPU (static) | OpenVINO CPU (dynamic) | `ggml` CPU reference |
|---|---:|---:|---:|
| `pp32` | 54.9 t/s | 335 t/s | 447 t/s |
| `pp128` | 219 t/s | 567 t/s | 546 t/s |
| `pp512` | **415 t/s** | 610 t/s | 570 t/s |
| `pp1024` | `ZE_RESULT_ERROR_DEVICE_LOST` (see below) | `scatter_update` check (see below) | 572 t/s |
| `tg32` | not reached at this size | — | 53.4 t/s |

**Read this table, not the short-prompt one below.** At `pp512` — two fully populated 256-token
chunks, i.e. no padding waste — the NPU reaches 73% of the native CPU reference and 68% of
OpenVINO-on-CPU. The NPU is *not* bad at prefill; the earlier "6–12 t/s" figure in this document was
an artifact of how prompt throughput is reported for a fixed-width static graph (next section).

The remaining prefill headroom is real, though: 415 t/s on a 1.7 B model is ≈ 870 GFLOP per 256-token
chunk, about **1.4 TOPS effective out of ~13 TOPS INT8**. Something is leaving an order of magnitude
on the table — candidates in [npu-internals.md § 6](npu-internals.md#6-performance-observations).

### Why short prompts report almost nothing on the NPU

The static prefill graph is always `GGML_OPENVINO_PREFILL_CHUNK_SIZE = 256` columns wide. A 4-token
prompt still pays for 256 columns, and llama.cpp reports `tokens actually processed / wall time`:

| Sample | Reported prompt t/s | Wall time per 256-column chunk | Useful tokens |
|---|---:|---:|---|
| 4-token prompt | 5.99 | ~670 ms | 4 / 256 = 1.6% |
| 8-token prompt | 12.19 | ~656 ms | 8 / 256 = 3.1% |

Same graph, same cost, 1.6% useful → the reported number is 60× lower than the graph's own throughput
(~380 t/s of columns). **Never compare NPU prompt t/s against CPU prompt t/s on short prompts**: the
CPU paths have no column padding, so the comparison measures padding, not hardware. Compare
`llama-bench pp<N>` at N ≥ chunk size, or compare wall time per chunk.

Corollary for tuning: if your workload is dominated by short prompts, lower
`GGML_OPENVINO_PREFILL_CHUNK_SIZE` (toward the typical prompt length) — it is a straight multiplier on
short-prompt latency. It is part of the graph cache key, so each value costs one compile.

### Decode

| | t/s |
|---|---:|
| **NPU (static)** | **8.3 – 8.7** |
| OpenVINO CPU, dynamic | 21.7 – 29.2 |
| `ggml` CPU reference | 54.1 |

Decode is where the project actually loses, and by 6× against the reference. At 1.7 B parameters that
is ≈ 3.4 GFLOP/token, so ~0.03 TOPS effective — two orders of magnitude below the accelerator. This is
the number to attack (roadmap Phase 2), not prefill.

One-off costs:

| | |
|---|---|
| Cold NPU graph compilation (both graphs) | 36.4 s |
| Recompile with `NPUW_FOLD=NO` | 383 s |
| Warm start with a populated `GGML_OPENVINO_CACHE_DIR` | most of the above disappears |

## What these numbers do *not* prove

- **Single data points.** Three backends, one machine, one model, `-r 1`, no warm-up protocol, no
  confidence interval. `llama-bench` prints `± 0.00` because there is one repetition. Order of
  magnitude and direction only; re-run with `-r 3` before quoting anywhere.
- **The NPU decode figure is a working number, not a tuned one.** Losing 6× to the CPU on a 1.7 B
  model means something is wrong in our static path or in the compile configuration, not that the
  accelerator is out of ideas — and prefill at 73% of the reference proves the plugin is not
  uniformly hopeless. See [npu-internals.md § 6](npu-internals.md#6-performance-observations).
- **`pp1024` failures are not a throughput result.** They are an out-of-range KV write index: with
  `llama-bench`'s default `-c -1` (model context 1024), `-p 1024 -n 32` needs 1056 cache slots. The
  same shape that crashes at 1024 runs clean at 512 on the same device. On the CPU plugin this
  surfaces as a `scatter_update` bounds check; on the NPU plugin the bad index takes the device down
  with `ZE_RESULT_ERROR_DEVICE_LOST` — strictly worse failure mode for the same bug, and worth filing
  upstream on its own. Always size `-c` ≥ `-p` + `-n`.
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
