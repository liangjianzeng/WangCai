"""汪柴生图服务 —— Qwen-Image-2.1-Turbo（diffusers 直调）· OpenAI 协议兼容壳。

定位（2026-11-10 评估拍板 → 2026-11-12「一实例三角色」升级，见
docs/image-gen-integration-plan.md 与 CHANGELOG）：与 unsloth Studio 8888
并存的第二条生图链路，且是 **16GB 单卡零换载主链路**——生图（DiT+VAE）、
提示词扩写、轻量聊天共用同一份常驻 Qwen3-VL-8B text_encoder（完整
ForConditionalGeneration，带 lm_head 能 generate；unsloth Studio 那份 TE
被结构性拆头 + 私有 ConvRot 格式，不可共享，实证见其
diffusion_text_encoder_trim.py）。端点契约严格对齐 app 已核实口径：

  GET  /api/health              免鉴权，200 即算可达（客户端 6s 超时）
  GET  /v1/models               Bearer；生图 id + chat id 双条目进下拉；
                                key 不符回 401 + unsloth 同款 error 体
  POST /v1/images/generations   Bearer；model 可省略（走本服务缺省模型）、
                                prompt / negative_prompt? / n(1-4) /
                                size "WxH" / response_format 'b64_json' /
                                seed?；回 data[].b64_json
  POST /v1/chat/completions     Bearer；OpenAI 兼容（model/messages/
                                stream/temperature/max_tokens）；TE 实例
                                自回归生成，SSE 流式对齐 chatCompletion。
                                扩写（app image_prompt_rewriter）与闲聊同端点。

与 unsloth 的差异由本壳吸收：Turbo checkpoint 自带 8 步采样调度
（num_inference_steps 不可覆盖）且 CFG=1（negative_prompt 收下但不生效，
仅为协议兼容）。生成/对话全局串行锁：显存只允许一个在飞。

显存调度（16GB 硬预算，5060 Ti 实测定档）：DiT（本地 GGUF 量化）+ VAE
常驻卡上；**TE 默认 CPU 驻留**，encode/chat 时上卡、空闲 QI_TE_KEEP_SEC
秒后回 CPU（unsloth 自己也是 TE 流式上卡，实测单程 PCIe ~秒级）。

组件装配（区别于整仓 from_pretrained）：官方 turbo 仓的 text_encoder/
processor/scheduler/vae 走 ModelScope；transformer 允许指本地 GGUF
（QI_DIT_GGUF，diffusers GGUF 量化路线，与 unsloth Windows GPU 同款格式），
省 20GB bf16 DiT 权重与 16GB 显存装不下的死路。

模型加载是惰性的（首请求触发），加载期间 /api/health 仍回 200
（status=loading），客户端绿灯不受冷启动影响；失败则 health 带
status=error + 原因，避免「端口通着但永远卡住」的黑箱。

环境变量（全部 env 化，兼容本机 N 卡与 DGX Spark 128GB 统一内存两宿主）：
  QI_REPO        模型仓：ModelScope repo id 或本地目录（默认 Qwen/Qwen-Image-2.1-Turbo）
  QI_MODEL_ID    /v1/models 报出的生图 id（默认取 QI_REPO 末段）
  QI_CHAT_MODEL_ID  /v1/models 报出的聊天 id（默认 Qwen3-VL-8B-Instruct）
  QI_DIT_GGUF    本地 DiT GGUF 路径（qwen-image-2.1-turbo-*.gguf）；空 =
                 用 QI_REPO 内 transformer/ 的 safetensors（需整仓下载）
  QI_API_KEY     客户端需带的 Bearer key；空 = 免鉴权（仅建议 tailnet 内）
  QI_HOST/QI_PORT  监听（默认 0.0.0.0:8899；8888 留给 unsloth，互不打架）
  QI_DTYPE       bf16|fp16|fp32（默认 bf16；无 CUDA 时自动退化 fp32）
  QI_OFFLOAD     none|model|sequential（DiT/VAE 驻留策略，默认 none=全卡；
                 TE 不受此管，见 QI_TE_DEVICE）
  QI_TE_DEVICE   cpu|cuda（默认 cpu=按需上卡+空闲回迁【16GB 单卡主链路口径】；
                 cuda=常驻不搬【大显存宿主省 PCIe 往返】）
  QI_TE_KEEP_SEC TE 上卡后空闲回迁秒数（默认 120；扩写→生图连续场景免二次
                 搬运；0=用完即回）
  QI_CHAT_TEMPERATURE / QI_CHAT_MAX_TOKENS  chat 端点采样（默认 0.7/512）
  QI_STEPS       采样步数提示（默认 8；Turbo 忽略之，换非 Turbo 仓才生效）
  QI_CACHE_DIR   ModelScope 下载缓存目录（默认 SDK 自管）
"""

