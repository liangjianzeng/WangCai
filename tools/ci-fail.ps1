<#
    ci-fail.ps1 - turn a captured build log into a GitHub annotation.

    Runner logs need authentication to download (`/actions/jobs/<id>/logs` answers 403 anonymously),
    but check-run annotations on a public repository are readable through the API by anyone. A step
    that merely exits 1 therefore tells a maintainer nothing they can act on. This prints the lines
    that explain the failure - plus enough context after each to contain the actual message - as one
    ::error:: annotation.

      pwsh -File tools/ci-fail.ps1 -Log $env:RUNNER_TEMP\configure.log -Exit $code -Label configure
      pwsh -File tools/ci-fail.ps1 -Log build.log -Exit $code -Label build -Pattern 'error C\d{4}|FAILED:'

    ASCII only: Windows PowerShell parses .ps1 files as ANSI.
#>
param(
    [Parameter(Mandatory = $true)][string]$Log,
    [int]$Exit = 1,
    [string]$Label = 'step failed',
    [string]$Pattern = 'CMake Error|Could NOT find|error C\d{4}|error LNK\d{4}|undefined reference|FAILED:|fatal error|check\.cpp:\d+',
    [int]$Context = 5,
    [int]$MaxLines = 30,
    [int]$MaxChars = 1800
)

$lines = @()
if (Test-Path $Log) {
    $lines = @(Get-Content $Log -ErrorAction SilentlyContinue)
}
else {
    Write-Output ("::warning::{0} :: no log captured at {1}" -f $Label, $Log)
}

$pick = @()
for ($i = 0; $i -lt $lines.Count; $i++) {
    if ($lines[$i] -match $Pattern) {
        $hi = [Math]::Min($i + $Context, $lines.Count - 1)
        $pick += $lines[$i..$hi]
        $i = $hi          # do not re-match inside the context we just took
    }
}
if (-not $pick) { $pick = @($lines | Select-Object -Last 15) }

$text = (($pick | Where-Object { "$_".Trim() -ne '' } | Select-Object -Unique | Select-Object -First $MaxLines) -join ' || ')
$text = $text -replace '[\r\n\t]', ' '
if ($text.Length -gt $MaxChars) { $text = $text.Substring(0, $MaxChars) }

Write-Output ("::error::{0} (exit {1}) :: {2}" -f $Label, $Exit, $text)
exit $Exit
