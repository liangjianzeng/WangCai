# 汪柴生图服务一键起服（Windows 宿主，2026-11-10）。
#
# 幂等四步：建 .venv → 依赖闸（QwenImage21Pipeline 导得进来就跳过安装）→
# 模型没落盘就 modelscope 下载 → 注入 env 起 server.py（前台，Ctrl+C 停）。
#
# 用法（本目录）：
#   .\start.ps1                                    # 全默认：模型自动下到 ./models，8899 免鉴权
#   .\start.ps1 -ApiKey sk-wc-xxx                  # 局域网共享必开鉴权
#   .\start.ps1 -Repo D:\models\qit -Offload model # 模型已在别处 / 显存紧
#   .\start.ps1 -TorchIndex https://…/cu126         # 本机 CUDA 非 12.4 时换 torch 源
# 依赖前提：系统 python（3.10+）与 git 在 PATH（requirements 里有 git+ 行）。

param(
  [string]$Repo = "",          # 本地模型目录或 ModelScope repo id；空=自动下到 ./models/qit
  [string]$ApiKey = $env:QI_API_KEY,
  [int]$Port = 8899,
  [ValidateSet("none", "model", "sequential")] [string]$Offload = "none",
  [string]$Dtype = "bf16",
  [string]$TorchIndex = "https://download.pytorch.org/whl/cu124"
)
$ErrorActionPreference = "Stop"
Set-Location (Split-Path -Parent $MyInvocation.MyCommand.Path)

$py = Join-Path .venv "Scripts\python.exe"
if (-not (Test-Path $py)) {
  Write-Host "[start] 建 venv …"
  python -m venv .venv
}

# 依赖闸：以「pipeline 导得进来」为准（旧版 PyPI diffusers 没有该类，照样触发重装）。
& $py -c "from diffusers import QwenImage21Pipeline" 2>$null | Out-Null
if ($LASTEXITCODE -ne 0) {
  Write-Host "[start] 首次装依赖（torch 走 $TorchIndex，diffusers 走 git 主）…"
  & $py -m pip install -U pip
  & $py -c "import torch" 2>$null | Out-Null
  if ($LASTEXITCODE -ne 0) { & $py -m pip install torch torchvision --index-url $TorchIndex }
  & $py -m pip install -r requirements.txt
  if ($LASTEXITCODE -ne 0) { throw "依赖安装失败：确认 git 在 PATH、CUDA 版本与 -TorchIndex 匹配" }
}

if (-not $Repo) { $Repo = "./models/qit" }
if (-not (Test-Path $Repo)) {
  Write-Host "[start] 下载 Qwen/Qwen-Image-2.1-Turbo → $Repo（数十 GB，耐心）…"
  & $py -c "from modelscope import snapshot_download; snapshot_download('Qwen/Qwen-Image-2.1-Turbo', local_dir='$Repo')"
  if ($LASTEXITCODE -ne 0) { throw "模型下载失败：查网络/磁盘，或手动 modelscope download 后用 -Repo 指过去" }
}

$env:QI_REPO = $Repo
$env:QI_API_KEY = $ApiKey
$env:QI_PORT = "$Port"
$env:QI_OFFLOAD = $Offload
$env:QI_DTYPE = $Dtype
$authZh = if ($ApiKey) { '开' } else { '关' }
Write-Host "[start] 起服：repo=$Repo port=$Port offload=$Offload dtype=$Dtype 鉴权=$authZh"
Write-Host "[start] 汪柴设置页 → 服务地址 http://127.0.0.1:$Port · API key 同 -ApiKey"
& $py server.py
