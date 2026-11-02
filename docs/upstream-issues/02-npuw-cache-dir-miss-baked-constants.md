# [Issue 2] NPUW: NPUW_CACHE_DIR never hits for graphs whose weights are baked `ov::Constants` — full recompile every process

Repository: openvinotoolkit/openvino · Area: intel_npu plugin / NPUW caching · Type: performance / docs

## Environment
Same as issue #1 (OpenVINO 2026.4.1, NPU 3720, Windows 11).

## Reproduction
1. Build/obtain a fully-static ov::Model whose weights are baked as `ov::Constants`
   (e.g. an mtmd CLIP vision encoder, ~100 MB constants; IR md5 is bit-stable across processes).
2. `compile_model(model, "NPU", {NPU_USE_NPUW=YES, ..., NPUW_CACHE_DIR=<dir>})` in two
   consecutive processes with the identical IR and config.
3. Measured: every process pays the full NPUW compile (~12–13 s for this graph).
4. Same test with `ov::cache_dir(<dir>)` added (plugin blob cache): 0.41–0.74 s.
5. Control: an LLM graph whose weights go through `NPUW_WEIGHTS_BANK=shared` hits
   `NPUW_CACHE_DIR` normally (~2.3 s).

## Actual result
`NPUW_CACHE_DIR` only caches NPUW's own funcall/subgraph decomposition keyed in a way that
misses graphs with baked `ov::Constants` — silently recompiles every process start.

## Expected result
Either the NPUW cache covers baked-`Constant` graphs, or the limitation is documented so
integrators know to set `ov::cache_dir` as well.

## Our workaround
Set both `NPUW_CACHE_DIR` and `ov::cache_dir` to the same directory on the NPU route.