from __future__ import annotations

import base64
import binascii
import hmac
import io
import json
import os
import re
import secrets
import threading
import types
import time

from fastapi import FastAPI, Request
from fastapi.responses import JSONResponse, StreamingResponse

# ---------------------------------------------------------------- 配置 ----

QI_REPO = os.environ.get("QI_REPO", "Qwen/Qwen-Image-2.1-Turbo").strip()
QI_MODEL_ID = os.environ.get("QI_MODEL_ID", "").strip() or QI_REPO.rstrip("/").split("/")[-1]
QI_CHAT_MODEL_ID = os.environ.get("QI_CHAT_MODEL_ID", "Qwen3-VL-8B-Instruct").strip()
QI_DIT_GGUF = os.environ.get("QI_DIT_GGUF", "").strip()
# QI_SKIP_DIT=1：DiT 不装载（transformer=None），/v1/images/generations 如实
# 503——16GB 卡 TE 17G(bf16) 与 DiT 同卡不可行的 TE-only 验收档（2026-11-13
# 实证 TE=Qwen3-VL-8B bf16 17G，此前 ~9G 假设作废）；chat 扩写/轻量聊天全功能。
QI_SKIP_DIT = os.environ.get("QI_SKIP_DIT", "").strip() == "1"
# QI_TE_INT4=1：TE 用 bitsandbytes nf4 **4bit 量化常驻上卡**（8B → ~5.5G）——
# 16GB 单卡生图档的显存解：DiT GGUF Q5_K_M 5.4G + VAE 0.65G + TE int4 5.5G
# ≈ 11.6G。bnb 加载即量化上卡（不可再 .to 搬运），TE 调度在本档禁用。
QI_TE_INT4 = os.environ.get("QI_TE_INT4", "").strip() == "1"
QI_API_KEY = os.environ.get("QI_API_KEY", "").strip()
QI_HOST = os.environ.get("QI_HOST", "0.0.0.0")
QI_PORT = int(os.environ.get("QI_PORT", "8899"))
QI_DTYPE = os.environ.get("QI_DTYPE", "bf16").strip().lower()
QI_OFFLOAD = os.environ.get("QI_OFFLOAD", "none").strip().lower()
QI_TE_DEVICE = os.environ.get("QI_TE_DEVICE", "cpu").strip().lower()
QI_TE_KEEP_SEC = max(0, int(os.environ.get("QI_TE_KEEP_SEC", "120")))
QI_CHAT_TEMPERATURE = float(os.environ.get("QI_CHAT_TEMPERATURE", "0.7"))
QI_CHAT_MAX_TOKENS = max(16, int(os.environ.get("QI_CHAT_MAX_TOKENS", "512")))
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
_use_cuda = False  # 加载时定夺；chat/TE 调度共用
_state = {"status": "idle", "error": ""}  # idle|loading|ready|error
_load_lock = threading.Lock()  # 只护加载（幂等）
_gen_lock = threading.Lock()  # 生成/对话全局串行（显存单飞）

# —— TE 显存驻留调度（16GB 主链路口径，全部调用点在 _gen_lock 内）——
# DiT+VAE 常驻卡上；TE（Qwen3-VL，~9GB bf16）默认 CPU 驻留，encode/chat
# 前上卡、空闲 QI_TE_KEEP_SEC 秒后回迁。unsloth 同硬件也是 TE 流式化
# （其日志 offload=group「text encoders streamed too, they run once」），
# 我们把它显式化并加 TTL：扩写→确认→生图连续场景只搬一次。
_te_on_cuda = False
_te_last_used = 0.0
_te_timer: threading.Timer | None = None


