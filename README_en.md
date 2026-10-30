# WangCai 旺财

> **Pure-NPU on-device inference engine for Intel® Core™ Ultra.**
> Giving *Intel® AI Boost* — the accelerator the industry forgot — a second life.

[简体中文](README.md) · **English**

*This is the secondary language; [README.md](README.md) (Chinese) is the primary document.*

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

The engine's source lives in the repository: [`src/ggml-openvino/`](src/ggml-openvino/)
(provenance and the change list in [`src/ggml-openvino/WANGCAI.md`](src/ggml-openvino/WANGCAI.md)).

---

## Why

Every Intel Core Ultra laptop ships an NPU rated in the tens of TOPS, and for the last several
generations it has been, charitably, under-utilized by the open-source LLM ecosystem. The usual
"AI PC" story ends with the NPU running a webcam effect while the LLM runs on the CPU.

The accelerator is genuinely attractive for this workload: decode is memory-bandwidth-bound, the NPU
has its own high-bandwidth path and fixed-function array, it sips power, and it leaves the CPU cores
free for the rest of the system. Getting there is not a switch to flip — the device wants **static
shapes, a single sequence, and no dynamic control flow**, which is the opposite of how LLM runtimes
are usually written.

WangCai's bet: the gap is an *engineering* gap, not a hardware one.

## Status

Honest, measured, tracked in [docs/status.md](docs/status.md).

| Milestone | Status |
|---|---|
| Build the OpenVINO backend without the GPU/OpenCL SDK | ✅ done |
| LFM3-1.7B compiles and runs **end-to-end on the NPU** | ✅ done |
| Hybrid (short-conv + SWA + full) attention addressing its KV rings correctly | ✅ done |
| Numerical parity with the CPU reference on the NPU | 🟡 in progress |
| Prefill competitive with CPU | 🟡 73% of the reference; headroom still unexplained |
| Decode competitive with CPU | 🟡 6× behind; the current performance target |
| LFM3 omni modalities (audio in / vision in) | ⬜ planned |

What "in progress" means concretely: greedy generation on the NPU tracks the CPU reference for the
first few tokens and then wanders. Cosine similarity against reference logits is `0.969` at the end of
prefill and `0.73–0.87` during decode, with the logit distribution measurably flattened. Per-layer
comparison now shows the divergence is **present in the first prefill chunk** and grows monotonically
with depth (conv state: `0.999` at layer 0 → `0.72` at layer 9 → `0.22` at layer 17), which points at
per-op arithmetic compounding through the residual stream rather than at state bookkeeping. See
[docs/npu-internals.md](docs/npu-internals.md).

## Measured numbers

Intel Core Ultra 9 275HX · Intel AI Boost (NPU 3720) · 32 GB · OpenVINO 2026.4.1
LFM3-1.7B `Q4_K_M` (1049 MB) · 24 layers (13 gated short-conv, 5 sliding-window@256, 6 global) ·
`-fa 1 -np 1`

| Execution path | Prefill (`llama-bench pp512`) | Decode | Notes |
|---|---:|---:|---|
| `ggml` CPU reference (`-dev none`) | 570 t/s | 54.1 t/s | coherence reference |
| OpenVINO · CPU device, dynamic graphs | 610 t/s | 21.7–29.2 t/s | coherent |
| **OpenVINO · NPU device, static graphs** | **415 t/s** | **8.3–8.7 t/s** | runs; accuracy WIP |
| OpenVINO · NPU, first graph compile (cold) | — | — | ~36 s one-off, then cached |

Two things worth stating plainly:

- **Prefill on the NPU is not the problem** — 415 t/s is 73% of the CPU reference. Decode is, at
  roughly 0.03 of the available TOPS.
- **Short-prompt prompt-throughput on the NPU is meaningless as reported.** The static prefill graph
  is always 256 columns wide, so 4 useful tokens pay for 256 while llama.cpp reports useful tokens per
  second: the same 0.66 s chunk reads as ~6 t/s. Measure `pp512` or larger, or tune
  `GGML_OPENVINO_PREFILL_CHUNK_SIZE` to your prompt length. Arithmetic in
  [docs/benchmarks.md](docs/benchmarks.md).

