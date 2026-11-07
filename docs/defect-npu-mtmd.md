# 缺陷：NPU/OV 后端 mtmd（视觉编码）计算失败

- 发现：2026-11-03（M3-c 多模态真机验证，汪柴助手 v0.0.2）
- 现象：`LFM3-Omni-2B-Q4_0.gguf` + `mmproj-LFM3-Omni-2B-Q4_0.gguf`
  在 wangcai fork llama-server 上加载成功（`loaded multimodal model`），
  带图请求（OpenAI image_url base64 content part，一张 1920×1200 JPG，
  编码为 ~2016 vision tokens）后：

  - `-dev OPENVINO3`（NPU）：`E clip_encode: ggml_backend_sched_graph_compute
    failed with error -1` → `failed to process mtmd chunk`
  - `-dev OPENVINO0`（CPU-OV）：`E graph_compute: ... failed with error -1` →
    `failed to decode mtmd chunk ... res = -3` → 同错

- 范围：引擎层（`src/llama` fork 的 ggml-openvino 后端），与壳无关 ——
  壳侧链路（--mmproj 渲染、image_url 组包、base64、错误如实传播）已由
  `app/test/platform/multimodal_npu_test.dart` 验证为正确。
- 影响：NPU/OV 线**识图不可用**；`-c 512` 时还会先撞
  `request (2016 tokens) exceeds ctx`（识图场景 ctx ≥ 2300，建议 4096）。
- 工作线（v0.0.2 采取）：识图 DoD 归**官方 llama.cpp 引擎（引擎商店
  CUDA/Vulkan）+ 官方支持 mtmd 的 VL 模型**；NPU 线做纯文本。
- 修复线索（引擎侧）：mtmd 的 clip 图与 LLM decode 图在 OV 后端的
  sched 分配；怀疑 ggml-openvino 对 clip/ViT 图的支持缺口（错误在
  chunk 13/末批，疑似 token 类型或 RoPE 分支）。

## 2026-11-07 深夜战役取证（b12034 引擎 + 本日 NPU 视觉修复战）

三份新现场（`tmp/omni-matrix/logs/`，全部串行独占取证）：

1. **ViT 图翻译期卡死**（4096 ctx + mmproj）：`loaded multimodal model` 后
   health 永不就绪，日志停在 `ov-mask prefill=1`（启动后 0.03s）→ 10 分钟
   零新行 → **主图/mmproj 图编译管线卡死**。
2. **2560 ctx + mmproj + 发图（壁纸 1920×1200）**：主图编译过了（health
   174s），发图后翻译器连环刷
   `cannot determine dynamic dim for RESHAPE node 'conv_spatial-* (permuted)
   (cont) (reshaped)'`（ViT patch-embedding 卷积输出 reshape 链的动态维度
   解析失败，`ggml-decoder.cpp` RESHAPE 分支）→ 6 秒后**翻译完全停摆**，
   无错误栈（curl 300s 超时取消）。形态比 11-03 的 `compute -1` 更早期：
   **翻译期卡死取代计算期失败**。
3. **`--no-mmproj-offload`（clip 留 CPU）+ 小图 128px**：不卡了，快速返回
   `failed to process mtmd chunk`——失败点后移到 **LLM prefill 注入 vision
   embedding** 段；且日志线程竞争严重（错误行被吞、W 行交错堆积）。
4. 对照 `-dev OPENVINO0`（OV-CPU 设备）+ 小图：请求同样长时间无响应——
   倾向 **OV 后端对 mtmd 图的通病**（CPU 编译管线慢未完全排除）。

**修复战役计划（引擎 C++，src/llama/ggml/src/ggml-openvino 镜像）**：

- 第一刀：`ggml-decoder.cpp` 动态维度传播对 `conv_spatial` RESHAPE 链的
  失败处理——假设：解析失败 → 翻译器走动态 shape 模式 → OV reshape/
  recompile 循环卡死；实验性一刀 = 该链强制静态化（判定失败即锁静态 +
  翻译前 dump 该子图拓扑），先拿「能编译完」再说正确性。
- 前置：给翻译主循环加 per-node trace（env 开关，如
  `GGML_OPENVINO_TRANSLATE_TRACE`）——三个现场全是静默停摆，没有 trace
  定位不到确切停摆节点。
- 第二刀：mtmd chunk 的 embedding 注入路径（现场 3）与日志线程竞争
  （错误被吞）。
- 验收：2560/4096 ctx + mmproj + 壁纸图出非空正确读图回答，速度与 NPU
  文本线同量级。
