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
#>
param(
    [string]$Model = '',                        # path or bare gguf name; searched under models/ and -ModelDir
    [string]$ModelDir = '',                     # extra directory to search by file name (or WANGCAI_MODEL_DIR)
    [int]$Ctx = 2048,                           # conversation window; 1.7B verified at c8192
    [int]$MaxTokens = 256,                      # per-reply cap
    [int]$Chunk = 128,                          # prefill chunk of the proven text config
    [string]$CacheDir = '',                     # persistent graph cache; default .cache\npu_chat
    [switch]$LevelsOff                          # escape hatch if the device budget acts up
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
if (-not $CacheDir) { $CacheDir = Join-Path (Join-Path $repo '.cache') 'npu_chat' }
New-Item -ItemType Directory -Force -Path $CacheDir | Out-Null
$env:GGML_OPENVINO_CACHE_DIR = $CacheDir

Write-Host "chat [NPU] model=$Model ctx=$Ctx cache=$CacheDir"
Write-Host 'type at "> " and Enter; /exit quits, /clear resets, /regen repeats the last answer'

& $cli -m "$Model" -c $Ctx -n $MaxTokens -fa 1 -np 1 -dev OPENVINO3
Write-Host "chat exited with code $LASTEXITCODE"
