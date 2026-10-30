# NPU internals: what is actually hard

The parts of "run an LLM on Intel AI Boost" that are not covered by the fact that a backend exists.
Each section states the constraint, the symptom you see when you violate it, and the fix.

---

## 1. Static shapes couple the parameter shape to the host binding

A compiled graph bakes in every input shape. Two independent pieces of code must therefore agree
exactly, for every input:

```
GgmlOvDecoder::get_graph_input_shape(op, input)      ← the compiled parameter shape
get_ov_input_tensor_static_{decode,prefill}(…)        ← the ov::Tensor you actually bind
```

If they disagree, the NPU plugin refuses the binding:

```
Check 'is_dynamic || port_partial_shape == tensor_shape' failed at
  intel_npu/src/backend/src/zero_infer_request.cpp:1250: got [1,1,256,1024] expecting [1,1,256,768]
```

Note the asymmetry of that message: it does not tell you *which* of the two is wrong, and both sides
have plausible reasons for their number. Any change to one side must be made to the other in the same
commit. `get_mask_ctx_size()` exists precisely so they cannot drift.

---

## 2. Hybrid models address two KV rings with one mask tensor

LFM3-1.7B is 24 layers: 13 gated short-conv, 5 sliding-window@256, 6 global attention. Under a static
graph it needs **two** different mask widths:

| Mask | Context | Why |
|---|---:|---|
| full attention | `1024` (= `-c`) | attends over the whole context |
| sliding-window | `768` (the ring: `3 × window`) | attends over the ring only |

What llama.cpp actually hands the backend, measured — both masks:

```
ov-mask: name=attn_inp_kq_mask ne=[256,2,1,1] is_swa=0 -> mask_kv=1024 | ctx=1024 ctx_swa=768 chunk=256
ov-mask: name=attn_inp_kq_mask ne=[256,2,1,1] is_swa=1 -> mask_kv= 768 | ctx=1024 ctx_swa=768 chunk=256
```

Neither width comes from the host tensor. `256` is llama.cpp's `n_kv` rounded up to a multiple of its
occupancy granularity; the width a static graph needs comes from **the cache the consuming op reads**.
Deriving it from the tensor is the bug; deriving it from the consuming cache is
`get_mask_ctx_size()`.

The failure modes on the way there, all real:

| Attempt | Result |
|---|---|
| both masks at `ctx` (original) | `Check 'attention_mask_input_correctness' failed at scaled_dot_product_attention_shape_inference.hpp:92` — mask `[1,1,256,1024]` vs K/V `[1,16,768,128]` |
| both masks at the ring length | SDPA accepts it, binding rejects it: `got [1,1,256,1024] expecting [1,1,256,768]` |
| both masks at the host width (256) | SDPA now fails on the **full-attention** layers: `{[1,16,256,128],[1,16,1024,128],[1,16,1024,128],[1,1,256,256]}` |
| per-module width (correct) | both graphs compile and run |

Two supporting rules:

- **Column slicing is strided, so pad on the host and slice in the graph, never both.** Padding the
  shared host mask is a `pad_input()` with `std::min(cols, padded_cols)`, which conveniently truncates
  to the first N columns — the convention upstream also uses for its stateful sliced mask.
- **Keep padded rows finite.** `set_zero_diagonal()` exists so a fully masked padded row does not
  evaluate `softmax` as `0/0`. A NaN in a padded row is not harmless: the recurrent-state gather reads
  columns *immediately after* the last valid token, i.e. exactly the padding region.

---

## 3. The recurrent (conv) state is a stream, not a buffer

LFM3's short conv has `d_conv = 7`, so the per-layer state is `6 × 2048 = 12288` elements
(`cache_r_l*`, bound as `[1,1,1,12288]`). The op consumes a stream laid out as

```
[ previous state: 6 columns │ chunk tokens: chunk_size columns ]
```

and the write-back must capture the 6 columns **ending at the last valid token**, i.e. stream columns
`[v, v+6)` for `chunk_valid_len = v`. Prefill does that with a `Gather` at `chunk_valid_len` (a Gather
rather than a Slice, so the output shape stays static); decode uses a `Slice` at `rs_src_begin_*`.
Two different code paths for the same conceptual operation — a useful thing to remember when one of
them is wrong.

