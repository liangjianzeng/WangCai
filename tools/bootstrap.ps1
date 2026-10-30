<#
    bootstrap.ps1 - create the vendored llama.cpp checkout and install the WangCai backend sources.

    src/ggml-openvino/ in this repository is the authoritative copy of the engine's code. It is
    overlaid onto the pinned llama.cpp checkout, which makes the build reproducible and lets anyone
    read the engine without applying anything. patches/ remains as the readable history of the change
    (and the artifact for upstreaming); -UsePatch applies that patch instead of the overlay, which is
    the way to check that the two are still equivalent.

    ASCII only: Windows PowerShell parses .ps1 as ANSI, so non-ASCII literals break the parser.
#>
param(
    [string]$Commit = 'abb76ab380c7f3f731e365a859fb4cc64e939bb8',
    [string]$Url = 'https://github.com/ggml-org/llama.cpp',
    [switch]$Force,
    [switch]$UsePatch
)

$ErrorActionPreference = 'Stop'
# PowerShell 7.3+ turns a non-zero native exit code into a terminating error under EAP=Stop, which
# would pre-empt every exit-code check below and hide git's own message. Keep git's output, decide
# on the exit code ourselves.
if (Test-Path 'Variable:PSNativeCommandUseErrorActionPreference') {
    $PSNativeCommandUseErrorActionPreference = $false
}

# Log through Write-Host (information stream) and report the exit code through a variable, never
# through the pipeline: a function whose log lines enter the output stream returns an array, and
# `if ((Invoke-Git ...) -ne 0)` is then true for a *successful* git command - which is how CI failed
# in this step on both runners regardless of what git did.
$script:GIT_EXIT = 0
function Invoke-Git {
    param([Parameter(Mandatory = $true, ValueFromRemainingArguments = $true)][string[]]$GitArgs)
    Write-Host ('  $ git ' + ($GitArgs -join ' '))
    $out = & git @GitArgs 2>&1
    $script:GIT_EXIT = $LASTEXITCODE
    foreach ($line in $out) { Write-Host ('    | ' + $line) }
}

$repo  = Split-Path -Parent $PSScriptRoot
# Nested Join-Path everywhere (never 'src\llama') so the scripts also work on the Linux path that
# the upstream OpenVINO backend supports.
$src      = Join-Path $repo 'src'
$engine   = Join-Path $src 'ggml-openvino'      # WangCai's own source, tracked in this repo
$llama    = Join-Path $src 'llama'              # vendored clone, git-ignored
$pdir     = Join-Path $repo 'patches'
$patch    = Join-Path $pdir '0001-ggml-openvino-npu-adaptation.patch'
$shim     = Join-Path $pdir 'ov_opencl_shim.hpp'
$ovtarget = Join-Path (Join-Path (Join-Path $llama 'ggml') 'src') 'ggml-openvino'

if ($UsePatch) {
    foreach ($f in @($patch, $shim)) { if (-not (Test-Path $f)) { throw "missing patch artifact: $f" } }
}
elseif (-not (Test-Path (Join-Path $engine 'utils.cpp'))) {
    throw "missing engine sources in $engine - was the repository checked out completely?"
}

if ((Test-Path $llama) -and $Force) { Remove-Item $llama -Recurse -Force }
if (-not (Test-Path (Join-Path $llama '.git'))) {
    New-Item -ItemType Directory -Force -Path $src | Out-Null
    Write-Host "cloning $Url -> $llama"
    # core.autocrlf=false at clone time, not afterwards: Windows runners default to autocrlf=true,
    # which materializes the worktree with CRLF and then every LF-context hunk in the patch fails to
    # match, for a reason that has nothing to do with the patch.
    Invoke-Git clone --quiet --config core.autocrlf=false $Url $llama
    if ($script:GIT_EXIT -ne 0) { throw 'git clone failed' }
}

Push-Location $llama
try {
    # The patch context is LF; keep the worktree byte-exact even for a tree cloned earlier by hand on
    # a machine whose default is autocrlf=true.
    Invoke-Git config core.autocrlf false

    # The pinned revision is a specific upstream commit; make sure it is present locally before
    # checking it out, otherwise a shallow or aged clone fails with a message that looks like a typo.
    Invoke-Git rev-parse --verify -q "$Commit^{commit}"
    if ($script:GIT_EXIT -ne 0) {
        Invoke-Git fetch --all --tags --quiet
    }
    Invoke-Git checkout --quiet --detach $Commit
    if ($script:GIT_EXIT -ne 0) {
        Write-Host "could not check out $Commit; tip of the checked-out branch:"
        Invoke-Git log --oneline --decorate -3
        throw "git checkout $Commit failed"
    }

    if ($UsePatch) {
        Invoke-Git apply --check --verbose $patch
        if ($script:GIT_EXIT -ne 0) {
            Write-Host ''
            Write-Host 'The patch does not apply cleanly (see the git apply output above).'
            Write-Host 'The OpenVINO backend moves between llama.cpp releases: this is a rebase of'
            Write-Host 'the hunks against your revision, not a broken tree. Try the pinned commit,'
            Write-Host 'or re-derive the hunks - see patches/README.md.'
            Write-Host ('  core.autocrlf = ' + ((& git config --get core.autocrlf) | Select-Object -First 1))
            throw 'git apply --check failed'
        }
        Invoke-Git apply $patch
        if ($script:GIT_EXIT -ne 0) { throw 'git apply failed' }
        Copy-Item $shim $ovtarget
        Write-Host 'installed via patches/'
    }
    else {
        if (-not (Test-Path $ovtarget)) { throw "no ggml/src/ggml-openvino in the checkout - wrong revision?" }
        # Overlay file by file, preserving the upstream layout (openvino/op/... etc).
        Get-ChildItem $engine -Recurse -File | ForEach-Object {
            $rel = $_.FullName.Substring($engine.Length).TrimStart('\', '/')
            $dest = Join-Path $ovtarget $rel
            $dd = Split-Path $dest -Parent
            if (-not (Test-Path $dd)) { New-Item -ItemType Directory -Force -Path $dd | Out-Null }
            Copy-Item $_.FullName $dest -Force
        }
        $count = (Get-ChildItem $engine -Recurse -File).Count
        Write-Host "overlaid $count files from src/ggml-openvino onto ggml/src/ggml-openvino"
    }

    # Prove the engine code actually landed, instead of trusting the copy.
    Invoke-Git diff --stat -- ggml/src/ggml-openvino
    Invoke-Git status --porcelain -- ggml/src/ggml-openvino | ForEach-Object { Write-Host ("    | " + $_) }
    Write-Host ('HEAD: ' + ((& git rev-parse HEAD) | Select-Object -First 1))
    Write-Host 'next: tools/configure.ps1 -OpenVinoDir <path-to-openvino/cmake>'
}
finally {
    Pop-Location
}
