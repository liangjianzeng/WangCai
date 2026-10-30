# `src/ggml-openvino` — the engine's source

This directory is **WangCai's own code**: the ggml OpenVINO backend that turns a `ggml_cgraph` into a
static OpenVINO graph and runs it on `Intel(R) AI Boost`. It is tracked here so the engine can be read
and reviewed directly, without applying anything.

The upstream README ([README.md](README.md)) still describes the backend as llama.cpp ships it. This
file describes the delta.

## Provenance

| | |
|---|---|
| Upstream | `ggml/src/ggml-openvino/` from llama.cpp `abb76ab380c7f3f731e365a859fb4cc64e939bb8` |
| Contents | the full upstream directory (95 files, ~900 KB) **plus** WangCai's changes |
| Install | `tools/bootstrap.ps1` clones the pinned llama.cpp into `src/llama/` (git-ignored) and overlays this directory onto `ggml/src/ggml-openvino/` |
| History | [../../patches/0001-ggml-openvino-npu-adaptation.patch](../../patches/0001-ggml-openvino-npu-adaptation.patch) is the same change as a reviewable diff; `bootstrap.ps1 -UsePatch` applies that instead of the overlay |
| License | Apache-2.0 (same as upstream, which is MIT — see [../../LICENSE](../../LICENSE)) |

`bootstrap.ps1` prints `git diff --stat` for this directory after installing, so "did the engine code
actually land?" is answered by the tool rather than assumed.

## What differs from upstream

Three groups; details and reasoning in [../../patches/README.md](../../patches/README.md) and
[../../docs/npu-internals.md](../../docs/npu-internals.md).

| Files | Change |
|---|---|
| `ov_opencl_shim.hpp` *(new)* + include swaps in `ggml-openvino.cpp`, `utils.cpp`, `ggml-openvino-extra.{h,cpp}` | lets an NPU-only build compile without the Khronos CL headers / GPU SDK the GPU remote-context path drags in |
| `ggml-decoder.h` `get_mask_ctx_size()`, its use in `ggml-decoder.cpp`, and both static binders in `utils.cpp` | hybrid models (short-conv + sliding-window + full attention) address their own KV ring instead of the model-wide context, and the compiled parameter shape and the bound host tensor stop drifting apart |
| `openvino/op/flash_attn_ext.cpp` `trim_mask_to_kv()` | slices a mask wider than K to the KV extent, honouring `seq_active_start` |
| `utils.cpp` `dump_ov_outputs_raw()` + `GGML_OPENVINO_DUMP_BIN` | raw per-output dumps on both static and dynamic paths — element-wise device comparison, without appending `Result` nodes (which aborts the NPU plugin) |
| `utils.cpp` + `GGML_OPENVINO_MASK_MODE` | position-derived causal mask for the static prefill path, to separate mask-content bugs from execution bugs |
| `ggml-openvino-extra.{h,cpp}` | registers the new variables in the env table and parses `GGML_OPENVINO_NPU_COMPILE_OVERRIDES`, which replaces top-level NPU compile-config entries at run time |

## Editing rules

- This directory is a **mirror of what gets compiled**. Change it here and the build changes; do not
  edit the copy under `src/llama/` — it is git-ignored and overwritten by the next bootstrap.
- Keep the diff against the pinned upstream readable: it is the thing that gets upstreamed, and
  `patches/` must stay reproducible from it
  (`git diff -- ggml/src/ggml-openvino > ../../patches/0001-….patch`, then copy the changed files back
  here).
- New behaviour goes behind an env var registered in `ggml-openvino-extra.cpp` and documented in
  [../../docs/env-vars.md](../../docs/env-vars.md). A variable that is not in that table reads as
  unset with no warning — that has cost real debugging time.
- Style follows llama.cpp: 4 spaces, 120 columns, `snake_case`, `m_` members, and comments that record
  the constraint rather than the code.
