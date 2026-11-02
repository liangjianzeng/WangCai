# [Issue 3] NPUW: export_model/import_model blob is not weights-bank-aware — imported model duplicates device weights / asserts on shared bank

Repository: openvinotoolkit/openvino · Area: intel_npu plugin / NPUW compiled-model cache · Type: feature (perf blocker)

## Environment
Same as issue #1.

## Context
Fast multi-graph warm start: compile prefill + decode + vision-encoder graphs once, export
each `CompiledModel` with `export_model()`, later `Core::import_model(...)` to skip the
~2 s frontend conversion + ~1 s plugin compile per graph per process.

## Reproduction
With `NPUW_WEIGHTS_BANK=shared` active (the multi-graph weights-sharing path):

1. Export a graph with `ov::cache_mode(OPTIMIZE_SPEED)`; on disk the blob is weightless
   (~26 MB/graph — NPUW recognizes the weights as external and strips them).
2. `Core::import_model(blob, "NPU", {ov::weights_path(f) | ov::hint::model(m)})`:
   - the imported model does **not** join the live shared weights bank → its weights are
     duplicated on device alongside subsequently compiled graphs (measured 10× decode
     regression: 729 ms/token vs 75 ms; `ZE_RESULT_ERROR_OUT_OF_HOST_MEMORY` risk on the
     ~24 GB device budget);
   - a second import of a bank-sharing blob asserts on duplicate UID in `read_and_add_tensor`
     (no dedup — the GenAI flow only ever imports one model per process).

## Impact
Blocks "<5 s multi-graph warm start" for llama.cpp-style multi-graph engines on the NPU.
We keep our compiled-model cache opt-in OFF on NPU because of this.

## Expected
A weights-handle provider / bank-aware import path (see `should_use_weightless_flow` /
`make_import_weights_ctx` in `npuw/compiled_model.cpp`) so imported blobs and freshly
compiled graphs share one device copy of the weights bank.

## Workaround
Disable the compiled-model cache on NPU (recompile every process; 8.9 s warm start).