def _te_acquire() -> None:
    """TE 上卡（幂等）。取消待触发的回迁计时；记使用时戳。

    上卡条件 = `_use_cuda` **且 QI_TE_DEVICE=="cuda"**——cpu 档 TE 永驻 RAM
    （2026-11-13 实案：TE bf16 17G 会整卡塞满 16GB 消费卡，挤死 DiT/桌面）；
    int4 档 TE 已随 bnb 加载上卡，本函数 no-op。"""
    global _te_on_cuda, _te_last_used, _te_timer
    if QI_TE_INT4:
        return
    if _te_timer is not None:
        _te_timer.cancel()
        _te_timer = None
    if _use_cuda and QI_TE_DEVICE == "cuda" and not _te_on_cuda:
        t0 = time.monotonic()
        _pipe.text_encoder.to("cuda")
        _te_on_cuda = True
        print(f"[imagegen] TE 上卡 {time.monotonic() - t0:.1f}s", flush=True)
    _te_last_used = time.monotonic()


def _te_offload_now() -> None:
    global _te_on_cuda, _te_timer
    import torch

    _pipe.text_encoder.to("cpu")
    _te_on_cuda = False
    torch.cuda.empty_cache()  # 让出显存池给 denoise 峰值/DX12 侧
    print("[imagegen] TE 回迁 CPU", flush=True)


def _te_release() -> None:
    """解锁前调用：QI_TE_DEVICE=cuda 常驻不搬；cpu/int4 档 no-op。"""
    global _te_last_used, _te_timer
    if not _use_cuda or QI_TE_DEVICE != "cuda" or QI_TE_INT4:
        return  # cpu 档（TE 从未上卡）/ int4 档（常驻卡不搬）
    _te_last_used = time.monotonic()
    if QI_TE_KEEP_SEC == 0:
        _te_offload_now()
        return
    # 定时器兜底回迁；若到期时锁被占（新一轮在飞）则顺延，不动在飞对象。
    def _due():
        global _te_timer
        _te_timer = None
        if not _gen_lock.acquire(blocking=False):
            _te_timer = threading.Timer(5.0, _due)
            _te_timer.daemon = True
            _te_timer.start()
            return
        try:
            if _te_on_cuda and time.monotonic() - _te_last_used >= QI_TE_KEEP_SEC:
                _te_offload_now()
        finally:
            _gen_lock.release()

    _te_timer = threading.Timer(float(QI_TE_KEEP_SEC), _due)
    _te_timer.daemon = True
    _te_timer.start()


def _resolve_model_path() -> str:
    """本地目录直用；否则走 ModelScope snapshot_download。

    QI_DIT_GGUF 有值时 transformer 权重不落地（省 ~20GB），只拉其余组件
    ——官方 turbo 仓的 DiT bf16 在 16GB 卡上是死路，GGUF 档才是主配方。"""
    if os.path.isdir(QI_REPO):
        return QI_REPO
    from modelscope import snapshot_download  # 延迟 import：本地路径场景不强依赖

    if QI_DIT_GGUF:
        return snapshot_download(
            QI_REPO, cache_dir=QI_CACHE_DIR,
            ignore_patterns=["transformer/*.safetensors", "transformer/*.bin",
                             "transformer/*index*.json"])
    return snapshot_download(QI_REPO, cache_dir=QI_CACHE_DIR)


