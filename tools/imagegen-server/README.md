# 汪柴生图服务（Qwen-Image-2.1-Turbo · diffusers 直调 · 一实例三角色）

生图**主推链路**的服务端：不依赖 unsloth Studio，直接用 diffusers
`QwenImage21Pipeline` 跑 [ModelScope Qwen/Qwen-Image-2.1-Turbo](https://modelscope.cn/models/Qwen/Qwen-Image-2.1-Turbo)，
对外暴露与 unsloth 同构的 OpenAI 协议壳（`/api/health`、`/v1/models`、
`/v1/images/generations`）+ **对话端点 `/v1/chat/completions`**（2026-11-12
「一实例三角色」：生图、提示词扩写、轻量聊天共用**同一份常驻 Qwen3-VL
text_encoder**——`pipe.text_encoder` 是完整 `Qwen3VLForConditionalGeneration`，
带 lm_head 能 `generate()`，扩写零新增加载）——**汪柴客户端零改动**，
设置页换个地址就能切链路。unsloth Studio（8888）保留为可选链路；注意其 TE
被拆头（`NoLogitsHead`，见 `docs/image-gen-integration-plan.md` 源码实证），
**物理上不能承担扩写/聊天**——要扩写就走本服务。

| | unsloth Studio（可选链路） | 本服务（主推） |
|---|---|---|
| 端口 | 8888 | **8899**（默认，互不打架） |
| 模型 | Studio 扫描目录（如 flux 系） | Qwen-Image-2.1-Turbo（DiT 可换本地 GGUF） |
| 中文渲染/文字海报 | 一般 | 强（Qwen-Image 系卖点） |
| 提示词扩写（🎨/「/图」确认卡流） | ✗（TE 拆头不可 generate） | ✓ `/v1/chat/completions`（同一份 Qwen3-VL 常驻） |
| 采样 | Studio 管理 | checkpoint 内置 8 步，CFG=1（`num_inference_steps`/负向提示不生效，协议照收） |

**16GB 单卡显存口径（5060Ti 实测基线，2026-11-13 修正）**：
TE（Qwen3-VL-8B）**bf16 实测 17G**——远超此前的 ~9G 假设，**16GB 卡物理装不下
TE 上卡**。现行档：`QI_TE_DEVICE=cpu`（默认）TE 常驻系统 RAM（47G 机器实测
chat 全程显存 **0 MiB**），chat/扩写全功能；生图（DiT）档位为**开放项**——
候选解 TE int8/fp8 上卡（~8.5G）+ DiT GGUF（Q5_K_M 5.4G）+ VAE 0.65G ≈ 14.6G，
需二轮评估 TE 量化精度与可搬运性；`QI_SKIP_DIT=1` 是当前 TE-only 验收档
（生图端点如实 503）。DiT GGUF 装载的 diffusers 双坑与键映射工程已完成
（见 `convert_gguf_keys.py`），剩 norm 布局对账（norm_q 512 vs 128 等）未收口。
本地聊天模型（LFM2.5-24B ~13G / Bonsai-27B）与生图栈**互斥**口径不变；
DGX Spark（128GB 统一内存）无所谓：`-TeDevice cuda` TE 全常驻上卡。

## 快速开始（一键脚本）

```powershell
# Windows 宿主（N 卡）：
cd tools\imagegen-server
# 16GB 单卡主配方（DiT 本地 GGUF，只下载 TE/VAE/processor）：
.\start.ps1 -ApiKey sk-wc-自己的随机串 -DitGguf E:\Unsloth\models\qwen-image-2.1-turbo-Q5_K_M.gguf
# 整仓 safetensors 档（大显存宿主）：
.\start.ps1 -ApiKey sk-wc-自己的随机串
# 常用开关：-Repo D:\models\qit（模型已下别处）· -Offload model（显存紧）
#          -TeDevice cuda -TeKeepSec 0（大显存 TE 常驻）· -Port 8899 · -Dtype bf16
#          -TorchIndex …（50 系 Blackwell 必须 cu128+，脚本默认已是 cu128）
```

```bash
# Linux 宿主（WSL 自测 / DGX Spark 正式）：
cd tools/imagegen-server
QI_API_KEY=sk-wc-自己的随机串 ./start.sh
# 常用开关：REPO=/data/models/qit · OFFLOAD=model · TORCH_INDEX=…
# DGX Spark：arm64/CUDA13 的 torch 用 NVIDIA 官方轮/NGC 预装好再跑（脚本会跳过 torch 安装）。
```

脚本幂等：建 venv → 依赖闸（`QwenImage21Pipeline` + `Qwen3VLForConditionalGeneration`
导得进来就跳过安装）→ 模型没落盘自动 modelscope 下载（数十 GB，落 `./models/qit`；
`-DitGguf`/`DIT_GGUF` 时跳过 transformer 大权重）→ 前台起服（Ctrl+C 停）。
前提：**python 3.11~3.13**（diffusers git 主干需 ≥3.11——2026-11-12 实案：3.10 装
依赖才被拒；3.14 torch 轮子未跟上）与 git 在 PATH；PATH 里没有就
`$env:QI_PYTHON`（PS）/ `QI_PYTHON=…`（bash）指到便携版 python.exe——本机即用
`E:\dev-tools\python312\tools\python.exe`（NuGet 官方包解压，免安装）。

<details><summary>手动步骤（脚本等价展开 / 排障用）</summary>

```bash
python -m venv .venv && . .venv/bin/activate     # Windows: .venv\Scripts\activate
pip install torch torchvision --index-url https://download.pytorch.org/whl/cu124  # 按宿主 CUDA 调整
pip install -r requirements.txt                   # diffusers 从 git 主装（见文件内注释）
modelscope download --model Qwen/Qwen-Image-2.1-Turbo --local_dir ./models/qit
QI_REPO=./models/qit QI_API_KEY=sk-wc-自己的随机串 python server.py
```

</details>

启动即后台预热加载（首个请求不会卡十分钟下载）；`curl http://127.0.0.1:8899/api/health`
看到 `model_status:"ready"` 即可用。

## 环境变量

| 变量 | 默认 | 说明 |
|---|---|---|
| `QI_REPO` | `Qwen/Qwen-Image-2.1-Turbo` | ModelScope repo id 或本地模型目录 |
| `QI_DIT_GGUF` | 空（safetensors） | 本地 DiT GGUF 路径（16GB 卡主配方）；设了则下载跳过 transformer 大权重、`from_single_file` 装载 |
| `QI_MODEL_ID` | repo 末段 | `/v1/models` 报出的生图 id = 汪柴生图下拉项 |
| `QI_CHAT_MODEL_ID` | `Qwen3-VL-8B-Instruct` | `/v1/models` 报出的 chat id = apiModels 扩写档的模型名 |
| `QI_API_KEY` | 空（免鉴权） | 汪柴「API key」须填同值；局域网/公网部署**必须设** |
| `QI_HOST` / `QI_PORT` | `0.0.0.0` / `8899` | 监听；8888 留给 unsloth |
| `QI_DTYPE` | `bf16` | `bf16/fp16/fp32`；无 CUDA 自动退化 fp32（能跑，很慢） |
| `QI_OFFLOAD` | `none` | 显存紧：`model`（推荐，速度换显存）或 `sequential`（更省更慢） |
| `QI_TE_DEVICE` | `cpu` | TE 驻留档：`cpu`（TE 常驻系统 RAM，实测显存 0 占用；**16GB 卡必选**）或 `cuda`（大显存常驻上卡） |
| `QI_TE_KEEP_SEC` | `120` | TE 空闲回迁 TTL 秒（仅 `cuda` 档生效；cpu 档 TE 从不上卡） |
| `QI_SKIP_DIT` | 空 | `1` = TE-only 验收档：DiT 不装载、生图端点 503，chat/扩写全功能 |
| `QI_CHAT_TEMPERATURE` | `0.7` | chat 端点缺省采样温度（请求体可覆盖；0=greedy，扩写要稳可传 0） |
| `QI_CHAT_MAX_TOKENS` | `512` | chat 端点 max_new_tokens 上限（请求体更大值被钳到此） |
| `QI_STEPS` | 8 | Turbo 忽略之（调度烘焙在 checkpoint）；换非 Turbo 仓才生效 |
| `QI_CACHE_DIR` | SDK 自管 | ModelScope 下载缓存 |

## 汪柴接入

设置 → API 接入 → 🎨 图像生成：

- **服务地址**：本机 `http://127.0.0.1:8899`；局域网 `http://<宿主IP>:8899`；
  tailnet 远程 `http://<主机>.tailnet.ts.net:<映射端口>`（tailnet 内 http 即加密，
  与 unsloth 8888 的接入口径一致）。
- **API key**：与服务端 `QI_API_KEY` 同值（存汪柴安全存储）。
- **模型**：点「测试连接」后从下拉选（就是 `QI_MODEL_ID`），不用人手填。
- **提示词扩写（确认卡流）**：设置 →「API 接入 → 模型服务」加一档 API 模型：
  baseUrl `http://127.0.0.1:8899/v1`、模型名 = `QI_CHAT_MODEL_ID`（`/v1/models`
  可见），然后在「图像生成」节的「扩写模型」下拉选中它。🎨/「/图」发送后先出
  确认卡（可编辑 / 用原话 / 重扩），确认才起 job；扩写档不可用/失败自动直发，
  永不阻塞（`app/lib/services/image_prompt_rewriter.dart` 降级纪律）。
  ⚠️ 扩写档指向 unsloth 8888 是死路——其 TE 拆头不可 generate（见文首）。
- 与 unsloth 并存 = 两行地址切着用；建议同时只开一个服务，双开注意显存。

协议契约（客户端实现 `app/lib/services/image_gen_service.dart` 与
`app/lib/services/image_prompt_rewriter.dart` 为准）：
`/api/health` 免鉴权秒回（含 `chat_model`/`te_residency`/`dit` 诊断字段）；
`/v1/models` Bearer，key 不符回 401
`{"error":{"message":"Not authenticated","type":"authentication_error"}}`，
成功回**双 id**（生图 + chat）；`/v1/images/generations` 收 `model?/prompt/negative_prompt?/n(1-4)/"WxH"/
b64_json/seed?`，尺寸钳 [256,2560] 且 16 对齐（放得下官方竖图例 1696×2528）；
`/v1/chat/completions` 收 OpenAI 形 `messages`（str 或 text-parts）+
`temperature?/max_tokens?/stream?`，非流回 `chat.completion`（含 usage），
流式回 SSE `chat.completion.chunk`（`delta.content` 增量 → `finish_reason:stop`
→ `data: [DONE]`）——`model` 字段宽松（单模型壳）。**三端点共用 `_gen_lock`
全局串行**（显存单飞：扩写与出图互斥排队，排队不 429，
客户端超时档 1024² 内 120s / 2048² 300s 已含排队预算）。

## 契约单测（不起模型）

```bash
.venv\Scripts\python.exe test_server.py   # Windows；Linux 用 .venv/bin/python
```

假 `_pipe` 打全契约：health 字段 / models 双 id+鉴权三态 / generations 参数
校验与 b64+seed 回声 / chat 非流式+流式（SSE 形状逐块断言）/ chat×generations
并发 `_gen_lock` 单飞断言。**25/25 全绿**（2026-11-13 实测）；改动 server.py 后必跑。

## 开放项（生图档 16GB 收口，2026-11-13 状态）

已完成：`convert_gguf_keys.py`（ComfyUI gguf → diffusers 键名，265 张量对齐
验证过）+ server.py 手工三步组装（`load_gguf_checkpoint` →
`_replace_with_gguf_linear` → 逐参数装载，绕开 0.43-dev 的
from_single_file/from_pretrained 双坑——前者无 GGUF 实现、后者文件发现不认
.gguf 名，均已实证）+ img_mlp `gate_up → gate_layer/proj` 行切拆分映射。

待收口：①norm 布局对账——gguf `attn.norm_q/norm_k (512,)` 与 2.1 config
`head_dim 128` 的 4× 差、`norm_out.linear (16384,4096)` vs 模型 `(4096,4096)`，
疑 unsloth 转换布局差异，需对照 ComfyUI 原版 checkpoint 实证；②TE int8/fp8
上卡（~8.5G）与 DiT GGUF 共卡的量化精度与可搬运性评估（TE bf16 17G 上卡已
实证不可行——整卡塞满 16042/16311 MiB）。`QI_SKIP_DIT=1` 为现行 TE-only
验收档：chat/扩写全功能实测通过，生图端点 503。

## 硬件宿主

- **16GB 消费卡（本机 geekpro RTX 5060 Ti 实案）**：TE bf16 17G 装不下卡
  （2026-11-13 nvidia-smi 实证），默认档 `QI_TE_DEVICE=cpu` TE 常驻 RAM——
  chat 扩写实测 20.8s/80token（CPU），生图端到端等 DiT 显存方案二轮收口
  （候选 TE int8 上卡，见文首开放项）。**勿与本地 24B/27B 聊天模型同时
  拉满 RAM**；50 系 Blackwell torch 必须 cu128+（脚本默认）。
- **DGX Spark（GB10 · 128GB 统一内存）**：`TE_DEVICE=cuda ./start.sh` 全常驻
  （TE 17G 上卡 + safetensors DiT 驻留都装得下）。注意 arm64 装 torch 用
  NVIDIA 官方轮/NGC 容器，不照抄 cu124 索引。
- 单卡单飞：与 unsloth 同宿主同卡时错峰用，或其中一个 offload。

## 许可（go/no-go 口径）

模型挂 **Qwen RESEARCH LICENSE（2026-09-20，杭州通义实验室）**，原文条款：
“Non-Commercial shall mean for research or evaluation purposes only”、
“You shall not use the Materials for any commercial purpose without obtaining
a separate commercial license”（商用申请：model-business@notice）。

即：**个人研究/评测可用；任何商用用途须先向通义取得商用授权**。汪柴只是
接入通道，用途合规责任在部署者——服务启动横幅与 `/api/health` 都会打印
此提示。对外提供生图服务（哪怕内部小圈子）前先过这一关。

## 排障

- **汪柴报「服务不可达」**：服务没起 / 端口没放行（firewallo 或 `tailscale serve`
  没映射）。`tailscale serve` 映射的 `:8888` 那类是**明文监听**，客户端用 `http://` 别用 `https://`。
- **绿灯但生图 503**：`model_status` 还是 loading/error，看 health 的 `detail`
  与服务端控制台。
- **401**：两端 key 不一致（服务端 env vs 汪柴安全存储）。
- **diffusers 报不认识 QwenImage21Pipeline**：PyPI 旧版 diffusers 在作怪，
  必须 `pip install git+https://github.com/huggingface/diffusers.git`（requirements 已锁）。