Evidence that pins the conv path as (probably) innocent: a **1-token prompt is coherent on the NPU**,
and it executes the same padded-to-256-column prefill graph, then 40 decode steps that each
read-and-write the conv state. Multi-column convolution and per-step state chaining therefore work.

---

## 4. The accuracy gap

**Status: open.** The NPU runs the model end to end; the numbers are off in a way that is consistent
and not yet explained.

### How it was localized

Greedy generation, same prompt/seed, three execution paths, then compare *raw output tensors*
(`GGML_OPENVINO_DUMP_BIN`) rather than text. Aligning passes by their top-1 token id:

| Pass | CPU dynamic | CPU static | NPU static |
|---|---|---|---|
| prompt batch 1 | id229 · 12.639 | id229 · 12.639 | id12942 · 10.555 |
| prompt batch 2 | id0 · 19.015 | id0 · 19.015 | id7 · 16.141 |
| **prefill (generating)** | id2083 · 18.98 | id2083 · 19.58 | id2083 · 17.53 |
| decode 1 | id1094 · 23.14 | id1094 · 20.27 | id1094 · 13.51 |
| decode 2 | id310 · 27.07 | id310 · 25.87 | id310 · 15.81 |
| decode 3 | id5141 · 20.90 | id5141 · 22.29 | **id342** · 14.91 |
| decode 4 | id278 · 25.82 | id278 · 26.06 | **id711** · 11.32 |

Derived facts:

- **CPU dynamic ≡ CPU static.** Same top-1 ids and essentially identical magnitudes, so static-mode
  graph construction and the mask/ring work are not the source of the error.
- **Prefill is close**: cosine `0.969` to the CPU reference, same top-1 and same top-5 set.
- **Decode is not**: cosine `0.73–0.87`, and the distribution is flattened — same L2 norm, lower peak
  (`25.87 → 15.81`). Greedy tracks the reference for 2–3 tokens, then leaves the rails.
- Cache writes (K, V, conv state) agree closely between devices on min/max/mean; a single wrong row is
  invisible in those aggregates, which is exactly why the raw dumps exist.

A flattened-but-norm-preserving logit distribution is a precision signature, not an indexing
signature: an off-by-one row or a mis-sliced window produces a *different* distribution, not a scaled
one.

### Per-layer divergence (first measurement)

Every graph output of the **first prefill chunk** dumped on both devices
(`GGML_OPENVINO_DUMP_BIN`, `tools/compare-tensors.ps1 -MaxElements 120000`) — the recurrent state
outputs `cache_r_l*` are the informative ones, because each is a function of everything below it:

| Layer | cosine | | Layer | cosine |
|---|---:|---|---|---:|
| `l0` | 0.9987 | | `l11` | 0.635 |
| `l1` | 0.989 | | `l13` | 0.419 |
| `l3` | 0.976 | | `l15` | 0.295 |
| `l5` | 0.944 | | `l17` | **0.215** |
| `l7` | 0.850 | | `l19` | 0.360 |
| `l9` | 0.720 | | `l21` / `l23` | 0.256 / 0.662 |

Two conclusions:

1. **Layer 0 is already different** (`0.9987`, max abs error 0.083 on order-1 values). Nothing deep in
   the stack is broken; every layer contributes a small error and the residual stream compounds it —
   which is exactly the signature of the flattened logits observed above, and of precision rather than
   indexing.
2. **The divergence is present before any decode step and before any state is reused**, so the whole
   cross-step state-chaining area (conv-state gather, `chunk_valid_len`, decode slicing) is exonerated
   for this defect. It still needs to be right, but it is not what makes the output wrong.

*Caveat, and what slicing showed.* The K/V numbers above were **not** usable as printed. Running the
comparison in row mode (`-RowSize 512`, one row = one position = 4 KV heads × 128) revealed that this
prompt wrote only **two rows**; every other row is zero on both sides, which is what produced
`cache_v_l20 cosine=0.135, maxDiff=0.0000` and the `maxDiff` in the millions. On the rows that were
actually written:

| Tensor | rows 0–1 | reading |
|---|---|---|
| `cache_v_l16`, `cache_v_l20` | max abs diff `8.6e-8`, `1.8e-7` | V writes are essentially exact |
| `cache_k_l2`, `cache_k_l8` | cosine `0.998` / `0.994` (row 0) | small relative error |
| `cache_k_l12` | cosine `0.974` (row 0) → `0.308` (row 1) | row 1 materially worse |

