# 更新日志

WangCai 所有值得记录的改动都在这里。格式遵循
[Keep a Changelog](https://keepachangelog.com/en/1.1.0/)，项目计划在打出第一个 tag 后遵循
[语义化版本](https://semver.org/spec/v2.0.0.html)。

Unreleased 段落里的日期是"该改动在硬件上被验证的日期"，不是写文档的日期。

## [Unreleased]

2026-11-01/02 在硬件上验证的四批改动。

### 新增 —— 跨模型验证（副靶 Spark-X2.6-4B + Qwen3-4B 复测）

- **副靶立项并通过**：讯飞 Spark-X2.6-4B（标准稠密 Transformer，与 LFM3 混合架构不同系）端到端跑通
  全部路径：native ✓（151.9/19.9 t/s）、OV-CPU 动态 ✓（77.4/8.2）、OV-CPU 静态三问 3/3、
  **NPU 三问 3/3**（chunk128 + 禁 levels，decode 2.4 t/s）。
- **Qwen3-4B NPU 复测翻案**：2026-10-31 记录的"从第一步单 token 塌缩（GGGG…）"在当前引擎上
  不再复现——副靶配置（chunk128 + 禁 levels + c512）下输出连贯且**三问验收 3/3**。两个外部模型
  家族全部通过 NPU 精度验收，引擎翻译层跨模型成立的第一个实证。
- NPU 4B 预算实测：默认配置（chunk256 + levels）在图编译完成后**执行期**撞
  `ZE_RESULT_ERROR_OUT_OF_HOST_MEMORY`（系统 RAM 空闲 28.8 GB，驱动侧预算）；levels 开启反而更慢
  （level 图与权重 bank 竞争预算）。副靶配置脚本 `tools/spark-npu-accept.ps1`。

### 修复 —— u4 权重宿主视图 + 精确 f16 零点（横切所有模型）

- **u4 无法包宿主内存**：这份 OV 构建里 `ov::Tensor(u4, shape, ptr)` 与
  `ov::Constant(u4, shape, raw_ptr)` 都抛 `is_pointer_representable`（i4/u8 通过）——所有非对称
  4-bit 路径从未可用：native Q4_K/Q4_1 的 OV-CPU 路径（Q4_K_M 是最常见 checkpoint 格式）与
  `REQUANT_KQUANT=q4_asym64*`。三层修复：`wrap_or_detach` 内部分配+回写槽位、
  `make_int4_weights` unsigned 分支改由 Tensor 拷贝构造 Constant、`count_bad_f16` 只校验 f16
  元素类型的 scales/zp（u4 zp 上 `data<f16>()` 本身就是抛出点）。修复后 q4_asym64_all 实测
  151.6/28.9 t/s。
- **native 非对称提取统一精确 f16 零点**：整数 zp 的 `round(min/scale)` 舍入让 LFM3 静态图思考
  退化成 "\n" 死循环（动态路径侥幸正确；MoE 专家因同一误差早已改 f16）。推广到全部 native 非对称
  提取（Q4_K/Q4_1/Q5_1/Q5_K），`extract_quantized_weights`/`process_weight_tensor`/
  `get_extracted_layout` 三处同步。修复后 LFM3 与 Spark 的 OV-CPU 静态三问**无 env** 全 3/3，
  `accept-smoke.ps1` 的 requant env 已摘除。

### 新增 —— 引擎（decode 性能主攻）

- **多跨度离散 decode 图组（缺陷 2 根因①的修复）：NPU decode 14–15 t/s 且与上下文长度无关。**
  按 PAD(n_kv,256) 离散级别（256/512/…/ctx）每级一张全静态 decode 图，llama.cpp 每步按当前 n_kv
  选级；KV cache 参数与绑定按级别裁视图，每步状态 I/O 与该级别成正比；编译新级别前驱逐旧级别
  （NPU 设备预算 = prefill + 一张 decode 图，第二张常驻在首次 execute 即
  ZE_RESULT_ERROR_UNINITIALIZED）；级别切换时把 KV 的 [fill,span) 段清零（跨级别正确性保障，
  A/B logits 逐位一致）。实测：c=8192 从 0.9 → 14.1 t/s（**17×**）、c=2048 从 3.3 → 14.3（4.5×）；
  600-token 任务跨 256/512/1024 三级切换全程无错；token 流不同 ctx 逐字节一致。逃生门
  `GGML_OPENVINO_DISABLE_DECODE_LEVELS=1` 回退全 ctx 单图，`GGML_OPENVINO_NO_KV_ZEROIZE` 调试用。

### 新增 —— 引擎（音频）

- **NPU 音频输入端到端跑通。** raw-embd 块补齐（chunk-pad）与动态 token 维传播
  （`compute_node_dynamic_dims` 对 raw-embd 叶子置 1）；此前 Reshape 把捕获的 [1,1,38,2048] 烤进图，
  对补齐后的 [1,1,256,2048] 形状推理失败。NPU 回答连贯，与 f32 参照有 top-1 级分歧
  （与文本自由生成已记录的 f16 复利行为同类）。

### 新增 —— 测量基建

- `GGML_OPENVINO_PROFILING=1`（每步 Graph inference / OV raw infer 分解）与 `=2`（静态路径逐节点
  CSV；注意 CSV 写入进程 CWD、-n N 只覆盖前 N+1 个文件、逐节点总和可超 wall time——DPU/DMA 并行
  记账）。缺陷 2 的三项根因（状态往返 ~32 ms/步@c512、全 ctx 跨度注意力超线性、lm_head 11 ms）
  即由此定案。

### 探针 —— stateful 路线证伪（tools/npu-probes/）

- NPU（OpenVINO 2026.4.1）**支持 VariableState**：query_state 正常、状态跨 infer() 在设备侧累积
  （初始值张量被忽略、按 0 初始化）。但每步成本 ≈5–6 ms/MB（0.18 GB/s）线性放大——8.4 MB KV 量级
  state 43–45 ms/步，比参数绑定（全步骤 6.1 ms，≈1.4 GB/s）**慢 7 倍**：每次 infer() 都走慢速状态
  检查点路径。**结论：设备驻留 KV 路线反模式，参数绑定 + 级别裁剪是当前最优架构**；defect-2 下一
  独立杠杆为 lm_head（11 ms/步）。附带教训：平铺 [1,N] 大形状 elementwise 图会让 NPUW 编译爆炸。

### 修复 —— 工具

- **accept-smoke Q3 "flake" 定案为测试基建 bug**：判定 `-match '2'` 匹配整个日志，性能行
  `[ Prompt: 23.7 t/s | Generation: 29.0 t/s ]` 的 t/s 数字随机含 '2' 造成假通过/假失败；且 n=48
  对思维链模型太短（note-4 幻觉在动/静态路径逐字节一致，非引擎回归）。修复：只匹配答案区段
  （回显 prompt 与性能行之间）+ 默认 n=96；修复后 3 轮 3/3 完全确定。

### 修复 —— 引擎（音频回归 + 设备预算自愈）

- **NPU 音频回归三层因果链闭合，输出与 native Q8_0 参照逐字一致。** ①NPU 默认把 Q4_0 重分组到
  group-128 对称，对 mmproj conv 栈是纯损失（嵌入 cos 0.963、范数 +12%，答案在 <think> 后即 EOS）
  ——`a.`-前缀编码器张量豁免走 native（0.9997），LLM 权重保持 128（native 化掉 40% 吞吐）；
  ②CPU 静态与 NPU 的 LLM 量化需一致（`q4_sym128_all`），音频答案在边际敏感区被量化差翻转
  （文本同幅度 KV 分歧 layer12=0.73 不受影响）；③Omni-2B decode level 图撞设备预算
  （ZE_RESULT_ERROR_UNINITIALIZED，缺陷-7 族，非确定性）。
- **level 图设备预算自动降级重试**：level 图 `infer()` 撞 UNINITIALIZED 时自动清空全部 level
  缓存、置进程级开关并重试一次 full-ctx decode 图——Omni-2B NPU 音频零 env 跑通，1.7B 不触发。
  实现坑：entry mutex 非递归（持锁重入 EDEADLK，改 unique_lock + unlock）；降级后的 ctx 图
  必须发布进 ctx-pair 缓存，否则每 token 重编译。
- **热启动 23 s → 8.9 s**：requant 全量物化路径行分块并行（发现 ov::parallel_for 在无
  TBB/OpenMP 的构建里是串行回退，改用 std::thread 池；chunk 对齐偶数块保 u4 zp 字节对）；
  make_dirs 盘符 bug（`_mkdir("D:")` EACCES 曾使 COMPILED_MODEL_CACHE_DIR 在 Windows 静默失效）；
  多级图接入 COMPILED_MODEL_CACHE_DIR（NPU 上与共享权重 bank 冲突，保持 opt-in 关，探针定案）。

### 修复 —— 引擎（视觉静态精度，两个根因连定案；NPU 视觉端到端收官）

- **根因①：cacheless 图的 `compute_params.input_len == -1` + size_t 回绕 → 多平面位置表读越界。**
  cacheless 图（mtmd 视觉编码器走显式 softmax，不走 FLASH_ATTN_EXT）没有任何代码给 `input_len`
  赋值，K/V 路径（ggml-decoder.cpp）与 cacheless FLASH_ATTN_EXT 扫描都只覆盖 KV 注意力图。作为
  size_t 它回绕到 2^64-1，多平面 inp_pos 绑定的平面步长 `p * input_len` 回绕成 `-p`，第 2/3/4
  平面从缓冲区**前面**读 p 个元素——rope 角度按位置错位（out[p][s] = h(s-p)），编码器输出 cos 0.54。
  修复：平面长度是张量自身属性（`ne[0]` 已堆叠 4 个平面），改从 `ne[0]/n_planes` 读取。修复后
  CPU 静态 node_416 与 native **逐位一致**（cos 1.00000，maxabs 0）。
- **根因②：NPUW 配置三元组在 clip 图上静默损坏编码器。** 引擎 NPU 默认编译配置里
  `NPU_USE_NPUW + NPUW_FOLD + NPUW_FUNCALL_FOR_ALL` 的组合把视觉编码器在 NPU 上打歪
  （同一 IR python 直接编译 cos 0.995，引擎配置路径 0.557；python 逐键二分定位到最小坏三元组，
  单键与两两组合全部干净）。clip 图的 softmax 没有 mask 输入，`is_cacheless_attn` 不置位，
  于是它吃到的是完整 NPUW 配置而非 `without_npuw` 过滤后的——三元组因此漏进了视觉图。
  修复：视觉 rope 图（`GGML_ROPE_TYPE_VISION`）编译时擦除 `NPUW_FUNCALL_FOR_ALL`；
  `extra_cfg` 3→4 使旧坏 blob 失效。修复后 NPU 视觉端到端描述与 native 一致，文本三问 3/3。
- **视觉 rope tile 扩展回退**：本轮曾把 decode 图的 cos/sin 头轴 tile 扩展到 VISION prefill
  （假设 NPU 视觉缺陷是同一头轴广播）——被证伪（tile 生效后 cos 不变），按位中性但理由不成立，
  回退到 LLM decode 专用，避免误导后来人。
- **TEMP 插桩拆除**：VISROPE（openvino/utils.cpp、rope.cpp）、PERFTRACE（decode 分支）、
  WARMTRACE 标记 TEMP 的 requant 计时块全部移除。

### 性能 —— 引擎（NPU 视觉编码 12.6 s → 0.54 s：插件 blob 缓存补位）

- **上一轮的"5061 ms 编码"是冷态假象**：单次冷跑把每进程 clip 重编译计进了编码时间。
  行级计时分解：clip 图 NPU **纯推理**本来只要 147–191 ms（python 直测同一 IR），真正的开销是
  **每进程 ~12.2 s 的全量 NPUW 重编译**；warm `mtmd batch encoding` 实际 12.6 s。
- **根因**：NPU 编译配置只设 `NPUW_CACHE_DIR`（NPUW 自身的 funcall/子图分解缓存），从不设
  `ov::cache_dir`（插件 blob 缓存）。视觉编码器权重烤成 `ov::Constants`，NPUW 缓存对它**永不命中**；
  LLM 图走 shared weights bank 路线 NPUW 缓存正常命中（~2.3 s），所以缺陷只在视觉侧暴露。
  python 实证：NPUW-only 每次 12–13 s；补 CACHE_DIR 后同一 IR 命中 0.41–0.74 s；视觉 IR
  跨进程逐位稳定（md5 相同，可安全命中）。
- **修复**：`ggml-openvino-extra.cpp` NPU 分支补插 `compile_config.insert(ov::cache_dir(cache_dir))`
  （`without_npuw` 路径剥 CACHE_MODE 但保留 CACHE_DIR，非 NPUW 路线接受该键）。修复后
  **warm encode 542 ms**（vs native 435 ms、OV-CPU 动态 956 ms），冷启动一次性 16.9 s；
  最终二进制验收：视觉描述正确、文本三问 3/3、音频 EXITCODE=0。
- **上游可报**：NPUW_CACHE_DIR 不覆盖权重烤成 Constants 的图——与 bank-aware blob import 同族。

### 新增 —— 引擎（视觉输入，探察）

- mmproj 含视觉编码器（133 v. 张量）。**native 与 OV-CPU 动态路径视觉端到端正确**（测试图描述
  与参照一致）；静态翻译与 NPU 卡在 4 段式视觉 rope 位置表（每 patch 4 行被当 4× token，
  Multiply [1,784,16,64] × [1,3136,1,64] broadcast 失败）——静态 rope lowering 的 mrope 分段
  支持列为下一工作项。

## [0.0.1] — 2026-10-31 · 汪柴首个版本

基线 `abb76ab`（llama.cpp）、OpenVINO 2026.4.1。

### 修复 —— 引擎（精度主缺陷，0.0.1 的收官修复）

- **NPU decode 答案质量的根因找到并修复（三问验收 3/3 首次全对）。** 铁证链：decode 图 K 分支
  pre-norm/post-norm 在 NPU 上完全正确（cos 0.997+）→ 缺陷只剩 RoPE；缓存 K 行只有偶数 128 块
  正确（h0/h2 逐位精确、h1/h3 摧毁，256 元素周期）；**位置 0 上 post-rope vs pre-rope 数学恒等，
  NPU 却算出 h1/h3 cos 0.38/0.49** → 静态 decode 图 RoPE 的 cos/sin `[1,1,1,128]` 沿头轴广播到
  `[1,1,4,128]`，在 NPUW 的 1-token（GEMV）形状降级下错误 tile；prefill 同构广播在
  `[1,1,256,4,128]` 上正确，故 prefill 无恙。修复：`rope.cpp` 把 cos/sin 沿头轴显式 Concat tile
  绕开隐式广播；`translate_session.cpp` 把 `AlignEltwiseOperandRanks` 的注册门从 `is_gpu()` 扩到
  gpu/npu/`FORCE_STATIC`——此前 NPU 上所有"tile 无效"实验都是被这扇门挡住的死代码（教训：改
  pass 注册门前，先拿 IR hash 确认 pass 真的在跑）。完整证据链与被证伪假设清单见
  [defect1-rootcause.md](docs/defect1-rootcause.md)。

### 修复 —— 引擎

- **越界 KV 写入（status.md 缺陷 3）根因找到并修复（2026-10-31 验证）。** llama.cpp 的 interleaved-SWA

- **越界 KV 写入（status.md 缺陷 3）根因找到并修复（2026-10-31 验证）。** llama.cpp 的 interleaved-SWA
  缓存为全量缓存与 SWA 子缓存各建一个 KV 写索引输入，且 `build_input_k_idxs()` 把两者命名为同一个
  `attn_inp_k_idxs`；解码器按名字注册参数（先到先得），SWA 的索引张量被全量缓存的同名张量覆盖。窗口层
  于是拿着全量缓存的 cell id（线性长到 `-c`）散射进只有 `n_swa` 大小的环——序列总长一越过 768（LFM3 的
  3×256），CPU 插件死于 `scatter_update.cpp:915` 断言，NPU 插件直接 `ZE_RESULT_ERROR_DEVICE_LOST`；
  `llama-perplexity` 也因此一直无法用作精度指标。这与注意力 mask 的同名冲突是同一类失败（mask 那次已按
  张量身份区分）。最终形态：prefill 图与动态路径按目的缓存所在层加 `_swa` 后缀；**静态 decode 图保持
  单一合并参数**（NPUW 对该图参数表结构敏感，多一个数值等价的参数会让每个 decode 步输出 NaN），越界
  改由图内 `Mod(索引, 环行数)` 处理——环内恒等，越环回绕。改名还要求每相位各自的 decoder 对象
  （`ptr`/`ptr_prefill`），否则一个对象被两相位经 `update_io` 反复重注册后必炸。原生 ggml 后端按张量
  指针绑定，所以从未受影响。修复后 `-p 1024 -n 32 -fa 1` 三条路径全通：原生 605 / OV-CPU 626 /
  NPU 368 t/s（pp1024）。证据：`GGML_OPENVINO_DEBUG_INPUT` 抓到第二 ubatch 的绑定值为 512..1023、
  cgraph 里 SWA 缓存仅 768 行。
- **`GGML_OPENVINO_DEBUG_NODE` 在 NPU 上改为显式拒绝（status.md 缺陷 4，2026-10-31 验证）。** 附加
  `Result` 节点此前会让 NPUW 在编译期死掉；现于 `translate_session.cpp` 直接拒绝并提示改用
  `GGML_OPENVINO_DUMP_BIN`。附带的新测量：在 OpenVINO 2026.4.1 上硬中止不再复现，但带附加 Result 编译
  出的 NPU 图 logits 全 NaN——拒绝同时挡住了一种静默劣化。

### 对照 —— 缺陷 5（异架构模型）

- 补上了缺失的对照模型（2026-10-31）：Qwen3-4B / 1.7B（纯 transformer）。NPU 的数值缺陷在 Qwen3 上同样
  出现（4B 在 `-c 1024` 还会执行期 `OUT_OF_HOST_MEMORY`），所以缺陷跟着"静态 NPU 路径"走，**不是 LFM3
  特有**；4B 放不下这一点也为 Phase 3 的"1–3 B 甜点区"猜想提供了第一个数据点。

### 新发现 —— 驱动状态污染

- 一次执行期的 `ZE_RESULT_ERROR_OUT_OF_HOST_MEMORY` 会把 NPU 驱动带进跨进程存活的坏状态：之后所有进程
  的原始输出回读（`get_output_tensor`）返回 NaN，而绑定缓冲的正常输出路径完全正确——**文本连贯、
  benchmark 正常、`GGML_OPENVINO_DUMP_BIN` 转储全 NaN**。换 DLL 版本、清 blob 缓存均无效；
  `pnputil /restart-device` 可恢复计算路径。见 [troubleshooting.md](docs/troubleshooting.md) 与
  [status.md 缺陷 6](docs/status.md)。

### 修复 —— 工具链

- `tools/build.ps1` 给 `$parallel` 和 `$clean` 赋值，而在 PowerShell 里它们**就是** `[int]$Parallel` 与
  `[switch]$Clean` 这两个参数（变量名大小写不敏感），于是 CI 在编译任何东西之前就死于
  `Cannot convert value "--parallel" to type "System.Int32"`。改名为 `$parallelArg` / `$cleanArg`。

### 更正 —— 文档

- [`docs/npu-internals.md`](docs/npu-internals.md) 里的逐层发散表原本是在 llama.cpp 的**预热** pass 上算的。
  `prefill_0`、`prefill_1`、`decode_2` 在"同一模型、不同 prompt"的两次运行之间逐字节相同，所以那条曲线描述
  的是合成输入，而不是 prompt。已在真实 chunk 上重测并替换（`l0 0.9956 · l9 0.873 · l13 0.534 · l17 0.163`）；
  该节现在以"用哈希比对给 pass 归类"的方法开头，并给出新的线索：**V 精确写入，K 只有第 0 行错**
  （余弦 `0.288`，最大绝对差 `1.06e10`）。
- `docs/env-vars.md` 曾写道 `GGML_OPENVINO_REQUANT_KQUANT` 在 NPU 上无效。在上面那个引擎修复之前这是对的；
  该行现在描述的是这个覆盖行为本身以及如何拒绝它。
- 本文件"已知问题"里的第一条曾引用 warmup 数据（`0.9987 / 0.72 / 0.215`），与上面的更正自相矛盾，已一并
  更正为真实 pass 的数字。

### 新增 —— 测量

- 原生 Q4_0 对照：`LFM3-1.7B-QAD-Q4_0.gguf`（ModelScope `LiquidAI/LFM3-1.7B-GGUF`，核对为 1 049 615 680
  字节）：220 token 的续写在原生 ggml CPU、OpenVINO-CPU 静态和 NPU 上**逐字节一致**；而 64 token 的中文指令
  任务仍然只在 NPU 上退化（conv 状态余弦 `decode_2 0.989 → decode_9 0.51 → 平台期 ≈0.25`，top-1 从第 10 步
  起发散）。作为方法论规律记录在案：**续写任务是通路测试，不是连贯性测试**——设备算错时它照样一致。
- 为多模态阶段编目 `LFM3-Omni-2B-GGUF`：`Q4_0` / `Q4_K_M` / `Q8_0` / `F16` 权重，外加
  `mmproj-LFM3-Omni-2B-{Q8_0,F16,BF16}.gguf` 投影器（540 MB / 950 MB）。

### 修复 —— 构建

- 后端 `CMakeLists.txt` 里的 `find_package(OpenCL REQUIRED)` 让后端在任何没装 OpenCL SDK 的机器上连*配置*
  都过不去（`Could NOT find OpenCL (missing: OpenCL_LIBRARY OpenCL_INCLUDE_DIR)`）——也就是每一台纯 NPU
  机器。这个依赖是虚构的：后端调用的每个 `cl*` 入口点在 `ov_opencl_shim.hpp` 里都有内联桩，所以根本没有
  东西需要链接。现在改为"找到就用、可选"，并且配置步骤会打印它的决定。这个问题之所以在本地开发时没暴露，
  是因为 `PATH` 上某个 CUDA 工具包留下了一份 `OpenCL.lib` 被 `find_package` 捡到；是 CI 发现的。

### 修复 —— 工具链

- `configure.ps1` 与 `build.ps1` 给 `$isWindows` 赋值，而它会在 PowerShell 7 下与只读自动变量 `$IsWindows`
  冲突（名字大小写不敏感）并以 `Cannot overwrite variable IsWindows` 中止。两者在 Windows PowerShell 5.1
  下都正常、在每个 CI runner 上都失败——一次"本地绿、CI 红"，因为子进程 `pwsh -File` 把消息吞了，找了五轮
  才定位。改名为 `$onWindows`；`scripts` CI job 现在会 grep 对只读自动变量的赋值，构建步骤会把捕获到的失败
  以 `::error::` annotation 重新抛出，于是真实那行能通过公开的 check-runs API 看到。
- CI 安装 `cmake<4`（CMake 4 移除了 `cmake_minimum_required(<3.5)` 兼容，而 llama.cpp vendored 的项目与
  OpenVINO 打包的 config 文件仍然声明着它），并且 `configure.ps1` 在检测到 CMake ≥ 4 时传
  `-DCMAKE_POLICY_VERSION_MINIMUM=3.5`。
- `compare-tensors.ps1`：跳过 `.txt` 边车文件（自定义 `-Filter` 会把它们当 f32 读，于是报告里全是 `3e+32`
  的张量）；`Top-K` 现在受比对前缀长度约束（它以前为了打印 5 个数字去给几 MB 的缓冲区排序）；新增
  `-RowSize`/`-MaxRows`/`-RowTol` 行模式——这正是让 KV 缓存比对变得有意义的前提，因为对一个 chunk 根本没写过的
  行做整缓冲区统计毫无意义。

### 新增 —— 仓库

- `src/ggml-openvino/` 现在**纳入版本管理**：完整的后端目录（95 个文件）带着汪柴的改动，于是引擎可以在
  "什么都不用应用"的前提下被直接阅读。`tools/bootstrap.ps1` 把钉住版本的 llama.cpp 克隆进 `src/llama/`
  （仍被 git 忽略）并用这个目录覆盖之，随后打印 `git diff --stat` 作为"代码确实落地了"的证据。`patches/`
  保留下来作为可评审的 diff 与上游化产物；`bootstrap.ps1 -UsePatch` 切回打补丁路径。来源与改动规矩见
  `src/ggml-openvino/WANGCAI.md`。
- README 改为中文为主，`README_en.md` 作为次要语言文档。

### 新增 —— 构建

- `patches/ov_opencl_shim.hpp`：`<CL/cl.h>` 与 `openvino/runtime/intel_gpu/ocl/ocl.hpp` 的自包含替身。
  OpenVINO 后端从 `ggml-openvino.cpp`、`utils.cpp` 与 `ggml-openvino-extra.{h,cpp}` include 了这些头文件，
  使得纯 NPU 构建需要 Khronos 的 `cl2.hpp` 与 GPU SDK——而这两样在干净的 Build Tools 安装上都不存在。shim
  声明了编译那段只服务于 GPU 的远程上下文代码所需的少量 OpenCL typedef、互不相同的不透明句柄类型与内联桩，
  而 NPU 从不执行那段代码。结果：OpenVINO 后端能从一个干净的 Visual Studio Build Tools + OpenVINO 运行时
  安装直接构建，全程见不到 GPU SDK。
- `GGML_OPENVINO_NPU_COMPILE_OVERRIDES=KEY=VALUE,...`：在运行期新增或替换 NPU 编译配置里的顶层条目。没有它，
  要回答"是不是这一个 flag 的问题"就得每个 flag 重编一次，而 NPU 图编译慢到（LFM3-1.7B 冷启动约 36 s）一次
  扫描要花掉几小时。
- `GGML_OPENVINO_DUMP_BIN=<dir>`：把一次 compute 调用的每个图输出写成原始的
  `<dir>/<tag>_<seq>_<name>.bin`，外加一个记录形状与元素类型的 `.txt` 边车；静态与动态路径都支持。与
  `GGML_OPENVINO_DEBUG_NODE` 不同，它不追加 `Result` 节点——这点要紧，因为追加额外输出时 NPU 插件会让整个
  进程中止。
- `GGML_OPENVINO_MASK_MODE=1`：在静态 prefill 路径上，用 token 位置构造注意力 mask，而不消费 llama.cpp
  递过来的 mask。加它是为了把"mask 内容错了"与"图被错误执行"分开；在这个模型上它证明了 mask 是无辜的。
- `tools/`：`configure.ps1`、`build.ps1`、`run-npu.ps1`、`npu-sweep.ps1`、`compare-tensors.ps1`、
  `top-token.ps1`。

### 新增 —— 正确性

- `GgmlOvDecoder::get_mask_ctx_size()`：决定一个注意力 mask 输入必须有多宽的唯一一处。混合结构模型交给后端的
  是每个注意力模块一块 mask、并补齐到模型里*最大*的那块 KV 缓冲区，而每一层实际只对各自的缓存做注意力。动态图
  下 K 会被切片去迁就 mask；静态（NPU）图下两个形状都被焊死，于是窗口层需要环长、全局注意力层需要上下文长度。
  编译进参数的形状与为主机构建用于绑定的张量，现在都从同一个函数推导；此前它们各算各的、可以不一致——NPU
  插件会用 `input tensor size is not equal to the model input type` 拒绝它，opset-13 的 SDPA 会用
  `attention_mask_input_correctness` 拒绝它。
- `openvino/op/flash_attn_ext.cpp` 里的 `trim_mask_to_kv()`：把比 K 操作数更宽的 mask 裁到 KV 范围，并遵守
  `seq_active_start`，作为"两者仍然不一致"那些情况的护栏。

### 修复

- LFM3-1.7B（13 门控短卷积 + 5 滑动窗口@256 + 6 全局注意力层）此前在 NPU 设备上连图都建不出来。现在两张图
  （分块 prefill 与单 token decode）都能编译，并能在 `Intel(R) AI Boost` 上端到端生成。

### 已知问题

- 精度缺陷的逐层测量（真实 chunk 上的 conv 状态输出）：余弦从 `l0 0.9956` 一路到 `l9 0.873`、`l13 0.534`、
  `l17 0.163`。误差在第一层就存在并被复利放大，所以它是逐算子的精度问题——既不是图深处某个坏掉的算子，也不是
  状态记账。K/V 侧几乎干净：V 精确，K 除第 0 行外都在 `0.90–0.9998`。
- NPU 输出与 CPU 参照尚未数值对齐：与参照 logits 的余弦在 prefill 结束时是 `0.969`、在前几个解码步是
  `0.73–0.79`，且 logit 分布被明显压平（top-1 在 CPU 是 `19.58`、在 NPU 是 `17.53`）。贪心解码与参照一致
  2–3 个 token 后发散。已排除项见 [docs/npu-internals.md](docs/npu-internals.md)。
- NPU 解码吞吐（`8.3–8.7 t/s`）比 CPU 参照（`54.1 t/s`）低 6 倍、比 CPU 上的 OpenVINO
  （`21.7–29.2 t/s`）低 2.5 倍——约为可用 TOPS 的 0.03。预填充并**没有**以同样的方式受影响
  （`pp512` 415 t/s，对比原生 570），这把问题定位到每步路径，而不是整体的编译配置。
- 比 KV 缓存更长的序列会把 OpenVINO 后端拖垮：任意设备上的 `llama-perplexity`，以及 1024 上下文下的
  `llama-bench -p 1024 -n 32`，都会以
  `Check 'idxValue < static_cast<int64_t>(srcDimAxis) ...' failed at intel_cpu\src\nodes\scatter_update.cpp:915`
  失败——一个越界的 KV 写入索引。同样形状在 `-p 512` 下跑得干净。在 NPU 上，同样的条件不报检查失败，而是
  产生 `ZE_RESULT_ERROR_DEVICE_LOST`（`zeCommandQueueExecuteCommandLists`，`0x70000001`）。这挡住了把
  perplexity 用作精度指标。*（此处早前有一条把原因归咎于多输出图；`-p 512` / `-p 1024` 的差分不支持那个说法，
  故已撤回。）*

### 更正

- 此前公布的 NPU prompt-eval 数字（`6.0–12.2 t/s`）是一个假象，不是对加速器的测量。静态 prefill 图永远是
  `GGML_OPENVINO_PREFILL_CHUNK_SIZE`（256）列宽，所以 4 个 token 也要付 256 列的钱，而 llama.cpp 上报的是有效
  token 每秒——比图自身的列吞吐低了 60 倍。在真实 token 数下测量，NPU 在 `pp512` 达到 **415 t/s**（OpenVINO-CPU
  的 68%、原生参照的 73%）。NPU 上短 prompt 的 prompt-t/s 根本不该与 CPU 数字对比；见
  [docs/benchmarks.md](docs/benchmarks.md)。
- 通过 `GGML_OPENVINO_DEBUG_NODE` 追加图输出会在 NPU 上让进程中止。改用 `GGML_OPENVINO_DUMP_BIN`，它读的是
  已有的输出。

### 关于被推翻假设的备注

记下来，免得再有人为它烧一周：

- **权重重量化不是原因。** 在 NPU 上后端把所有非 embedding 重量化成 `Q4_0_128`（group 128，对称），而 CPU
  保持原生 `Q4_K`。在 CPU 上强制同样的重量化后输出依然连贯，所以单靠重量化解释不了这个缺陷。*（补充：两侧
  策略对齐后，最差 conv 状态从 `0.215` 升到 `0.9589`——原来三分之二的差距来自"两台设备加载了两个不同的模型"。）*
- **chunk 尺寸不是原因。** `GGML_OPENVINO_PREFILL_CHUNK_SIZE` = 1 / 2 / 7 / 32 / 128 / 256 表现一致。
- **mask 内容不是原因。** `GGML_OPENVINO_MASK_MODE=1`（按位置推导的因果 mask）让 CPU 静态路径保持连贯，
  NPU 依旧错。
- **多列卷积不是原因。** 单 token prompt 执行的是同一张补到 256 列的 prefill 图，在 NPU 上连贯。
- **没有任何 NPUW 开关能修好它。** `NPU_USE_NPUW=NO` 编译不过；
  `NPU_COMPILER_DYNAMIC_QUANTIZATION=NO` 死于 `ZE_RESULT_ERROR_OUT_OF_HOST_MEMORY`；`NPUW_DQ=NO`、
  `NPUW_DQ_FULL=YES`、`NPUW_FOLD=NO` 让生成塌缩成重复的同一个 token；`NPUW_WEIGHTS_BANK=none` 无变化。
  这个缺陷在所有有文档记载的开关下都存活。
- NPU 上 `GGML_OPENVINO_STATEFUL_EXECUTION=1` 没有帮助（有状态模式按设计只支持 CPU/GPU）。
- `-fa 0` 在 NPU 上是死路：强制走非 SDPA 路径会让 llama.cpp 有意把 V 摊成每行一个元素
  （`llama_kv_cache.cpp`），随后 scatter 写回就会拒绝该索引。

[Unreleased]: https://github.com/liangjianzeng/WangCai

### 修复 —— 4B NPU decode 性能（性能轮：2.4 → 4.9 t/s）

- **根因（level 预算三图问题）**：NPU 设备预算 = prefill + 一张 decode 图（权重 bank 按
  CompiledModel 计），而 prefill 在新 entry 上还会预编 legacy 全 ctx decode 图——三图常驻。
  1.7B 模型三张权重 bank 装得下（LFM3 的 levels 一直正常），4B 必爆：level 图编译成功后首个
  execute 即 `ZE_RESULT_ERROR_UNINITIALIZED`，自动降级后每步都跑全 ctx 图（436 ms/step）。
- **修复**（utils.cpp）：levels 激活时 prefill 跳过 legacy decode 预编；level 编译时连同
  legacy 图一并驱逐（fallback 重进按需重编）；level==0 的 cache_hit 按相位拆分（并修复
  复用检查解引用 null decoder 的段错误）。
- **实测**（热缓存稳态）：Spark-X2.6-4B 2.4 → **4.9 t/s**（raw infer 436→~150 ms）、
  Qwen3-4B 2.3 → **4.0 t/s**、LFM3-1.7B 13–15 t/s 无回归；三模型 NPU 三问验收全 3/3。
- **剩余**：~200 ms/步为 36 层标准注意力的算子降级开销 + 权重带宽下限（~7 t/s）；杠杆与
  排查链（PROFILING 分解、算子级 CSV、ctx 对照）见 HANDOFF 2026-11-01 性能轮。
