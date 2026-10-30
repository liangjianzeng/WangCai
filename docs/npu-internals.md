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

### The warmup trap — read this before trusting any dump comparison

`GGML_OPENVINO_DUMP_BIN` numbers passes in execution order, and **the first passes are not the prompt**.
llama.cpp warms the backend up before the first real token, so `prefill_0`, `prefill_1` and `decode_2`
came out **byte-identical between two runs of the same model with two different prompts**, while
`prefill_3..6` and `decode_7..11` did not. Statistics over warmup passes look clean and mean nothing.

The first version of the section below did exactly this and reported a per-layer curve computed on
synthetic warmup input. It was removed and re-measured. Identify the passes mechanically rather than by
index — run the same model twice with different prompts and compare hashes; every name whose hash
matches is a warmup pass:

```powershell
foreach ($f in Get-ChildItem dbg\runA -Filter *.bin) {
    $b = Join-Path dbg\runB $f.Name
    if (Test-Path $b) {
        $same = (Get-FileHash $f.FullName).Hash -eq (Get-FileHash $b).Hash
        '{0}  {1}' -f $(if ($same) { 'WARMUP' } else { 'REAL  ' }), $f.Name
    }
}
```

### Per-layer divergence (real passes)

`LFM3-1.7B-Q4_K_M`, ~220-token prompt (one full 256-column chunk), NPU against the CPU-static reference
under each side's default quantization — i.e. the configuration that outputs the wrong thing. The
recurrent conv state (`cache_r_l*`, 6 × 2048 per layer) is the informative output because each layer's
state is a function of everything below it:

| Layer | `prefill_3` | `prefill_4` | `decode_7` | | Layer | `prefill_3` | `prefill_4` | `decode_7` |
|---|---:|---:|---:|---|---|---:|---:|---:|
| `l0` | 0.9956 | 0.9939 | 0.9985 | | `l13` | 0.5343 | 0.9068 | 0.8275 |
| `l1` | 0.9856 | 0.9832 | 0.9930 | | `l15` | 0.3684 | 0.8903 | 0.7809 |
| `l3` | 0.9711 | 0.9185 | 0.9490 | | `l17` | **0.1627** | 0.8315 | 0.7243 |
| `l5` | 0.9562 | 0.9107 | 0.9434 | | `l19` | 0.2849 | 0.8967 | 0.7705 |
| `l7` | 0.9296 | 0.8376 | 0.8353 | | `l21` | 0.2420 | 0.9136 | 0.6947 |
| `l9` | 0.8728 | 0.8390 | 0.7865 | | `l23` | 0.6455 | 0.9450 | 0.8721 |
| `l11` | 0.8290 | 0.8691 | 0.7800 | | | | | |

Four things follow:

1. **Layer 0 already differs** (`0.9956`, max abs `0.064` on order-1 values). No single layer is broken;
   each contributes a small error and the residual stream compounds it. That is the signature of
   arithmetic rather than indexing, and it matches the flattened logits measured above.
2. **It is present in the first real prefill chunk** — before any decode step and before any state is
   reused — so the cross-step state-chaining area (conv-state gather, `chunk_valid_len`, decode slicing)
   is exonerated for this defect. It still has to be right; it is not what makes the output wrong.
3. The collapse is **data-dependent, not step-count-dependent**: the worst case is deep layers of the
   *first* chunk (`0.16` at l17) while the second chunk of the same prompt stays ≥ 0.83 and decode sits
   around 0.7–0.9.
4. It is concentrated in the **short-conv path**. The attention writes tell the opposite story:

| KV tensor (row mode, `-RowSize 512` = one position = 4 KV heads × 128) | reading |
|---|---|
| `cache_v_*`, all 200 written rows | max abs diff `1.5e-9`–`2.7e-6`, `leading-clean=200` → **V is written exactly** |
| `cache_k_l2` rows 1–7 | cosine 0.95–0.9998 → small relative error |
| `cache_k_l12` rows 1–7 | cosine 0.90–0.99 → same order |
| **row 0 of every K layer** | cosine **0.2876**, max abs **1.06e10** → position 0 is grossly wrong on one side |

V exact means the dequant → norm → projection chain is broadly right, which is also what the requant
control below shows. **K row 0 is the one structural anomaly in the whole comparison** and the sharpest
lead available: whatever writes the first position (the prefill write index for row 0, or the value
written there) does not behave like rows 1..n.

Whole-buffer statistics over the rows a chunk never wrote are not measurements: both sides hold zeros
there, which reads as `cosine 0.135, maxDiff 0.0000`. Use row mode — see
[`tools/README.md`](../tools/README.md).

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

### The requant control, and what it settled

Comparing the NPU against the CPU is only meaningful if both sides load the same weights, and by default
they do not: the NPU forces grouped 4 bit on every weight (`docs/env-vars.md`). Measured with the policy
made identical on both sides (`GGML_OPENVINO_REQUANT_KQUANT=q4_sym128_all` on the CPU, `GGML_OPENVINO_FORCE_STATIC=1`
so the CPU runs the NPU's static code path):

| Comparison | worst conv state | worst K row | logits |
|---|---:|---:|---|
| NPU (forced requant) vs CPU (native Q4_K) | `0.215` | `0.31` | flattened, garbage past ~3 tokens |
| NPU vs CPU, **both** requantized to `Q4_0_128` | `0.9589` | `0.9994`–`1.0000` | top-1 agrees on 4 of 6 passes |

Two thirds of the gap was the two devices running *different quantizations*, not the NPU computing badly.
What survives is real but far smaller, and it is consistent with the earlier conclusion: a per-layer
rounding error in the conv path, compounding.

A native-Q4_0 checkpoint (`LFM3-1.7B-QAD-Q4_0.gguf`) pushes this further and separates the last conflated
pair of behaviours: on a 220-token **continuation** it is byte-identical on native CPU, OpenVINO-CPU static
and the NPU, while on a 64-token Chinese **instruction** run the NPU alone degenerates, with the conv state
diverging per step as `decode_2 0.989 → decode_9 0.51 → plateau ≈0.25`. Low-entropy tasks hide the defect
completely; they are useful as plumbing checks and as nothing else.

### Where to take it next

1. **K row 0.** Every K layer's row 0 is wrong by eight orders of magnitude (`cosine 0.288`, max abs
   `1.06e10`) while rows 1..n sit at `0.90–0.9998`, and V is exact everywhere. That asymmetry — one row of
   one tensor family — is the most specific thing the dumps have produced. Look at the prefill write index
   for the first position and at what value lands there.
2. **Why the conv path degrades while V does not.** Both consume the same requantized weights and the same
   hidden states; one compounds, one is exact to `1e-8`. The difference is the op (`d_conv=7` gated causal
   conv + its state slicing) and the state layout — that is where the f32 bisection should start.
3. **Isolate the output projection.** `output.weight` is requantized to Q8_0_C and the projection is
   128000×2048. `result_norm` is not dumpable (appending a `Result` node aborts the NPU plugin), so this
   needs a different hook than `GGML_OPENVINO_DUMP_BIN`.
4. **F32 for a single op.** Force one op at a time into f32 (the RMS-norm chain, the short conv, the final
   `MatMul`, the SDPA) and watch the cosine.
5. **A different architecture as control.** A small pure-transformer model validated upstream on NPU would
   still separate "NPU plugin numeric issue" from "LFM3-specific issue"; a second quantization of the same
   model (item above) narrowed but did not close it.

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
