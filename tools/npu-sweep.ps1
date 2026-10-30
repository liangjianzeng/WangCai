<#
    npu-sweep.ps1 - run a matrix of NPU configurations and print one line per cell.

    Each cell gets a fresh compiled-graph cache directory and a clean environment, so a cell can
    never silently reuse a graph compiled under another cell's flags. Cold compilation is ~36 s per
    graph for LFM3-1.7B, and a cell with a bad override may fail to compile at all - both are
    reported, not fatal.
#>
param(
    [Parameter(Mandatory = $true)][string]$Model,
    [object]$Cases = $null,          # array of hashtables: @{ Label=; Overrides=; Extra=@{} }
    [string]$PromptFile = '',
    [string]$Prompt = 'hi',
    [int]$N = 24,
    [int]$Ctx = 1024
)

$ErrorActionPreference = 'Continue'
$here = $PSScriptRoot

if (-not $Cases) {
    # A starting point: the documented NPUW / dynamic-quantization levers.
    $Cases = @(
        @{ Label = 'default';        Overrides = '' },
        @{ Label = 'chunk64';        Extra = @{ GGML_OPENVINO_PREFILL_CHUNK_SIZE = '64' } },
        @{ Label = 'nofold';         Overrides = 'NPUW_FOLD=NO' },
        @{ Label = 'dqfull';         Overrides = 'NPUW_DQ_FULL=YES' },
        @{ Label = 'bank_off';       Overrides = 'NPUW_WEIGHTS_BANK=none' },
        @{ Label = 'nodynquant';     Overrides = 'NPU_COMPILER_DYNAMIC_QUANTIZATION=NO' }
    )
}

foreach ($c in $Cases) {
    $p = @{
        Model      = $Model
        N          = $N
        Ctx        = $Ctx
        Backend    = 'npu'
        Label      = [string]$c.Label
        CacheTag   = [string]$c.Label
    }
    if ($PromptFile) { $p.PromptFile = $PromptFile } else { $p.Prompt = $Prompt }
    if ($c.ContainsKey('Overrides')) { $p.Overrides = [string]$c.Overrides }
    if ($c.ContainsKey('Extra'))     { $p.Extra = $c.Extra }
    if ($c.ContainsKey('Backend'))   { $p.Backend = $c.Backend }
    try {
        & (Join-Path $here 'run-npu.ps1') @p
    }
    catch {
        Write-Output ("### [{0}] FAILED: {1}" -f $c.Label, $_.Exception.Message)
    }
}