def _ensure_loaded() -> None:
    """惰性加载（首请求触发），幂等且线程安全；失败留在 error 态不重试风暴。"""
    global _pipe, _use_cuda
    if _state["status"] == "ready":
        return
    with _load_lock:
        if _state["status"] == "ready":
            return
        _state["status"] = "loading"
        try:
            import torch
            from diffusers import (AutoencoderKLQwenImage21,  # noqa: F401
                                   FlowMatchEulerDiscreteScheduler,
                                   QwenImage21Pipeline,
                                   QwenImage21Transformer2DModel)
            from transformers import Qwen3VLForConditionalGeneration, Qwen3VLProcessor
        except ImportError as e:  # pragma: no cover - 环境错配路径
            _state.update(status="error", error=(
                f"依赖缺失：{e}。QwenImage21Pipeline 需 git 版 diffusers、"
                "Qwen3VL* 需 transformers>=4.57，"
                "请按 requirements.txt 安装（pip install git+https://github.com/huggingface/diffusers.git）"))
            return
        try:
            path = _resolve_model_path()
            dtype = {"bf16": torch.bfloat16, "fp16": torch.float16}.get(QI_DTYPE, torch.float32)
            _use_cuda = torch.cuda.is_available()
            if not _use_cuda and dtype is not torch.float32:
                dtype = torch.float32  # CPU 宿主退化 fp32（能跑但慢，见 README）
            # 组件装配（而非整仓 from_pretrained）：transformer 允许换本地
            # GGUF 量化档，其余仍走仓内 safetensors。
            scheduler = FlowMatchEulerDiscreteScheduler.from_pretrained(
                path, subfolder="scheduler")
            vae = AutoencoderKLQwenImage21.from_pretrained(
                path, subfolder="vae", torch_dtype=dtype)
            if QI_TE_INT4 and _use_cuda:
                # 4bit nf4 量化：加载即逐层上卡量化（bnb 不支持加载后 .to）。
                from transformers import BitsAndBytesConfig
                text_encoder = Qwen3VLForConditionalGeneration.from_pretrained(
                    os.path.join(path, "text_encoder"), torch_dtype=dtype,
                    quantization_config=BitsAndBytesConfig(
                        load_in_4bit=True, bnb_4bit_compute_dtype=dtype,
                        bnb_4bit_quant_type="nf4"),
                    device_map={"": 0})
                _te_on_cuda = True  # int4 档常驻卡，调度全程 no-op
                print(f"[imagegen] TE int4(nf4) 常驻上卡（显存 ~"
                      f"{torch.cuda.memory_allocated() / 2**30:.1f}G）", flush=True)
            else:
                # TE 先建在 CPU（QI_TE_DEVICE=cpu 档的初始态；cuda 档随后统一 .to）
                text_encoder = Qwen3VLForConditionalGeneration.from_pretrained(
                    os.path.join(path, "text_encoder"), torch_dtype=dtype)
            processor = Qwen3VLProcessor.from_pretrained(
                path, subfolder="processor")
            if QI_SKIP_DIT:
                transformer = None
                print("[imagegen] QI_SKIP_DIT=1：跳过 DiT 装载（生图端点将 503，"
                      "chat/扩写全功能）", flush=True)
            elif QI_DIT_GGUF:
                # ComfyUI 系 gguf 在 diffusers 0.43-dev 双坑实锤：from_single_file
                # 无 GGUF 实现（"Unable to load weights"→形状爆炸）；from_pretrained
                # 文件发现不认 .gguf 名（只找 diffusion_pytorch_model.bin/safetensors，
                # config 也从 weights 路径找 → 直接炸）。而正确入口
                # load_gguf_checkpoint（.gguf → GGUFParameter(quant_type)）与
                # _replace_with_gguf_linear（nn.Linear→GGUFLinear，前向按块
                # dequant——显存驻留 = 量化块）都是公开稳定 API，此处手工三步
                # 组装出与官方 GGUFQuantizationConfig 语义完全一致的加载。
                from convert_gguf_keys import convert_gguf_keys
                from diffusers.models.model_loading_utils import load_gguf_checkpoint
                from diffusers.quantizers.gguf.utils import _replace_with_gguf_linear

                dit_file = convert_gguf_keys(QI_DIT_GGUF)
                transformer = QwenImage21Transformer2DModel.from_config(
                    os.path.join(path, "transformer"), torch_dtype=dtype)
                dit_sd = load_gguf_checkpoint(dit_file)
                _replace_with_gguf_linear(transformer, compute_dtype=dtype,
                                          state_dict=dit_sd)
                # 官方 create_quantized_param 同款语义：GGUFParameter（raw 量化
                # 块形状）**直接赋 _parameters**——GGUFLinear 权重驻留本就是
                # raw 形状，load_state_dict 的形状校验会误炸（0.43 实锤）；
                # 非 quant 张量（bias/norm，gguf 里 F32）按 dtype copy_。
                from diffusers.quantizers.gguf.utils import (
                    GGUFParameter,
                    dequantize_gguf_tensor,
                )
                msd_keys = set(dict(transformer.state_dict()))
                _loaded = _raw = 0
                for k, v in dit_sd.items():
                    # 键映射（两代架构 img_mlp 重布线，实证 transformer_qwenimage21
                    # L206-212 前向 out(act(gate_layer) * proj)：原版 Qwen-Image 的
                    # gate_up（gate|up 沿输出维拼接，24576=2×12288）→ 2.1 的
                    # gate_layer(gate, act 通道) + proj(up, 乘子)。K-quant 块沿
                    # 输出行独立 → 按行切半零损失。键级处理（先于 get_submodule——
                    # `…img_mlp.gate_up.weight` 按尾点切会得到不存在的模块路径）。
                    if k.endswith("img_mlp.gate_up.weight"):
                        # gate_layer/proj 是 nn.Linear（_replace_with_gguf_linear
                        # 不认识 gate_up 键，没替换它们）——直接往 fw._parameters
                        # 塞键会**遮蔽同名 _modules**（nn.Module.__getattr__ 先查
                        # _parameters → self.gate_layer 变成不可调用 Tensor，
                        # 'GGUFParameter' object is not callable 实锤）。正确做法
                        # 是把两层整体换成 GGUFLinear：raw Q5 驻留 + 前向自动
                        # dequant，显存优势与全链一致。
                        from diffusers.quantizers.gguf.utils import GGUFLinear
                        fw = transformer.get_submodule(k[:-len(".gate_up.weight")])
                        half = v.shape[0] // 2
                        fw.gate_layer = GGUFLinear(4096, half, bias=False,
                                                   compute_dtype=dtype)
                        fw.proj = GGUFLinear(4096, half, bias=False,
                                             compute_dtype=dtype)
                        fw.gate_layer._parameters["weight"] = GGUFParameter(
                            v.as_tensor()[:half], quant_type=v.quant_type)
                        fw.proj._parameters["weight"] = GGUFParameter(
                            v.as_tensor()[half:], quant_type=v.quant_type)
                        _raw += 2
                        continue
                    mod_name, pname = k.rsplit(".", 1)
                    module = transformer.get_submodule(mod_name)
                    is_gguf_linear = "GGUFLinear" in type(module).__name__
                    if isinstance(v, GGUFParameter):
                        if pname in module._parameters:
                            if is_gguf_linear:
                                # raw 驻留（GGUFLinear 前向按块 dequant，不 .to
                                # 保 quant_type 属性）。
                                module._parameters[pname] = v
                            else:
                                # 官方 create_quantized_param 的 excluded-module
                                # 同款语义：非-Linear（RMSNorm 等）拿 raw 字节
                                # 视图会前向广播炸（text_norm 8192 vs 4096 实锤）
                                # → 就地 dequant 落值。
                                module._parameters[pname] = torch.nn.Parameter(
                                    dequantize_gguf_tensor(v).to(dtype),
                                    requires_grad=False)
                            _raw += 1
                        elif pname in module._buffers:
                            module._buffers[pname] = dequantize_gguf_tensor(v).to(dtype)
                            _raw += 1
                        else:
                            raise RuntimeError(f"{k} 无对应参数位")
                    else:
                        cur = getattr(module, pname)
                        if pname in module._parameters:
                            # 整参数替换（copy_ 在 2026-11-13 实案中未落地——
                            # norm_out.linear.weight 装载后仍 f32，前向 dtype
                            # 炸；Parameter 重建不受 copy 语义牵制）。
                            module._parameters[pname] = torch.nn.Parameter(
                                v.to(dtype).clone().contiguous(),
                                requires_grad=False)
                        elif pname in module._buffers:
                            module._buffers[pname] = v.to(dtype).clone().contiguous()
                        else:
                            raise RuntimeError(f"{k} 无对应参数位")
                        _loaded += 1
                _missing = [k for k in msd_keys if k not in dit_sd
                            and not (k.endswith("img_mlp.proj.weight")
                                     or k.endswith("img_mlp.gate_layer.weight"))]
                if _missing:
                    raise RuntimeError(f"GGUF DiT 缺键：{_missing[:8]}")
                _nl = dict(transformer.named_modules())["norm_out.linear"]
                print(f"[imagegen] DiT GGUF 装载 OK：raw={_raw} dequant-copied="
                      f"{_loaded}（含 img_mlp gate_up→gate_layer/proj 拆分）；"
                      f"norm_out.linear.weight dtype="
                      f"{_nl.weight.dtype}", flush=True)
            else:
                transformer = QwenImage21Transformer2DModel.from_pretrained(
                    path, subfolder="transformer", torch_dtype=dtype)
            if QI_SKIP_DIT:
                # chat/扩写只碰 text_encoder/processor——不建 pipeline（组件注册
                # 不容 transformer=None），给个同形 namespace。
                _pipe = types.SimpleNamespace(text_encoder=text_encoder,
                                              processor=processor)
            else:
                _pipe = QwenImage21Pipeline(
                    vae=vae, transformer=transformer, text_encoder=text_encoder,
                    scheduler=scheduler, processor=processor)
            if _use_cuda and not QI_SKIP_DIT:
                if QI_OFFLOAD == "model":
                    # 整链 offload 与 TE 调度互斥语义：交给 diffusers 全权管
                    _pipe.enable_model_cpu_offload()
                elif QI_OFFLOAD == "sequential":
                    _pipe.enable_sequential_cpu_offload()
                else:
                    transformer.to("cuda")
                    vae.to("cuda")
                    if QI_TE_DEVICE == "cuda" and not QI_TE_INT4:
                        text_encoder.to("cuda")
                        _te_on_cuda = True
                    # QI_TE_INT4 档：TE 已随 bnb 加载上卡，禁止再 .to
            else:
                if not QI_SKIP_DIT:
                    _pipe.to("cpu")
                _te_on_cuda = True  # CPU 宿主无所谓搬移
            if _use_cuda:
                import torch as _torch
                _torch.cuda.empty_cache()  # 挤出 bnb 量化/装载过程的 allocator 缓存
            _state.update(status="ready", error="")
            print(f"[imagegen] 模型就绪：{QI_MODEL_ID} + chat:{QI_CHAT_MODEL_ID}"
                  f"（{path}，{dtype}, {'cuda/' + QI_OFFLOAD + '/te:' + QI_TE_DEVICE if _use_cuda else 'cpu'}"
                  f"{', dit:gguf' if QI_DIT_GGUF else ''}{'，TE-only(QI_SKIP_DIT)' if QI_SKIP_DIT else ''}）",
                  flush=True)
        except Exception as e:  # pragma: no cover - 运行期兜底
            _pipe = None
            _state.update(status="error", error=f"{type(e).__name__}: {e}")
            print(f"[imagegen] 模型加载失败：{_state['error']}", flush=True)


