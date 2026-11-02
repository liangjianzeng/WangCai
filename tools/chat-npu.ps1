<#
    chat-npu.ps1 - interactive terminal chat on the NPU (the 0.0.1-style text UI).

    Starts llama-cli WITHOUT -st/-p, so it stays in the conversation loop: type at "> ",
    get an answer, keep chatting. Slash commands: /exit (or Ctrl+C) quits, /clear resets the
    chat history, /regen regenerates the last answer, /read <file> and /glob <pattern> feed
    files into the conversation.

    Differences from run-npu.ps1 (the measurement harness): chat keeps a PERSISTENT graph
    cache (.cache\npu_chat) so warm starts cost ~9 s instead of recompiling, uses the model's
    own sampling defaults instead of forcing greedy, and does not redirect the console -- it
    needs the real terminal.

    Expect on first run against an empty cache: a one-off NPU graph compile (tens of seconds).
    A conversation that grows past a 256-token KV span pauses once while that decode-level
    graph compiles; the next conversations hit the cache. For CJK input comfort use Windows
    Terminal (or chcp 65001) so the "> " line reads UTF-8.

    Works from ANY current directory -- everything is located relative to this file and
    printed as an absolute path in the banner. Invoke it by absolute path:
        E:\DTXY\WangCai\tools\chat-npu.ps1 -Model Spark-X2.6-4B-Q4_K_M.gguf
    Any model in the model dir works (LFM3-1.7B, Spark-X2.6-4B, Qwen3-4B, ...); the chunk=128
    default is the proven 4B chat config -- do NOT raise it to 256 for chat/server flows on 4B:
    the driver host budget only fits chunk256 in the llama-bench flow (HANDOFF 2026-11-02
    evening). Graph cache is per model under .cache\npu_chat\<model>.

    Vision/audio scenarios: one-shot questions through llama-mtmd-cli (the pinned llama-cli
    has no --mmproj): -Image photo.png -Ask 'What is in this picture?' or -Audio clip.wav.
    The projector is auto-detected as mmproj-<model>.gguf next to the model, or pass -Mmproj.
#>
param(
    [string]$Model = '',                        # path or bare gguf name; searched under models/ and -ModelDir
    [string]$ModelDir = '',                     # extra directory to search by file name (or WANGCAI_MODEL_DIR)
    [int]$Ctx = 2048,                           # conversation window; 1.7B verified at c8192
    [int]$MaxTokens = 256,                      # per-reply cap
    [int]$Chunk = 128,                          # prefill chunk of the proven text config
    [string]$CacheDir = '',                     # persistent graph cache; default .cache\npu_chat\<model>
    [switch]$LevelsOff,                         # escape hatch if the device budget acts up
    [string]$Image = '',                        # one-shot vision question via llama-mtmd-cli
    [string]$Audio = '',                        # one-shot audio question via llama-mtmd-cli
    [string]$Mmproj = '',                       # projector gguf; default: auto-detect next to -Model
    [string]$Ask = 'Describe this briefly.'     # prompt for the -Image/-Audio one-shot
)
$ErrorActionPreference = 'Stop'
if (Test-Path 'Variable:PSNativeCommandUseErrorActionPreference') {
    $PSNativeCommandUseErrorActionPreference = $false
}
$repo = Split-Path -Parent $PSScriptRoot
$bin  = Join-Path (Join-Path (Join-Path (Join-Path $repo 'src') 'llama') 'build') 'bin'
$exe  = if ($env:OS -eq 'Windows_NT') { 'llama-cli.exe' } else { 'llama-cli' }
$cli  = Join-Path $bin $exe
if (-not (Test-Path $cli)) { throw "not built yet - run tools\build.ps1 (looked for $cli)" }
# Model resolution: accept a path that exists (absolute or cwd-relative), otherwise look the
# file name up under -ModelDir / $env:WANGCAI_MODEL_DIR / repo\models. models/ is gitignored,
# so on a dev box the weights usually live elsewhere; the searched dirs are listed on failure.
if (-not $Model) { $Model = 'LFM3-1.7B-Q4_K_M.gguf' }
if (-not (Test-Path $Model)) {
    $name  = Split-Path -Leaf $Model
    $tries = @()
    if ($ModelDir)                  { $tries += $ModelDir }
    if ($env:WANGCAI_MODEL_DIR)     { $tries += $env:WANGCAI_MODEL_DIR }
    $tries += (Join-Path $repo 'models')
    $hit = $null
    foreach ($d in $tries) {
        $cand = Join-Path $d $name
        if (Test-Path $cand) { $hit = $cand; break }
    }
    if (-not $hit) {
        throw ("no such model: '{0}' (searched: {1}) -- pass a path, a bare file name found in " +
               'one of those directories, or -ModelDir <dir> (models/ is gitignored)' -f $Model, ($tries -join ', '))
    }
    $Model = $hit
}

