<#
    bootstrap.ps1 - create the vendored llama.cpp checkout and apply the WangCai patch set.
    Idempotent: re-running only re-applies the patches if they are missing.
    ASCII only: Windows PowerShell parses .ps1 as ANSI, so non-ASCII literals break the parser.
#>
param(
    [string]$Commit = 'abb76ab380c7f3f731e365a859fb4cc64e939bb8',
    [string]$Url = 'https://github.com/ggml-org/llama.cpp',
    [switch]$Force
)

$ErrorActionPreference = 'Stop'
$repo  = Split-Path -Parent $PSScriptRoot
# Nested Join-Path everywhere (never 'src\llama') so the scripts also work on the Linux path that
# the upstream OpenVINO backend supports.
$src   = Join-Path $repo 'src'
$llama = Join-Path $src 'llama'
$pdir  = Join-Path $repo 'patches'
$patch = Join-Path $pdir '0001-ggml-openvino-npu-adaptation.patch'
$shim  = Join-Path $pdir 'ov_opencl_shim.hpp'

foreach ($f in @($patch, $shim)) {
    if (-not (Test-Path $f)) { throw "missing patch artifact: $f" }
}

if ((Test-Path $llama) -and $Force) { Remove-Item $llama -Recurse -Force }
if (-not (Test-Path (Join-Path $llama '.git'))) {
    New-Item -ItemType Directory -Force -Path $src | Out-Null
    Write-Output "cloning $Url -> $llama"
    git clone $Url $llama
    if ($LASTEXITCODE -ne 0) { throw "git clone failed" }
}

Push-Location $llama
try {
    git checkout $Commit
    if ($LASTEXITCODE -ne 0) { throw "git checkout $Commit failed (git fetch --all first?)" }

    $ovdir = Join-Path (Join-Path (Join-Path $llama 'ggml') 'src') 'ggml-openvino'
    if (-not (Test-Path (Join-Path $ovdir 'ov_opencl_shim.hpp'))) {
        git apply --check $patch
        if ($LASTEXITCODE -ne 0) {
            Write-Output ''
            Write-Output 'The patch does not apply cleanly. The OpenVINO backend moves between'
            Write-Output 'llama.cpp releases: this is a rebase of the hunks, not a broken tree.'
            Write-Output 'Try the pinned commit, or re-derive the hunks against your revision.'
            throw 'git apply --check failed'
        }
        git apply $patch
        if ($LASTEXITCODE -ne 0) { throw 'git apply failed' }
        Copy-Item $shim $ovdir
        Write-Output 'patched: ggml/src/ggml-openvino (+ ov_opencl_shim.hpp)'
    }
    else {
        Write-Output 'already patched (ov_opencl_shim.hpp present) - nothing to do'
    }

    git rev-parse HEAD | ForEach-Object { Write-Output "HEAD: $_" }
    Write-Output 'next: tools\configure.ps1 -OpenVinoDir <path-to-openvino\cmake>'
}
finally {
    Pop-Location
}
