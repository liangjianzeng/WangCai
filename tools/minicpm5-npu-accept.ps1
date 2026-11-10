# minicpm5-npu-accept.ps1 - 3-question NPU acceptance for the MiniCPM5-2B sub-target (OpenBMB,
# ModelScope OpenBMB/MiniCPM5-2B-gguf, standard llama-arch Q4_K_M, thinking model).
#
# Budget config follows the sub-target discipline: 2.6B (~1.45 GB weights) sits between the
# LFM3-1.7B defaults (chunk256 + decode levels) and the Spark-4B fallback (chunk128 +
# DISABLE_DECODE_LEVELS, ZE_RESULT_ERROR_OUT_OF_HOST_MEMORY otherwise). Default arm = 1.7B-like;
# the spark arm is one env change away for the fallback.
#
# Token budget: MiniCPM5-2B is a thinking model -- CoT preamble (~60-90 tokens) precedes the
# answer, so n=48 truncates before it (same failure family as the P12 n=48 Beijing flake).
# n=192 verified on native and OV-CPU static.
# ASCII only (PS 5.1 reads BOM-less files in the ANSI codepage).
[CmdletBinding()]
param(
    [ValidateSet('default', 'spark')][string]$Arm = 'default',
    [int]$Ctx = 512,
    [int]$Tokens = 192
)
$ErrorActionPreference = 'Stop'
$Exe = 'E:\llm\npu\src\llama\build\bin\llama-cli.exe'
$Model = 'E:\llm\npu\models\MiniCPM5-2B-Q4_K_M.gguf'
$env:PATH = 'E:\llm\npu\src\llama\build\bin;E:\llm\npu\ov\openvino\libs;' + $env:PATH
$env:GGML_OPENVINO_DEVICE = 'NPU'
$env:GGML_OPENVINO_CACHE_DIR = 'E:\llm\npu\cache_mcpm_npu_' + $Arm
if ($Arm -eq 'spark') {
    # 4B-proven reduced-budget arm (HANDOFF 2026-11-01): chunk128 + no decode level graphs.
    $env:GGML_OPENVINO_PREFILL_CHUNK_SIZE = '128'
    $env:GGML_OPENVINO_DISABLE_DECODE_LEVELS = '1'
}

$questions = @(
    @{ Prompt = 'What is the capital city of China? Answer with the city name only.'; Expect = 'Beijing' },
    @{ Prompt = 'What is the capital of France? Answer with the city name only.'; Expect = 'Paris' },
    @{ Prompt = '1+1 equals what? Answer with the number only.'; Expect = '2' }
)

$failed = 0
foreach ($q in $questions) {
    $log = 'E:\llm\npu\txt\minicpm5_npu_' + $Arm + '_q_' + $q.Expect + '.log'
    # cmd.exe redirection, not PowerShell *>: PS stream redirection truncates the OpenVINO
    # exception text exactly where diagnostics are needed (run-npu.ps1 lesson) and writes
    # UTF-16 that dies as a 0-byte file when the process is killed.
    cmd.exe /c "`"$Exe`" -m `"$Model`" -c $Ctx -n $Tokens --temp 0 --seed 42 -np 1 -fa 1 -dev OPENVINO3 -st --no-warmup -p `"$($q.Prompt)`" 1> `"$log`" 2>&1"
    $code = $LASTEXITCODE
    $text = ''
    if (Test-Path $log) { $text = [System.IO.File]::ReadAllText($log) }
    if ($code -ne 0) {
        Write-Output ("FAIL(exit={0}) expect='{1}'" -f $code, $q.Expect)
        Get-Content $log -Tail 6 | ForEach-Object { Write-Output ('  ' + $_) }
        $failed++
        continue
    }
    if ($text -match 'NaN|nan inf') {
        Write-Output ("FAIL(nan) expect='{0}'" -f $q.Expect)
        $failed++
        continue
    }
    # Keyword-check the answer section only (echoed prompt -> perf footer): the perf footer
    # carries arbitrary digits and would false-pass the single-digit expectation (2026-11-01 Q3 flake).
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
        Write-Output ('  ' + $answer.Substring(0, [Math]::Min(200, $answer.Length)))
        $failed++
        continue
    }
    Write-Output ("PASS expect='{0}'" -f $q.Expect)
}
if ($failed -gt 0) { throw ("minicpm5 npu acceptance failed: {0}/3 (arm={1})" -f $failed, $Arm) }
Write-Output ("MINICPM5-NPU-ACCEPT-OK 3/3 (arm={0})" -f $Arm)
