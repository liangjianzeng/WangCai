# Architecture

How a batch of tokens becomes work on `Intel(R) AI Boost`, and which part of the stack is responsible
for what.

```
┌──────────────────────────────────────────────────────────────────────┐
│ llama.cpp   tokenizer · KV/conv-cache allocation · graph builder ·   │
│             sampler · chat template                                  │
└───────────────────────────────┬──────────────────────────────────────┘
                                │  ggml_cgraph  (nodes = GGML_OP_*)
┌───────────────────────────────▼──────────────────────────────────────┐
│ ggml-backend  ·  ggml_backend_sched assigns each node a backend      │
│   └── ggml_backend_openvino  (registered as OPENVINO0..N)            │
└───────────────────────────────┬──────────────────────────────────────┘
                                │  graph_compute(cgraph)
┌───────────────────────────────▼──────────────────────────────────────┐
│ ggml/src/ggml-openvino/                                              │
│   utils.cpp              graph lifecycle, input binding, output copy │
│   ggml-decoder.{h,cpp}   ModelParams/ComputeParams, input shapes     │
│   openvino/op_table.cpp  GGML_OP_* → translate_* registry            │
│   openvino/op/*.cpp      per-op lowering into the OpenVINO frontend  │
│   openvino/translate_session.cpp  builds the Result set              │
│   model-cache.cpp        compiled-graph cache key                    │
└───────────────────────────────┬──────────────────────────────────────┘
                                │  ov::Model (static shapes on NPU)
┌───────────────────────────────▼──────────────────────────────────────┐
│ OpenVINO NPU plugin · NPUW (weight compression, on-device dequant) · │
│ LEIF compiler → execution on AI Boost                                │
└──────────────────────────────────────────────────────────────────────┘
```

## Which path runs

`ov_graph_compute()` picks between two implementations:

```cpp
const auto is_static = ggml_openvino_is_npu() || ggml_openvino_getenv_int("GGML_OPENVINO_FORCE_STATIC");
```

| | dynamic path | static path |
|---|---|---|
| Used by | CPU, GPU | **NPU**, or anything with `GGML_OPENVINO_FORCE_STATIC=1` |
| Shapes | `-1` wherever possible | every dimension concrete at compile time |
| Graphs per model | one, reused | **two**: chunked prefill (`n_tokens = chunk`) and decode (`n_tokens = 1`) |
| KV / conv state | read and written in place, or as OV `Variables` in stateful mode | bound as plain inputs, returned as outputs, every call |
| `n_seq` | > 1 possible | 1 only |
| bf16 | supported | rejected at scheduling |

The static path is the interesting one, and `GGML_OPENVINO_FORCE_STATIC=1` with
`GGML_OPENVINO_DEVICE=CPU` runs it on the CPU — same code, no NPU compile. That single switch is what
makes it possible to tell a graph-construction bug from a plugin bug, and this project leans on it
constantly.

## The static lifecycle

1. `compute_llm_params()` derives `ModelParams` (context length, per-sequence and sliding-window ring
   lengths, head counts, recurrent state size, sliding-window layer list) and `ComputeParams`
   (active sequences, output length, positions) from the cgraph.
2. Two `GgmlOvDecoder`s are constructed over the *same* cgraph — `is_prefill = true` with the
   configured chunk size, `is_prefill = false` with 1 token. Each answers one question per graph
   input: *what shape does this parameter have?*
3. Both graphs are compiled (or fetched from the compiled-graph cache, keyed by graph topology,
   device, static/stateful flags and chunk size — see `model-cache.cpp`), then wrapped in reusable
   `ov::InferRequest`s.
4. Per call, inputs are materialized by `get_ov_input_tensor_static_prefill(decoder, name, chunk)` /
   `get_ov_input_tensor_static_decode(decoder, name)`, which are responsible for turning llama.cpp's
   eager, dynamically-sized buffers into the fixed-size tensors the compiled graph demands.
5. `infer()`, then outputs are copied back into the ggml buffers bound by `create_ov_output_tensor()`.

### What the binding layer has to invent

The compiled graph expects exactly `chunk_size` of everything. llama.cpp hands over `n_valid` tokens.
So the binding layer synthesizes the rest, and every one of these is a place a bug can hide:

