"""汪柴生图服务 —— Qwen-Image-2.1-Turbo（diffusers 直调）· OpenAI 协议兼容壳。

定位（2026-11-10 评估拍板，docs/image-gen-integration-plan.md 同族方案）：
与 unsloth Studio 8888 并存的第二条生图链路。只做「模型托管 + 协议翻译」，
汪柴客户端零改动——三个端点严格对齐 app/lib/services/image_gen_service.dart
已核实的线上契约：

  GET  /api/health              免鉴权，200 即算可达（客户端 6s 超时）
  GET  /v1/models               Bearer；data[].id 进设置页模型下拉；
                                key 不符回 401 + unsloth 同款 error 体
  POST /v1/images/generations   Bearer；model 可省略（走本服务缺省模型）、
                                prompt / negative_prompt? / n(1-4) /
                                size "WxH" / response_format 'b64_json' /
                                seed?；回 data[].b64_json

与 unsloth 的差异由本壳吸收：Turbo checkpoint 自带 8 步采样调度
（num_inference_steps 不可覆盖）且 CFG=1（negative_prompt 收下但不生效，
仅为协议兼容）。生成全局串行锁：客户端虽已单飞排队，但服务可能被
多端直连，显存只允许一个在飞。

模型加载是惰性的（首请求触发），加载期间 /api/health 仍回 200
（status=loading），客户端绿灯不受冷启动影响；失败则 health 带
status=error + 原因，避免「端口通着但永远卡住」的黑箱。

环境变量（全部 env 化，兼容本机 N 卡与 DGX Spark 128GB 统一内存两宿主）：
  QI_REPO        模型仓：ModelScope repo id 或本地目录（默认 Qwen/Qwen-Image-2.1-Turbo）
  QI_MODEL_ID    /v1/models 报出的模型 id（默认取 QI_REPO 末段）
  QI_API_KEY     客户端需带的 Bearer key；空 = 免鉴权（仅建议 tailnet 内）
  QI_HOST/QI_PORT  监听（默认 0.0.0.0:8899；8888 留给 unsloth，互不打架）
  QI_DTYPE       bf16|fp16|fp32（默认 bf16；无 CUDA 时自动退化 fp32）
  QI_OFFLOAD     none|model|sequential（默认 none=全卡驻留；显存紧用 model）
  QI_STEPS       采样步数提示（默认 8；Turbo 忽略之，换非 Turbo 仓才生效）
  QI_CACHE_DIR   ModelScope 下载缓存目录（默认 SDK 自管）
"""

from __future__ import annotations

import base64
import binascii
import hmac
import io
import os
import re
import secrets
import threading
import time

from fastapi import FastAPI, Request
from fastapi.responses import JSONResponse

# ---------------------------------------------------------------- 配置 ----

QI_REPO = os.environ.get("QI_REPO", "Qwen/Qwen-Image-2.1-Turbo").strip()
QI_MODEL_ID = os.environ.get("QI_MODEL_ID", "").strip() or QI_REPO.rstrip("/").split("/")[-1]
QI_API_KEY = os.environ.get("QI_API_KEY", "").strip()
QI_HOST = os.environ.get("QI_HOST", "0.0.0.0")
QI_PORT = int(os.environ.get("QI_PORT", "8899"))
QI_DTYPE = os.environ.get("QI_DTYPE", "bf16").strip().lower()
QI_OFFLOAD = os.environ.get("QI_OFFLOAD", "none").strip().lower()
QI_STEPS = int(os.environ.get("QI_STEPS", "8"))
QI_CACHE_DIR = os.environ.get("QI_CACHE_DIR", "").strip() or None

# 客户端档位表（image_gen_service.dart kImageGenSizes）之外的尺寸也放行，
# 但钳进模型舒适区：16 对齐（VAE 8× + patch 2），边长 [256, 2560]——上限
# 2560 是留给官方竖图例 1696×2528 的（2048 会把它腰斩）。
_SIZE_RE = re.compile(r"^\s*(\d{2,5})\s*[xX×]\s*(\d{2,5})\s*$")
_SIDE_MIN, _SIDE_MAX = 256, 2560

LICENSE_NOTE = (
    "Qwen RESEARCH LICENSE（2026-09-20，杭州通义实验室）：仅研究/评测用途，"
    "商用需另行取得授权（model-business@notice）。部署到他人可访问的网络前请先确认用途合规。"
)