def _call_pipe(prompt: str, width: int, height: int, seed: int):
    """按 pipeline 实际签名过滤 kwargs（Turbo 忽略 steps/负向，参数面存在版本差）。

    调用方须持 _gen_lock 并先 _te_acquire()（encode 发生在 pipeline 内部）。"""
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
        "chat_model": QI_CHAT_MODEL_ID,
        "model_status": _state["status"],
        "te_residency": ("cuda-int4" if QI_TE_INT4 else
                         ("cuda" if _te_on_cuda else "cpu")) if _use_cuda else "cpu",
        "dit": "skipped" if QI_SKIP_DIT else ("gguf" if QI_DIT_GGUF else "safetensors"),
        "detail": _state["error"],
        "license": "Qwen Research License（非商用；商用需另行授权）",
    })


@app.get("/api/vram")
def vram():
    """显存诊断（免鉴权）：分清 allocated（真用）/ reserved（PyTorch 缓存池）/
    驱动层总量——nvidia-smi 看到 98% 时先看这里，别误判「重复加载」。"""
    if not _use_cuda:
        return JSONResponse({"cuda": False})
    import torch
    return JSONResponse({
        "cuda": True,
        "allocated_gib": round(torch.cuda.memory_allocated() / 2**30, 2),
        "reserved_gib": round(torch.cuda.memory_reserved() / 2**30, 2),
        "note": "reserved-allocated = caching allocator 池（可复用/empty_cache 可挤），"
                "非第二份模型",
    })