| Input | Static shape (LFM3-1.7B, chunk 256) | Fill rule |
|---|---|---|
| `inp_tokens` | `[1,1,1,256]` | chunk slice; valid length recorded in `chunk_valid_len` |
| `inp_pos` | `[1,1,1,256]` (× planes for mRoPE) | chunk slice, then **padded with `last+1, last+2, …`** |
| `attn_inp_k_idxs` / `v_idxs` (KV write index) | `[1,1,1,256]` | `cache_idx % chunk_size` per element |
| `attn_inp_kq_mask` | `[1,1,256,ctx]` = `[1,1,256,1024]` | llama.cpp mask padded right with −∞; own-diagonal zeroed |
| `attn_inp_kq_mask_swa` | `[1,1,256,ctx_swa]` = `[1,1,256,768]` | same, at the **ring** width |
| `cache_r_l*` (conv state) | `[1,1,1,12288]` | state stream `[prev 6 cols │ tokens]`, window gathered at `chunk_valid_len` |
| `chunk_valid_len` | `[1]` i64 | `min(chunk, input_len − chunk·i)` |
| `cache_rs_reset_len` | `[1]` | forced to 0 after the first chunk, else later chunks wipe accumulated state |

Padding positions with `last+1` and keeping padded rows' softmax finite are both load-bearing: a
fully masked padded row evaluates `softmax` as `0/0`, and the NaN then rides the recurrent-state
gather into every subsequent step.

## Op lowering

`openvino/op_table.cpp` maps each `GGML_OP_*` to a translator; unregistered ops fail at graph build
time rather than silently. The ones that matter for a hybrid model:

| ggml op | lowered to | notes |
|---|---|---|
| `GGML_OP_SSM_CONV` | `ov::op::v1::GroupConvolution` (depthwise) | causal left-padding, kernel = `d_conv` (LFM3: 7 → state width 6), groups = channels |
| `GGML_OP_FLASH_ATTN_EXT` | `ov::op::v1::SDPA` (opset 13) | mask must be width-consistent with K; see `trim_mask_to_kv()`; `GGML_OPENVINO_MANUAL_GQA_ATTN` bypasses SDPA |
| `GGML_OP_SET_ROWS` | `ScatterUpdate` / `ScatterElementsUpdate` | the KV write path; sensitive to the V layout llama.cpp chooses when SDPA is off |
| `GGML_OP_CPY` | gather/slice/concat plan | doubles as the recurrent-state write-back; classified by an internal `op_case` (single-slot assign, slice-assign, conv-window) |
| `GGML_OP_RMS_NORM` | `Multiply/ReduceMean/Sqrt/Divide` chain | `GGML_OPENVINO_*` does not promote this to f32 |
| `GGML_OP_MUL_MAT` | `MatMul` (+ weights-bank path under NPUW) | the requantized-weights path lives here |

`GGML_OP_SSM_CONV` support already exists upstream — worth stating because "the NPU backend has no
conv-state op" is the assumption that costs a project a week. It is implemented as a depthwise
grouped convolution; it is not missing.

## Weights

`create_weight_nodes()` walks the graph, materializes weights as OpenVINO constants or parameters and
may requantize them. The policy differs by device:

| Weight | CPU / GPU | **NPU** |
|---|---|---|
| `token_embd.weight` | Q8_0_C | F16 (if Q6_K) else Q8_0_C |
| `output.weight` | Q8_0_C | Q8_0_C |
| everything else | native `Q4_K` (group 32, f16 scale + zero point) | **`Q4_0_128`** (group 128, symmetric, no zero point) |

plus NPUW keeping weights compressed on-device (`NPUW_DQ`, `NPUW_WEIGHTS_BANK=shared`) and the NPU
compiler quantizing activations (`NPU_COMPILER_DYNAMIC_QUANTIZATION=YES`). These are the accuracy/
throughput trade knobs and they are the current focus of
[npu-internals.md](npu-internals.md#the-accuracy-gap).

## Constraints worth memorizing

| Constraint | Consequence |
|---|---|
| Static shapes only | every variable dimension must be synthesized by the binding layer |
| Stateless caches on NPU | caches are inputs *and* outputs every call → bandwidth cost per step |
| `n_seq = 1` | `-np 1`; multiple slots are rejected before compilation |
| No bf16 | bf16 weights/activations are refused at scheduling |
| Extra graph outputs abort the plugin | use `GGML_OPENVINO_DUMP_BIN`, not `GGML_OPENVINO_DEBUG_NODE` |
| ~36 s cold compile per graph | always configure a cache dir; keep one dir per experiment |

## Where to read next

- The hard parts, with the measurements: [npu-internals.md](npu-internals.md)
- Every knob: [env-vars.md](env-vars.md)
- Failure modes by error text: [troubleshooting.md](troubleshooting.md)