So the attention state writes are close, and the large divergences live in the **short-conv path**
(`cache_r_l*`), which is the same path that degrades monotonically with depth. Two caveats remain
honest about: the prompt was two tokens, so a `d_conv=7` causal conv state is dominated by the
zero-padded region and its relative error is amplified by small magnitudes; and K magnitudes of order
`1e4` were seen on *both* devices, so they are a model property, not an NPU artifact.

**Next measurement:** re-dump with a ~240-token prompt (one full 256-column chunk) so the conv state is
filled with real data and K/V have hundreds of written rows, then repeat the row profile. Until that
exists, the depth curve is directional evidence, not a localization.

### What has been ruled out

| Hypothesis | Test | Verdict |
|---|---|---|
| mask content wrong | `GGML_OPENVINO_MASK_MODE=1` (position-derived causal mask) | CPU-static stays coherent, NPU still wrong → mask content exonerated |
| multi-column conv | `PREFILL_CHUNK_SIZE` = 1/2/7/32/128/256 | no change → not chunk-shape related |
| conv op itself | 1-token prompt, 40 decode steps | coherent → conv and per-step state chaining fine |
| bound inputs differ | `GGML_OPENVINO_DEBUG_INPUT` on both devices | identical bound inputs (tokens, positions, indices, masks) |
| static path itself | `GGML_OPENVINO_FORCE_STATIC=1` on CPU | coherent → static translation is correct |
| weight requant to `Q4_0_128` | force the same requant on CPU | still coherent → not sufficient on its own |
| missing op lowering (`SSM_CONV`) | read the code | already implemented as depthwise `GroupConvolution` |
| GQA/SDPA lowering | `GGML_OPENVINO_MANUAL_GQA_ATTN=1`, `LOG_UNSUPPORTED_OPS=1` | no unsupported-op fallbacks logged; no improvement |
| `-fa 0` | any device | dead end by design (see [troubleshooting](troubleshooting.md)) |

### The NPUW / quantization lever sweep

Everything the backend sets for the NPU plugin, toggled at run time via
`GGML_OPENVINO_NPU_COMPILE_OVERRIDES` (each cell a fresh `GGML_OPENVINO_CACHE_DIR`):

| Override | Result |
|---|---|
| *(none — default)* | runs, flattened logits, garbage past ~3 tokens |
| `NPU_COMPILER_DYNAMIC_QUANTIZATION=NO` | `ZE_RESULT_ERROR_OUT_OF_HOST_MEMORY` (`pfnAppendGraphExecute`, code `0x70000002`) — the non-quantized graph does not fit |
| `NPU_USE_NPUW=NO` | `ov::Exception` from `core.cpp:120` at compile; unsupported configuration |
| `NPUW_DQ=NO` | compiles, generation degenerates to `>>>>>>>>>>>>>>>>>` |
| `NPUW_DQ=NO,NPUW_DQ_FULL=YES` | `ov::Exception`, compile fails |
| `NPUW_DQ_FULL=YES` | degenerates to `>>>>>>>>>>>>>>>>>` |
| `NPUW_FOLD=NO` | degenerates to `>>>>>>>>>>>>>>>>>`, compile time 383 s |
| `NPUW_WEIGHTS_BANK=none` | unchanged |

Reading: the compressed-weights + on-device-dequant path is not merely an optimization here — turning
it off makes things strictly worse (a collapsed single-token output is a *broken weights* signature).
And the accuracy defect survives every documented lever. That combination points away from "pick a
better flag" and towards something structural in how this model's graph is executed on-device.

### Where to take it next

1. **Row-sliced per-layer comparison.** The conv-state comparison above is the first cut and it already
   says where the error lives (every layer, compounding). What is missing is a trustworthy K/V
   comparison: `compare-tensors.ps1` must slice to the rows a chunk actually wrote, following the
   `cache_idx` write positions, instead of comparing whole buffers whose unwritten regions are zeros or
   uninitialized garbage.
2. **Isolate the output projection.** `output.weight` is requantized to Q8_0_C and the projection is
   128000×2048. Compare `result_norm` against `result_output` between devices: if the hidden state
   matches and only the logits differ, the defect is localized to the final `MatMul` + requant.