Reproduce with [`tools/`](tools/README.md).

## Quick start

```powershell
# 1. toolchain: VS 2022 Build Tools (MSVC), CMake + Ninja, OpenVINO runtime (the PyPI wheel works)
pip download openvino==2026.4.1 --no-deps -d .\ovdl
Expand-Archive .\ovdl\openvino-2026.4.1-*.whl -DestinationPath .\ov     # → .\ov\openvino\cmake

# 2. get the engine: clone llama.cpp at the pinned commit and overlay src/ggml-openvino onto it
git clone https://github.com/liangjianzeng/WangCai
cd WangCai
tools\bootstrap.ps1

# 3. configure + build (Release, OpenVINO backend only)
tools\configure.ps1 -OpenVinoDir ..\ov\openvino\cmake
tools\build.ps1

# 4. run on the NPU
$env:GGML_OPENVINO_DEVICE = 'NPU'
$env:GGML_OPENVINO_CACHE_DIR = 'D:\npu_cache'
src\llama\build\bin\llama-cli.exe -m models\LFM3-1.7B-Q4_K_M.gguf -c 1024 -fa 1 -dev OPENVINO3 -st -p 'Introduce the Great Wall in one sentence.'
```

Details in [docs/getting-started.md](docs/getting-started.md) and [docs/build.md](docs/build.md).

## Repository layout

```
src/ggml-openvino/    the engine itself: the ggml OpenVINO backend (upstream + WangCai changes)
patches/              the same change as a reviewable patch, with per-hunk notes
tools/                bootstrap / configure / build / run-npu / npu-sweep / compare-tensors / top-token
docs/                 getting started, build, architecture, NPU internals, env vars, benchmarks,
                      status, troubleshooting, roadmap
prompts/              sample prompts (UTF-8)
src/llama/            vendored llama.cpp (git-ignored, produced by bootstrap)
```

## Documentation

| Document | What it answers |
|---|---|
| [Getting started](docs/getting-started.md) | hardware, model files, first NPU run |
| [Build from source](docs/build.md) | toolchain, OpenVINO dev files, the CL-header problem |
| [Architecture](docs/architecture.md) | how a ggml cgraph becomes a static NPU graph |
| [NPU internals](docs/npu-internals.md) | the hard parts: static shapes, KV rings, conv state, NPUW |
| [Environment variables](docs/env-vars.md) | upstream knobs + the ones WangCai adds |
| [Benchmarks](docs/benchmarks.md) | numbers, how they were taken, what they do *not* prove |
| [Status](docs/status.md) | what works today, with the command that proves it |
| [Troubleshooting](docs/troubleshooting.md) | every error we hit and how it was resolved |
| [Roadmap](docs/roadmap.md) | accuracy first, then throughput, then omni modalities |

## Hardware requirements

| | |
|---|---|
| SoC | Intel Core Ultra (Series 1/2) with `Intel(R) AI Boost` — `PCI\VEN_8086&DEV_AD1D` class device |
| Driver | Intel NPU driver matching the installed OpenVINO release |
| OS | Windows 11 (the Linux path is upstream-supported; untested here) |
| RAM | ≥ 8 GB free per 2 GB of model; 16 GB comfortable for 1–4 B models |

## Contributing

See [CONTRIBUTING.md](CONTRIBUTING.md). A repro report with a `GGML_OPENVINO_DUMP_BIN` capture and a
`tools/compare-tensors.ps1` output is worth more than a thousand "it doesn't work" issues.

Disproven hypotheses are welcome too — they go in [CHANGELOG.md](CHANGELOG.md), and they often save
the next person more time than a fix does.

## License

Apache-2.0 — see [LICENSE](LICENSE). Upstream llama.cpp (MIT) and OpenVINO (Apache-2.0) terms continue
to apply to their respective code.

## Acknowledgements

The ggml-org llama.cpp maintainers, and the OpenVINO NPU team — the OpenVINO backend inside llama.cpp
is the reason this project is a patch set rather than a rewrite.
