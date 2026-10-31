# 会话交接（上下文耗尽时读我）

> **✅ 已收尾（2026-10-31）：** 下方记录的 decode K 分支缺陷**已定案并修复**（commit `63179ef`，
> rope.cpp 显式 Concat tile + 注册门扩到 NPU），三问验收 3/3 首次全对。终章见
> [defect1-rootcause.md](defect1-rootcause.md)。本文其余内容保留为过程记录；首次验收闸门已过，
> 本地 commit 已随 v0.0.1 发布。

## 核心状态
- 根因已定案：NPU scatter 丢 index-0 写入 → docs/defect1-rootcause.md（但注意下面的修正）
- 修复尝试 #1（set_rows.cpp 静态 prefill 的 pad+shift+slice，工作树未提交）：**未生效**
  - 证据：nowarmf dump 逐 pass 差分与修复前逐位一致（row0 仍是 decode 预热的 65.49 常量）
  - 副作用：row43 从 0.9947 变为 0.0169（49.66 范数）——原因未明
  - 首要疑点：`context.is_prefill()` 在翻译期可能没有按预期置位（检查 NodeContext::is_prefill
    与 decoder 的 virtual is_prefill 在 prefill/decode 两图各自的返回值；用 GGML_LOG_ERROR 在
    translate_set_rows 入口打印 is_static/is_prefill/idx_name 三个值即可定案，改完必须同步
    E:→D: 两个树：src/ggml-openvino → D:\llm\npu\src\llama\ggml\src\ggml-openvino）
  - row0 的 65.49 常量 = 上下文初始化 decode 预热（decode_1）写入的哑 token K；
    --no-warmup 关不掉它（在 llama_context 构造里）
- 验收闸门未过（0/3），本地 7 commit 未推
- 工具：npu-probe.ps1 / WangCaiNpuReset 计划任务 / D: 构建树 bld_mtmd.bat

## 下一步精确顺序
1. 在 translate_set_rows 加三值日志，确认两图的 is_static/is_prefill 实际值
2. 若 flag 不对：改 decoder 的 is_prefill 传递（GgmlOvDecoder per-phase 已有 ptr_prefill）
3. 生效判据：nowarmf 复测 row0 cos(npu,cpu) ≈ 0.99 且 row43 恢复 0.99
4. 然后：三问验收（accept.ps1）→ 全对 → push 全部本地 commit
5. 别忘了 user 的 GPU server 占 20GB 的事：大 ctx 实验前先问

## 更新（pad/slice 修复尝试后的关键新事实）
1. is_static/is_prefill 探针证明 flag 正确：prefill 图 static=1 prefill=1，decode 图 prefill=0。
2. pad+shift+slice 修复**确实进入了执行图并生效**——但结果错误：row0 仍是 65.49 常量，
   且 row43 从正确(0.9947)变为错误(0.0169/49.66)。即 scatter+pad 路径本身能写，
   但与状态回写/refill 机制的交互有问题（疑似 Slice 输出作为 set_output_tensor/状态更新的
   形状或别名问题）。已回退到原始 scatter，构建绿色。
3. row0 的 65.49 值与 prompt 无关 + 上下文初始化 decode 预热（decode_1，--no-warmup 关不掉，
   在 llama_context::sched_reserve 里）用哑 token（可能是零/未初始化 embedding）写 row 0。
   真实 prefill 的 row-0 写入从未覆盖它。
4. 下一步候选（按序）：
   a. 给 ScatterUpdate 换 v12 ScatterND 或检查 indices 的 dtype/形状（Squeeze 后 [N] i64）
      ——先做一个 TBO 式最小 SET_ROWS 复现：TBO `-o SET_ROWS -p '.*ne=\[512.*'` 之类，
      用 0 索引复现"跳 0"，拿到 Intel 插件级证据；
   b. 若确认插件 bug：引擎侧修法改为"静态 prefill 的写用 Copy/Concat 重构"而不是 scatter
      （写范围连续且编译期已知 chunk 起点=indices[0]，可用 indices[0] 作 Gather 推导偏移）；
   c. 或在 llama.cpp 侧给 KV cache 的 cell id 加 1 偏移（rows 1-based），代价是全链路检查。
5. 当前 DLL = 原始 scatter（回归到本会话开始前的行为），构建绿色。

