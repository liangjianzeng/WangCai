# Environment variables

All variables are read **once at backend initialization** from a registered table in
`ggml-openvino-extra.cpp`. Two consequences that have each cost real time:

- A variable that is not in that table reads as **unset, with no error**. If you add one and it seems
  to do nothing, check the registration first.
- Values cannot change mid-process; start a new process.

`GGML_OPENVINO_CACHE_DIR` keys the compiled-graph cache. **Use a fresh directory per configuration** —
reusing one across flag changes silently reuses a graph compiled under the old settings, which makes a
working flag look broken.

## Device selection

| Variable | Values | Notes |
|---|---|---|
| `GGML_OPENVINO_DEVICE` | `CPU`, `GPU.0`, `GPU.1`, `NPU` | selects which registered `OPENVINO<n>` device the backend targets. Combined with `-dev OPENVINO<n>` on the command line. |
| `GGML_OPENVINO_FORCE_STATIC` | `0`/`1` | run the **static (NPU-shape) code path on any device**. The single most useful variable in this project: static-mode bugs reproduce on CPU in seconds. |
| `GGML_OPENVINO_ENABLE_CACHE` / `GGML_OPENVINO_DISABLE_CACHE` | `0`/`1` | decoder-level graph cache. |
| `GGML_OPENVINO_COMPILED_MODEL_CACHE_DIR` / `_ONLY` | path / `0`/`1` | OV compiled-model cache; `_ONLY` fails instead of recompiling, which is how you prove a graph was already cached. |

## Execution model

| Variable | Values | Notes |
|---|---|---|
| `GGML_OPENVINO_PREFILL_CHUNK_SIZE` | int, default `256` | tokens per static prefill chunk; must be ≤ `-b`. Also part of the graph cache key. |
| `GGML_OPENVINO_STATEFUL_EXECUTION` | `0`/`1` | OV `Variable`-based caches (no re-binding per step). **CPU/GPU only** — forced off on NPU. |
| `GGML_OPENVINO_MANUAL_GQA_ATTN` | `0`/`1` | bypass `SDPA` and compose GQA attention from primitives. |
| `GGML_OPENVINO_NATIVE_SOFTPLUS` | `0`/`1` | native `SoftPlus` vs the composed form. |
| `GGML_OPENVINO_DISABLE_REMOTE_OUTPUTS` | `0`/`1` | stop aliasing outputs to ggml buffers via remote tensors. |
| `GGML_OPENVINO_LOG_UNSUPPORTED_OPS` | `0`/`1` | log ops that cannot be lowered, instead of failing obscurely. |
| `GGML_OPENVINO_REQUANT_KQUANT` | `native`, `q4_sym128[_all]`, `q4_asym64[_all]` | requantization target for K-quant weights. **Caveat:** on NPU the code returns `Q4_0_128` before consulting this variable, so it has no effect there; the CPU is the place to use it (e.g. to reproduce the NPU's requant on a device that gives a coherent reference). |

## NPU plugin configuration

Defaults set by the backend when the device is an NPU:

```
NPU_COMPILER_DYNAMIC_QUANTIZATION = YES      NPUW_FOLD          = YES
NPU_USE_NPUW                      = YES      NPUW_WEIGHTS_BANK  = shared
NPUW_DEVICES                      = NPU      NPUW_FUNCALL_FOR_ALL = YES
NPUW_DQ                           = YES      NPUW_FUNCALL_ASYNC = YES
NPUW_DQ_FULL                      = NO       NPUW_CACHE_DIR     = <GGML_OPENVINO_CACHE_DIR>
```

| Variable | Values | Notes |
|---|---|---|
| `GGML_OPENVINO_NPU_COMPILE_OVERRIDES` | `KEY=VALUE,KEY=VALUE` | **added by WangCai.** Adds or replaces the entries above at run time. Each override logged on startup. Always pair with a fresh cache dir. |
| `GGML_OPENVINO_NPU_COMPILE_CONFIG` | string | forwarded verbatim as `NPU_COMPILATION_MODE_PARAMS` (compiler-internal knobs only — it cannot touch the top-level NPUW keys, which is why the variable above exists). |

Results of the documented toggles are in
[npu-internals.md § the NPUW sweep](npu-internals.md#the-npuw--quantization-lever-sweep).

## Diagnostics

| Variable | Values | Notes |
|---|---|---|
| `GGML_OPENVINO_DUMP_BIN` | directory | **added by WangCai.** Raw per-output dumps (`<tag>_<seq>_<name>.bin` + shape/type sidecar) on both static and dynamic paths. Reads existing outputs, so it is safe on NPU. Compare with `tools/compare-tensors.ps1`, align passes with `tools/top-token.ps1`. |
| `GGML_OPENVINO_MASK_MODE` | `0`/`1` | **added by WangCai.** Static prefill builds the mask from token positions instead of llama.cpp's. Used to separate mask-content bugs from execution bugs. |
| `GGML_OPENVINO_DEBUG_OUTPUT` | `0`/`1` | prints `First/Min/Max/Mean` per output. Useful as a fingerprint; **misleading for row-level errors** — see npu-internals. |
| `GGML_OPENVINO_DEBUG_INPUT` | `0`/`1` | same for bound inputs; the way to prove two devices received identical tensors. |
| `GGML_OPENVINO_DEBUG_NODE` | `name1,name2` | appends `Result` nodes for intermediate tensors. **Aborts the process on the NPU** — use `DUMP_BIN` instead. |
| `GGML_OPENVINO_DUMP_CGRAPH` | `0`/`1` | writes `cgraph_ov.txt` (the ggml graph with shapes and backend assignment) into the current directory. |
| `GGML_OPENVINO_DUMP_IR` | `0`/`1` | serializes the OpenVINO IR of the naive path. |
| `GGML_OPENVINO_PROFILING` | `0`/`1`/`2` | per-phase timings; `2` also enables OV per-layer profiling. |
| `GGML_OPENVINO_PRINT_CGRAPH_TENSOR_ADDRESS` | `0`/`1` | tensor addresses, for aliasing investigations. |

## Worked example: comparing two devices

```powershell
foreach ($cfg in @(
        @{ n = 'cpu'; dev = 'OPENVINO0'; ov = 'CPU'; st = '1' },   # static path on CPU
        @{ n = 'npu'; dev = 'OPENVINO3'; ov = 'NPU'; st = '' })) {
    Get-ChildItem Env:GGML_OPENVINO_* | ForEach-Object { Remove-Item "Env:$($_.Name)" }
    $env:GGML_OPENVINO_DEVICE     = $cfg.ov
    $env:GGML_OPENVINO_CACHE_DIR  = "D:\cache\$($cfg.n)"          # fresh per config
    $env:GGML_OPENVINO_DUMP_BIN   = "D:\dumps\$($cfg.n)"
    if ($cfg.st) { $env:GGML_OPENVINO_FORCE_STATIC = '1' }
    .\build\bin\llama-cli.exe -m models\LFM3-1.7B-Q4_K_M.gguf -c 1024 -n 5 --temp 0 --seed 42 `
        -fa 1 -dev $cfg.dev -st -p '用一句话介绍长城。'
}
tools\compare-tensors.ps1 -A D:\dumps\cpu -B D:\dumps\npu
```

Match pass-for-pass before trusting any number — see `tools/top-token.ps1`.