# ------------------------------------------------------------ 模型装载 ----

app = FastAPI(title="汪柴生图服务", version="0.1.0", docs_url=None, redoc_url=None)

_pipe = None  # QwenImage21Pipeline 实例（加载成功后）
_state = {"status": "idle", "error": ""}  # idle|loading|ready|error
_load_lock = threading.Lock()  # 只护加载（幂等）
_gen_lock = threading.Lock()  # 生成全局串行（显存单飞）


def _resolve_model_path() -> str:
    """本地目录直用；否则走 ModelScope snapshot_download。"""
    if os.path.isdir(QI_REPO):
        return QI_REPO
    from modelscope import snapshot_download  # 延迟 import：本地路径场景不强依赖

    return snapshot_download(QI_REPO, cache_dir=QI_CACHE_DIR)


def _ensure_loaded() -> None:
    """惰性加载（首请求触发），幂等且线程安全；失败留在 error 态不重试风暴。"""
    global _pipe
    if _state["status"] == "ready":
        return
    with _load_lock:
        if _state["status"] == "ready":
            return
        _state["status"] = "loading"
        try:
            import torch
            from diffusers import QwenImage21Pipeline  # 需 diffusers git 主（PR #14950）
        except ImportError as e:  # pragma: no cover - 环境错配路径
            _state.update(status="error", error=(
                f"依赖缺失：{e}。QwenImage21Pipeline 需 git 版 diffusers，"
                "请按 requirements.txt 安装（pip install git+https://github.com/huggingface/diffusers.git）"))
            return
        try:
            path = _resolve_model_path()
            dtype = {"bf16": torch.bfloat16, "fp16": torch.float16}.get(QI_DTYPE, torch.float32)
            use_cuda = torch.cuda.is_available()
            if not use_cuda and dtype is not torch.float32:
                dtype = torch.float32  # CPU 宿主退化 fp32（能跑但慢，见 README）
            _pipe = QwenImage21Pipeline.from_pretrained(path, torch_dtype=dtype)
            if use_cuda:
                if QI_OFFLOAD == "model":
                    _pipe.enable_model_cpu_offload()
                elif QI_OFFLOAD == "sequential":
                    _pipe.enable_sequential_cpu_offload()
                else:
                    _pipe.to("cuda")
            else:
                _pipe.to("cpu")
            _state.update(status="ready", error="")
            print(f"[imagegen] 模型就绪：{QI_MODEL_ID}（{path}，{dtype}, "
                  f"{'cuda/' + QI_OFFLOAD if use_cuda else 'cpu'}）", flush=True)
        except Exception as e:  # pragma: no cover - 运行期兜底
            _pipe = None
            _state.update(status="error", error=f"{type(e).__name__}: {e}")
            print(f"[imagegen] 模型加载失败：{_state['error']}", flush=True)


def _call_pipe(prompt: str, width: int, height: int, seed: int):
    """按 pipeline 实际签名过滤 kwargs（Turbo 忽略 steps/负向，参数面存在版本差）。"""
    import inspect

    import torch

    kwargs = {"prompt": prompt, "width": width, "height": height,
              "generator": torch.Generator(device="cpu").manual_seed(seed)}
    for k, v in (("num_inference_steps", QI_STEPS), ("true_cfg_scale", 1.0)):
        if k in inspect.signature(_pipe.__call__).parameters:
            kwargs[k] = v
    return _pipe(**kwargs).images[0]


# ---------------------------------------------------------------- 鉴权 ----

def _auth_error(request: Request) -> JSONResponse | None:
    """未配 key 全放行；配了则严格 Bearer 匹配，401 体对齐 unsloth/OpenAI。"""
    if not QI_API_KEY:
        return None
    auth = request.headers.get("authorization", "")
    token = auth[7:].strip() if auth.lower().startswith("bearer ") else ""
    if token and hmac.compare_digest(token, QI_API_KEY):
        return None
    return JSONResponse(status_code=401, content={
        "error": {"message": "Not authenticated", "type": "authentication_error"}})


def _err(status: int, message: str, err_type: str = "invalid_request_error") -> JSONResponse:
    return JSONResponse(status_code=status,
                        content={"error": {"message": message, "type": err_type}})


# -------------------------------------------------------------- 端点 ----