## 2026-11-01 续：缺陷收窄到 SSM_CONV 状态路径（scatter/conv 算子均排除）
- 裸 ScatterUpdate（含索引 0、含 SET_ROWS 精确形状/轴）：NPU 正常 → 插件不跳 0
- ScatterND 替换 prefill 写入：row0 依旧 → 与写入算子无关
- 裸 GroupConvolution python 对拍：max diff 0.003（f16 噪声级）→ conv 算子干净
- **引擎转储 cache_r 逐 pass 对比：第一个 pass（零状态）cos 就只有 0.4546，
  NPU 侧 nz 少 66（整段写零）** → 缺陷在 SSM_CONV 的状态视图/切片装配
- 同时确认：cell 0 由 ctx 初始化 decode 预热（BOS）独占写入是正常 llama.cpp 行为
  （两设备索引一致 [1..39]，prefill 不写 cell 0），CPU 的 cell-0 值是对的、
  NPU 的同一 pass 算出 65.49 错误值——与 conv 状态首 pass 发散同源
- 下一步：python 复刻 SSM_CONV 的状态视图装配（state 缓冲视图偏移 + 输入 concat
  的 NPUW 降级行为），或直接读 build_lfm_shortconv 的 view/concat 结构

## 2026-11-01 晚：decode 图 K 分支算子级定位 + IR 对比工具
- decode_5 同 pass：V row43 完美（0.9998 四头全对），K row43 h0/h2 逐位精确、
  h1/h3 摧毁（范数 17→33 / 13.8→34），周期 256 元素 → k_norm/RoPE 链的视图错误
  （V 证明 hidden/W_v/scatter 全对；prefill 同 token K 正确排除权重/量化）
- IR 已转储：E:\DTXY\WangCai\model_{decode,prefill}_3726599.xml
  对比脚本：D:\llm\npu\ctrl\trace_ir.py / trace_back.py（ElementTree，<layer>/<edge>）
- k_norm 结构两图一致（RMS 经 MatMul+Squeeze 降级）；差异待查 <port> 形状属性
  （decode 的 [4,128] reshape 视图 vs prefill 的 [n_seq,4,128]）与 RoPE 的
  VariadicSplit 常量
- 修复验证判据：nowarmf 式转储 row0 与 row43 的 cos(npu,cpu)≈0.99 → accept.ps1
  三问验收 → 全对 push 全部本地 commit（当前 13 个）

## 2026-11-01 深夜：IR 形状对比（最锐利线索）
- decode Kcur 链：MatMul(W_k) → Unsqueeze → Divide(RMS, MatMul+Squeeze 降级, 每头
  128 元素分组) → Reshape [1,1,4,128] → Multiply(×k_norm weight) → RoPE(VariadicSplit)
  ——prefill 同构，形状 [1,256,4,128]
- 损坏模式：同 pass 内 V 完美、K 的 h0/h2 逐位精确、h1/h3 摧毁（256 元素周期）
  → 嫌疑 = NPUW 对 1-token 形状 [1,1,4,128] 的 4 头广播（k_norm weight 与 RoPE
  cos/sin 的 broadcast tile）降级错误；prefill 的 [1,256,4,128] tile 正确
- 修复候选：把 decode 图的 k_norm/RoPE 形状改成与 prefill 同构（[1,1,4,128] →
  [1,4,128]→unsqueeze 回来），或绕过广播（k_norm weight 用 Concat 复制 4 份、
  cos/sin 同理）——在 translate 端做，避开 NPUW 的 broadcast tile bug
- 验证：ndtest 式转储 row0/row43 cos≈0.99 → accept.ps1 三问 → push

## 2026-11-01 深夜 II：广播 tile 修复无效 → elementwise-on-GEMV 理论
- AlignEltwiseOperandRanks 扩展（低秩 operand unsqueeze+4 头 tile，k_norm weight 与
  RoPE cos/sin 都覆盖）：row0/row43 完全不变 → 隐式广播排除
- 现有铁证组合：V 分支（matmul→直连 scatter，无 elementwise）完美；
  K 分支（matmul→norm/RoPE elementwise→scatter）h0/h2 逐位对、h1/h3 坏
  → **NPUW 的 DQ/GQ2i（N=1 GEMV）路径上 elementwise 算子的子块处理可疑**
- 下一轮：① GGML_OPENVINO_DEBUG_INPUT 已不可用（值太多），改为把 decode 图的
  K-cur（scatter 的 data operand）硬编码为额外图输出做一次 debug 构建
  （CPU 端 DEBUG_NODE 可行，NPU 端须静态加输出而非 Result 追加）；
  ② 或试 NPUW_DQ_FULL=NO / 其他 DQ 子开关针对 GQ2i；
  ③ 或把 decode 图 K 分支的 elementwise 全部换成 Concat/Copy 显式实现