@app.get("/v1/models")
def models(request: Request):
    err = _auth_error(request)
    if err is not None:
        return err
    # 双 id：生图 id 进生图下拉（image_gen_section），chat id 供
    # apiModels/chat 下拉指过来做提示词扩写与轻量闲聊（一实例三角色）。
    created = int(time.time())
    return JSONResponse({"object": "list", "data": [
        {"id": QI_MODEL_ID, "object": "model", "created": created,
         "owned_by": "wangcai-imagegen"},
        {"id": QI_CHAT_MODEL_ID, "object": "model", "created": created,
         "owned_by": "wangcai-imagegen"},
    ]})


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
    if QI_SKIP_DIT:
        return _err(503, "生图档未装载：QI_SKIP_DIT=1（TE-only 验收档，DiT 显存方案见 README 开放项）",
                    "server_error")

    def _run() -> list[str]:
        outs = []
        if QI_SKIP_DIT:
            raise RuntimeError("DiT 未装载（QI_SKIP_DIT=1 TE-only 档，见 README 开放项）")
        with _gen_lock:  # 显存单飞：排队而非 429（客户端超时档 120s/300s 已含排队预期）
            _te_acquire()  # encode 在 pipeline 内部，先把 TE 搬上卡
            try:
                for _ in range(n):
                    img = _call_pipe(prompt, w, h, seed if n == 1 else seed + len(outs))
                    buf = io.BytesIO()
                    img.convert("RGB").save(buf, format="PNG")
                    outs.append(base64.b64encode(buf.getvalue()).decode("ascii"))
            finally:
                _te_release()
                # 生图收尾挤缓存：GGUF 逐层 dequant 工作区 / 激活波峰的块
                # 会被 caching allocator 保留（nvidia-smi 观感 98%+），每次
                # 生图后归还驱动，保证 2048² 大图 / 桌面侧余量。
                import torch as _torch
                _torch.cuda.empty_cache()
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


