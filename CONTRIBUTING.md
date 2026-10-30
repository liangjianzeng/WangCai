# Contributing to WangCai

Thanks for spending your time on the least-loved accelerator in the laptop.

## Before you open an issue

Most "it doesn't work" reports in this project resolve to one of three things, and the difference
between them is not visible from the console:

1. the graph never compiled (an `ov::Exception` / `Check ... failed` line is present),
2. it compiled and ran but the numbers are wrong (silent),
3. it ran fine but on the wrong device (silent).

So please include:

```powershell
# which device actually got used
.\build\bin\llama-cli.exe --list-devices

# the run itself, with the device-decision log
$env:GGML_OPENVINO_DEVICE = 'NPU'
$env:GGML_OPENVINO_CACHE_DIR = 'D:\npu_cache'      # fresh dir per config, see below
.\build\bin\llama-cli.exe -m models\<model>.gguf -c 1024 -n 32 --temp 0 -fa 1 -dev OPENVINO3 -st -p '...' 2>&1 |
    Tee-Object issue.log
```

and, if the output is nonsense rather than an exception, the two artifacts that make a report
actionable:

```powershell
$env:GGML_OPENVINO_DUMP_BIN = 'D:\dumps\npu'   # raw per-output tensors
# ... run once ...
# ... then the same run with GGML_OPENVINO_DEVICE=CPU, dumping to D:\dumps\cpu ...
..\tools\compare-tensors.ps1 -A D:\dumps\cpu -B D:\dumps\npu
```

Also state: OS build, `Intel(R) AI Boost` driver version, OpenVINO version, llama.cpp commit, whether
the patch applied cleanly, and the model file with its size and quantization.

**Use a fresh `GGML_OPENVINO_CACHE_DIR` per configuration.** A stale compiled-graph cache silently
reuses a graph built under a different flag set, which is the single most confusing failure mode in
this project — it makes a flag look like it did nothing.

## Setting up a dev tree

```powershell
git clone https://github.com/liangjianzeng/WangCai
cd WangCai
tools\bootstrap.ps1        # clones llama.cpp at the pinned commit and applies the patches
tools\configure.ps1 -OpenVinoDir C:\openvino\openvino\cmake
tools\build.ps1
```

The build is Release + Ninja + MSVC. Incremental rebuilds of the backend are ~1–2 min; a cold
configure is ~3 min. See [docs/build.md](docs/build.md) for the toolchain versions that are known
good, and for why the OpenVINO *runtime* wheel is an acceptable source of the development headers.

## The iteration loop you actually want

NPU graph compilation costs ~36 s cold for LFM3-1.7B, and there is no way to avoid it. So debug
everything that can be debugged off-device:

- `GGML_OPENVINO_FORCE_STATIC=1` with `GGML_OPENVINO_DEVICE=CPU` runs the **static NPU code path on
  the CPU**, no NPU compile, seconds instead of minutes. Translation bugs reproduce there; plugin
  bugs do not. That split is how "static-mode mask sizing" and "NPU numeric behaviour" got separated.
- `tools/npu-sweep.ps1` runs a matrix of env overrides with an isolated cache dir per cell and prints
  one line per cell.
- `tools/compare-tensors.ps1` compares two dumps by cosine similarity, top-1 agreement and element
  count above a threshold. Aggregate statistics mislead; cosine does not.

## Style and structure

- Match the surrounding llama.cpp style: 4-space indent, 120 columns, `snake_case` functions,
  `m_`-prefixed members. The backend is upstream code; keep diffs readable for an upstream PR.
- Every behavioural change needs an env-var escape hatch that restores upstream behaviour, and an
  entry in [docs/env-vars.md](docs/env-vars.md). Register new variables in the table in
  `ggml-openvino-extra.cpp` — an unregistered name reads as unset with no error.
- Comments should explain the constraint that forced the code, not the code. The useful comment in
  this tree is "llama.cpp pads the mask to the largest KV buffer, so a static graph must take the
  width from the consuming cache", not "set mask_kv".
- No `#ifdef`-based feature flags where an env var does the job; no dead code left behind "just in
  case".

## What to work on

The [roadmap](docs/roadmap.md) lists things that are individually tractable. Two are especially
suitable for a first contribution because they are measurement tasks with a defined answer, not
open-ended debugging:

- quantify the accuracy gap per layer (the dump harness makes this a day of work, not a week),
- find why NPU decode is ~2.5× slower than OpenVINO-CPU on this model.

## Repository hygiene

Agent/assistant project-memory files (`AGENTS.md`, `CLAUDE.md`, `.claude/`, and similar) are
**git-ignored** in this repository. They carry machine inventories, internal endpoints and build
pipeline notes that do not belong in a public clone. Keep them in your private docs repo; if a
decision from them needs to be public, write it up as a document in `docs/` instead of letting the
memory file drift back into the index. Check `git status --ignored` before your first commit.

## Pull requests

- One concern per PR; link the issue or the roadmap item.
- Include the measured before/after. "Faster" without a `t/s` number and the command line that
  produced it is not a result.
- If you changed graph construction, include both a CPU-static and an NPU run.
- Update [CHANGELOG.md](CHANGELOG.md); rejected hypotheses are as valuable as fixes, and belong
  there too.

By contributing you certify that you wrote the contribution or have the right to submit it under the
Apache-2.0 license, and you understand that the project and the contribution are public and that a
record is kept indefinitely.
