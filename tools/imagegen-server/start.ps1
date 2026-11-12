# 汪柴生图服务一键起服（Windows 宿主，2026-11-10；2026-11-12 一实例三角色升级）。
#
# 幂等五步：找 python → 建 .venv → 依赖闸（QwenImage21Pipeline 导得进来就跳过
# 安装）→ 模型没落盘就 modelscope 下载（-DitGguf 时跳过 transformer 大权重）→
# 注入 env 起 server.py（前台，Ctrl+C 停）。
#
# 用法（本目录）：
#   .\start.ps1                                    # 全默认：整仓下到 ./models/qit，8899 免鉴权
#   .\start.ps1 -DitGguf E:\Unsloth\models\qwen-image-2.1-turbo-Q5_K_M.gguf
#                                                  # 16GB 单卡主链路：DiT 用本地 GGUF，
#                                                  #  只下载 TE/VAE/processor（省 ~20GB）
#   .\start.ps1 -ApiKey sk-wc-xxx                  # 局域网共享必开鉴权
#   .\start.ps1 -Repo D:\models\qit -Offload model # 模型已在别处 / 显存紧
#   .\start.ps1 -TeDevice cuda                     # 大显存宿主：TE 常驻不搬
#   .\start.ps1 -TorchIndex https://…/cu128        # torch 轮子源（Blackwell 50 系必须 cu128+）
# 依赖前提：python 3.11~3.13（diffusers git 主干 ≥3.11；3.14 轮子未跟上）——PATH 里
# 没有就用 $env:QI_PYTHON 指到便携版 python.exe；git 在 PATH（requirements 有 git+ 行）。

param(
  [string]$Repo = "",          # 本地模型目录或 ModelScope repo id；空=自动下到 ./models/qit
  [string]$DitGguf = $env:QI_DIT_GGUF,  # 本地 DiT GGUF（16GB 卡推荐，配 TE cpu 驻留）
  [string]$ApiKey = $env:QI_API_KEY,
  [int]$Port = 8899,
  [ValidateSet("none", "model", "sequential")] [string]$Offload = "none",
  [ValidateSet("cpu", "cuda")] [string]$TeDevice = "cpu",
  [int]$TeKeepSec = 120,
  [string]$Dtype = "bf16",
  [string]$TorchIndex = "https://download.pytorch.org/whl/cu128"
)
$ErrorActionPreference = "Stop"
Set-Location (Split-Path -Parent $MyInvocation.MyCommand.Path)

# python 探测：QI_PYTHON 显式指定 → 系统 python → py 启动器 → 常见安装路径
# （2026-11-12 实案：本机三版 python 全不在 PATH；且 diffusers git 主干要求
# ≥3.11——3.10 装依赖时才报错太晚，探测闸直接收紧到 3.11~3.13）。
$sysPy = $null
foreach ($cand in @($env:QI_PYTHON,
                    (Get-Command python -ErrorAction SilentlyContinue).Source,
                    (Get-Command py -ErrorAction SilentlyContinue).Source)) {
  if ($cand -and (Test-Path $cand)) {
    $ver = & $cand -c "import sys;print('%d.%d' % sys.version_info[:2])" 2>$null
    if ($ver -match '^3\.1[1-3]$') { $sysPy = $cand; break }
    Write-Host "[start] 候选 $cand 版本 $ver 不合（需 3.11~3.13），跳过"
  }
}
if (-not $sysPy) {
  $guess = Get-ChildItem "$env:LOCALAPPDATA\Programs\Python\Python3*" -Directory -ErrorAction SilentlyContinue |
    Where-Object { $_.Name -match '^Python31[1-3]$' -and (Test-Path "$($_.FullName)\python.exe") } |
    Sort-Object { [int]($_.Name -replace 'Python', '') } -Descending |
    Select-Object -First 1
  if ($guess) { $sysPy = "$($guess.FullName)\python.exe" }
}
if (-not $sysPy) { throw "找不到 python 3.11~3.13（diffusers git 主干需 ≥3.11，3.14 轮子未跟上）：装一个，或用 QI_PYTHON 指到便携版 python.exe" }
Write-Host "[start] 宿主 python：$sysPy"
# 原生命令的 stderr 是信息不是异常（依赖闸靠 $LASTEXITCODE 判定）；Stop 偏好
# 会把闸的探测输出炸成 NativeCommandError（2026-11-12 实案）。
$ErrorActionPreference = "Continue"