3. **F32 for a single op.** Force one op at a time into f32 (the RMS-norm chain, the final `MatMul`,
   the SDPA) and watch the cosine.
4. **A second model.** Any pure-transformer model that is validated upstream on NPU (small, ≤2 B) as a
   control would immediately separate "NPU plugin numeric issue" from "LFM3-specific issue". The local
   control model was a truncated download, so this is still missing.

---

## 5. Tooling that is part of the engine

These exist because reading the code was not enough:

| Tool | Why it exists |
|---|---|
| `GGML_OPENVINO_DUMP_BIN` + `tools/compare-tensors.ps1` | aggregate `min/max/mean` statistics hide single-row errors; element-wise cosine does not |
| `tools/top-token.ps1` | aligns passes between two runs by top-1 token id — without it you compare the wrong pass of each run and draw confident, wrong conclusions |
| `GGML_OPENVINO_MASK_MODE` | separates "mask content" from "graph execution" |
| `GGML_OPENVINO_NPU_COMPILE_OVERRIDES` | turns an overnight flag sweep into a five-minute one |
| `GGML_OPENVINO_FORCE_STATIC` on CPU | seconds instead of ~36 s per experiment, same code path |

`GGML_OPENVINO_DEBUG_NODE` (extra graph outputs) **aborts the process on the NPU** — the plugin cannot
take appended results. Everything diagnostic in this tree reads outputs the graph already produces.

---

## 6. Performance observations

Two halves, and they deserve to be treated separately — conflating them produced a badly wrong
conclusion in an earlier revision of this document.

**Prefill is fine.** At `pp512` (two full 256-token chunks, no padding waste) the NPU reaches
**415 t/s**, vs 610 on OpenVINO-CPU and 570 on the native CPU reference — 68%/73%. The accelerator
does what it is supposed to do on the compute-bound half of the workload.

What is *not* explained is the absolute efficiency: 415 t/s on a 1.7 B model is ≈ 870 GFLOP per
256-token chunk ≈ **1.4 TOPS effective out of ~13 TOPS INT8**. An order of magnitude is unaccounted
for.

**Decode is the problem.** `8.3–8.7 t/s` on NPU vs `21.7–29.2` on OpenVINO-CPU and `54.1` on the
native CPU reference: a **6× loss to the CPU it was meant to replace**. At ≈ 3.4 GFLOP/token that is
~0.03 TOPS — two orders of magnitude below the hardware. Whatever is wrong, it is wrong here.

**And short-prompt numbers on the NPU are meaningless.** The static prefill graph is fixed at
`GGML_OPENVINO_PREFILL_CHUNK_SIZE` columns (256 by default), so a 4-token prompt pays the full cost
of 256 and llama.cpp reports `useful tokens / wall time`: the same 0.66 s chunk reads as 6 t/s for a
4-token prompt and 12 t/s for an 8-token one. Any NPU-vs-CPU prompt comparison made on short prompts
measures padding. Use `llama-bench -p 512` or larger; for short-prompt workloads, shrink the chunk
size — it is a direct multiplier (and part of the graph cache key, so budget one compile per value).

Candidate causes for the decode gap, roughly by suspicion:

1. the stateless cache contract — every step re-binds and re-writes K/V for 11 layers plus 13 conv
   states, in and out, as graph inputs and outputs,
2. activation quantization cost per step (`NPU_COMPILER_DYNAMIC_QUANTIZATION`), which for a single
   token is pure overhead against very little arithmetic,
3. `optimization-level` / compile hints not being set for a decode-shaped graph, and NPUW funcall
   granularity — ~1000-node graphs executed per token with per-invocation submit overhead,
4. the conv-state write-back being expressed as a runtime-indexed `Gather` (static shape, dynamic
   index → nothing on-device can optimize it away).

Cold compile is ~36 s per graph; warm (cache dir hit) most of that disappears, which is why a
persistent `GGML_OPENVINO_CACHE_DIR` is mandatory rather than advisory.

**Related robustness finding:** an out-of-range KV write index — e.g. `-p 1024 -n 32` against a 1024
context — makes the CPU plugin fail its `scatter_update` bounds check, and makes the NPU plugin drop
the device with `ZE_RESULT_ERROR_DEVICE_LOST`. Same bug, and on the NPU it is the worse of the two
failure modes.
