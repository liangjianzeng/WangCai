# Changelog

All notable changes to WangCai are documented here. The format follows
[Keep a Changelog](https://keepachangelog.com/en/1.1.0/), and the project intends to follow
[Semantic Versioning](https://semver.org/spec/v2.0.0.html) once it tags a release.

Unreleased dates are the dates the change was verified on hardware, not the date it was written.

## [Unreleased] — baseline `abb76ab` (llama.cpp), OpenVINO 2026.4.1

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

- NPU output is not yet numerically on par with the CPU reference: cosine similarity to reference
  logits is `0.969` at the end of prefill and `0.73–0.79` in the first decode steps, with the logit
  distribution measurately flattened (top-1 `19.58` on CPU vs `17.53` on NPU). Greedy generation
  tracks the reference for 2–3 tokens and then diverges. See
  [docs/npu-internals.md](docs/npu-internals.md) for what has been ruled out.
- NPU decode throughput (`8.3–8.7 t/s`) is below OpenVINO on CPU (`21.7–29.2 t/s`) for this 1.7 B
  model. Not yet investigated; the recurrent-state write-back per step is the current suspicion.
- `llama-perplexity` cannot run on the OpenVINO backend at all: its multi-output graph triggers
  `ScatterUpdate ... indices value that points to non-existing output tensor element`. Unrelated to
  the NPU; blocks using perplexity as an accuracy metric.
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
