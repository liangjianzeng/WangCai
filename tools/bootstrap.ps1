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
# PowerShell 7.3+ turns a non-zero native exit code into a terminating error under EAP=Stop, which
# would pre-empt every $LASTEXITCODE check below and hide git's own message. Keep git's output,
# decide on the exit code ourselves.
if (Test-Path 'Variable:PSNativeCommandUseErrorActionPreference') {
    $PSNativeCommandUseErrorActionPreference = $false
}

function Invoke-Git {
    param([Parameter(Mandatory = $true, ValueFromRemainingArguments = $true)][string[]]$GitArgs)
    Write-Output ("  $ git " + ($GitArgs -join ' '))
    $out = & git @GitArgs 2>&1
    $code = $LASTEXITCODE
    foreach ($line in $out) { Write-Output ("    | " + $line) }
    return $code
}

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
    if ((Invoke-Git clone --quiet $Url $llama) -ne 0) { throw 'git clone failed' }
}

Push-Location $llama
try {
    # The pinned revision is a specific upstream commit; make sure it is present locally before
    # checking it out, otherwise a shallow or aged clone fails with a message that looks like a typo.
    if ((Invoke-Git rev-parse --verify -q "$Commit^{commit}") -ne 0) {
        Invoke-Git fetch --all --tags --quiet | Out-Null
    }
    if ((Invoke-Git checkout --quiet --detach $Commit) -ne 0) {
        Write-Output "could not check out $Commit; tip of the default branch:"
        Invoke-Git log --oneline --decorate -3 | Out-Null
        throw "git checkout $Commit failed"
    }

    $ovdir = Join-Path (Join-Path (Join-Path $llama 'ggml') 'src') 'ggml-openvino'
    if (-not (Test-Path (Join-Path $ovdir 'ov_opencl_shim.hpp'))) {
        $check = Invoke-Git apply --check --verbose $patch
        if ($check -ne 0) {
            Write-Output ''
            Write-Output 'The patch does not apply cleanly (see the git apply output above).'
            Write-Output 'The OpenVINO backend moves between llama.cpp releases: this is a rebase of'
            Write-Output 'the hunks against your revision, not a broken tree. Try the pinned commit,'
            Write-Output 'or re-derive the hunks - see patches/README.md.'
            throw 'git apply --check failed'
        }
        if ((Invoke-Git apply $patch) -ne 0) { throw 'git apply failed' }
        Copy-Item $shim $ovdir
        Write-Output 'patched: ggml/src/ggml-openvino (+ ov_opencl_shim.hpp)'
    }
    else {
        Write-Output 'already patched (ov_opencl_shim.hpp present) - nothing to do'
    }

    Write-Output ("HEAD: " + (git rev-parse HEAD))
    Write-Output 'next: tools/configure.ps1 -OpenVinoDir <path-to-openvino/cmake>'
}
finally {
    Pop-Location
}
