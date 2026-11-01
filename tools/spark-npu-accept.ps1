# spark_npu_accept.ps1 - 3-question NPU acceptance for the Spark-X2.6-4B secondary target.
# NPU 4B needs the reduced-budget config found in the first NPU round:
# prefill chunk 128 + decode levels disabled (ZE_RESULT_ERROR_OUT_OF_HOST_MEMORY otherwise).
$ErrorActionPreference = 'Stop'
$Exe = 'D:\llm\npu\src\llama\build\bin\llama-cli.exe'
$Model = 'D:\llm\npu\models\Spark-X2.6-4B-Q4_K_M.gguf'
$env:PATH = 'D:\llm\npu\src\llama\build\bin;D:\llm\npu\ov\openvino\libs;' + $env:PATH
$env:GGML_OPENVINO_DEVICE = 'NPU'
$env:GGML_OPENVINO_CACHE_DIR = 'D:\llm\npu\cache_spark_npu2'
$env:GGML_OPENVINO_PREFILL_CHUNK_SIZE = '128'
$env:GGML_OPENVINO_DISABLE_DECODE_LEVELS = '1'

$questions = @(
    @{ Prompt = 'What is the capital city of China? Answer with the city name only.'; Expect = 'Beijing' },
    @{ Prompt = 'What is the capital of France? Answer with the city name only.'; Expect = 'Paris' },
    @{ Prompt = '1+1 equals what? Answer with the number only.'; Expect = '2' }
)

$failed = 0
foreach ($q in $questions) {
    $log = "D:\llm\npu\txt\spark_npu_q_" + $q.Expect + ".log"
    & $Exe -m $Model -c 512 -n 48 --temp 0 --seed 42 -np 1 -fa 1 -dev OPENVINO3 -st -p $q.Prompt *> $log
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
if ($failed -gt 0) { throw ("spark npu acceptance failed: {0}/3" -f $failed) }
Write-Output 'SPARK-NPU-ACCEPT-OK 3/3'