# OpenVINO runtime DLLs/SOs must be reachable; the ov/ drop is the conventional location in this repo.
$ovlibs = Join-Path (Join-Path (Join-Path $repo 'ov') 'openvino') 'libs'
$sep = if ($env:OS -eq 'Windows_NT') { ';' } else { ':' }
$env:PATH = "$bin" + $sep + $(if (Test-Path $ovlibs) { "$ovlibs$sep" } else { '' }) + $env:PATH

Get-ChildItem 'Env:GGML_OPENVINO_*' | ForEach-Object { Remove-Item "Env:$($_.Name)" }
$env:GGML_OPENVINO_DEVICE = 'NPU'
$env:GGML_OPENVINO_PREFILL_CHUNK_SIZE = [string]$Chunk
if ($LevelsOff) { $env:GGML_OPENVINO_DISABLE_DECODE_LEVELS = '1' }
# Per-model cache subdirectory: different weights/architectures must never share one blob dir.
$stem = [IO.Path]::GetFileNameWithoutExtension($Model)
if (-not $CacheDir) { $CacheDir = Join-Path (Join-Path (Join-Path $repo '.cache') 'npu_chat') $stem }
New-Item -ItemType Directory -Force -Path $CacheDir | Out-Null
$env:GGML_OPENVINO_CACHE_DIR = (Resolve-Path $CacheDir).Path

# Absolute paths everywhere in the banner: the script locates everything itself via its own
# file location, so it can be launched from ANY cwd as E:\...\tools\chat-npu.ps1.
Write-Host ("chat [NPU] repo={0}" -f $repo)
Write-Host ("chat [NPU] cli={0}" -f (Resolve-Path $cli).Path)
Write-Host ("chat [NPU] model={0}" -f (Resolve-Path $Model).Path)
Write-Host ("chat [NPU] cache={0} ctx={1}" -f $env:GGML_OPENVINO_CACHE_DIR, $Ctx)

# Vision/audio scenarios are one-shot questions through llama-mtmd-cli (the pinned llama-cli
# has no --mmproj). Same NPU environment as the chat path above.
if ($Image -or $Audio) {
    $mexe = if ($env:OS -eq 'Windows_NT') { 'llama-mtmd-cli.exe' } else { 'llama-mtmd-cli' }
    $mtmd = Join-Path $bin $mexe
    if (-not (Test-Path $mtmd)) { throw "not built yet - build target llama-mtmd-cli (looked for $mtmd)" }
    if (-not $Mmproj) {
        $mdir   = Split-Path -Parent $Model
        $want   = "mmproj-$stem.gguf"                        # models convention: mmproj-<model>.gguf
        $Mmproj = Join-Path $mdir $want
        if (-not (Test-Path $Mmproj)) {
            $found = @(Get-ChildItem -Path $mdir -Filter '*mmproj*.gguf' -ErrorAction SilentlyContinue)
            if ($found.Count -eq 1) { $Mmproj = $found[0].FullName } else { $Mmproj = '' }
        }
    }
    if (-not $Mmproj -or -not (Test-Path $Mmproj)) {
        throw "mmproj not found: pass -Mmproj <path> (looked for mmproj-$stem.gguf in $(Split-Path -Parent $Model))"
    }
    Write-Host ("chat [NPU] mtmd={0} mmproj={1}" -f (Resolve-Path $mtmd).Path, (Resolve-Path $Mmproj).Path)
    $media = if ($Image) { @('--image', $Image) } else { @('--audio', $Audio) }
    & $mtmd -m "$Model" --mmproj "$Mmproj" $media -p "$Ask" --temp 0 -c $Ctx -n $MaxTokens
    Write-Host "mtmd exited with code $LASTEXITCODE"
    exit $LASTEXITCODE
}

Write-Host 'type at "> " and Enter; /exit quits, /clear resets, /regen repeats the last answer'

& $cli -m "$Model" -c $Ctx -n $MaxTokens -fa 1 -np 1 -dev OPENVINO3
Write-Host "chat exited with code $LASTEXITCODE"
