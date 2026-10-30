# Patches

Everything WangCai changes in upstream code lives here, as a patch set against a pinned llama.cpp
commit. Keeping it outside the vendored tree means the fork stays a clean checkout and the delta
stays reviewable.

| Artifact | Against | Size |
|---|---|---|
| `0001-ggml-openvino-npu-adaptation.patch` | llama.cpp `abb76ab380c7f3f731e365a859fb4cc64e939bb8` | 7 files, +213 / −8 |
| `ov_opencl_shim.hpp` | new file → `ggml/src/ggml-openvino/ov_opencl_shim.hpp` | ~150 lines |

All hunks are inside `ggml/src/ggml-openvino/`. No llama.cpp core, sampler, or ggml-CPU file is
touched.

## How this relates to `src/ggml-openvino/`

The engine's source is **in the repository** at [`src/ggml-openvino/`](../src/ggml-openvino/) — the
full upstream backend directory with WangCai's changes applied, so it can be read and reviewed without
applying anything. `tools/bootstrap.ps1` clones the pinned llama.cpp into `src/llama/` and **overlays**
that directory onto `ggml/src/ggml-openvino/`, then prints `git diff --stat` so you can see exactly what
changed relative to pristine upstream.

This directory is the same change expressed as a diff — the artifact for review and for upstreaming.
To use it instead of the overlay (e.g. to verify the two are still equivalent):

```powershell
tools\bootstrap.ps1 -UsePatch
```

or by hand:

```powershell
git clone https://github.com/ggml-org/llama.cpp src/llama
cd src/llama
git checkout abb76ab
git apply ..\..\patches\0001-ggml-openvino-npu-adaptation.patch
Copy-Item ..\..\patches\ov_opencl_shim.hpp ggml\src\ggml-openvino\
```

`git apply --check` first if you are trying a newer llama.cpp: the OpenVINO backend moves around
between releases, and a rejected hunk is a rebase of these hunks, not a bug in your tree.

## What each hunk does

### `ov_opencl_shim.hpp` (new file) + the four include swaps

**Problem.** `ggml-openvino.cpp`, `utils.cpp` and `ggml-openvino-extra.{h,cpp}` include
`<openvino/runtime/intel_gpu/ocl/ocl.hpp>` (and `ggml-openvino-extra.h` included `<CL/cl.h>`). That
header pulls `<CL/cl2.hpp>`, which is not in the OpenVINO runtime package and not in a Visual Studio
Build Tools install. An NPU-only build therefore fails on a GPU header it never uses:
`fatal error C1083: cannot open include file "CL/cl2.hpp"`, from
`openvino/runtime/intel_gpu/ocl/ocl_wrapper.hpp:50`.

**Fix.** A header that declares exactly what those files need to *compile*: the `cl_*` scalar
typedefs, distinct opaque handle types (`_cl_context*`, `_cl_command_queue*`, … — distinct, so the
overloaded `ClContext` constructors do not become ambiguous), the handful of enums referenced,
inline throwing stubs for the `clGet*`/`clCreate*` entry points, plus `ov::intel_gpu::ocl::ClContext`
and `USMTensor`. Every path in it is GPU-only; the NPU never calls into it.

Swapping the include is a one-line change per file and keeps the diff honest — nothing is `#ifdef`'d
out, the GPU paths are still type-checked.

### `ggml-decoder.h` — `get_mask_ctx_size()`

The one function that decides how wide an attention mask input must be.

llama.cpp hands the backend one mask per attention module, padded to the **largest** KV buffer in
the model (`llama_kv_cache::get_n_kv()`), while each layer attends over its own cache. Under dynamic
graphs that is invisible because K gets sliced down to the mask width. Under static (NPU) graphs both
shapes are baked into the compiled graph, so the sliding-window layers need the ring length and the
full-attention layers the context length — and the parameter shape *and* the host tensor built for
the binding have to agree, or the NPU plugin rejects the binding
(`input tensor size is not equal to the model input type`) or opset-13 SDPA refuses shape inference
(`attention_mask_input_correctness`).

For LFM3-1.7B that is the difference between `mask_kv = 1024` for six layers and `768` for five.

### `ggml-decoder.cpp` — mask branch of `get_graph_input_shape()`

Uses `get_mask_ctx_size()` instead of the model-wide context for the mask parameter, and keeps a
one-line-per-distinct-mask `ov-mask:` warning. That log line is what turned a shape-guessing game
into a fact: both mask tensors arrive as `ne=[256,2,1,1]`, so neither width comes from the host
tensor.

### `utils.cpp` — the two static bindings, plus diagnostics

- `get_ov_input_tensor_static_decode()` and `get_ov_input_tensor_static_prefill()` now size the
  padded mask with `get_mask_ctx_size()`. These two sites and the parameter shape above must move
  together; that coupling is the whole reason the bug was hard.
- `GGML_OPENVINO_MASK_MODE=1`: build the mask from token positions instead of llama.cpp's. The
  padding keeps padded rows finite on their own column, mirroring `set_zero_diagonal()`, so a fully
  masked row cannot produce `0/0 = NaN` and leak into the recurrent-state gather.
- `dump_ov_outputs_raw()` (`GGML_OPENVINO_DUMP_BIN`): raw per-output dumps on the static *and*
  dynamic paths, so two devices can be compared element by element. Aggregate `min/max/mean`
  statistics — the only thing `GGML_OPENVINO_DEBUG_OUTPUT` gives you — hide single-row errors, and a
  single wrong row is exactly what a mis-selected chunk position looks like.

### `openvino/op/flash_attn_ext.cpp` — `trim_mask_to_kv()`

When the mask is still wider than the K operand, slice it to the KV extent from
`seq_active_start`. A guard rather than a fix: with `get_mask_ctx_size()` in place the widths already
agree on LFM3, so this path stays inert.

### `ggml-openvino-extra.{h,cpp}` — env plumbing

Registers the three new variables in the recognized-env table (`ggml_openvino_getenv_int`/`_str`
read from a table cached at backend init, so an unregistered name silently reads as unset — that
cost an afternoon), parses `GGML_OPENVINO_NPU_COMPILE_OVERRIDES`, and points the CL include at the
shim.

## Regenerating the patch

From a patched llama.cpp checkout — and remember the patch and `src/ggml-openvino/` are two views of
one change, so both must move together:

```powershell
git diff -- ggml/src/ggml-openvino > ..\..\patches\0001-ggml-openvino-npu-adaptation.patch
Copy-Item ggml\src\ggml-openvino\ov_opencl_shim.hpp ..\..\patches\
Copy-Item ggml\src\ggml-openvino\* ..\..\src\ggml-openvino\ -Recurse -Force
```

Keep the hunks in one file per concern; if a change is orthogonal (a new knob, a new lowering), make
it `0002-*.patch` so it can be reviewed and upstreamed separately.

## Upstreaming

Items 2–4 (`get_mask_ctx_size`, the paired bindings, `trim_mask_to_kv`) are model-correctness fixes
for hybrid models on the static path and are the natural upstream candidates. The shim is arguably an
upstream build-config question (make the GPU remote-context usage optional), and the diagnostics
belong there too as first-class env vars.
