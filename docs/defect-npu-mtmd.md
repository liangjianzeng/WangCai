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

## 2026-11-07 深夜战役第二幕：破案（磁盘伪象 + 真病根）与修复落地

### 取证转折（tmp/omni-matrix/logs/mtmdcli_fix5..r4.log，全程串行独占）

1. **fix5-8 的「WeightlessCacheAttribute 丢失」全是磁盘 100% 满的 I/O 伪象**。
   战役期间 E: 盘被历次矩阵 cache 吃到 100%（剩 6.3MB，tmp/omni-matrix/cache
   独占 88GB）；清理 85GB 后净盘复验 R2（fix5 完全同款条件、无任何新 env）：
   **7 次编译（LLM 主图 + 6 段 ViT）全部通过**，WS 报错消失。NPUW 的
   weights separation 流要落盘权重文件，满盘下报出误导性的属性检查错。
   （旁证：R1 的 `ios_base::badbit` 即序列化写盘失败；fix9ir 抢到最后
   1.3GB 空间写 dump 后磁盘见底。）
2. **「绕开 NPUW」是死路（fix8 实证，结论保留）**：erase NPU_USE_NPUW +
   清 NPUW_* 后编译 3 分钟通过，但 L0 `pfnAppendGraphExecute` 拒绝执行
   （`ZE_RESULT_ERROR_INVALID_NATIVE_BINARY — BufferInfo already exists`）。
   NPU 设备必须要 NPUW 管线——修复方向必须是让图过 NPUW，不是绕开。
3. **真病根 = sched 切段产物无 inp_pos**：净盘后失败点稳定为
   `get_inp_pos_tensor: inp_pos not found in cgraph`（46 节点尾段）→
   `clip_encode failed -1`。链条：CLIP 图的 FLASH_ATTN_EXT 不被 OV 后端
   支持（warmup 实证）→ sched 把 clip 图切成 OV/CPU 交替段（OV 段
   87/52×5/46 节点）→ 不含 ROPE 的尾段没有 inp_pos 输入 →
   `ov_graph_compute_static` 无条件 `get_inp_pos_tensor` 抛异常。
   **11-03 原发缺陷 `clip_encode failed -1` 的真身即此**（当时无 trace
   不可见）。fix9ir/R2 中 5 个含 vision ROPE 的段全部编译通过，佐证
   「有无 inp_pos」是唯一分界。
4. **代码核对勘误**：translate_session.cpp `translate()` 的
   WeightlessCacheAttribute 打标循环在公共路径（naive 分支只跳过
   preprocess）——战役期间「naive 产物不带标」的注释是磁盘时代误诊。

### 修复（utils.cpp / utils.h，未提交）

- 新增 `find_inp_pos_tensor`（找不到返回 nullptr 不抛）；
  `get_inp_pos_tensor` 改为薄壳（找不到才抛）。
- `ov_graph_compute_static`：无 inp_pos 的静态图早退分流
  `naive_compute`（一次性 translate+compile+infer，无 KV/位置语义可依；
  擦 `NPUW_FUNCALL_FOR_ALL` 视觉片段同款保护）。代价：naive 无编译缓存，
  server 每张图多一次尾段编译（秒级）。
- 拆除 naive_compute 两处 `NPUW_WEIGHTS_SEPARATION=false` 地雷（该键在
  NPU 插件配置表不存在，fix6 实证 NOT_FOUND assert）。

### 验证（验收线：ctx≥2300 + 图出正确读图回答）

- **R3（2560 ctx + 128px 纯红图）PASS**：46 节点尾段走 naive 编译执行成功，
  `mtmd batch encoding done in 24163 ms`（首图冷编译总成本），embd 注入后
  LLM 图 3 个变体编译通过，回答「**这张图是红色的**」——正确。
- **R4（2560 ctx + 1920×1200 纯红壁纸 ≈2017 vision tokens）PASS**：
  `encoding done in 433775 ms`（大图全冷编译），回答「这张图的整体颜色是
  **红棕色**（色调偏红…颜色比较均匀）」——纯红图经 ViT 采样偏暗红，
  判定本质正确。
- **server E2E（llama-server，app 同款参数/env：-c 2560 -fa 1 -dev
  OPENVINO3 --jinja --no-warmup + 四件套 env）PASS**：OpenAI 格式带图请求
  （image_url base64），`loaded multimodal model` 后 health 155s，回答
  「这张图主要是**红色**…几乎没有其他颜色」（prompt 82 tok、生成 63 tok
  @ 10.15 t/s）——无 500、无 clip_encode -1。decode 10.1 t/s 较纯文本线
  （21.9）偏低，为带图变体图首次编译后的首请口径，后续优化项记录在案。

### 遗留与后续

- 尾段 naive 无编译缓存：每张图一次尾段编译（秒级）；不同尺寸图的 ViT
  段形状各异，各自冷编译（大图首编 ≈7 分钟）——后续可做 per-shape 缓存
  与预编译预热。
- 4096+mmproj 编译管线卡死（第一幕现场 1）未单独复验——净盘后疑似同源
  （磁盘压力/编译队列），下次带图 4096 场景实证后闭环。
- conv_spatial RESHAPE 动态维度警告（第一幕现场 2 的伴生信号）实测非致命
  （翻译继续走完、结果正确），降级为噪声日志观察项。
