<#
    build.ps1 - incremental build of the targets WangCai cares about.
    Same vcvars-through-a-batch trick as configure.ps1.
#>
param(
    [string[]]$Target = @('llama-cli', 'llama-completion', 'llama-bench', 'llama-server'),
    [string]$LlamaDir = '',
    [int]$Parallel = 0,
    [switch]$Clean
)

$ErrorActionPreference = 'Stop'
# Under EAP=Stop, PowerShell 7.3+ raises a terminating error on a non-zero native exit before the
# EXITCODE=0 scan below can report which compile line failed.
if (Test-Path 'Variable:PSNativeCommandUseErrorActionPreference') {
    $PSNativeCommandUseErrorActionPreference = $false
}
$repo = Split-Path -Parent $PSScriptRoot
if (-not $LlamaDir) { $LlamaDir = Join-Path (Join-Path $repo 'src') 'llama' }
$build = Join-Path $LlamaDir 'build'
$onWindows = ($env:OS -eq 'Windows_NT')
if (-not (Test-Path (Join-Path $build 'build.ninja'))) {
    throw "not configured yet - run tools\configure.ps1 -OpenVinoDir <path> first"
}

$targets = ($Target -join ' ')
# Not $parallel / $clean: PowerShell variable names are case-insensitive, so those collide with the
# [int]$Parallel and [switch]$Clean parameters and assigning a string to them fails with
# "Cannot convert value '--parallel' to type System.Int32" before a single compile line runs.
$parallelArg = if ($Parallel -gt 0) { "--parallel $Parallel" } else { '--parallel' }
$cleanArg = if ($Clean) { '--clean-first' } else { '' }

$tmp = Join-Path $repo 'tmp'
New-Item -ItemType Directory -Force -Path $tmp | Out-Null
$log = Join-Path $tmp 'build.log'

Write-Output "building: $targets"
if ($onWindows) {
    $vswhere = Join-Path ${env:ProgramFiles(x86)} 'Microsoft Visual Studio\Installer\vswhere.exe'
    $vsPath = (& $vswhere -latest -products * -requires Microsoft.VisualStudio.Component.VC.Tools.x86.x64 `
            -property installationPath | Select-Object -First 1)
    $vcvars = Join-Path (Join-Path (Join-Path $vsPath 'VC') 'Auxiliary') 'Build\vcvars64.bat'
    $bat = Join-Path $tmp 'build.bat'
    @"
@echo off
call "$vcvars" >nul || exit /b 1
cmake --build "$build" --target $targets $parallelArg $cleanArg || exit /b 1
echo EXITCODE=0
"@ | Set-Content -Path $bat -Encoding ASCII
    # Redirect inside cmd rather than piping in PowerShell: PowerShell stream redirection truncates
    # OpenVINO exception text, and MSVC diagnostics get mangled the same way.
    cmd.exe /c "`"$bat`" > `"$log`" 2>&1"
}
else {
    $sh = Join-Path $tmp 'build.sh'
    @(
        '#!/usr/bin/env bash'
        'set -e'
        "cmake --build `"$build`" --target $targets $parallelArg $cleanArg"
        'echo EXITCODE=0'
    ) | Set-Content -Path $sh
    bash $sh *> $log
}
$out = Get-Content $log -ErrorAction SilentlyContinue
$out | Select-String -Pattern 'error C|error LNK|fatal error|FAILED' | Select-Object -First 20
if (($out | Select-String -Pattern 'EXITCODE=0').Count -eq 0) {
    Write-Output "--- tail of $log ---"
    $out | Select-Object -Last 25
    throw 'build failed - see the output above'
}
# The embedded-UI download warnings are noise (llama-server assets from Hugging Face).
$out | Select-String -Pattern 'UI: download|HF download|without an embedded UI' |
    Select-Object -First 3 | ForEach-Object { '  (benign) ' + $_.ToString().Trim() }
Write-Output ("binaries: " + (Join-Path $build 'bin'))
Get-ChildItem (Join-Path $build 'bin') -Filter 'llama-*.exe' | ForEach-Object { '  ' + $_.Name }
