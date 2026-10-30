<#
    top-token.ps1 - align passes between two device captures.

    Two runs of the same prompt do not produce the same number of graph calls, and comparing pass N
    of one run against pass N of another is how confident, wrong conclusions get drawn. This prints
    the top-1 token id, its value and the L2 norm per dumped output, so passes can be matched by
    token id instead of by call order.
#>
param(
    [Parameter(Mandatory = $true)][string]$Dir,
    [string]$Filter = '*result_output*.bin',
    [switch]$All
)

Get-ChildItem $Dir -Filter $Filter | Sort-Object Name | ForEach-Object {
    $bytes = [System.IO.File]::ReadAllBytes($_.FullName)
    $type = 'f32'
    $side = "$($_.FullName).txt"
    if (Test-Path $side) {
        $txt = (Get-Content $side -Raw)
        if ($txt -match '\b(f32|f16|bf16|i64|i32)\b') { $type = $Matches[1] }
    }
    if ($type -ne 'f32') { Write-Output ('  {0,-38} skipped ({1})' -f $_.Name, $type); return }

    $n = [int]($bytes.Length / 4)
    if ($n -lt 2 -and -not $All) { Write-Output ('  {0,-38} (%{1} elements)' -f $_.Name, $n); return }

    $v = New-Object 'double[]' $n
    for ($i = 0; $i -lt $n; $i++) { $v[$i] = [BitConverter]::ToSingle($bytes, $i * 4) }
    $bi = 0; $bv = $v[0]; $sum = 0.0; $mn = $v[0]; $mx = $v[0]
    for ($i = 0; $i -lt $n; $i++) {
        $x = $v[$i]
        if ($x -gt $bv) { $bv = $x; $bi = $i }
        if ($x -lt $mn) { $mn = $x }
        if ($x -gt $mx) { $mx = $x }
        $sum += $x * $x
    }
    $shape = ''
    if (Test-Path $side) { $shape = (Get-Content $side -First 1) }
    Write-Output ('  {0,-38} top1=id{1,7} val={2,9:F3} norm={3,10:F1} min={4,9:F3} max={5,9:F3}  {6}' -f `
            $_.Name, $bi, $bv, [Math]::Sqrt($sum), $mn, $mx, $shape)
}
