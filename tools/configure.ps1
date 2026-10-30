<#
    configure.ps1 - CMake-configure the vendored llama.cpp with the OpenVINO backend only.

    Runs inside a Visual Studio developer environment. The commands are written into a .bat file
    and executed by cmd.exe: calling vcvars64.bat inline from PowerShell
    (cmd /c "call vcvars64.bat && cmake ...") loses the && chain through quoting and produces a
    misleading "No CMAKE_C_COMPILER could be found".
#>
param(
    [Parameter(Mandatory = $true)][string]$OpenVinoDir,
    [string]$LlamaDir = '',
    [string]$BuildType = 'Release',
    [string]$Ninja = 'ninja',
    [switch]$RelWithDebInfo
)

$ErrorActionPreference = 'Stop'
# Keep cmake's own diagnostics: under EAP=Stop, PowerShell 7.3+ turns a non-zero native exit into a
# terminating error before the $LASTEXITCODE check below can report it.
if (Test-Path 'Variable:PSNativeCommandUseErrorActionPreference') {
    $PSNativeCommandUseErrorActionPreference = $false
}
$repo = Split-Path -Parent $PSScriptRoot
if (-not $LlamaDir) { $LlamaDir = Join-Path (Join-Path $repo 'src') 'llama' }
if ($RelWithDebInfo) { $BuildType = 'RelWithDebInfo' }
$build = Join-Path $LlamaDir 'build'
$OpenVinoDir = (Resolve-Path $OpenVinoDir).Path
$isWindows = ($env:OS -eq 'Windows_NT')

if (-not (Test-Path (Join-Path $OpenVinoDir 'OpenVINOConfig.cmake'))) {
    throw "no OpenVINOConfig.cmake in $OpenVinoDir - point -OpenVinoDir at the cmake/ dir of an OpenVINO package or unpacked wheel"
}

# Windows needs a Visual Studio developer environment; locate vcvars64.bat through vswhere so a
# non-default VS install/layout still works. Linux/macOS use the native toolchain directly.
$prologue = ''
if ($isWindows) {
    $vswhere = Join-Path ${env:ProgramFiles(x86)} 'Microsoft Visual Studio\Installer\vswhere.exe'
    if (-not (Test-Path $vswhere)) { throw "vswhere.exe not found - install VS 2022 Build Tools with the C++ workload" }
    $vsPath = (& $vswhere -latest -products * -requires Microsoft.VisualStudio.Component.VC.Tools.x86.x64 `
            -property installationPath | Select-Object -First 1)
    if (-not $vsPath) { throw "no Visual Studio installation with the C++ toolset was found" }
    $vcvars = Join-Path (Join-Path (Join-Path $vsPath 'VC') 'Auxiliary') 'Build\vcvars64.bat'
    if (-not (Test-Path $vcvars)) { throw "vcvars64.bat missing from $vsPath" }
    $prologue = "call `"$vcvars`" >nul || exit /b 1"
}

$tmp = Join-Path $repo 'tmp'
New-Item -ItemType Directory -Force -Path $tmp | Out-Null

# Allow pointing at a ninja that is not on PATH (e.g. the one bundled with the Android SDK).
$ninjaDir = ''
$ninjaFull = Get-Command $Ninja -ErrorAction SilentlyContinue
if ($ninjaFull) { $ninjaDir = Split-Path $ninjaFull.Source -Parent }
if (-not $ninjaDir -and (Test-Path $Ninja)) { $ninjaDir = Split-Path $Ninja -Parent }

$cmakeArgs = @(
    '-DCMAKE_BUILD_TYPE=' + $BuildType,
    '-DGGML_OPENVINO=ON',
    '-DGGML_CUDA=OFF', '-DGGML_VULKAN=OFF', '-DGGML_SYCL=OFF', '-DGGML_OPENCL=OFF', '-DGGML_RPC=OFF',
    '-DGGML_CCACHE=OFF', '-DLLAMA_CURL=OFF',
    '-DOpenVINO_DIR="' + $OpenVinoDir + '"'
) -join ' '

Write-Output "configuring $LlamaDir (OpenVINO=$OpenVinoDir, build=$BuildType)"
if ($isWindows) {
    $pathPre = if ($ninjaDir) { "set `"PATH=$ninjaDir;%PATH%`"" } else { '' }
    $bat = Join-Path $tmp 'configure.bat'
    @(
        '@echo off'
        $prologue
        $pathPre
        "cmake -S `"$LlamaDir`" -B `"$build`" -G Ninja $cmakeArgs || exit /b 1"
        'echo EXITCODE=0'
    ) | Where-Object { $_ -ne '' } | Set-Content -Path $bat -Encoding ASCII
    cmd.exe /c "`"$bat`""
}
else {
    $sh = Join-Path $tmp 'configure.sh'
    $exports = if ($ninjaDir) { "export PATH=`"$ninjaDir`:$PATH`"" } else { '' }
    @(
        '#!/usr/bin/env bash'
        'set -e'
        $exports
        "cmake -S `"$LlamaDir`" -B `"$build`" -G Ninja $cmakeArgs"
        'echo EXITCODE=0'
    ) | Where-Object { $_ -ne '' } | Set-Content -Path $sh
    bash $sh
}
if ($LASTEXITCODE -ne 0) { throw "cmake configure failed (exit $LASTEXITCODE)" }
Write-Output 'next: tools/build.ps1'
