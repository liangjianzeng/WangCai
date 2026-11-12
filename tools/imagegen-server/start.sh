#!/usr/bin/env bash
# 汪柴生图服务一键起服（Linux 宿主：WSL 自测 / DGX Spark 正式，2026-11-10）。
#
# 幂等四步：建 .venv → 依赖闸（QwenImage21Pipeline 导得进来就跳过安装）→
# 模型没落盘就 modelscope 下载 → 注入 env 起 server.py（前台，Ctrl+C 停）。
#
# 用法（本目录）：
#   ./start.sh                                   # 全默认：模型自动下到 ./models/qit，8899 免鉴权
#   QI_API_KEY=sk-wc-xxx ./start.sh              # 局域网共享必开鉴权
#   REPO=/data/models/qit OFFLOAD=model ./start.sh   # 模型已在别处 / 显存紧
#   DIT_GGUF=/path/qwen-image-2.1-turbo-Q5_K_M.gguf ./start.sh   # 16GB 单卡主链路：
#                                                #  DiT 用本地 GGUF，只下载 TE/VAE/processor
#   TE_DEVICE=cuda ./start.sh                    # 大显存宿主：TE 常驻不搬（DGX 用这个）
# DGX Spark 注意：arm64/CUDA13 的 torch 用 NVIDIA 官方轮或 NGC 容器，
# 预装好再跑本脚本（torch 闸会跳过 pip 的 cu124 装法）。
set -u
cd "$(dirname "$0")"

# python 闸：diffusers git 主干要求 ≥3.11（3.14 轮子未跟上）。QI_PYTHON 可指
# 便携版/指定解释器（与 start.ps1 同口径）。
py_ok() { "$1" -c 'import sys; raise SystemExit(0 if (3,11) <= sys.version_info[:2] <= (3,13) else 1)' 2>/dev/null; }
SYS_PY="${QI_PYTHON:-}"
if [ -z "$SYS_PY" ] || ! py_ok "$SYS_PY"; then
  SYS_PY=""
  for c in python3 python; do
    command -v "$c" >/dev/null 2>&1 && py_ok "$c" && { SYS_PY="$c"; break; }
  done
fi
[ -n "$SYS_PY" ] || { echo "需要 python 3.11~3.13（diffusers git 主干需 ≥3.11）：QI_PYTHON=… 指过去"; exit 1; }

REPO="${REPO:-${QI_REPO:-./models/qit}}"
API_KEY="${QI_API_KEY:-}"
PORT="${QI_PORT:-8899}"
OFFLOAD="${QI_OFFLOAD:-none}"
DTYPE="${QI_DTYPE:-bf16}"
TORCH_INDEX="${TORCH_INDEX:-https://download.pytorch.org/whl/cu124}"
DIT_GGUF="${DIT_GGUF:-${QI_DIT_GGUF:-}}"
TE_DEVICE="${TE_DEVICE:-${QI_TE_DEVICE:-cpu}}"
TE_KEEP_SEC="${TE_KEEP_SEC:-${QI_TE_KEEP_SEC:-120}}"

PY=.venv/bin/python
if [ -x "$PY" ] && ! py_ok "$PY"; then
  echo "[start] 既有 .venv 版本不合（需 3.11~3.13），重建 …"
  rm -rf .venv
fi
if [ ! -x "$PY" ]; then
  echo "[start] 建 venv（$SYS_PY）…"
  "$SYS_PY" -m venv .venv || { echo "需要 python + venv（apt install python3-venv）"; exit 1; }
fi

# 依赖闸：以「pipeline + Qwen3VL 导得进来」为准（旧版 PyPI diffusers 没有该类、
# transformers<4.57 没有 qwen3_vl，照样触发重装——chat 端点要 TE generate）。
if ! "$PY" -c "from diffusers import QwenImage21Pipeline; from transformers import Qwen3VLForConditionalGeneration; import gguf" 2>/dev/null; then
  echo "[start] 首次装依赖（torch 走 $TORCH_INDEX，diffusers 走 git 主）…"
  "$PY" -m pip install -U pip
  if ! "$PY" -c "import torch" 2>/dev/null; then
    "$PY" -m pip install torch torchvision --index-url "$TORCH_INDEX" || {
      echo "torch 装失败：DGX/特殊 CUDA 请预装官方轮子后重跑"; exit 1; }
  fi
  "$PY" -m pip install -r requirements.txt || {
    echo "依赖安装失败：确认 git 在 PATH、CUDA 版本与 TORCH_INDEX 匹配"; exit 1; }
fi

if [ ! -d "$REPO" ]; then
  if [ -n "$DIT_GGUF" ]; then
    echo "[start] 下载 turbo 仓（跳 transformer 大权重，DiT 走本地 GGUF）→ $REPO …"
    "$PY" - "$REPO" <<'PYEOF' || { echo "模型下载失败：查网络/磁盘，或手动 modelscope download 后用 REPO= 指过去"; exit 1; }
import sys
from modelscope import snapshot_download
snapshot_download('Qwen/Qwen-Image-2.1-Turbo', local_dir=sys.argv[1],
                  ignore_patterns=['transformer/*.safetensors', 'transformer/*.bin',
                                   'transformer/*index*.json'])
PYEOF
  else
    echo "[start] 下载 Qwen/Qwen-Image-2.1-Turbo → $REPO（数十 GB，耐心）…"
    "$PY" - "$REPO" <<'PYEOF' || { echo "模型下载失败：查网络/磁盘，或手动 modelscope download 后用 REPO= 指过去"; exit 1; }
import sys
from modelscope import snapshot_download
snapshot_download('Qwen/Qwen-Image-2.1-Turbo', local_dir=sys.argv[1])
PYEOF
  fi
fi

export QI_REPO="$REPO" QI_API_KEY="$API_KEY" QI_PORT="$PORT" QI_OFFLOAD="$OFFLOAD" QI_DTYPE="$DTYPE"
export QI_DIT_GGUF="$DIT_GGUF" QI_TE_DEVICE="$TE_DEVICE" QI_TE_KEEP_SEC="$TE_KEEP_SEC"
if [ -n "$API_KEY" ]; then AUTH=开; else AUTH=关; fi
DIT_ZH=gguf; [ -z "$DIT_GGUF" ] && DIT_ZH=safetensors
echo "[start] 起服：repo=$REPO dit=$DIT_ZH port=$PORT offload=$OFFLOAD te=$TE_DEVICE/keep${TE_KEEP_SEC}s dtype=$DTYPE 鉴权=$AUTH"
echo "[start] 汪柴设置页 → 服务地址 http://127.0.0.1:$PORT · API key 同 QI_API_KEY"
echo "[start] 提示词扩写/轻量聊天：apiModels 里加一档 baseUrl http://127.0.0.1:$PORT/v1（chat 模型 id 见 /v1/models）"
exec "$PY" server.py
