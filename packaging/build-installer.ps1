# 汪柴 v0.0.4 打包脚本（M4）。
#   产出 1（无需 Inno）：dist/WangCai-0.0.4-win-x64-portable.zip —— 解压即用
#   产出 2（装了 Inno Setup 6 时）：dist/WangCai-0.0.4-win-x64-Setup.exe
# 用法：powershell -ExecutionPolicy Bypass -File packaging/build-installer.ps1
$ErrorActionPreference = "Stop"
$root = Split-Path -Parent $PSScriptRoot
$ver = "0.0.4"

Write-Host "== 1/4 flutter build windows --release =="
if (-not (Get-Command flutter -ErrorAction SilentlyContinue)) {
    $env:PATH = "C:\src\flutter\bin;$env:PATH"
}
Push-Location "$root\app"
flutter build windows --release
if ($LASTEXITCODE -ne 0) { Pop-Location; throw "flutter build failed" }
Pop-Location

$release = "$root\app\build\windows\x64\runner\Release"
$stage = "$root\packaging\stage"

Write-Host "== 2/4 staging =="
if (Test-Path $stage) { Remove-Item $stage -Recurse -Force }
New-Item -ItemType Directory -Path $stage | Out-Null
# 壳：Release 全量 → stage\App
Copy-Item $release "$stage\App" -Recurse
# 引擎包：llama-server 全家（exe + impl.dll + manifest）+ ggml/llama DLL
# + OV 运行时 → stage\Engines\wangcai\（缺 llama-server-impl.dll 会
# error while loading shared libraries —— 2026-11-03 便携包自测实案）
New-Item -ItemType Directory -Path "$stage\Engines\wangcai\ovlibs" -Force | Out-Null
# 全部运行期 dll/manifest（ggml*/llama/mtmd/llama-server-impl——漏 mtmd.dll
# 同样 0xC0000135）+ 仅 llama-server 可执行（其他工具 exe 不打包）
Get-ChildItem "$root\src\llama\build\bin" | Where-Object {
    $_.Name -match '\.(dll|manifest)$'
} | ForEach-Object { Copy-Item $_.FullName "$stage\Engines\wangcai\" }
Get-ChildItem "$root\src\llama\build\bin" -Filter "llama-server*.exe" |
    ForEach-Object { Copy-Item $_.FullName "$stage\Engines\wangcai\" }
# OV 运行时源解析（v0.0.3 修正）：仓库 vendored 副本优先，回落本机
# E:\dev-tools 解压布局（注意双层 openvino 目录）。缺 openvino.dll 直接报错
# —— 只打 ggml-openvino.dll 壳会导致 llama-server 起不来（缺 openvino.dll）。
$ovSrc = @("$root\ov\openvino\libs", "E:\dev-tools\ov\openvino\openvino\libs") |
    Where-Object { Test-Path "$_\openvino.dll" } | Select-Object -First 1
if (-not $ovSrc) {
    throw "OpenVINO 运行时未找到（找过 $root\ov\openvino\libs 与 E:\dev-tools\ov\openvino\openvino\libs）"
}
Copy-Item "$ovSrc\*" "$stage\Engines\wangcai\ovlibs\" -Recurse -Force
# 便携包说明
@'
汪柴 v0.0.4 便携包：解压到任意目录后运行 App\WangCai.exe。
引擎位于 Engines\wangcai\（llama-server.exe + OpenVINO 运行时），
首启自动被识别（安装器形态同布局）。模型库：%APPDATA%\WangCai\models
（可用 WANGCAI_MODEL_DIR 指到别处）。
'@ | Out-File "$stage\README-便携包.txt" -Encoding utf8

Write-Host "== 3/4 portable zip =="
$dist = "$root\packaging\dist"
New-Item -ItemType Directory -Path $dist -Force | Out-Null
$zip = "$dist\WangCai-$ver-win-x64-portable.zip"
if (Test-Path $zip) { Remove-Item $zip -Force }
Compress-Archive -Path "$stage\*" -DestinationPath $zip
Write-Host "PORTABLE: $zip ($([math]::Round((Get-Item $zip).Length/1MB,1)) MB)"

Write-Host "== 4/4 Inno Setup（可选） =="
$iscc = @("${env:ProgramFiles(x86)}\Inno Setup 6\ISCC.exe", "${env:ProgramFiles}\Inno Setup 6\ISCC.exe") |
    Where-Object { Test-Path $_ } | Select-Object -First 1
if ($iscc) {
    & $iscc "$root\packaging\wangcai-setup.iss"
    Write-Host "SETUP: $dist\WangCai-$ver-win-x64-Setup.exe"
} else {
    Write-Host "SKIPPED: 未装 Inno Setup 6（装后重跑本脚本即产出 Setup.exe；.iss 已就绪）"
}

Remove-Item $stage -Recurse -Force -ErrorAction SilentlyContinue
Write-Host "DONE"