# ------------------------------------------------- 对话（TE 复用一实例）----

def _flatten_content(content) -> str:
    """OpenAI content 允许 str 或 [{type:'text',...}] 部件表；本端点文本向。"""
    if isinstance(content, str):
        return content
    if isinstance(content, list):
        return "\n".join(str(p.get("text", "")) for p in content
                         if isinstance(p, dict) and p.get("type") == "text")
    return "" if content is None else str(content)


def _prepare_chat_inputs(messages: list[dict]):
    """chat template → processor tokenize → 张量落 TE 当前所在设备。"""
    import torch

    text = _pipe.processor.apply_chat_template(
        [{"role": str(m.get("role", "user")),
          "content": _flatten_content(m.get("content"))} for m in messages],
        add_generation_prompt=True, tokenize=False)
    inputs = _pipe.processor(text=[text], return_tensors="pt")
    return inputs.to("cuda" if _te_on_cuda else "cpu")


def _chat_generate_kwargs(temperature, max_tokens) -> dict:
    kwargs = {"max_new_tokens": max(16, min(int(max_tokens or QI_CHAT_MAX_TOKENS),
                                            QI_CHAT_MAX_TOKENS)),
              "do_sample": (temperature if temperature is not None
                            else QI_CHAT_TEMPERATURE) > 0}
    t = QI_CHAT_TEMPERATURE if temperature is None else float(temperature)
    if kwargs["do_sample"]:
        kwargs["temperature"] = max(0.01, min(t, 2.0))
    else:
        kwargs["temperature"] = None  # greedy（扩写要稳时可传 0）
    return kwargs


def _run_chat(messages: list[dict], temperature, max_tokens, streamer=None) -> dict:
    """持锁 + TE 上卡跑一次自回归。返回 usage 供两端点拼响应。"""
    import torch

    with _gen_lock:  # 与生图全局互斥：显存单飞语义同 /images/generations
        _te_acquire()
        try:
            inputs = _prepare_chat_inputs(messages)
            kw = _chat_generate_kwargs(temperature, max_tokens)
            if streamer is not None:
                kw["streamer"] = streamer
            with torch.no_grad():
                out = _pipe.text_encoder.generate(**inputs, use_cache=True, **kw)
            gen = out[0][inputs["input_ids"].shape[1]:] if streamer is None else None
            return {"input_len": int(inputs["input_ids"].shape[1]),
                    "output_len": int(gen.shape[0]) if gen is not None else 0,
                    "text": "" if gen is None else
                    _pipe.processor.tokenizer.decode(gen, skip_special_tokens=True)}
        finally:
            if streamer is not None:
                streamer.end()
            _te_release()


