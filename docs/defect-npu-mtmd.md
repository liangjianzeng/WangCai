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
