# WangCai 汪柴

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
| Continuation task byte-identical to the CPU reference | ✅ done (Q4_0 weights) |
| Numerical parity on an **instruction-following** task | 🟡 in progress — the one open item |
| Prefill competitive with CPU | 🟡 73% of the reference; headroom still unexplained |
| Decode competitive with CPU | 🟡 6× behind; the current performance target |
| LFM3 omni modalities (audio in / vision in) | ⬜ planned (official GGUF + `mmproj` on ModelScope) |
| **On-device multimodal assistant "WangCai"** | 🟡 planned — this engine inside TongYiLite (Flutter, Android→Windows) |

What "in progress" means concretely: greedy generation on the NPU tracks the CPU reference for the
first few tokens and then wanders. Cosine similarity against reference logits is `0.969` at the end of
prefill and `0.73–0.87` during decode, with the logit distribution measurably flattened. On **real**
prefill chunks the divergence is present from the first one and grows with depth (conv state: `0.9956`
at layer 0 → `0.873` at layer 9 → `0.163` at layer 17), which points at per-op arithmetic compounding
through the residual stream rather than at state bookkeeping. The attention side is nearly innocent: V is
written exactly (max abs `2.7e-6` over all 200 rows) and K holds at `0.90–0.9998` **except row 0**, which
misses by eight orders of magnitude (`cosine 0.288`, max abs `1.06e10`) — the sharpest lead available.

Two measurement rules earned the hard way, both in
[docs/npu-internals.md](docs/npu-internals.md): `prefill_0/1` and `decode_2` are llama.cpp **warmup**
passes (byte-identical across different prompts), so statistics over them measure nothing; and **a
continuation task is not a coherence test** — it agrees byte-for-byte even when the device is wrong,
which only an instruction-following prompt reveals.

## Roadmap: the on-device multimodal assistant "WangCai"

In one line: **WangCai is an on-device multimodal assistant, and the NPU engine is its low-power heart.**

This repository currently does one thing: run a quantized LLM **entirely on the Intel NPU**. That is the
engine. The engine is not the destination — putting it inside an assistant that talks, sees, listens and
reasons is what "WangCai" means.

### Three layers

| Layer | Component | Responsibility |
|---|---|---|
| Application | **TongYiLite** (Flutter) | UI, agent loop, tool calling, memory, speech pipeline, vision input pipeline |
| Service | **inference core** (pluggable backends) | One platform-neutral C ABI; backends switchable: CPU (`ggml-cpu`) / GPU (`ggml-vulkan`) / **NPU (`ggml-openvino` / WangCai)** |
| Engine | **WangCai** | Pure-NPU inference: translate a `ggml_cgraph` into static OpenVINO graphs and run them on `AI Boost` |

### Android → Windows

TongYiLite is a **Flutter application (not Kotlin)**: roughly 54k lines of Dart against 6 Kotlin files and
2k lines of host shell. The heavy code is one C++ file — `tongyilite_jni.cpp` (3887 lines) does model
loading, per-token callbacks, MTP speculative decoding and mtmd vision encoding. The porting judgement
(backed by **artifacts already built on this machine**; see
`Windows移植_CPU_GPU_NPU_实施方案_2026-10-30.md` in the TongYiLite tree):

- **About 90% of the Dart side is reused unchanged** in Flutter Windows — the agent, tools, memory and
  speech pipelines do not touch Android APIs.
- **The real work is the C++ core**: extract that 3887-line JNI shell into a platform-neutral **C ABI**,
  rewrite logging / OOM probing / path handling, and replace MainActivity's 8 `MethodChannel`s with a
  Dart FFI bridge.
- **The backend set is rewired**: drop KleidiAI (ARM), the OpenCL stub and the NDK Vulkan stub; add
  MSVC + Ninja + **`ggml-openvino` (NPU)**.
  Feasibility is already demonstrated locally: `.upgrade-tmp/host-mingw/bin/llama-mtmd-cli.exe` proves
  llama.cpp builds natively for Windows x64 under MinGW.

### Why the NPU (low power)

Decode is memory-bound, and that is where the NPU is strong: **very low power, CPU cores left free for
the rest of the system**. NPU prefill on LFM3 reaches **415 t/s** (73% of the CPU reference) with the CPU
idle. The price: decode is still **8.3–8.7 t/s** and accuracy is not there yet
([docs/status.md](docs/status.md)) — both are the next targets.

> Stated honestly: **this machine exposes no NPU counters, has no battery, and is on the "high
> performance" power plan**, so there is no performance-per-watt number yet. What the roadmap commits to is
> reproducible proxy evidence (CPU occupancy, temperature, throttle events); watts need an external meter
> or a battery-backed machine.

### Modalities

TongYiLite already ships text ✅, vision ✅ (mtmd + mmproj), speech in ✅ (sherpa ASR) and speech out ✅
(Edge TTS + sherpa VITS). Its model catalog already carries `LFM3-VL-2B QAD-Q4_0` with an mmproj — once the
text path is right, the modalities are a question for the same backend.

### Phases

- **Phase 0 (this repository)**: pure-NPU engine, LFM3 text path. 🟡 in progress.
- **Phase 1**: move the engine into the TongYiLite service layer — C ABI extraction, pluggable backends.
- **Phase 2**: the app runs on Windows; CPU backend first, NPU second.
- **Phase 3**: modalities (vision / speech) end to end on the NPU.
- **Phase 4**: measured low power, and power-aware scheduling policy.

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
