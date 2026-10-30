# tools

Scripts that wrap the two things you repeat constantly in this project — building inside a Visual
Studio environment, and running a model on the NPU under a controlled environment — plus the
comparison harness that the accuracy work depends on.

Windows PowerShell 5.1 and PowerShell 7 both work. **Keep these files ASCII-only**: PowerShell 5.1
parses `.ps1` as ANSI, so a Chinese string literal or an em-dash in the source breaks the parser with
a misleading `Missing ')' in function call`.

| Script | What it is for |
|---|---|
| `bootstrap.ps1` | clone llama.cpp at the pinned commit, apply `patches/`, drop in the shim |
| `configure.ps1` | CMake configure (Release, Ninja, OpenVINO backend only) inside `vcvars64` |
| `build.ps1` | incremental build of `llama-cli llama-completion llama-bench llama-server` |
| `run-npu.ps1` | one controlled run on NPU / OpenVINO-CPU / CPU-static / native CPU, with its own cache dir and log |
| `npu-sweep.ps1` | matrix of NPU compile-config overrides, one line per cell |
| `compare-tensors.ps1` | element-wise comparison of two `GGML_OPENVINO_DUMP_BIN` captures |
| `top-token.ps1` | per-pass top-1 token / norm / min / max, for aligning passes between runs |

Everything lands under `tmp/` (git-ignored): logs, caches, dumps.

## First build

```powershell
tools\bootstrap.ps1
tools\configure.ps1 -OpenVinoDir D:\ov\openvino\cmake
tools\build.ps1
```

`configure.ps1` finds `vcvars64.bat` through `vswhere` and writes the real commands into
`tmp\configure.bat` — invoking `vcvars64.bat` inline from PowerShell loses the `&&` chain and reports
"No CMAKE_C_COMPILER could be found". Point `-Ninja` at a `ninja.exe` that is not on `PATH` if that is
your setup.

`build.ps1` writes `tmp\build.log` and prints only the error lines plus the benign embedded-UI
warnings.

## Runs

```powershell
# on the NPU
tools\run-npu.ps1 -Model models\LFM3-1.7B-Q4_K_M.gguf -PromptFile prompts\zh.txt -N 32 -Ctx 1024

# the same graph, static path, on the CPU (seconds instead of a 36 s NPU compile)
tools\run-npu.ps1 -Model models\LFM3-1.7B-Q4_K_M.gguf -PromptFile prompts\zh.txt -Backend static

# reference: ggml CPU, no OpenVINO at all
tools\run-npu.ps1 -Model models\LFM3-1.7B-Q4_K_M.gguf -PromptFile prompts\zh.txt -Backend native

# a compile-flag experiment, with its own cache dir and dump directory
tools\run-npu.ps1 -Model models\LFM3-1.7B-Q4_K_M.gguf -PromptFile prompts\zh.txt `
    -Overrides 'NPUW_FOLD=NO' -CacheTag nofold -DumpBin tmp\dumps\nofold
```

Each run prints one block:

```
### [npu] backend=npu overrides='' elapsed=51s   log=tmp\run_npu_npu.log
    MASK W ov-mask: name=attn_inp_kq_mask ne=[256,2,1,1] is_swa=1 -> mask_kv=768 | ctx=1024 ctx_swa=768 chunk=256
    TEXT 用一句话介绍长城。 万里长城是中国古代的军事防御工程…
    PERF eval time = 0.86 seconds / 7 tokens | 8.14 tokens per second
```

`-Backend` is the axis that matters most: `npu` (static path, NPU plugin), `ovcpu` (dynamic path,
coherent reference), `static` (static path on the CPU — translation bugs reproduce here, plugin bugs
do not), `native` (no OpenVINO at all).

## Sweeping NPU compile flags

```powershell
tools\npu-sweep.ps1 -Model models\LFM3-1.7B-Q4_K_M.gguf -PromptFile prompts\zh.txt
# or your own matrix
tools\npu-sweep.ps1 -Model models\LFM3-1.7B-Q4_K_M.gguf -Cases @(
    @{ Label = 'base';    Overrides = '' },
    @{ Label = 'chunk128'; Extra = @{ GGML_OPENVINO_PREFILL_CHUNK_SIZE = '128' } },
    @{ Label = 'nofold';  Overrides = 'NPUW_FOLD=NO' }
)
```

Cells get isolated `GGML_OPENVINO_CACHE_DIR`s. This is not cosmetic: a reused compiled-graph cache
makes a working flag look like it did nothing.

## Comparing two devices

```powershell
tools\run-npu.ps1 -Model ... -Backend static -DumpBin tmp\dumps\cpu -Label cpu
tools\run-npu.ps1 -Model ... -Backend npu    -DumpBin tmp\dumps\npu -Label npu

# 1. align the passes first
tools\top-token.ps1 -Dir tmp\dumps\cpu
tools\top-token.ps1 -Dir tmp\dumps\npu

# 2. then compare
tools\compare-tensors.ps1 -A tmp\dumps\cpu -B tmp\dumps\npu
tools\compare-tensors.ps1 -A tmp\dumps\cpu -B tmp\dumps\npu -OnlyMismatched -Top 8
```

Always do step 1 before trusting step 2. Pass counts differ between runs, and comparing pass N of one
device against pass N of the other produces confident nonsense. `compare-tensors.ps1` reads the
`.txt` sidecar written next to each dump for the element type (f32 and f16 supported; anything else is
skipped by name rather than silently misread).

### Row mode, and why whole-buffer KV comparison is a trap

A KV cache tensor is `[1,1,ctx,heads*head_dim]`: the rows are positions, and a chunk writes only the
rows it was given. Everything past the last written position holds whatever the buffer happened to
contain — on a fresh allocation, often zeros on *both* sides. Whole-tensor statistics over that region
are not measurements:

```
cache_v_l20   cosine=0.135  maxDiff=0.0000      # both sides zero: "0.135" is 0/0, not divergence
cache_k_l2    cosine=0.998  maxDiff=45091        # one row disagrees, the rest is padding
```

`-RowSize` compares row by row instead — one row = one position = `n_kv_heads × head_dim` (512 for
LFM3-1.7B), and prints per-row cosine and max-abs plus `leading-clean`, how many rows from the start
agree within `-RowTol` (default 0.05):

```powershell
# rows 0..25 of the K cache written by the first prefill chunk
tools\compare-tensors.ps1 -A dbg\cpu\prefill_0_cache_k_l2.bin -B dbg\npu\prefill_0_cache_k_l2.bin `
    -RowSize 512 -MaxRows 26
```

Read `leading-clean` first: if the chunk wrote N rows, that is the only region worth reading, and a
tensor whose clean rows stop at the write boundary is telling you about the write, not the arithmetic.
Use `-MaxElements` with it to keep the scan (and the f16 decode) bounded.
