# WangCai 旺财

> **Pure-NPU on-device inference engine for Intel® Core™ Ultra.**
> Giving *Intel® AI Boost* — the accelerator the industry forgot — a second life.

**English** · [简体中文](README_zh.md)

---

WangCai runs quantized LLMs **entirely on the Intel NPU** (`Intel(R) AI Boost`), with no CPU
fallback for the transformer body and no discrete GPU in the picture. The token stream goes in,
the whole forward pass — prefill *and* decode — is compiled once into static OpenVINO graphs and
executed on the NPU.

The current target line is **[LFM3](https://www.liquid.ai)** from Liquid AI: a hybrid
short-convolution / sliding-window / global-attention family that ships as an omni-modal stack.
The first milestone is the **text (LLM) path**, which is what this repository documents today.

```
prompt ──► llama.cpp (tokenize, build ggml cgraph)
                    │
                    ▼
        ggml-openvino  ── translates the cgraph into an OpenVINO op graph
                    │       (op_table + per-op lowering, static-shape mode)
                    ▼
        OpenVINO NPU plugin (NPUW)  ── compiles to a LEIF graph, runs on AI Boost
                    │
                    ▼
        logits ──► llama.cpp sampler ──► tokens
```

---

## Why

Every Intel Core Ultra laptop ships an NPU rated in the tens of TOPS, and for the last several
generations it has been, charitably, under-utilized by the open-source LLM ecosystem. The usual
"AI PC" story ends with the NPU being used for a webcam effect while the LLM runs on the CPU.

The NPU is genuinely attractive for this workload: decode is memory-bandwidth-bound and the
accelerator has its own high-bandwidth path plus a fixed-function array that sips power while the
CPU cores stay free for the rest of the system. Getting there is not a matter of flipping a switch
— the accelerator wants **static shapes, a single sequence, and no dynamic control flow**, which is
exactly the opposite of how LLM runtimes are usually written.

WangCai's bet: the gap is an *engineering* gap, not a hardware one.

## Status

Honest, measured, and tracked in [docs/status.md](docs/status.md).

| Milestone | Status |
|---|---|
| Build the OpenVINO backend without the GPU/OpenCL SDK | ✅ done |
| LFM3-1.7B graph compiles and runs **end-to-end on the NPU** | ✅ done |
| Hybrid (short-conv + SWA + full) attention masked correctly on static graphs | ✅ done |
| Numerical parity with the CPU reference on the NPU | 🟡 in progress |
| Throughput tuning past the first working number | ⬜ next |
| LFM3 omni modalities (audio in / vision in) | ⬜ planned |

What "in progress" means concretely: greedy generation on the NPU agrees with the CPU reference on
the first few tokens and then wanders. The cosine similarity against reference logits is `0.969` at
the end of prefill and `0.73–0.87` during decode, with the logit distribution measurably flattened.
[docs/npu-internals.md](docs/npu-internals.md) documents how that was localized and what is
currently ruled in and out.

## Measured numbers

Intel Core Ultra 9 275HX · Intel AI Boost (NPU 3720) · 32 GB · OpenVINO 2026.4.1
LLM3-1.7B `Q4_K_M` (1049 MB) · 24 layers (13 gated short-conv, 5 sliding-window@256, 6 global) ·
`-c 1024 -fa 1 -np 1 --temp 0`

| Execution path | Prefill (`pp512`) | Decode | Notes |
|---|---:|---:|---|
| `ggml` CPU reference (`-dev none`) | 570 t/s | 54.1 t/s | coherence reference |
| OpenVINO · CPU device, dynamic graphs | 610 t/s | 21.7–29.2 t/s | coherent |
| **OpenVINO · NPU device, static graphs** | **415 t/s** | **8.3–8.7 t/s** | runs; accuracy WIP |
| OpenVINO · NPU, first graph compile (cold) | — | — | ~36 s one-off, then cached |

Prefill on the accelerator reaches 73% of the CPU reference. **Decode is the real gap** (6× behind the
reference, ~0.03 of the available TOPS) and is the current performance target. Beware the tempting
shortcut: prompt throughput measured on a 4-token prompt reads ~6 t/s on the NPU, because the static
prefill graph is always 256 columns wide and 4 useful tokens pay for 256. Measure `pp512` or larger —
[benchmarks.md](docs/benchmarks.md) explains the arithmetic.

Reproduce with [`tools/`](tools/README.md). Full methodology and caveats:
[docs/benchmarks.md](docs/benchmarks.md).

## Quick start

```powershell
# 1. toolchain: Visual Studio 2022 BuildTools (MSVC), CMake + Ninja, OpenVINO runtime
git clone https://github.com/ggml-org/llama.cpp src/llama
cd src/llama; git checkout abb76ab
git apply ..\..\patches\0001-ggml-openvino-npu-adaptation.patch
copy ..\..\patches\ov_opencl_shim.hpp ggml\src\ggml-openvino\

# 2. configure + build (Release, OpenVINO backend only)
..\..\tools\configure.ps1 -OpenVinoDir C:\openvino\openvino\cmake
..\..\tools\build.ps1

# 3. run on the NPU
$env:GGML_OPENVINO_DEVICE = 'NPU'
$env:GGML_OPENVINO_CACHE_DIR = 'D:\npu_cache'
.\build\bin\llama-cli.exe -m models\LFM3-1.7B-Q4_K_M.gguf -c 1024 -fa 1 -dev OPENVINO3 -st -p 'hello'
```

Details in [docs/getting-started.md](docs/getting-started.md) and [docs/build.md](docs/build.md).

## Documentation

| Document | What it answers |
|---|---|
| [Getting started](docs/getting-started.md) | hardware, model files, first NPU run |
| [Build from source](docs/build.md) | toolchain, OpenVINO dev files, the CL-header problem |
| [Architecture](docs/architecture.md) | how a ggml cgraph becomes a static NPU graph |
| [NPU internals](docs/npu-internals.md) | the hard parts: static shapes, KV rings, conv state, NPUW |
| [Environment variables](docs/env-vars.md) | upstream knobs + the ones WangCai adds |
| [Benchmarks](docs/benchmarks.md) | numbers, how they were taken, what they do *not* prove |
| [Troubleshooting](docs/troubleshooting.md) | every error we hit and how it was resolved |
| [Roadmap](docs/roadmap.md) | accuracy parity, throughput, then omni modalities |

## What WangCai actually changes

Two things, both small enough to read:

1. **Patches to `ggml/src/ggml-openvino/`** — 7 files, +213 lines on top of llama.cpp `abb76ab`
   ([patch](patches/0001-ggml-openvino-npu-adaptation.patch), [notes](patches/README.md)):
   makes the backend buildable for an NPU-only target, makes hybrid sliding-window + full-attention
   models address their KV rings correctly under static shapes, and adds device-comparison
   instrumentation (raw output dumps, position-derived masks, NPU compile-config overrides).
2. **`tools/`** — build/run/diagnose scripts and an element-wise tensor comparison harness that made
   the accuracy work possible.

Everything else is upstream [llama.cpp](https://github.com/ggml-org/llama.cpp) and
[OpenVINO](https://github.com/openvinotoolkit/openvino).

## Hardware requirements

| | |
|---|---|
| SoC | Intel Core Ultra (Series 1/2) with `Intel(R) AI Boost` — `PCI\VEN_8086&DEV_AD1D` class device |
| Driver | Intel NPU driver matching the installed OpenVINO release |
| OS | Windows 11 (Linux path is upstream-supported; untested here) |
| RAM | ≥ 8 GB free per 2 B of model; 16 GB comfortable for 1–4 B models |

## Contributing

See [CONTRIBUTING.md](CONTRIBUTING.md). Repro reports with a `GGML_OPENVINO_DUMP_BIN` capture and a
`tools/compare-tensors.ps1` output are worth more than a thousand "it doesn't work" issues.

## License

Apache-2.0 — see [LICENSE](LICENSE). Upstream llama.cpp (MIT) and OpenVINO (Apache-2.0) terms
continue to apply to their respective code.

## Acknowledgements

The ggml-org llama.cpp maintainers, and the OpenVINO NPU team — the OpenVINO backend inside
llama.cpp is the reason this project is a patch set rather than a rewrite.
