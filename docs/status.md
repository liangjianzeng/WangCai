# Status

Point-in-time, measured, and falsifiable. Each claim lists the command that proves or disproves it.

**Baseline:** llama.cpp `abb76ab380c7f3f731e365a859fb4cc64e939bb8` + [patches/](../patches/README.md)
**Runtime:** OpenVINO 2026.4.1 · **Machine:** Intel Core Ultra 9 275HX, Intel AI Boost (NPU 3720), 32 GB
**Model under active development:** LFM3-1.7B `Q4_K_M`, 1049 MB, 24 layers
(13 gated short-conv + 5 sliding-window@256 + 6 global attention)

## Milestones

| # | Milestone | Status | Evidence |
|---|---|---|---|
| 0.1 | OpenVINO backend builds without GPU/OpenCL SDK | ✅ | `tools\build.ps1` on a Build Tools + OpenVINO wheel install |
| 0.2 | NPU device registered and selectable | ✅ | `llama-cli --list-devices` → `OPENVINO3: ... Intel(R) AI Boost (NPU 3720)` |
| 0.3 | Both static graphs compile on NPU | ✅ | run reaches generation; cold compile 36.4 s logged as load time |
| 0.4 | Hybrid KV rings addressed correctly | ✅ | `ov-mask:` shows `is_swa=1 -> mask_kv=768`, `is_swa=0 -> mask_kv=1024` |
| 0.5 | Short-conv state chains across decode steps | ✅ | 1-token prompt stays coherent over 40 decode steps on NPU |
| 0.6 | Static path proven numerically sound off-device | ✅ | `-Backend static` (CPU) coherent, matches dynamic bit-for-bit on early passes |
| **1.1** | **NPU output numerically on par with CPU reference** | 🟡 **open** | cosine to reference: prefill `0.969`, decode `0.73–0.87` |
| 1.2 | Greedy matches reference token-for-token ≥ 64 tokens | 🟡 | diverges after 2–3 tokens |
| 1.3 | Acceptance harness in CI | ⬜ | needs 1.1 |
| 2.1 | NPU decode beats OpenVINO-CPU | ⬜ | decode 8.3–8.7 t/s vs 21.7–29.2 (CPU) / 54.1 (native) |
| 2.1b | NPU prefill competitive | 🟡 | `pp512` 415 t/s = 73% of native reference; ~1.4 of ~13 TOPS used |
| 2.2 | Warm start < 5 s | ⬜ | cache dir works, 36 s cold |
| 3.x | Model-line breadth (0.3 B–8 B, long context) | ⬜ | |
| 4.x | LFM3 omni modalities (audio in, vision in) | ⬜ | |

## What works today

- **Reference quality output on CPU.** `-Backend native` and `-Backend ovcpu` both produce coherent
  Chinese and English answers through the chat template. This is the ground truth every NPU claim is
  measured against.
- **The NPU runs the full model end to end**, including the recurrent short-conv layers, sliding-window
  attention and the global attention layers, with flash attention (`-fa 1`) and a single sequence.
- **The static path is trustworthy off-device.** `GGML_OPENVINO_FORCE_STATIC=1` on CPU reproduces the
  NPU's code path, which turns most debugging into a seconds-long loop.
- **Diagnostics are good enough to localize a defect**, which is how the accuracy gap got narrowed to
  the plugin rather than the graph: raw output dumps, per-pass top-token alignment, element-wise
  comparison, and run-time NPU compile-config overrides.

## Open defects

### 1. NPU logits are flattened (blocking)

Greedy generation on the NPU agrees with the CPU reference for 2–3 tokens and then wanders into
word salad.

| Pass | CPU reference | NPU |
|---|---|---|
| prefill (generating) | id2083 · 19.58 | id2083 · 17.53 (cosine `0.969`) |
| decode 1 | id1094 · 20.27 | id1094 · 13.51 (cosine `0.786`) |
| decode 2 | id310 · 25.87 | id310 · 15.81 (cosine `0.804`) |
| decode 3 | id5141 · 22.29 | **id342** · 14.91 (cosine `0.870`) |
| decode 4 | id278 · 26.06 | **id711** · 11.32 (cosine `0.726`) |

