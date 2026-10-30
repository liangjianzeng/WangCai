<#
    compare-tensors.ps1 - element-wise comparison of two GGML_OPENVINO_DUMP_BIN captures.

    Aggregate min/max/mean statistics (what GGML_OPENVINO_DEBUG_OUTPUT prints) hide single-row
    errors, and a single wrong row is exactly what a mis-selected chunk position looks like. Cosine
    similarity over the whole tensor does not.

      tools\compare-tensors.ps1 -A tmp\dumps\cpu -B tmp\dumps\npu
      tools\compare-tensors.ps1 -A a\result_output_3_prefill.bin -B b\result_output_3_prefill.bin -Top 8

    Files are matched by name; each .bin has a .txt sidecar with "<shape> <type>" written by the
    dumper. f32 and f16 are supported; anything else is reported and skipped.
#>
param(
    [Parameter(Mandatory = $true)][string]$A,
    [Parameter(Mandatory = $true)][string]$B,
    [int]$Top = 5,
    [double]$Thresh = 0.25,
    [string]$Filter = '*.bin',
    # Compare only the leading N elements. Triaging "which of 300 tensors diverges" does not need a
    # full scan of every multi-megabyte cache buffer, and a leading slice is a fine indicator.
    [int]$MaxElements = 0,
    [switch]$OnlyMismatched
)

function Read-Elements([string]$path) {
    $bytes = [System.IO.File]::ReadAllBytes($path)
    $type = 'f32'
    $side = "$path.txt"
    if (Test-Path $side) {
        $txt = (Get-Content $side -Raw)
        if ($txt -match '\b(f32|f16|f64|i64|i32|bf16)\b') { $type = $Matches[1] }
    }
    switch ($type) {
        'f32' {
            $v = New-Object 'double[]' ([int]($bytes.Length / 4))
            for ($i = 0; $i -lt $v.Length; $i++) { $v[$i] = [BitConverter]::ToSingle($bytes, $i * 4) }
            return @{ type = $type; values = $v }
        }
        'f16' {
            # No System.Half on Windows PowerShell 5.1, so decode by hand.
            $v = New-Object 'double[]' ([int]($bytes.Length / 2))
            for ($i = 0; $i -lt $v.Length; $i++) {
                $u = [BitConverter]::ToUInt16($bytes, $i * 2)
                $sign = if ($u -band 0x8000) { -1.0 } else { 1.0 }
                $exp = ($u -shr 10) -band 0x1F
                $man = $u -band 0x3FF
                if ($exp -eq 0)     { $m = $man / 1024.0; $e = -14 }
                elseif ($exp -eq 31) { $m = 0.0; $e = 0 }
                else                 { $m = 1.0 + $man / 1024.0; $e = $exp - 15 }
                $v[$i] = $sign * $m * [Math]::Pow(2, $e)
            }
            return @{ type = $type; values = $v }
        }
        default { return @{ type = $type; values = $null } }
    }
}

function Top-K($v, $k, $limit) {
    # Bounded by the compared prefix: sorting the whole buffer of a multi-megabyte cache tensor to
    # print five numbers is the difference between seconds and minutes per tensor.
    if ($limit -le 0 -or $limit -gt $v.Length) { $limit = $v.Length }
    $order = 0..($limit - 1) | Sort-Object -Descending { $v[$_] } | Select-Object -First $k
    ($order | ForEach-Object { 'id{0}={1}' -f $_, ([Math]::Round($v[$_], 3)) }) -join '  '
}

$dirA = if (Test-Path $A -PathType Container) { $A } else { Split-Path $A -Parent }
$dirB = if (Test-Path $B -PathType Container) { $B } else { Split-Path $B -Parent }
$names = if (Test-Path $A -PathType Container) {
    (Get-ChildItem $A -Filter $Filter | Select-Object -ExpandProperty Name)
}
else { @(Split-Path $A -Leaf) }

$worst = @()
foreach ($name in $names) {
    $pa = Join-Path $dirA $name
    $pb = Join-Path $dirB $name
    if (-not (Test-Path $pa) -or -not (Test-Path $pb)) { Write-Output ("  SKIP  {0} (missing on one side)" -f $name); continue }

    $ea = Read-Elements $pa
    $eb = Read-Elements $pb
    if (-not $ea.values -or -not $eb.values) {
        Write-Output ("  SKIP  {0} (unsupported element type {1}/{2})" -f $name, $ea.type, $eb.type); continue
    }

    $n = [Math]::Min($ea.values.Length, $eb.values.Length)
    if ($MaxElements -gt 0 -and $n -gt $MaxElements) { $n = $MaxElements }
    if ($n -eq 0) { Write-Output ("  SKIP  {0} (empty)" -f $name); continue }
    $va = $ea.values; $vb = $eb.values

    $dot = 0.0; $na = 0.0; $nb = 0.0; $maxd = 0.0; $maxi = -1; $nd = 0
    for ($i = 0; $i -lt $n; $i++) {
        $x = $va[$i]; $y = $vb[$i]
        $dot += $x * $y; $na += $x * $x; $nb += $y * $y
        $d = [Math]::Abs($x - $y)
        if ($d -gt $maxd) { $maxd = $d; $maxi = $i }
        if ($d -gt $Thresh) { $nd++ }
    }
    $cos = if ($na -gt 0 -and $nb -gt 0) { $dot / [Math]::Sqrt($na * $nb) } else { 0.0 }

    $line = ('  {0,-38} n={1,7} cosine={2:F6} maxDiff={3:F4}@{4} |d|>{5}={6} ({7:P2})' -f `
            $name, $n, $cos, $maxd, $maxi, $Thresh, $nd, ($nd / $n))
    $bad = ($cos -lt 0.999) -or ($nd -gt 0)
    if (-not $OnlyMismatched -or $bad) {
        Write-Output $line
        Write-Output ('      A top{0}: {1}' -f $Top, (Top-K $va $Top))
        Write-Output ('      B top{0}: {1}' -f $Top, (Top-K $vb $Top))
        $ia = 0; $ib = 0; $ba = -1e300; $bb = -1e300
        for ($i = 0; $i -lt $n; $i++) { if ($va[$i] -gt $ba) { $ba = $va[$i]; $ia = $i }; if ($vb[$i] -gt $bb) { $bb = $vb[$i]; $ib = $i } }
        $agree = if ($ia -eq $ib) { 'AGREE' } else { 'DIFFER' }
        Write-Output ('      top1 {0}: A=id{1}({2:F3}) B=id{3}({4:F3})  |  A-top1 in B={5:F3}  B-top1 in A={6:F3}' -f `
                $agree, $ia, $ba, $ib, $bb, $vb[$ia], $va[$ib])
    }
    $worst += [pscustomobject]@{ name = $name; cosine = $cos; maxDiff = $maxd }
}

if ($worst.Count) {
    Write-Output ''
    Write-Output '  lowest-cosine tensors:'
    $worst | Sort-Object cosine | Select-Object -First 5 | ForEach-Object {
        Write-Output ('    {0,-38} cosine={1:F6} maxDiff={2:F4}' -f $_.name, $_.cosine, $_.maxDiff)
    }
}
