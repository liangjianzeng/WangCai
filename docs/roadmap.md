# Roadmap

Ordered by what unlocks what. The premise throughout: the NPU is capable, and the missing piece is
engineering, not silicon.

## Phase 0 — make it run · ✅ done

- [x] Build the OpenVINO backend for an NPU-only target without the GPU/OpenCL SDK
      (`ov_opencl_shim.hpp`).
- [x] Get LFM3-1.7B to compile both static graphs on the NPU. The blocker was the hybrid mask/KV-ring
      sizing: 13 short-conv + 5 sliding-window + 6 full-attention layers need per-module mask widths,
      and under static shapes the compiled parameter shape and the host binding have to agree.
- [x] Confirm the short-conv path (`GGML_OP_SSM_CONV` → depthwise `GroupConvolution`) and its
      per-step state chaining work on the NPU — verified with single-token prompts over 40 decode
      steps.
- [x] Instrumentation: raw output dumps, per-pass top-token alignment, element-wise comparison,
      position-derived masks, run-time NPU compile-config overrides.

## Phase 1 — make it correct · 🟡 in progress

The one thing that matters right now. NPU logits track the CPU reference through prefill
(cosine `0.969`) and flatten during decode (`0.73–0.87`); greedy generation drifts after 2–3 tokens.

- [ ] **Per-layer divergence map.** Dump every graph output on CPU-static and NPU, compare *row
      slices* of the valid region, find the first layer that diverges materially. Deliverable: a table
      of per-layer cosine, and a verdict — early layers (→ embedding/conv path) or late
      (→ output projection / requant).
- [ ] **Isolate the output projection.** `output.weight` is Q8_0_C and the projection is
      128000×2048. Compare `result_norm` vs `result_output` across devices; if the hidden state matches
      and only the logits differ, the defect is one `MatMul`.
- [ ] **Single-op precision bisection.** Promote one op class at a time to f32 (RMS-norm chain,
      `MatMul`, SDPA) and watch the cosine move.
- [ ] **A control model.** A small upstream-validated model that works on NPU, to separate "NPU plugin
      behaviour" from "LFM3-specific behaviour". (The local candidate was a truncated download.)
- [ ] **Re-quantization parity.** NPU forces `Q4_0_128` for all non-embedding weights. Not sufficient on
      its own to explain the defect, but the `GGML_OPENVINO_REQUANT_KQUANT` parser sits behind an
      `is_npu()` early return, so it needs a real CPU-side counter-test to be exonerated properly.
- [ ] **Un-examined NPU-only branches.** Audit every `ggml_openvino_is_npu()` divergence in the lowering
      code for precision implications (some unary lowerings deliberately skip f32 promotion on NPU).
- [ ] **Acceptance harness.** A fixed prompt set + reference logits per device, so "correct" is a
      number and not a vibe. Regression-gate it in CI.

*Exit criteria:* greedy generation matches the CPU reference token-for-token for ≥ 64 tokens on the
fixed prompt set, and per-layer cosine ≥ 0.99.

## Phase 2 — make it fast · 🟡 in progress

Reframed by measurement: **prefill is already competitive** (`pp512` 415 t/s = 73% of the native CPU
reference), so the accelerator and the compile configuration are not broken across the board. **Decode
is the loss** — 8.3–8.7 t/s vs 54.1 native, about 0.03 of the available TOPS — and prefill's 1.4-of-13
TOPS says there is headroom there too.

- [ ] **Attribute the decode budget per step.** Host↔NPU transfer of K/V for 11 layers plus 13 conv
      states in and out, activation quantization, and NPUW funcall submit overhead for a ~1000-node
      graph executed once per token. Numbers first, optimization second.
- [ ] **Compile-hint sweep for a decode-shaped graph** (`optimization-level`, funcall granularity,
      weights-bank strategy) via `GGML_OPENVINO_NPU_COMPILE_OVERRIDES`, one cache dir per cell.
- [ ] **Cut per-step state traffic**: batch the conv-state writes; replace the runtime-indexed `Gather`
      with a static slice where the index is known.
- [ ] **Chunk size vs workload.** The static prefill graph always costs a full chunk, so short prompts
      read absurdly slow (4 tokens in a 256-column graph reports ~6 t/s for a 0.66 s chunk). Ship a
      sensible default per use size, and document `GGML_OPENVINO_PREFILL_CHUNK_SIZE` as the direct
      multiplier it is.
- [ ] **Cold start.** 36 s compile is a terrible first impression: ship a precompiled-graph cache with
      the model, or warm it at install. Target warm start < 5 s.
- [ ] **Fix the out-of-range KV write** (`scatter_update` check on CPU, `ZE_RESULT_ERROR_DEVICE_LOST`
      on NPU). It blocks `llama-perplexity`, which is the accuracy metric wanted for Phase 1.

*Exit criteria:* NPU decode beats OpenVINO-CPU on the same model, at comparable or lower package
power, with a warm start under 5 s.

## Phase 3 — broaden the model line · ⬜

Upstream's validated-model table marks the hybrid/SSM family ✗ on NPU, so this is genuinely untrodden.
Widen on purpose rather than by accident:

- [ ] Sibling sizes of the same family (0.3 B → 8 B) to find the practical ceiling; ~13 TOPS INT8 says
      1–3 B is the sweet spot, and the number to confirm is where decode latency crosses what a user
      will tolerate.
- [ ] Pure-transformer models as regression controls.
- [ ] Long context: the KV-ring and mask logic is only exercised at `-c 1024` today. Sweep context
      length, document memory and t/s.
- [ ] Quantization matrix: `Q4_K_M` is the only one measured.

## Phase 4 — LFM3 omni modalities · ⬜ planned

The model line is omni-modal; the text path is the first of its stack.

- [ ] **Audio in.** The encoder side is convolution/attention-heavy and static-shape friendly — the most
      likely next win. Needs a GGUF/pipeline story for the encoder and a way to feed non-token inputs
      through the ggml graph.
- [ ] **Vision in**, same shape of work.
- [ ] **Audio out**, if the NPU can meet the real-time factor of the vocoder; measure before promising.
- [ ] **Mixed scheduling**: encoder on the NPU, LM on the NPU, and a policy for what (if anything) should
      be allowed to run elsewhere. The project's stance is "pure NPU for the model", so anything leaving
      the NPU needs a reason.

## Phase 5 — product surface · ⬜

- [ ] `llama-server` on NPU as the deliverable, with the chat template exercised end to end.
- [ ] Prebuilt Windows binaries + a pinned driver/OpenVINO compatibility note.
- [ ] A `wangcai doctor` that prints device enumeration, driver and OpenVINO versions, and runs a
      30-second correctness probe against a reference — most support burden is configuration, not code.
- [ ] Power/thermal numbers: the honest argument for the NPU is performance per watt while the CPU stays
      free, and we do not have that measurement yet.

## Non-goals

- Chasing the discrete GPU or the iGPU. The whole point is the accelerator nobody uses.
- Forking llama.cpp. The delta is patches; keeping it small and upstreamable is a feature.
- Benchmarks without coherent output attached.

## How to pick something up

Take an item, open an issue saying you are on it, and land the *measurement* even if the fix does not
land. Rejected hypotheses go in [CHANGELOG.md](../CHANGELOG.md) — several dead ends in this project were
worth more than the fixes.
