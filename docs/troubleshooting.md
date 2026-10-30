# Troubleshooting

Every error we actually hit, in the order they tend to appear, with the resolution. If your message is
not here, open an issue with the artifacts from [../CONTRIBUTING.md](../CONTRIBUTING.md).

## Build

### `fatal error C1083: cannot open include file "CL/cl2.hpp"`

From `openvino/runtime/intel_gpu/ocl/ocl_wrapper.hpp:50`, pulled in by the OpenVINO backend. The GPU
remote-context headers are not needed on an NPU build but are included unconditionally.

**Fix:** apply the patch set and drop `ov_opencl_shim.hpp` into `ggml/src/ggml-openvino/` — see
[build.md](build.md#the-opencl-header-problem). Downloading the Khronos headers also works if you can
reach the headers repository.

### `C2668: ambiguous call to overloaded function` in `ClContext` construction

Someone typedef'd `cl_context` and `cl_command_queue` both to `void*`. The `ClContext` constructors are
overloaded on them. **Fix:** distinct opaque types (`struct _cl_context *`, `struct _cl_command_queue *`).
The shim already does this; it bites when the shim gets hand-rewritten.

### `No CMAKE_C_COMPILER could be found` right after `vcvars64.bat` succeeded

PowerShell quote-eating on `cmd /c "call vcvars64.bat && cmake ..."`. **Fix:** put the commands in a
`.bat` file and run `cmd.exe /c that.bat`. `tools/configure.ps1` does.

### `-- UI: download dist.tar.gz.sha256 ... Timeout was reached` / `HF download failed`

Noise. `llama-server`'s embedded web UI assets, unreachable CDN. The build succeeds; the binaries work.
Gate on the exit code, not on the word "failed".

### `error: invalid argument: -cnv` (or `-d`)

This llama.cpp revision has no `-cnv` (chat is the default; `-st` is single turn) and `-d` is not a
flag — device selection is `-dev` / `--device`.

## Model loading

### `tensor 'blk.NN.xxx.weight' data is not within the file bounds, model is corrupted or incomplete`

Truncated download. Check the file size against the source before debugging anything else — a corrupt
GGUF will otherwise convincingly imitate a backend defect.

## Device selection

### The NPU does not appear in `Available devices`

NPU driver missing or too old for the installed OpenVINO. Check:

```powershell
Get-PnpDevice -Class ComputeAccelerator | Format-Table FriendlyName, Status, InstanceId
```

You want `Intel(R) AI Boost` in `OK` state. Then verify the OpenVINO version matches the driver's
supported range, and that `openvino.dll` plus the plugin DLLs are on `PATH` at run time.

### It runs, but the numbers look CPU-like

It ran on the CPU. Confirm with `--list-devices`, the backend line in the log, and a
`GGML_OPENVINO_DUMP_BIN` comparison — tensors from two devices are never bit-identical.

### A flag appears to do nothing

Stale compiled-graph cache. Use a **fresh** `GGML_OPENVINO_CACHE_DIR` per configuration. Second
suspect: the variable is not registered in the env table in `ggml-openvino-extra.cpp`, which makes it
read as unset with no warning.

## Graph compilation

### `Check 'attention_mask_input_correctness' failed at ... scaled_dot_product_attention_shape_inference.hpp:92`

Mask width disagrees with K/V — for example mask `[1,1,256,1024]` against K/V `[1,16,768,128]`. Typical
for hybrid sliding-window + full-attention models. **Fix:** `get_mask_ctx_size()`
([npu-internals § 2](npu-internals.md#2-hybrid-models-address-two-kv-rings-with-one-mask-tensor)).

### `Check 'is_dynamic || port_partial_shape == tensor_shape' failed at ... zero_infer_request.cpp:1250: got [1,1,256,1024] expecting [1,1,256,768]`

The compiled parameter shape and the bound tensor disagree. Both sides must be derived from the same
helper; fixing only one produces the *other* error above, which is how this bug gets mistaken for
progress.

### `Check 'idxValue < static_cast<int64_t>(srcDimAxis) && ...' failed at intel_cpu\src\nodes\scatter_update.cpp:915`

A KV write index landed outside the cache. Reproduced from `llama-perplexity` on any OpenVINO device,
and from `llama-bench -p 1024 -n 32` with a 1024 context — the same test at `-p 512` passes, which is
what points at an out-of-range index rather than at the graph shape. **Workaround:** keep
`-c` ≥ prompt + generated tokens and stay inside the cache; perplexity is unusable as a metric until
this is fixed, so use native CPU (`-dev none`) for it and text/tensor comparison for the NPU.

### `ZE_RESULT_ERROR_DEVICE_LOST` (`zeCommandQueueExecuteCommandLists`, code `0x70000001`)

The NPU-side signature of the same out-of-range KV write: where the CPU plugin fails a bounds check,
the NPU plugin takes the device down. Check `-c` against prompt + generated length first. A bad index
that hangs the device rather than returning an error is a plugin robustness bug worth reporting
upstream.

### `-fa 0` crashes the same scatter path

Deliberate on llama.cpp's side: with flash attention off it flattens V to one element per row because
the write-back only needs one column. Do not "fix" the scatter; run `-fa 1`.

### `state is only supported with stateless` when using `-np 2`

The static path is single-sequence. Use `-np 1`; multi-sequence on NPU would require a rework of the
cache contract.

## Execution

### `ZE_RESULT_ERROR_OUT_OF_HOST_MEMORY` (`pfnAppendGraphExecute`, code `0x70000002`)

Seen when setting `NPU_COMPILER_DYNAMIC_QUANTIZATION=NO`: the unquantized graph does not fit the NPU's
host-side budget. Either keep dynamic quantization on or shrink the model/context.

### `ov::Exception` from `core.cpp:120` at compile time

The plugin rejected the requested configuration. `NPU_USE_NPUW=NO` and
`NPUW_DQ=NO,NPUW_DQ_FULL=YES` both land here — the compressed-weights path is required for this model.

### The process aborts during compile when using `GGML_OPENVINO_DEBUG_NODE`

The NPU plugin cannot take appended `Result` nodes. **Fix:** use `GGML_OPENVINO_DUMP_BIN`, which reads
the outputs the graph already produces.

### The log file is empty after a crash

Inline `2>&1 >` in PowerShell truncates the OpenVINO exception text. Redirect through
`cmd.exe /c "llama-cli ... > log 2>&1"`.

### Prompt throughput on the NPU looks hopeless (single-digit t/s)

Almost certainly a measurement artifact, not a result. The static prefill graph is always
`GGML_OPENVINO_PREFILL_CHUNK_SIZE` (256) columns wide, so a 4-token prompt pays for 256 columns while
llama.cpp reports *useful* tokens per second — the same 0.66 s chunk reads as ~6 t/s. Measure with
`llama-bench -p 512` (where the chunk is actually full), and for genuinely short-prompt workloads lower
the chunk size. Never compare NPU prompt t/s with CPU prompt t/s on short prompts: you are comparing
padding against no padding.

### Generation repeats one token (`>>>>>>>>>>>>>`) forever

A weights/execution failure signature, not a sampling problem. It appeared whenever NPUW dequantization
was disabled (`NPUW_DQ=NO`, `NPUW_DQ_FULL=YES`, `NPUW_FOLD=NO`). Restore the defaults.

### Coherent on CPU, garbage on NPU, no exception

The open defect — see [npu-internals § 4](npu-internals.md#4-the-accuracy-gap). Diagnostic order:
confirm device, then dump both devices and compare pass-by-pass (`tools/compare-tensors.ps1`,
`tools/top-token.ps1`), then bisect with `GGML_OPENVINO_FORCE_STATIC=1` on CPU.

### Garbage on **every** device including native CPU

You are driving an instruct model with raw completion. Use `llama-cli -st` so the chat template is
applied. This exact false alarm cost a "the model is broken" detour.

## Scripting

### `Missing ')' in function call` / mojibake when running a `.ps1`

Windows PowerShell parses `.ps1` files as ANSI, so non-ASCII literals (Chinese text, `…`) corrupt the
parser. Keep scripts ASCII-only and pass non-ASCII prompts through a UTF-8 file with `-f`.