@app.post("/v1/chat/completions")
async def chat_completions(request: Request):
    """OpenAI 兼容对话：app 提示词扩写（image_prompt_rewriter）与轻量聊天共用。

    model 字段宽松（单模型壳）；stream=true 走 SSE chunk，对齐 app
    openai_service.dart chatCompletion 的消费面（delta.content/[DONE]）。"""
    err = _auth_error(request)
    if err is not None:
        return err
    try:
        body = await request.json()
    except Exception:
        return _err(400, "请求体必须是 JSON")
    if not isinstance(body, dict):
        return _err(400, "请求体必须是 JSON 对象")
    messages = body.get("messages")
    if (not isinstance(messages, list) or not messages
            or not all(isinstance(m, dict) and m.get("role") for m in messages)):
        return _err(400, "messages 需为非空 [{role, content}] 数组")
    temperature = body.get("temperature")
    if temperature is not None:
        try:
            temperature = float(temperature)
        except (TypeError, ValueError):
            return _err(400, "temperature 必须是数")
    max_tokens = body.get("max_tokens") or body.get("max_completion_tokens")

    try:
        _ensure_loaded()
    except Exception as e:
        return _err(500, f"模型加载异常：{e}", "server_error")
    if _state["status"] != "ready":
        return _err(503, f"模型未就绪（{_state['status']}）：{_state['error'] or '加载中'}",
                    "server_error")

    import asyncio

    model_id = str(body.get("model") or QI_CHAT_MODEL_ID)
    created = int(time.time())
    cid = f"chatcmpl-{secrets.token_hex(12)}"

    def _chunk(delta, finish=None):
        return "data: " + json.dumps({
            "id": cid, "object": "chat.completion.chunk", "created": created,
            "model": model_id,
            "choices": [{"index": 0, "delta": delta, "finish_reason": finish}],
        }, ensure_ascii=False) + "\n\n"

    if not body.get("stream"):
        try:
            r = await asyncio.to_thread(_run_chat, messages, temperature, max_tokens)
        except Exception as e:
            import traceback
            traceback.print_exc()
            return _err(500, f"生成失败：{type(e).__name__}: {e}", "server_error")
        return JSONResponse({
            "id": cid, "object": "chat.completion", "created": created,
            "model": model_id,
            "choices": [{"index": 0, "message": {"role": "assistant",
                                                 "content": r["text"]},
                         "finish_reason": "stop"}],
            "usage": {"prompt_tokens": r["input_len"],
                      "completion_tokens": r["output_len"],
                      "total_tokens": r["input_len"] + r["output_len"]}})

    from transformers import TextIteratorStreamer

    streamer = TextIteratorStreamer(_pipe.processor.tokenizer,
                                    skip_prompt=True, skip_special_tokens=True)
    thread = threading.Thread(target=_run_chat,
                              args=(messages, temperature, max_tokens, streamer),
                              daemon=True)
    thread.start()

    async def _sse():
        loop = asyncio.get_event_loop()
        yield _chunk({"role": "assistant"})
        try:
            while True:
                # streamer 的 next() 阻塞（等 token），经线程池让出事件循环
                piece = await loop.run_in_executor(None, lambda: next(streamer, None))
                if piece is None:
                    break
                if piece:
                    yield _chunk({"content": piece})
        except Exception as e:  # 生成线程炸了：错误以内容面暴露后收尾
            yield _chunk({"content": f"[生成错误：{type(e).__name__}: {e}]"})
        yield _chunk({}, finish="stop")
        yield "data: [DONE]\n\n"

    return StreamingResponse(_sse(), media_type="text/event-stream",
                             headers={"Cache-Control": "no-cache",
                                      "X-Accel-Buffering": "no"})


# ---------------------------------------------------------------- 入口 ----

if __name__ == "__main__":
    import uvicorn

    print(f"[imagegen] 汪柴生图服务启动 {QI_HOST}:{QI_PORT} · 模型 {QI_MODEL_ID}"
          f" + chat {QI_CHAT_MODEL_ID}（repo={QI_REPO}"
          f"{', dit=gguf:' + QI_DIT_GGUF if QI_DIT_GGUF else ''}"
          f", te:{QI_TE_DEVICE}/keep{QI_TE_KEEP_SEC}s）· 鉴权 {'开' if QI_API_KEY else '关'}",
          flush=True)
    print(f"[imagegen] ⚠️ {LICENSE_NOTE}", flush=True)
    # 冷启动即预热加载：首图不等 10 分钟下载/编译（加载失败不阻止监听，
    # health 会带 error 详情）。
    threading.Thread(target=_ensure_loaded, daemon=True).start()
    uvicorn.run(app, host=QI_HOST, port=QI_PORT, log_level="info")