- 判据不变：row0/row43 cos≈0.99 → accept.ps1 三问 → push（本地 14 commit）

## 2026-11-01 深夜 III：DQ 也排除 + RMS 分组成为头号嫌疑
- NPUW_DQ=NO：row0/row43 逐位不变 → DQ/GQ2i 排除；且错误值对图结构
  （ScatterUpdate/ScatterND/pad/broadcast-tile/DQ）全部不变、对输入 prompt 有响应
  （nowarm2 换 prompt 后 row0 变化 cos 0.15）→ 是"计算错误"不是"残留"
- NPU 与 CPU 唯一未排除的差异：K 独有的 RMS 链。rms_norm.cpp 的 ReduceMean 走 -1 轴
  （512 全池化），而 ggml 参考是每头 128 分组——需确认 llama.cpp lfm2.cpp 在
  build_norm 前是否 reshape（若 reshape 存在于 ggml 图而 OV 端丢失/错位，
  且 CPU-static 与 NPU 同错则 CPU 参照本身也偏离 native——需与 native CPU 对比 row0）
- 下一轮第一动作：① 读 lfm2.cpp k_norm 前的 reshape；② native CPU（-dev none）
  转储 row0/K(BOS) 与 CPU-static 对比 → 若 CPU-static 本身就错，缺陷在图翻译的
  RMS 分组，修复点 = rms_norm.cpp 的轴处理

## 2026-11-01 深夜 IV：待办第一项
- RMS 池化验证未完成：native CPU（-dev none）不经 OV 后端、GGML_OPENVINO_DUMP_BIN
  无效 → 需要 native 侧的 K 转储挂钩（或在 python 里用 GGUF 权重直接算 BOS 的
  每 head RMS K 参照）来回答"CPU-static 的 k_norm 是否真的 512 池化"
- 已排除清单（勿重测）：scatter 三种实现、NPUW FOLD/FUNCALL/DQ、广播 tile、
  conv 算子、权重量化、hidden（V 证明）、驱动/内存预算

## 2026-11-01 深夜 V：512 池化假说在 IR 层面死亡；同秩广播是唯一未排除项
- IR 复核（model_decode_3726599.xml）：k_norm 的 ReduceMean_73975 是 [1,1,4,128]→[1,1,4,1]，
  **每头 128 分组，图翻译本身正确**——"RMS 512 池化"假说不用再做 native 参照验证，省一轮
- 但发现此前"广播 tile 无效"结论的漏洞：AlignEltwiseOperandRanks 旧版只处理**秩不同**的广播，
  K 链上三个**同秩**广播从未被覆盖：
  ① RMS scale [1,1,4,128]×[1,1,4,1]（Multiply_73981）② RoPE cos/sin [1,1,4,64]×[1,1,1,64]
  ③ rotate-half [1,1,4,128]×[1,1,1,128]（Multiply_73993）
  且 k_norm weight 是 Constant，旧版顶部 guard 直接 return false——commit e904f84 声称覆盖
  weight 是不准确的，实际从未 tile 过 Constant 操作数
- 修复（align_eltwise_ranks.cpp 重写）：decode 形状门（out 秩≥2、head 轴=4、head 前全是 1）内，
  每个操作数 unsqueeze 到输出秩 + 显式 tile 全部 size-1 轴；Constant 直接材料化成全形
  Constant（f32、≤64k 元素），其余 Concat 倍增。prefill [1,256,...] 与动态图不进门
- 构建绿。验证：cache_tile（NPU）/ cache_tilecpu（CPU-static），compare-k-heads.ps1
  row0/row43 每头 cos≈0.99 判据

## 2026-11-01 深夜 VI：tile 真正进图后的新状态
- 修复注册门（translate_session.cpp：is_gpu() → gpu/npu/FORCE_STATIC）后 pass 首次真正生效：
  新 decode IR（model_decode_36452578.xml）k_norm weight 已材料化 [1,1,4,128]、
  Multiply 两操作数同形——343 个 Concat（旧 90）
- 中途修了一个倍增 bug：eps Add 上 Concat 倍增 1→2→8（应为 4）导致 shape inference 崩；
  改为成倍 + Slice 补尾
- 常量 tile 版（bld_tile5）：NPU decode 全 NaN（K/V/logits），文本退化为 ">>"
- 非常量 tile 版（bld_tile6，Constant 操作数跳过）：NPU decode 仍全 NaN（K l10/l12 NaN，
  文本退化）→ NaN 不是常量材料化引起，而是激活侧 Concat tile（RMS scale ×128 /
  cos/sin ×4 / softmax max / mask ×4 之一或组合）
