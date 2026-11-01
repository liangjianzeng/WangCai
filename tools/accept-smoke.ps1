# accept-smoke.ps1 - 3-question acceptance smoke for the OpenVINO static path, CPU device.
# CI has no NPU; this validates the same static graph translation (rope tile, rank align,
# set_rows) on the CPU plugin, which is the device-independent part of the NPU path.
# The NPU-specific gate stays local: tools/run-npu.ps1 + accept.ps1 on real hardware.
#
# Greedy decode, 3 questions, assert each answer contains the expected keyword.
# ASCII only (PS 5.1 reads BOM-less files in the ANSI codepage).
[CmdletBinding()]
param(
    [Parameter(Mandatory = $true)][string]$Exe,
    [Parameter(Mandatory = $true)][string]$Model,
    [string]$PathPrefix = '',   # extra dirs for the runtime DLLs (OpenVINO libs); ';'-separated
    [int]$Ctx = 1024,
    [int]$Tokens = 96
)
$ErrorActionPreference = 'Stop'

if (-not (Test-Path $Exe)) { throw "llama-cli not found: $Exe" }
if (-not (Test-Path $Model)) { throw "model not found: $Model" }

# Fresh cache dir per run: a stale compiled graph silently winning is the failure mode
# this project can least afford (see docs/troubleshooting.md).
$tmp = Join-Path ([System.IO.Path]::GetTempPath()) ("wangcai-accept-" + [guid]::NewGuid().ToString('N').Substring(0, 8))
New-Item -ItemType Directory -Path $tmp | Out-Null
$env:GGML_OPENVINO_DEVICE = 'CPU'
$env:GGML_OPENVINO_FORCE_STATIC = '1'
$env:GGML_OPENVINO_CACHE_DIR = $tmp
# K-quants (Q4_K_M) need the requant strategy the NPU path applies by default: without it,
# the u4-compressed weights fail to copy on the CPU plugin ("element type u4 is not
# representable as pointer to f16") and 136 ffn weights load as garbage.
$env:GGML_OPENVINO_REQUANT_KQUANT = 'q4_sym128_all'
# Runtime DLLs: the exe's directory first, then any extra lib dirs (the OpenVINO pip
# package's libs dir on CI).
$exeDir = Split-Path -Parent $Exe
$env:PATH = $exeDir + ';' + $PathPrefix + ';' + $env:PATH

$questions = @(
    @{ Prompt = 'What is the capital city of China? Answer with the city name only.'; Expect = 'Beijing' },
    @{ Prompt = 'What is the capital of France? Answer with the city name only.'; Expect = 'Paris' },
    @{ Prompt = '1+1 equals what? Answer with the number only.'; Expect = '2' }
)

$failed = 0
foreach ($q in $questions) {
    $log = Join-Path $tmp ('q_' + $q.Expect + '.log')
    & $Exe -m $Model -c $Ctx -n $Tokens --temp 0 --seed 42 -np 1 -fa 1 -dev OPENVINO0 -st -p $q.Prompt *> $log
    $code = $LASTEXITCODE
    $text = ''
    if (Test-Path $log) { $text = [System.IO.File]::ReadAllText($log) }
    if ($code -ne 0) {
        Write-Output ("FAIL(exit={0}) expect='{1}'" -f $code, $q.Expect)
        Get-Content $log -Tail 8 | ForEach-Object { Write-Output ('  ' + $_) }
        $failed++
        continue
    }
    if ($text -match 'NaN|nan inf') {
        Write-Output ("FAIL(nan) expect='{0}'" -f $q.Expect)
        $failed++
        continue
    }
    # Match the answer section only (between the echoed prompt and the perf footer), never
    # the whole log: the "[ Prompt: 23.7 t/s | Generation: 29.0 t/s ]" footer contains
    # arbitrary digits, so a single-digit expectation like '2' randomly false-passed or
    # false-failed on timing noise (the Q3 flake of 2026-11-01).
    $answer = $text
    $promptEcho = '> ' + $q.Prompt
    $idx = $text.IndexOf($promptEcho)
    if ($idx -ge 0) {
        $start = $idx + $promptEcho.Length
        $end = $text.IndexOf('[ Prompt:', $start)
        if ($end -lt 0) { $end = $text.Length }
        $answer = $text.Substring($start, $end - $start)
    }
    if ($answer -notmatch $q.Expect) {
        Write-Output ("FAIL(missing '{0}')  answer:" -f $q.Expect)
        $head = ($text -split "`n" | Select-String -Pattern 'thinking|answer|We need' | Select-Object -First 3)
        $head | ForEach-Object { Write-Output ('  ' + $_.Line.Substring(0, [Math]::Min(160, $_.Line.Length))) }
        $failed++
        continue
    }
    Write-Output ("PASS expect='{0}'" -f $q.Expect)
}

Remove-Item -Recurse -Force $tmp -ErrorAction SilentlyContinue
if ($failed -gt 0) { throw ("acceptance smoke failed: {0}/3" -f $failed) }
Write-Output 'ACCEPTANCE-SMOKE-OK 3/3'