$py = Join-Path .venv "Scripts\python.exe"
if (Test-Path $py) {
  # venv 是坏版本 python 建的（3.10 装不上 diffusers 主干 / 3.14 轮子缺）→
  # 推倒重建，别往死路上装依赖。
  $v = & $py -c "import sys;print('%d.%d' % sys.version_info[:2])" 2>$null
  if (-not ($v -match '^3\.1[1-3]$')) {
    Write-Host "[start] 既有 .venv 版本不合（$v），重建 …"
    Remove-Item -Recurse -Force .venv
  }
}
if (-not (Test-Path $py)) {
  Write-Host "[start] 建 venv …"
  & $sysPy -m venv .venv
}

# 依赖闸：以「pipeline + Qwen3VL 导得进来」为准（旧版 PyPI diffusers 没有该类、
# transformers<4.57 没有 qwen3_vl，照样触发重装）。
& $py -c "from diffusers import QwenImage21Pipeline; from transformers import Qwen3VLForConditionalGeneration; import gguf" 2>$null | Out-Null
if ($LASTEXITCODE -ne 0) {
  Write-Host "[start] 首次装依赖（torch 走 $TorchIndex，diffusers 走 git 主）…"
  & $py -m pip install -U pip
  & $py -c "import torch" 2>$null | Out-Null
  if ($LASTEXITCODE -ne 0) { & $py -m pip install torch torchvision --index-url $TorchIndex }
  & $py -m pip install -r requirements.txt
  if ($LASTEXITCODE -ne 0) { throw "依赖安装失败：确认 git 在 PATH、CUDA 版本与 -TorchIndex 匹配（50 系 Blackwell 需 cu128+）" }
}

if (-not $Repo) { $Repo = "./models/qit" }
if (-not (Test-Path $Repo)) {
  if ($DitGguf) {
    Write-Host "[start] 下载 turbo 仓（跳 transformer 大权重，DiT 走本地 GGUF）→ $Repo …"
    & $py -c "from modelscope import snapshot_download; snapshot_download('Qwen/Qwen-Image-2.1-Turbo', local_dir='$Repo', ignore_patterns=['transformer/*.safetensors','transformer/*.bin','transformer/*index*.json'])"
  } else {
    Write-Host "[start] 下载 Qwen/Qwen-Image-2.1-Turbo → $Repo（数十 GB，耐心）…"
    & $py -c "from modelscope import snapshot_download; snapshot_download('Qwen/Qwen-Image-2.1-Turbo', local_dir='$Repo')"
  }
  if ($LASTEXITCODE -ne 0) { throw "模型下载失败：查网络/磁盘，或手动 modelscope download 后用 -Repo 指过去" }
}

$env:QI_REPO = $Repo
$env:QI_DIT_GGUF = $DitGguf
$env:QI_API_KEY = $ApiKey
$env:QI_PORT = "$Port"
$env:QI_OFFLOAD = $Offload
$env:QI_TE_DEVICE = $TeDevice
$env:QI_TE_KEEP_SEC = "$TeKeepSec"
$env:QI_DTYPE = $Dtype
$authZh = if ($ApiKey) { '开' } else { '关' }
$ditZh = if ($DitGguf) { 'gguf' } else { 'safetensors' }
Write-Host "[start] 起服：repo=$Repo dit=$ditZh port=$Port offload=$Offload te=$TeDevice/keep${TeKeepSec}s dtype=$Dtype 鉴权=$authZh"
Write-Host "[start] 汪柴设置页 → 服务地址 http://127.0.0.1:$Port · API key 同 -ApiKey"
Write-Host "[start] 提示词扩写/轻量聊天：apiModels 里加一档 baseUrl http://127.0.0.1:$Port/v1（chat 模型 id 见 /v1/models）"
& $py server.py
