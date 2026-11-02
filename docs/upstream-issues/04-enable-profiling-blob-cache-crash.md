# [Issue 4] NPU: blobs compiled with ov::enable_profiling crash when re-imported from the plugin blob cache (ZE_RESULT_ERROR_INVALID_NULL_HANDLE)

Repository: openvinotoolkit/openvino · Area: intel_npu plugin (blob cache key) · Type: bug (crash)

## Environment
Same as issue #1 (OpenVINO 2026.4.1, NPU 3720, Windows 11).

## Reproduction
1. `compile_model(model, "NPU", {ov::enable_profiling(true), ov::cache_dir(DIR), ...})` in
   process A (DIR empty) → works, correct profiling data, blob written to DIR.
2. New process, same model + same config (profiling still true) → blob imported from DIR,
   and the first `infer()` throws:

   ```
   Exception from src\inference\src\cpp\infer_request.cpp:224:
   Exception from src\plugins\intel_npu\src\utils\src\zero\zero_wrappers.cpp:208:
   L0 pfnAppendGraphExecute result: ZE_RESULT_ERROR_INVALID_NULL_HANDLE,
     code 0x78000005 - handle argument is not valid
   ```

3. Delete DIR (or use a fresh one) → works again. So `enable_profiling` evidently does not
   participate in the plugin blob-cache key: the profiling-less cached blob (no profiling
   handles) is served to a profiling-enabled request.

## Actual result
Hard crash on first inference whenever a profiling-compiled config hits a cached blob
compiled without profiling handles (and vice-versa).

## Expected result
Either `enable_profiling` participates in the blob-cache key, or the interaction is
documented.

## Workaround
Our profiling probes (`GGML_OPENVINO_PROFILING>=2`) use throwaway cache directories. No
production impact (profiling is off by default).