@app.get("/api/health")
def health() -> JSONResponse:
    """免鉴权存活探针（客户端 6s 超时，绝不阻塞：加载态/失败态也秒回 200）。"""
    return JSONResponse({
        "status": "healthy" if _state["status"] == "ready" else _state["status"],
        "model": QI_MODEL_ID,
        "model_status": _state["status"],
        "detail": _state["error"],
        "license": "Qwen Research License（非商用；商用需另行授权）",
    })


@app.get("/v1/models")
def models(request: Request):
    err = _auth_error(request)
    if err is not None:
        return err
    # 单模型也如实列全（未来多仓可扩 env QI_REPO_LIST）；id 即下拉选项。
    return JSONResponse({"object": "list", "data": [{
        "id": QI_MODEL_ID,
        "object": "model",
        "created": int(time.time()),
        "owned_by": "wangcai-imagegen",
    }]})


@app.post("/v1/images/generations")
async def generations(request: Request):
    err = _auth_error(request)
    if err is not None:
        return err
    try:
        body = await request.json()
    except Exception:
        return _err(400, "请求体必须是 JSON")
    if not isinstance(body, dict):
        return _err(400, "请求体必须是 JSON 对象")

    prompt = str(body.get("prompt", "")).strip()
    if not prompt:
        return _err(400, "缺少 prompt 参数")
    # model 字段：省略/空 = 本服务缺省模型；给了别的名字不拒（单模型壳，
    # 与 unsloth「目录名当 id」的宽松口径一致），仅记录供排查。
    fmt = str(body.get("response_format", "b64_json")).lower()
    if fmt != "b64_json":
        return _err(400, "本服务仅支持 response_format=b64_json")
    try:
        n = max(1, min(4, int(body.get("n", 1))))
    except (TypeError, ValueError):
        return _err(400, "n 必须是 1-4 的整数")
    m = _SIZE_RE.match(str(body.get("size", "1024x1024")))
    if not m:
        return _err(400, 'size 需为 "WxH"（如 1024x1024）')
    w = min(_SIDE_MAX, max(_SIDE_MIN, int(m.group(1)))) // 16 * 16
    h = min(_SIDE_MAX, max(_SIDE_MIN, int(m.group(2)))) // 16 * 16
    if body.get("seed") is None:
        seed = secrets.randbelow(2**31)
    else:
        try:
            seed = int(body["seed"]) % (2**31)
        except (TypeError, ValueError):
            return _err(400, "seed 必须是整数")

    try:
        _ensure_loaded()
    except Exception as e:  # _ensure_loaded 内部已兜底，此为最后防线
        return _err(500, f"模型加载异常：{e}", "server_error")
    if _state["status"] != "ready":
        return _err(503, f"模型未就绪（{_state['status']}）：{_state['error'] or '加载中'}",
                    "server_error")

    def _run() -> list[str]:
        outs = []
        with _gen_lock:  # 显存单飞：排队而非 429（客户端超时档 120s/300s 已含排队预期）
            for _ in range(n):
                img = _call_pipe(prompt, w, h, seed if n == 1 else seed + len(outs))
                buf = io.BytesIO()
                img.convert("RGB").save(buf, format="PNG")
                outs.append(base64.b64encode(buf.getvalue()).decode("ascii"))
        return outs

    import asyncio
    try:
        items = await asyncio.to_thread(_run)
    except (Exception,) as e:  # noqa: F841 - 推理期任何异常折算 500
        import traceback
        traceback.print_exc()
        return _err(500, f"生成失败：{type(e).__name__}: {e}", "server_error")

    return JSONResponse({"created": int(time.time()), "data": [
        {"b64_json": b64} for b64 in items], "seed": seed})


# ---------------------------------------------------------------- 入口 ----

if __name__ == "__main__":
    import uvicorn

    print(f"[imagegen] 汪柴生图服务启动 {QI_HOST}:{QI_PORT} · 模型 {QI_MODEL_ID}"
          f"（repo={QI_REPO}）· 鉴权 {'开' if QI_API_KEY else '关'}", flush=True)
    print(f"[imagegen] ⚠️ {LICENSE_NOTE}", flush=True)
    # 冷启动即预热加载：首图不等 10 分钟下载/编译（加载失败不阻止监听，
    # health 会带 error 详情）。
    threading.Thread(target=_ensure_loaded, daemon=True).start()
    uvicorn.run(app, host=QI_HOST, port=QI_PORT, log_level="info")
