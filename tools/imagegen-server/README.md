# 汪柴生图服务（Qwen-Image-2.1-Turbo · diffusers 直调）

第二条生图链路的**服务端**：不依赖 unsloth Studio，直接用 diffusers
`QwenImage21Pipeline` 跑 [ModelScope Qwen/Qwen-Image-2.1-Turbo](https://modelscope.cn/models/Qwen/Qwen-Image-2.1-Turbo)，
对外暴露与 unsloth 完全同构的三端点 OpenAI 协议壳——**汪柴客户端零改动**，
设置页换个地址就能切链路。评估结论与方案沿革见
`docs/image-gen-integration-plan.md` 同族讨论（2026-11-10 拍板「施工」）。

| | unsloth Studio（现有主链路） | 本服务 |
|---|---|---|
| 端口 | 8888 | **8899**（默认，互不打架） |
| 模型 | Studio 扫描目录（如 flux 系） | Qwen-Image-2.1-Turbo 单模型 |
| 中文渲染/文字海报 | 一般 | 强（Qwen-Image 系卖点） |
| 采样 | Studio 管理 | checkpoint 内置 8 步，CFG=1（`num_inference_steps`/负向提示不生效，协议照收） |
| 定位 | 日常出图 | 中文图/海报向 + unsloth 不可用时的备胎 |

## 快速开始（一键脚本）

```powershell
# Windows 宿主（N 卡）：
cd tools\imagegen-server
.\start.ps1 -ApiKey sk-wc-自己的随机串
# 常用开关：-Repo D:\models\qit（模型已下别处）· -Offload model（显存紧）
#          -Port 8899 · -Dtype bf16 · -TorchIndex …（本机 CUDA 非 12.4 时换 torch 源）
```

```bash
# Linux 宿主（WSL 自测 / DGX Spark 正式）：
cd tools/imagegen-server
QI_API_KEY=sk-wc-自己的随机串 ./start.sh
# 常用开关：REPO=/data/models/qit · OFFLOAD=model · TORCH_INDEX=…
# DGX Spark：arm64/CUDA13 的 torch 用 NVIDIA 官方轮/NGC 预装好再跑（脚本会跳过 torch 安装）。
```

脚本幂等：建 venv → 依赖闸（`QwenImage21Pipeline` 导得进来就跳过安装）→
模型没落盘自动 modelscope 下载（数十 GB，落 `./models/qit`）→ 前台起服（Ctrl+C 停）。
前提：系统 python 3.10+ 与 git 在 PATH（requirements 含 git+ 行）。

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
| `QI_MODEL_ID` | repo 末段 | `/v1/models` 报出的 id = 汪柴设置页下拉项 |
| `QI_API_KEY` | 空（免鉴权） | 汪柴「API key」须填同值；局域网/公网部署**必须设** |
| `QI_HOST` / `QI_PORT` | `0.0.0.0` / `8899` | 监听；8888 留给 unsloth |
| `QI_DTYPE` | `bf16` | `bf16/fp16/fp32`；无 CUDA 自动退化 fp32（能跑，很慢） |
| `QI_OFFLOAD` | `none` | 显存紧：`model`（推荐，速度换显存）或 `sequential`（更省更慢） |
| `QI_STEPS` | 8 | Turbo 忽略之（调度烘焙在 checkpoint）；换非 Turbo 仓才生效 |
| `QI_CACHE_DIR` | SDK 自管 | ModelScope 下载缓存 |

## 汪柴接入

设置 → API 接入 → 🎨 图像生成：

- **服务地址**：本机 `http://127.0.0.1:8899`；局域网 `http://<宿主IP>:8899`；
  tailnet 远程 `http://<主机>.tailnet.ts.net:<映射端口>`（tailnet 内 http 即加密，
  与 unsloth 8888 的接入口径一致）。
- **API key**：与服务端 `QI_API_KEY` 同值（存汪柴安全存储）。
- **模型**：点「测试连接」后从下拉选（就是 `QI_MODEL_ID`），不用人手填。
- 与 unsloth 并存 = 两行地址切着用；建议同时只开一个服务，双开注意显存。

协议契约（客户端实现 `app/lib/services/image_gen_service.dart` 为准）：
`/api/health` 免鉴权秒回；`/v1/models` Bearer，key 不符回 401
`{"error":{"message":"Not authenticated","type":"authentication_error"}}`；
`/v1/images/generations` 收 `model?/prompt/negative_prompt?/n(1-4)/"WxH"/
b64_json/seed?`，尺寸钳 [256,2560] 且 16 对齐（放得下官方竖图例 1696×2528）；生成全局串行锁（排队不 429，
客户端超时档 1024² 内 120s / 2048² 300s 已含排队预算）。

## 硬件宿主

- **本机 geekpro N 卡**：bf16 全卡驻留需 ~60GB 级显存，消费卡基本要
  `QI_OFFLOAD=model`（速度换显存）；先 `nvidia-smi` 核对容量再定。
- **DGX Spark（GB10 · 128GB 统一内存）**：首选宿主，bf16 `none` 直接驻留。
  注意 arm64 装 torch 用 NVIDIA 官方轮/NGC 容器，不照抄 cu124 索引。
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
