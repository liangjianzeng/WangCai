# OpenVINO NPU / NPUW issues found (ready to file)

Collected while integrating an mtmd multimodal engine on **Intel AI Boost NPU (Lunar Lake,
NPU 3720)** with **OpenVINO 2026.4.1, Windows**. Each item has a local reproduction; ask and
we can attach the IRs (a CLIP-style vision encoder, ~417 ops, weights baked as `ov::Constants`,
and a 2B LLM prefill/decode pair). Workarounds already shipped on our side are noted.

## 1. [accuracy] `NPUW_FOLD` + `NPUW_FUNCALL_FOR_ALL` silently corrupt a vision-encoder graph

Compiling the same vision IR with

```
NPU_USE_NPUW=YES, NPUW_DEVICES=NPU, NPUW_FOLD=YES, NPUW_FUNCALL_FOR_ALL=YES,
NPUW_DQ=YES, NPUW_DQ_FULL=NO, NPUW_WEIGHTS_BANK=shared, NPUW_FUNCALL_ASYNC=YES,
NPU_COMPILER_DYNAMIC_QUANTIZATION=YES
```

yields cosine 0.557 vs CPU reference; the same IR with plugin defaults gives 0.995. Key
bisection: the minimal corrupting trio is `NPU_USE_NPUW` + `NPUW_FOLD` + `NPUW_FUNCALL_FOR_ALL`
— removing only `NPUW_FUNCALL_FOR_ALL` restores 0.995; all singles and pairs are clean. No
exception, no log — outputs are just numerically wrong. The graph is fully static; softmax
nodes have no mask input (plain attention encoder).
**Workaround:** we drop `NPUW_FUNCALL_FOR_ALL` for graphs containing vision-rope nodes.

## 2. [perf] `NPUW_CACHE_DIR` never hits for graphs with weights baked as `ov::Constants`

The vision encoder above (~100 MB of baked constants) recompiles fully on every process start
(~12 s) even with `NPUW_CACHE_DIR` set and unchanged; the NPUW cache only covers its own
funcall/subgraph decomposition keyed on the *decomposition*, which misses these graphs. Adding
the plugin blob cache (`ov::cache_dir`) makes the identical IR hit at 0.4–0.7 s. Either document
that `NPUW_CACHE_DIR` does not cover baked-`Constant` graphs, or make the NPUW cache cover them.
**Workaround:** set both `NPUW_CACHE_DIR` and `ov::cache_dir` to the same directory.

## 3. [perf/blocker] NPUW blob import is not weights-bank-aware (`import_model` + `NPUW_WEIGHTS_BANK=shared`)

Exporting via `CompiledModel::export_model()` under `NPUW_WEIGHTS_BANK=shared` produces a
weightless blob; re-importing it with `Core::import_model(..., {ov::weights_path | ov::hint::model})`:
- does not join the live shared weights bank → the imported model's weights are duplicated on
  device alongside subsequently compiled graphs (measured 10× decode regression, 729 ms/token
  vs 75 ms, `ZE_RESULT_ERROR_OUT_OF_HOST_MEMORY` risk on the ~24 GB device budget);
- a second import of a bank-sharing blob asserts on duplicate UID in `read_and_add_tensor`
  (no dedup — the GenAI flow only ever imports one model per process).

This blocks the fast-startup pattern "import prefill + decode + encoder blobs, no recompile".
A weights-handle provider / bank-aware import (see `should_use_weightless_flow` /
`make_import_weights_ctx` in `npuw/compiled_model.cpp`) would unblock <5 s multi-graph warm start.

## 4. [crash] `ov::enable_profiling` blobs reused from the plugin blob cache crash at inference

Compile with `ov::enable_profiling(true)` + `ov::cache_dir(DIR)`; on the next process the blob
is imported from `DIR` and the first `infer()` throws:

```
ZE_RESULT_ERROR_INVALID_NULL_HANDLE (0x78000005)
  zero_wrappers.cpp:208  L0 pfnAppendGraphExecute
  src\inference\src\cpp\infer_request.cpp:224
```

Same process-first-compile with the identical config works and produces correct profiling data,
so `enable_profiling` evidently does not participate in the plugin blob-cache key.
**Workaround:** profiling probes use throwaway cache directories.

---
Filing suggestion: one issue each; 2 and 3 are the same family (cache/import key coverage).
Environment for all: OpenVINO 2026.4.1 runtime libs, Windows 11, NPU driver bundled with the
platform, CPU fallback comparisons done on the same build.
