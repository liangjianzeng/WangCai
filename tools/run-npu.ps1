<#
    run-npu.ps1 - one controlled generation run, with a clean environment and its own log.

    Why the ceremony:
      * every GGML_OPENVINO_* variable is cleared first, so nothing leaks between runs;
      * GGML_OPENVINO_CACHE_DIR is per -CacheTag, because a stale compiled-graph cache silently
        reuses a graph built under a different flag set (the most confusing failure in this project);
      * output is redirected inside cmd.exe, since PowerShell stream redirection truncates the
        OpenVINO exception text.
#>
param(
    [Parameter(Mandatory = $true)][string]$Model,
    [string]$Prompt = '',
    [string]$PromptFile = '',
    [int]$N = 32,
    [int]$Ctx = 1024,
    [int]$Seed = 42,
    # npu = NPU device/static path, ovcpu = OpenVINO CPU dynamic, static = OpenVINO CPU with the
    # static (NPU-shape) path forced, native = ggml CPU reference, bypassing OpenVINO entirely.
    [ValidateSet('npu', 'ovcpu', 'static', 'native')][string]$Backend = 'npu',
    [string]$Overrides = '',                 # GGML_OPENVINO_NPU_COMPILE_OVERRIDES
    [hashtable]$Extra = @{},                 # @{ GGML_OPENVINO_PREFILL_CHUNK_SIZE = '64' }
    [string]$CacheTag = '',
    [string]$DumpBin = '',
    [string]$Label = '',
    [switch]$Stateful
)

$ErrorActionPreference = 'Stop'
$repo = Split-Path -Parent $PSScriptRoot
$bin  = Join-Path (Join-Path (Join-Path (Join-Path $repo 'src') 'llama') 'build') 'bin'
$exe  = if ($env:OS -eq 'Windows_NT') { 'llama-cli.exe' } else { 'llama-cli' }
$cli  = Join-Path $bin $exe
if (-not (Test-Path $cli)) { throw "not built yet - run tools\build.ps1 (looked for $cli)" }
if (-not (Test-Path $Model)) { throw "no such model: $Model" }
if (-not $Prompt -and -not $PromptFile) { throw 'pass -Prompt or -PromptFile' }

# OpenVINO runtime DLLs/SOs must be reachable; the ov/ drop is the conventional location in this repo.
$ovlibs = Join-Path (Join-Path (Join-Path $repo 'ov') 'openvino') 'libs'
$sep = if ($env:OS -eq 'Windows_NT') { ';' } else { ':' }
$env:PATH = "$bin" + $sep + $(if (Test-Path $ovlibs) { "$ovlibs$sep" } else { '' }) + $env:PATH

Get-ChildItem 'Env:GGML_OPENVINO_*' | ForEach-Object { Remove-Item "Env:$($_.Name)" }

$tag  = if ($CacheTag) { $CacheTag } elseif ($Label) { $Label } else { $Backend }
$tag  = $tag -replace '[^A-Za-z0-9]', ''
$tmp  = Join-Path $repo 'tmp'
New-Item -ItemType Directory -Force -Path $tmp | Out-Null

switch ($Backend) {
    'npu'    { $env:GGML_OPENVINO_DEVICE = 'NPU'; $dev = 'OPENVINO3'; $fs = $false }
    'ovcpu'  { $env:GGML_OPENVINO_DEVICE = 'CPU'; $dev = 'OPENVINO0'; $fs = $false }
    'static' { $env:GGML_OPENVINO_DEVICE = 'CPU'; $dev = 'OPENVINO0'; $fs = $true  }
    'native' {                                          $dev = 'none';     $fs = $false }
}
if ($fs) { $env:GGML_OPENVINO_FORCE_STATIC = '1' }
if ($Stateful) { $env:GGML_OPENVINO_STATEFUL_EXECUTION = '1' }
if ($Overrides) { $env:GGML_OPENVINO_NPU_COMPILE_OVERRIDES = $Overrides }
if ($DumpBin) { $env:GGML_OPENVINO_DUMP_BIN = $DumpBin }
foreach ($k in $Extra.Keys) { Set-Item "Env:$k" ([string]$Extra[$k]) }

if ($Backend -ne 'native') {
    $cache = Join-Path $repo "tmp\cache_$($tag)_$Backend"
    Remove-Item $cache -Recurse -Force -ErrorAction SilentlyContinue
    $env:GGML_OPENVINO_CACHE_DIR = $cache
}

$log = Join-Path $tmp "run_$($tag)_$Backend.log"
$arglist = "-m `"$Model`" -c $Ctx -n $N --temp 0 --seed $Seed -np 1 -fa 1 -dev $dev -st"
$arglist += $(if ($PromptFile) { " -f `"$PromptFile`"" } else { " -p `"$Prompt`"" })

$t0 = Get-Date
if ($env:OS -eq 'Windows_NT') {
    cmd.exe /c "`"$cli`" $arglist > `"$log`" 2>&1"
}
else {
    bash -c "`"$cli`" $arglist > `"$log`" 2>&1"
}
$secs = [int]((Get-Date) - $t0).TotalSeconds
$t = Get-Content $log -ErrorAction SilentlyContinue

$name = if ($Label) { $Label } else { $Backend }
Write-Output ("### [{0}] backend={1} overrides='{2}' elapsed={3}s   log={4}" -f $name, $Backend, $Overrides, $secs, $log)

$t | Select-String -Pattern 'ZE_RESULT|Check .* failed|ov::Exception|Compute error|error loading model' |
    Select-Object -First 3 | ForEach-Object {
        $s = $_.ToString().Trim(); Write-Output ('    ERR  ' + $s.Substring(0, [Math]::Min(140, $s.Length)))
    }

# Chat output starts at the '> ' marker; strip timestamped log lines around it.
$m = $t | Select-String -Pattern '^> ' | Select-Object -First 1
if ($m) {
    $body = ($t[($m.LineNumber)..([Math]::Min($t.Count - 1, $m.LineNumber + 12))] |
            Where-Object { $_ -notmatch '^\s*\d+\.\d+\.\d+\.\d+\s' -and $_ -notmatch 'Prompt:|Exiting' }) -join ' '
    if ($body.Length -gt 200) { $body = $body.Substring(0, 200) }
    Write-Output ('    TEXT ' + $body)
}
else { Write-Output '    TEXT <no generation marker - see log>' }

$t | Select-String -Pattern 'tokens per second' | Select-Object -Last 2 | ForEach-Object {
    $s = $_.ToString().Trim(); Write-Output ('    PERF ' + $s.Substring([Math]::Max(0, $s.Length - 74)))
}
$t | Select-String -Pattern 'ov-mask:' | Select-Object -First 2 | ForEach-Object {
    Write-Output ('    MASK ' + $_.ToString().Trim())
}
