# [Issue 1] NPUW: NPUW_FOLD + NPUW_FUNCALL_FOR_ALL silently produces numerically wrong results on a vision-encoder graph

Repository: openvinotoolkit/openvino · Area: intel_npu plugin / NPUW · Type: bug (correctness)

## Environment
- OpenVINO 2026.4.1 (runtime libs), Windows 11
- Intel AI Boost NPU (Lunar Lake, NPU 3720), driver bundled with platform
- Any llama.cpp-based engine feeding a fully-static ov::Model (CLIP-style vision encoder:
  ~417 ops, first_op IM2COL, all weights baked as `ov::Constants`, softmax without mask input)

## Reproduction
Compile the identical IR twice:

1. Engine config:
   `NPU_USE_NPUW=YES, NPUW_DEVICES=NPU, NPUW_FOLD=YES, NPUW_FUNCALL_FOR_ALL=YES,
    NPUW_DQ=YES, NPUW_DQ_FULL=NO, NPUW_WEIGHTS_BANK=shared, NPUW_FUNCALL_ASYNC=YES,
    NPU_COMPILER_DYNAMIC_QUANTIZATION=YES`
   → output cosine vs CPU reference: **0.557**
2. Same IR, `compile_model(model, "NPU", {})` (plugin defaults) → cosine **0.995**

Key bisection (same IR, python, one process): the minimal corrupting set is
`NPU_USE_NPUW + NPUW_FOLD + NPUW_FUNCALL_FOR_ALL`. All singles and all pairs are clean;
removing only `NPUW_FUNCALL_FOR_ALL` from the trio restores 0.995. No exception, no
warning — outputs are simply wrong.

Happy to attach the IR (xml+bin, ~100 MB) and the bisection script on request.

## Actual result
Silent numerical corruption of the whole graph output (cosine 0.557 vs reference).

## Expected result
Either correct execution, or a compile-time error/warning for the unsupported combination.

## Our workaround
Remove `NPUW_FUNCALL_FOR_ALL` when compiling graphs detected as vision encoders
(rope nodes with vision type). We'd like to drop this once fixed.
