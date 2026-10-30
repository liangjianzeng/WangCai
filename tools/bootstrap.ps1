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
    Write-Host "cloning $Url -> $llama"
    # core.autocrlf=false at clone time, not afterwards: Windows runners default to autocrlf=true,
    # which materializes the worktree with CRLF and then every LF-context hunk in our patch fails to
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

    $ovdir = Join-Path (Join-Path (Join-Path $llama 'ggml') 'src') 'ggml-openvino'
    if (-not (Test-Path (Join-Path $ovdir 'ov_opencl_shim.hpp'))) {
        Invoke-Git apply --check --verbose $patch
        if ($script:GIT_EXIT -ne 0) {
            Write-Host ''
            Write-Host 'The patch does not apply cleanly (see the git apply output above).'
            Write-Host 'The OpenVINO backend moves between llama.cpp releases: this is a rebase of'
            Write-Host 'the hunks against your revision, not a broken tree. Try the pinned commit,'
            Write-Host 'or re-derive the hunks - see patches/README.md.'
            # Line endings are the other common cause: LF-context hunks cannot match a CRLF worktree.
            Write-Host ('  core.autocrlf = ' + ((& git config --get core.autocrlf) | Select-Object -First 1))
            Write-Host '  (if that prints true, delete src/llama and re-run: the clone must be made with core.autocrlf=false)'
            throw 'git apply --check failed'
        }
        Invoke-Git apply $patch
        if ($script:GIT_EXIT -ne 0) { throw 'git apply failed' }
        Copy-Item $shim $ovdir
        Write-Host 'patched: ggml/src/ggml-openvino (+ ov_opencl_shim.hpp)'
    }
    else {
        Write-Host 'already patched (ov_opencl_shim.hpp present) - nothing to do'
    }

    Write-Host ('HEAD: ' + ((& git rev-parse HEAD) | Select-Object -First 1))
    Write-Host 'next: tools/configure.ps1 -OpenVinoDir <path-to-openvino/cmake>'
}
finally {
    Pop-Location
}