Same norm, lower peak → precision signature, not an indexing one. The per-layer measurement over the
**real** prefill chunks of a ~220-token prompt (conv-state outputs) shows a small error at the bottom of
the stack compounding upward — `l0 0.9956`, `l9 0.873`, `l13 0.534`, **`l17 0.163`** — and it is already
there in the first chunk, before any decode step or state reuse. The conv path degrades; the attention
writes largely do not: V is written exactly (max abs `2.7e-6` across all 200 rows), K sits at
`0.90–0.9998` **except row 0**, which misses by eight orders of magnitude (`cosine 0.288`, max abs
`1.06e10`). That single row is the most concrete lead in the investigation. Ruled out and still-standing
conclusions are tabulated in
[npu-internals.md § 4](npu-internals.md#4-the-accuracy-gap), including the full NPUW/dynamic-quantization
lever sweep (nothing fixes it; disabling those paths makes it strictly worse).

**Classify the dump passes before reading any comparison.** `prefill_0`, `prefill_1` and `decode_2` are
llama.cpp warmup: byte-identical between runs of the same model with different prompts. An earlier version
of the table above was measured on warmup and had to be redone; the hash-compare recipe that separates the
two is in [npu-internals.md § 4](npu-internals.md#4-the-accuracy-gap).

**A native-Q4_0 checkpoint separates two errors that were being conflated.** With
`LFM3-1.7B-QAD-Q4_0.gguf` (ModelScope, QAD = quantization-aware distillation) the requant asymmetry mostly
disappears, and the two remaining behaviours split cleanly by task: a 220-token continuation comes out
**byte-identical on native CPU, OV-CPU static and the NPU**, while a 64-token Chinese instruction run still
degenerates on the NPU alone (conv-state cosine `decode_2 0.989` → `decode_9 0.51` → plateau `≈0.25`,
top-1 diverging from step 10 onward). A continuation is a plumbing test, not a coherence test — it matches
even when the device is wrong.

Reproduce:

```powershell
tools\run-npu.ps1 -Model models\LFM3-1.7B-Q4_K_M.gguf -PromptFile prompts\zh.txt -Backend static -Label cpu -DumpBin tmp\dumps\cpu
tools\run-npu.ps1 -Model models\LFM3-1.7B-Q4_K_M.gguf -PromptFile prompts\zh.txt -Backend npu    -Label npu -DumpBin tmp\dumps\npu
tools\top-token.ps1 -Dir tmp\dumps\cpu ; tools\top-token.ps1 -Dir tmp\dumps\npu
tools\compare-tensors.ps1 -A tmp\dumps\cpu -B tmp\dumps\npu
```

### 2. NPU decode is 6× slower than the CPU reference (blocking for the thesis)

8.3–8.7 t/s vs 54.1 t/s native / 21.7–29.2 t/s OpenVINO-CPU on the same model and machine — about
**0.03 of the available TOPS**. The whole argument for using the NPU is performance per watt; losing to
the CPU on absolute throughput while the CPU stays free is not yet explained. Note this is *specific*
to decode: prefill at `pp512` is competitive (415 vs 570 t/s), so the plugin is not uniformly
misconfigured. Suspects, in order: stateless cache re-binding per step, activation quantization cost,
compile hints for decode-shaped graphs, the runtime-indexed conv-state `Gather`.

### 3. Sequences longer than the KV cache take the OpenVINO backend down

`Check 'idxValue < static_cast<int64_t>(srcDimAxis) ...' failed at intel_cpu\src\nodes\scatter_update.cpp:915`
whenever a KV write index lands outside the cache. Observed from `llama-perplexity` (any device) and
from `llama-bench -p 1024 -n 32` with a 1024 context; the same test at `-p 512` runs clean, which is
what points at an out-of-range index rather than at the graph shape. On the **NPU the same condition
takes the device down** with `ZE_RESULT_ERROR_DEVICE_LOST` instead of failing a check.

Consequences: perplexity is currently unusable as an accuracy metric (exactly the metric wanted for
defect 1), and an out-of-range index is a device-level failure on NPU, which deserves an upstream
report on its own. Root cause not established — the earlier claim in this document that "the
multi-output graph breaks the `SET_ROWS` lowering" was **not supported** by the `-p 512` / `-p 1024`
differential and has been withdrawn.

### 4. `GGML_OPENVINO_DEBUG_NODE` aborts the process on NPU

Appending `Result` nodes to a graph makes the plugin die during compile. Worked around with
`GGML_OPENVINO_DUMP_BIN`; the upstream fix is either plugin-side or refusing the request with an error.

### 5. No control model

Every conclusion so far comes from one architecture. A small model that is validated upstream on the
NPU would separate "NPU plugin behaviour" from "LFM3 behaviour"; the local candidate turned out to be
a truncated download.

## Constraints and non-negotiables

| Constraint | Why |
|---|---|
| `-fa 1` only | with `-fa 0` llama.cpp flattens V to one element per row; the OpenVINO scatter write-back then rejects the index |
| `-np 1` only | the static path is single-sequence; `-np 2` hits `state is only supported with stateless` |
| bf16 unsupported | rejected at scheduling on NPU |
| fresh `GGML_OPENVINO_CACHE_DIR` per configuration | otherwise a stale compiled graph silently wins |
| chat template required | an instruct model driven by raw completion produces repetition salad on every backend, including native CPU |
| ~36 s cold compile per graph | use a persistent cache dir; see roadmap 2.2 |

## How we know a claim is real

Three habits that are worth enforcing on every PR:

1. **Compare tensors, not adjectives.** `compare-tensors.ps1` output, not "looks better".
2. **Align passes before comparing them.** Two runs do not produce the same number of graph calls;
   comparing pass N to pass N is how you get confident, wrong answers.
3. **Prove the device.** `--list-devices` plus a dump comparison — two devices are never bit-identical,
   and a "NPU" run with CPU-like throughput has run on the CPU.