- 并行验证中：① python 最小复现（隐式广播 vs Concat tile，[1,1,4,128] 各模式，NPU vs CPU）
  ② 转储取证（gwcpu vs tile-cpu CPU 中立性；nowarmf 基线 h0/h2/h1/h3 签名复核；tile-npu NaN 范围）
- 注意：analyze-tensors.ps1 原有 PS7 语法已修复（line 18 return if）

## 2026-11-01 深夜 VII：根因修复 —— decode 图 RoPE 的 cos/sin 头轴广播（已验证）
- 决定性证据链（graph-output 调试构建，ggml_dup+build_forward_expand 制造图输出）：
  ① decode_1 的 K pre-norm/post-norm 在 NPU 上完全正确（cos 0.997+，范数逐位一致）
  ② 缓存 K 行 0 只有偶数 128 块正确，奇数块是跨构建逐位相同的确定性垃圾
  ③ NPU post-rope vs pre-rope（位置 0，数学上恒等）：h0/h2 cos=1.0、h1/h3 cos 0.38/0.49
  → 缺陷 = 静态 decode 图 rope 的 cos/sin [1,1,1,128] 头轴广播在 NPUW 降级下坏掉
- 修复（rope.cpp）：静态 decode 图把 cos_full/sin_full 沿头轴显式 Concat tile 到
  [1,1,4,X]，绕开隐式广播。位置 0 恢复恒等；缓存 row0 四头 cos 0.997+ 范数逐位一致
- 验收：三问 48 token 全对（Q2 明确 "Beijing"、Q3 明确 "Paris"、Q1 推理正确）——首次通过
- 今日教训（务必记住）：
  a. AlignEltwiseOperandRanks 曾被 is_gpu() 门住——NPU 上所有"tile 无效"实验都是死代码，
     一次无效实验浪费了多轮重建。改 pass 注册门前先确认它真的在跑（改 IR 后 hash 会变）
  b. "解码行全坏/h0h2 精确" 等旧结论是 pass 错位比较的产物——转储比对前先按字节对齐 pass
  c. ggml_set_output 不足以制造图输出（遍历不可达），要 ggml_dup + ggml_build_forward_expand(gf,)
  d. LFM3-1.7B 走 lfm3.cpp 不是 lfm2.cpp（打补丁前先确认模型到 builder 的映射）
- 修复 commit：translate_session.cpp（注册门 gpu→gpu/npu/FORCE_STATIC）+ rope.cpp（tile）
  + align_eltwise_ranks.cpp（同秩 tile 扩展，norm 门 + 跳过常量；已验证中性）

## 2026-10-31 深夜 VIII：剩余目标推进（1.2 ✅ / 4.x 新阻塞点）
- 里程碑 1.2 复测通过并入库 status.md：p220 续写 64 token CPU-static vs NPU **逐字节一致**
  （修复前同判据通过、修复中断、现已恢复）；zh 指令生成 72 token 连贯无坍塌；
  自由生成 top-1 与 f32 参照第 5 步起分歧 = f16 噪声复利（cos 0.5–0.9，无平台期）
- Omni 音频（milestone 4.x）重测推进两步：
  ① 417 个 "failed to process weight tensor" 归零（7c1d32f 回归修复确认生效）
  ② -c 512 下不再 DEVICE_LOST（默认 ctx 会撞内存预算；本次元凶 vmmemWSL 20GB）
  ③ 修了一个真 bug：ggml-decoder.cpp 的 IM2COL 动态维断言假设 OW==IW，对 stride-2
     下采样卷积（Whisper 式音频编码器）必误报——改为按卷积公式 (I+2p-d(k-1)-1)/s+1
     断言，批量维保持恒等（提交待做）
  ④ 当前阻塞点（下一个战场）：音频编码器注意力 Add(scores [1,8,38,69], mask [1,1,38,38])
     宽度不匹配——mask 是方的（38 帧查询）但 K 侧 69 列。两个假设：clip.cpp 的
     mel pad/分块策略给了 69 的 K 序列而 mask 仍按帧数建方阵；或 engine 的 clip mask
     构建假设方阵。下一步：dump clip 图的 K/V 与 mask 的 ggml 形状（GGML_OPENVINO_DUMP_IR
     已确认可用），对照 mtmd audio 分块逻辑（n_chunks=1/3、31 帧差值来源）
- 设备健康协议有效：DEVICE_LOST 后 WangCaiNpuReset 复位 + 探针（probe 缓存被清理后
  会冷编译，150s 超时会误报 SLOW——给 probe 换个常驻缓存目录或加大超时）
