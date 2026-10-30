# Changelog

All notable changes to WangCai are documented here. The format follows
[Keep a Changelog](https://keepachangelog.com/en/1.1.0/), and the project intends to follow
[Semantic Versioning](https://semver.org/spec/v2.0.0.html) once it tags a release.

Unreleased dates are the dates the change was verified on hardware, not the date it was written.

## [Unreleased] — baseline `abb76ab` (llama.cpp), OpenVINO 2026.4.1

### Fixed — engine

- The NPU requant override gated on `!is_opt("native")`, which swallowed **every**
  `GGML_OPENVINO_REQUANT_KQUANT` value: default, `q4_sym128_all` and `q4_asym64_all` all returned
  `Q4_0_128`. Three supposedly different NPU configurations produced byte-identical tensor dumps, so the
  experiment meant to separate "requant policy" from "NPU arithmetic" was measuring one thing three times.
  Now gated on `!rq`: no explicit choice keeps upstream's forced grouped 4 bit (native Q4_K does not
  compile on NPU — `vpux-compiler: Channels count of input tensor shape and filter shape must be the same:
  0 != 64`), and any explicit choice reaches the normal branches, making a like-for-like CPU/NPU
  comparison possible.

### Fixed — tooling

- `tools/build.ps1` assigned to `$parallel` and `$clean`, which in PowerShell **are** the `[int]$Parallel`
  and `[switch]$Clean` parameters (names are case-insensitive), so CI died before compiling anything with
  `Cannot convert value "--parallel" to type "System.Int32"`. Renamed to `$parallelArg` / `$cleanArg`.

### Corrected — documentation

- The per-layer divergence table in [`docs/npu-internals.md`](docs/npu-internals.md) had been computed on
  llama.cpp **warmup** passes. `prefill_0`, `prefill_1` and `decode_2` are byte-identical between runs of
  the same model with different prompts, so the curve described synthetic input, not the prompt. Re-measured
  on real chunks (`l0 0.9956 · l9 0.873 · l13 0.534 · l17 0.163`) and replaced; the section now opens with
  the hash-compare recipe that classifies passes, and reports the new lead: **V is written exactly, K is
  wrong only at row 0** (`cosine 0.288`, max abs `1.06e10`).
- `docs/env-vars.md` stated that `GGML_OPENVINO_REQUANT_KQUANT` has no effect on NPU. True until the engine
  fix above; the row now describes the override and how to decline it.

### Added — measurements

- Native-Q4_0 control, `LFM3-1.7B-QAD-Q4_0.gguf` (ModelScope `LiquidAI/LFM3-1.7B-GGUF`, verified at
  1 049 615 680 bytes): a 220-token continuation is **byte-identical across native ggml CPU, OpenVINO-CPU
  static and the NPU**, while a 64-token Chinese instruction run still degenerates on the NPU alone
  (conv-state cosine `decode_2 0.989 → decode_9 0.51 → plateau ≈0.25`, top-1 diverging from step 10).
  Recorded as a methodology rule: **a continuation task is a plumbing test, not a coherence test** — it
  matches even when the device is wrong.
- `LFM3-Omni-2B-GGUF` catalogued for the multimodal phase: `Q4_0` / `Q4_K_M` / `Q8_0` / `F16` checkpoints
  plus `mmproj-LFM3-Omni-2B-{Q8_0,F16,BF16}.gguf` projectors (540 MB / 950 MB).

### Fixed — build

- `find_package(OpenCL REQUIRED)` in the backend's `CMakeLists.txt` made the backend impossible to
  *configure* on a machine without an OpenCL SDK (`Could NOT find OpenCL (missing: OpenCL_LIBRARY
  OpenCL_INCLUDE_DIR)`) — i.e. on every NPU-only machine. The dependency was fictional: every `cl*`
  entry point the backend calls has an inline stub in `ov_opencl_shim.hpp`, so there is nothing to link
  against. It is now found-if-present and optional, and the configure step prints what it decided. This
  survived local development only because a CUDA toolkit on the PATH had left an `OpenCL.lib` for
  `find_package` to trip over; CI found it.

### Fixed — tooling

- `configure.ps1` and `build.ps1` assigned `$isWindows`, which under PowerShell 7 collides with the
  read-only automatic variable `$IsWindows` (names are case-insensitive) and aborts with
  `Cannot overwrite variable IsWindows`. Both worked on Windows PowerShell 5.1 and failed on every CI
  runner — a "local green, CI red" that took five runs to find because the child `pwsh -File` swallowed
  the message. Renamed to `$onWindows`; the `scripts` CI job now greps for assignments to read-only
  automatic variables, and build steps re-raise the captured failure as a `::error::` annotation so the
  real line is visible through the public check-runs API.
- CI installs `cmake<4` (CMake 4 removed `cmake_minimum_required(<3.5)` compatibility, still declared by
  llama.cpp's vendored projects and OpenVINO's packaged config files), and `configure.ps1` passes
  `-DCMAKE_POLICY_VERSION_MINIMUM=3.5` when it detects CMake ≥ 4.
- `compare-tensors.ps1`: skips `.txt` sidecars (a custom `-Filter` read them as f32 and reported tensors
  full of `3e+32`); `Top-K` is now bounded by the compared prefix (it was sorting multi-megabyte buffers
  to print five numbers); new `-RowSize`/`-MaxRows`/`-RowTol` row mode, which is what makes KV-cache
  comparison meaningful — whole-buffer statistics over the rows a chunk never wrote are not.

### Added — repository

- `src/ggml-openvino/` is now **tracked**: the complete backend directory (95 files) with WangCai's
  changes applied, so the engine can be read without applying anything. `tools/bootstrap.ps1` clones
  the pinned llama.cpp into `src/llama/` (still git-ignored) and overlays this directory, then prints
  `git diff --stat` as proof the code landed. `patches/` stays as the reviewable diff and the upstreaming
  artifact; `bootstrap.ps1 -UsePatch` switches back to patch application.
  See `src/ggml-openvino/WANGCAI.md` for provenance and editing rules.
- README is now Chinese-first with `README_en.md` as the secondary language document.

### Added — build

- `patches/ov_opencl_shim.hpp`: a self-contained stand-in for `<CL/cl.h>` and
  `openvino/runtime/intel_gpu/ocl/ocl.hpp`. The OpenVINO backend included those headers from
  `ggml-openvino.cpp`, `utils.cpp` and `ggml-openvino-extra.{h,cpp}`, which makes an NPU-only build
  require the Khronos `cl2.hpp` and the GPU SDK that are not present on a plain Build Tools
  install. The shim declares the handful of OpenCL typedefs, distinct opaque handle types and
  inline stubs needed to compile the GPU-only remote-context paths, which the NPU never executes.
  Result: the OpenVINO backend builds from a clean Visual Studio Build Tools + OpenVINO runtime
  install with no GPU SDK in sight.
- `GGML_OPENVINO_NPU_COMPILE_OVERRIDES=KEY=VALUE,...`: adds or replaces top-level entries in the
  NPU compile config at run time. Without it, reproducing "is it this one flag?" requires a rebuild
  per flag, and NPU graph compilation is slow enough (~36 s cold for LFM3-1.7B) that the sweep costs
  hours.
- `GGML_OPENVINO_DUMP_BIN=<dir>`: writes every graph output of a compute call to raw
  `<dir>/<tag>_<seq>_<name>.bin` plus a `.txt` sidecar with shape and element type, on both the
  static and the dynamic path. Unlike `GGML_OPENVINO_DEBUG_NODE` it appends no `Result` nodes —
  which matters, because the NPU plugin aborts the whole process when extra outputs are added.
- `GGML_OPENVINO_MASK_MODE=1`: builds the attention mask from token positions instead of consuming
  the mask llama.cpp supplies, for the static prefill path. Added to separate "the mask content is
  wrong" from "the graph is mis-executed"; on this model it exonerated the mask.
- `tools/`: `configure.ps1`, `build.ps1`, `run-npu.ps1`, `npu-sweep.ps1`, `compare-tensors.ps1`,
  `top-token.ps1`.

### Added — correctness

- `GgmlOvDecoder::get_mask_ctx_size()`: the single place that decides how wide an attention mask
  input has to be. Hybrid models hand the backend one mask per attention module padded to the
  *largest* KV buffer in the model, while each layer attends over its own cache. Under dynamic
  graphs K is sliced to match the mask; under static (NPU) graphs both shapes are baked in, so the
  windowed layers need the ring length and the full-attention layers the context length. Both the
  compiled parameter shape and the host tensor built for the binding now derive from the same
  function; previously they were computed independently and could disagree, which the NPU plugin
  rejects with `input tensor size is not equal to the model input type`, and opset-13 SDPA rejects
  with `attention_mask_input_correctness`.
- `trim_mask_to_kv()` in `openvino/op/flash_attn_ext.cpp`: slices a mask that is wider than the K
  operand down to the KV extent, honouring `seq_active_start`, as a guard for the cases where the
  two still disagree.

### Fixed

- LFM3-1.7B (13 gated short-conv + 5 sliding-window@256 + 6 global-attention layers) previously
  failed to build a graph at all on the NPU device. It now compiles both graphs (chunked prefill and
  single-token decode) and generates end to end on `Intel(R) AI Boost`.

### Known issues

- First per-layer measurement of the accuracy defect (`prefill_0`, conv-state outputs): cosine
  `0.9987` at layer 0 → `0.72` at layer 9 → `0.215` at layer 17. The error exists at the first layer and
  compounds, so it is per-op precision, not a broken op deep in the graph and not state bookkeeping.
  K/V comparisons are not yet meaningful (unwritten rows read as zeros/garbage); the comparison tool
  needs row slicing.

- NPU output is not yet numerically on par with the CPU reference: cosine similarity to reference
  logits is `0.969` at the end of prefill and `0.73–0.79` in the first decode steps, with the logit
  distribution measurately flattened (top-1 `19.58` on CPU vs `17.53` on NPU). Greedy generation
  tracks the reference for 2–3 tokens and then diverges. See
  [docs/npu-internals.md](docs/npu-internals.md) for what has been ruled out.
- NPU decode throughput (`8.3–8.7 t/s`) is 6× below the CPU reference (`54.1 t/s`) and 2.5× below
  OpenVINO on CPU (`21.7–29.2 t/s`) for this 1.7 B model — about 0.03 of the available TOPS. Prefill is
  *not* affected in the same way (`pp512` 415 t/s vs 570 native), which localizes the problem to the
  per-step path rather than to the compile configuration in general.

- A sequence longer than the KV cache takes the OpenVINO backend down: `llama-perplexity` on any
  device, and `llama-bench -p 1024 -n 32` with a 1024 context, fail with
  `Check 'idxValue < static_cast<int64_t>(srcDimAxis) ...' failed at intel_cpu\src\nodes\scatter_update.cpp:915`
  — an out-of-range KV write index. The same shape at `-p 512` runs clean. On the NPU the identical
  condition produces `ZE_RESULT_ERROR_DEVICE_LOST` (`zeCommandQueueExecuteCommandLists`, `0x70000001`)
  instead of a check failure. Blocks perplexity as an accuracy metric. *(An earlier entry here blamed
  the multi-output graph for this; the `-p 512` / `-p 1024` differential does not support that, so the
  claim is withdrawn.)*

### Corrected

- The published NPU prompt-eval figures (`6.0–12.2 t/s`) were an artifact, not a measurement of the
  accelerator. The static prefill graph is always `GGML_OPENVINO_PREFILL_CHUNK_SIZE` (256) columns
  wide, so a 4-token prompt pays for 256 columns while llama.cpp reports useful tokens per second —
  60× below the graph's own column throughput. Measured at real token counts the NPU reaches
  **415 t/s at `pp512`** (68% of OpenVINO-CPU, 73% of the native reference). Short-prompt prompt-t/s
  on the NPU should not be compared with CPU numbers at all; see
  [docs/benchmarks.md](docs/benchmarks.md).
- Adding extra graph outputs via `GGML_OPENVINO_DEBUG_NODE` aborts the process on the NPU. Use
  `GGML_OPENVINO_DUMP_BIN`, which reads existing outputs instead.

### Notes on rejected hypotheses

Recorded so nobody spends a week on them again:

- **Weight requantization is not the cause.** On NPU the backend requantizes all non-embedding
  weights to `Q4_0_128` (group 128, symmetric) while CPU keeps native `Q4_K`. Forcing the same
  requant on CPU leaves the output coherent, so the requant alone does not explain the defect.
- **Chunk size is not the cause.** `GGML_OPENVINO_PREFILL_CHUNK_SIZE` = 1 / 2 / 7 / 32 / 128 / 256
  all behave the same.
- **The mask content is not the cause.** `GGML_OPENVINO_MASK_MODE=1` (position-derived causal mask)
  leaves the CPU static path coherent and the NPU still wrong.
- **Multi-column convolution is not the cause.** A 1-token prompt executes the same 256-column
  padded prefill graph and is coherent on NPU.
- **No NPUW toggle fixes it.** `NPU_USE_NPUW=NO` fails to compile; `NPU_COMPILER_DYNAMIC_QUANTIZATION=NO`
  dies with `ZE_RESULT_ERROR_OUT_OF_HOST_MEMORY`; `NPUW_DQ=NO`, `NPUW_DQ_FULL=YES` and
  `NPUW_FOLD=NO` collapse generation to a single repeated token; `NPUW_WEIGHTS_BANK=none` is
  unchanged. The defect survives every documented lever.
- `GGML_OPENVINO_STATEFUL_EXECUTION=1` on NPU does not help (stateful is CPU/GPU-only by design).
- `-fa 0` is a dead end on NPU: forcing the non-SDPA path makes llama.cpp flatten V to one element
  per row on purpose (`llama_kv_cache.cpp`), which the scatter write-back then rejects.

[Unreleased]: https://github.com/liangjianzeng/WangCai
