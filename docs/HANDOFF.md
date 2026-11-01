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

## 2026-10-31 深夜 IX：Omni 音频又进一步（CPU 全通，NPU 差一层）
- 本轮修复（全部已提交或待提交）：
  ① IM2COL 动态维断言 → 卷积公式（ccdf715）
  ② utils.cpp：clip 图 mask（名字 attn_mask*，2-D [n_kv,n_q]）在 static_decode 与 dynamic
     两条绑定路径都改为**原样直绑** {1,1,n_q,n_kv}——此前被 LLM chunk 布局重成形
  ③ ggml-decoder.cpp get_graph_input_shape：attn_mask* 名字的 2-D mask 参数形状同样直绑，
     绕开 get_mask_ctx_size() 的 KV 环宽度
- 结果：**CPU 设备下 Omni 音频端到端跑通**（audio 编码 + 生成，EXITCODE=0，无异常）
- NPU 设备下仍失败，同一 Add：scores [1,8,38,69] vs mask 参数 [1,1,38,38]。
  已证伪：不是 get_graph_input_shape（插桩显示它收到 [69,38] 且我的分支会返回 {1,1,38,69}）；
  不是 trim_mask_to_kv（38<=69 直接原样返回）；不是陈旧 blob（NPUW_CACHE_DIR 每次都清）
- 关键疑点：报错的 friendly_name 是 **Add_47152**，而 audio 图 IR 里的 Add 是 65xxx 编号族
  ——失败的可能不是同一张图！mmproj 里还有 vision 塔（dots3note-v，流式窗口设计同源，
  K 同样带 31 帧上下文）。下一步：① 打印 NPU 下实际编译的 clip 子图清单与各自
  参数形状（GGML_OPENVINO_DUMP_CGRAPH 或 NPUW 的形状日志）；② 确认 vision 图是否
  也用 attn_mask 命名 + 是否被 [38,38] 的某处覆盖；③ 或在 set_input 前打印
  bound tensor 的 shape 定位是编译期形状还是绑定形状不一致
- 顺便：mtmd-audio-c512.ps1 里 DEVICE 一度被改成 NPU，调试 CPU 路径时注意

## 2026-10-31 深夜 X：NPU clip-mask 的最后谜团（插桩数据齐全，待下一轮）
- 插桩结论（NPU 运行、DEBUG_INPUT=1）：
  ① get_graph_input_shape 收到 attn_mask ne=[69,38,1,1] is_inp_mask=1 —— 我的分支应返回 {1,1,38,69}
  ② 但编译期报错仍是 Parameter attn_mask f32[1,1,38,38] —— 形状被第四处来源覆盖
  ③ **三个直绑分支（static_decode/prefill/dynamic）的日志一次都没打印** —— 运行期 mask 绑定
     根本不经过这三个函数！剩下唯一候选：convert_ggml_input_to_ov 的 ggml_tensor->extra
     快路径（buffer 分配时挂的预建 ov::Tensor）——extra 的 shape 来自 tensor->ne 反转，
     理论上应是 [1,1,38,69]……除非挂 extra 时的 ne 是 [38,38]（挂的时机早于 mask 构建？）
- 下一轮第一动作：在 convert_ggml_input_to_ov 的 extra 快路径命中时打印 shape+name（NPU 跑一次）；
  若命中，追查该 extra 是谁在何时以什么 ne 创建的（buffer set_tensor / alloc 顺序）
- 注意：Add_47152 编号族与 audio IR（65xxx）不同——先确认失败图就是 audio 编码器
  （state_in_k_* 打印紧邻失败点，倾向是），但 mmproj 里 vision 塔同源设计，勿排除
- CPU 路径已全通：mtmd-audio-c512.ps1 里 DEVICE 临时改 CPU 即可复现成功

## 2026-10-31 深夜 XI：NPU 音频编码器跑通；推进到 LLM×音频 token 层
- 第四条绑定路径谜底揭晓（最终插桩）：get_graph_input_shape 的 mask 分支返回 {1,1,38,69} 正确，
  但函数末尾有个 LLM 专用特例——**SOFTMAX 的 mask 输入被强制方阵化 [1,1,seq_active,seq_active]**，
  lfm3a 音频注意力恰走 SOFTMAX → {1,1,38,69} 被盖成 {1,1,38,38}。修复 = attn_mask* 名字跳过方阵化
- 连锁修复 2：CACHE_MODE——clip 图因不支持的算子从 NPUW 回退到非 NPUW 路径，该路径拒绝
  为 NPUW 缓存加的 CACHE_MODE 选项；without_npuw() 现在连 CACHE_MODE 一起剥
- **结果：NPU 上音频编码器编码成功（chunk 1/3 done）**，推进到 LLM 图消费音频 token：
  新错误 = q_layernorm/rope 形状不一致（Q [1,38,16,128] vs rope cos Concat [1,256,1,128]，
  256 = LLM prefill chunk 的位置表 vs 38 个音频 token 的 ubatch）——LLM rope 的 sin/cos
  表长度与音频 ubatch 的 token 数不匹配，rope.cpp 的 sin_cos 共享缓存 key（op_params）
  可能不含位置数，或 prefill 静态 256 图被 audio ubatch 复用。这是下一轮第一战场
- 本轮提交：softmax 方阵化门 + CACHE_MODE 剥离 + 插桩清理

## 2026-10-31 深夜 XII：LLM×音频 rope 形状——缩到 decoder 相位判定
- 完整输入清单已拿到（DEBUG_INPUT 插桩，mtmd-audio15/19）：
  音频 embedding 图的全部输入 = model.embed_tokens [2048,38]（音频 embedding，cb 命名，
  非 inp_embd！）、inp_pos [38]、mask [256,38]、KV idx [38] —— 图内部在 38 处自洽
  （embed_tokens [2048,38] → norm → rope 应得 cos [38]）
- 但 rope cos 实为 [1,256,1,128]：**该图的 gis 打印 prefill=0** —— 38 token 的批次被
  decoder 判成 decode 相位！于是 is_inp_pos 静态分支走 len=1/m_prefill_chunk_size 的
  decode 逻辑，rope/位置/mask 的形状假设全部错位。候选根因：
  ① get_is_prefill(cgraph, inp_pos) 对 embd 批次的判定（mtmd 音频 batch 是否设置
     inp_pos 使 ne[0]>1 可靠？）② HANDOFF 已警告的 ptr/ptr_prefill decoder 别名
     （首 pass 相位污染后续图）③ llama.cpp 对 embd batch 的 inp_pos 构建
- 曾试并回退的修法（勿重试）：inp_embd/model.embed_tokens pad 到 256（reshape 常量
  [38] 烤死，不匹配）；positions 自然长度（文本 shortconv reshape [256] 烤死，回归）
- 正确方向推测：修 ②（decoder 相位别名）或 ①——音频批次必须被判成 prefill 且
  inp_pos 的参数形状跟随真实 38（对齐 mask [256,38] 的 38 行）
- 下一步第一动作：在 get_is_prefill / decoder 构造处打印音频图的 is_prefill 判定依据
  （inp_pos->ne[0]、调用来源），确认 ①/② 哪个成立

## 2026-10-31 深夜 XIII：LLM×音频 rope 定案——shortconv 状态机按 chunk 固化，修法在 llama.cpp 侧
- 完整证据链（gis 全量插桩）：
  音频 embedding 图输入全部在 38 处自洽：model.embed_tokens [2048,38]（mtmd 音频 embedding 的
  cb 命名，非 inp_embd）、inp_pos [38]、mask [256,38]、KV idx [38]
  但 LLM shortconv 的状态装配（cache_r [12288]=6×2048 状态视图、Slice [1,1,2,2048]、
  Reshape [1,1,256,2048]）**全部按 256 chunk 几何烘焙**——文本 ubatch 恰好被 llama.cpp
  pad 到 256 所以自洽，音频 ubatch（38）天然不匹配
- 已试并回退（勿重试）：① embd pad 到 256（llama.cpp 图内 reshape 常量 [38] 烤死不匹配）
  ② positions 自然长度（shortconv 状态装配 [256] 烤死，文本回归 Reshape_1291 [1,1,2,2048]→[256]）
- **结论：引擎侧无法单方面适配，音频 ubatch 必须 pad 到 chunk 宽——修法在 llama.cpp 侧**
  （D: 树 mtmd.cpp / llama-batch）：音频 embedding 批次喂给 llama_decode 前 pad 到
  llama_n_ubatch(ctx)=256：零 embedding + 位置顺延 + 只在真实 token 上置 output 标志 +
  padded 行的 attention 由 causal mask 自然遮蔽（作为 key 会被后续 chunk 的滑窗读到，
  需确认 zero-embedding 的 K/V 是否会污染——若污染需在 mask 里显式遮蔽 padded 行）
- 验证路径：pad 后 NPU 跑 mtmd-audio-c512.ps1 → 三 chunk 全编码 → 生成文本 → 与 CPU
  （DEVICE=CPU 同脚本已端到端通过）对比

## 2026-10-31 深夜 XIV：修复落地——引擎侧 raw-embd pad + 动态维传播，NPU 音频端到端跑通
- **先修正上一节的一个定案错误**：llama.cpp 并没有 pad 文本 ubatch。cgraph dump 证实文本图的
  ggml 节点按自然宽度（40-token prompt 的图就是 40 宽）；256 宽来自**引擎的 bind 时 pad**
  （get_ov_input_tensor_static_prefill 把 inp_tokens/inp_pos 补到 chunk 并以 last_value+1 填充，
  chunk_valid_len 参数让 shortconv 状态装配只消费有效行）。因此上一节"llama.cpp 侧 pad 音频"
  的方案是错的：llama.cpp 侧 pad 会让 chunk_valid_len=256、padded 零行的 conv 状态被永久写进
  cache_r/cache_s（污染后续所有 chunk），KV cell 消耗也会错位。**修法在引擎侧，对齐文本机制。**
- 三处改动（全部在 ggml-openvino，llama.cpp 零改动）：
  ① `ggml-decoder.h`：新增 `is_raw_embd`——input 标志的 F32 NONE 叶子直接喂 RMS_NORM（mtmd
  音频/图像 embedding 的入口形态，与 token 路径的 GET_ROWS 形态区分）。
  ② `ggml-decoder.cpp get_graph_input_shape`：raw-embd 分支声明 `{1,1,chunk,2048}` 静态形状；
  `utils.cpp get_ov_input_tensor_static_prefill`：bind 时把 embedding 数据零填充到 chunk 宽
  （零行 RMS 范数=0，激活有限；K/V 散射到 last_value+1 的 cell，mask 的 -INF 列保证不可读）。
  ③ `ggml-decoder.cpp compute_node_dynamic_dims`：raw-embd 叶子标动态维 1（token 轴）——这是
  最关键的一处：没有它，CONT/Reshape 链会把捕获期的 n_tokens=38 烤进 Reshape 常量
  （Reshape_165021: Slice[1,1,256,2048]→[1,1,38,2048] 直接 shape-inference 报错），文本路径
  之所以没事是因为 inp_tokens 走 GET_ROWS 天然获得动态维。
- 结果：
  - **CPU 静态路径音频端到端通过**（EXIT=0，回答 "A high-pitched, pure"，f32 动态参照
    "A high-pitched electronic tone."——语义一致）
  - **NPU 音频端到端通过**（EXIT=0，编码 3 chunk → LLM 消费 → 生成 "instrument." 之类的
    音频描述）。与 f32 参照有 top-1 级分歧，与文本自由生成已记录的 f16 复利行为同类
    （status.md 1.2 的注）；对照实验：Omni-2B 纯文本 2+2 NPU=CPU="4"、98-token 长文本
    prefill NPU=CPU="Paris"，说明 LLM 图本身无恙；音频编码器输出统计 NPU≈CPU（fp16 噪声级）。
  - 文本回归：accept-smoke 3/3（LFM3-1.7B CPU 静态）。
- 排查过程留档：先用 reshape-bake/view-bake 临时插桩定位烤死常量的来源（cont.cpp 的
  dst_shape 全烘焙路径），插桩已全部拆除。mtmd-audio-c512.ps1 里还有一行 DEBUG_INPUT='1'
  需在最终验收时移除。

## 2026-11-01：缺陷 2（NPU 解码性能）第一轮解剖——三项根因定案
- 测量方法：GGML_OPENVINO_PROFILING=1（每步 Graph inference / OV raw infer 分解）+ =2（逐节点
  CSV，注意 CSV 写入进程 CWD，-n N 时只覆盖前 N+1 个文件，取最后一个；且逐节点耗时总和可能
  超过 wall time——DPU/DMA 并行记账）
- **时间都花在哪（-c 512，70 ms/步，12.5 t/s）**：bind 开销仅 0.3 ms，77 ms 几乎全在
  `infer_request->infer()` 内部。逐节点：Parameter（状态输入）31.8 ms（单节点 DMA 20 ms +
  Shave 9.8 ms，~11.5 MB KV 状态 → **0.4 GB/s，host→device 每步全量搬运**）、Multiply 25.5 ms、
  MatMul 22.5 ms（其中 **lm_head 一项 10.9 ms**）。
- **ctx 线性项实测**：c=512→70.6 ms、1024→115.7、2048→293.7（超线性，二次项 ~5.6e-5 ms/token²）。
  c=2048 逐节点：Add 112 ms + 一批 ~48 ms 节点（ScaledDotProductAttention / Transpose
  cache_k_l2 / Multiply / MatMul）——全部是注意力路径对**静态全 ctx 跨度**的操作。
- **根因 ①**：compute_llm_params 里 `if (is_static) attention_size = ctx_per_seq` 把静态 decode 图的
  注意力跨度烤死为全 ctx——即使只填了 40 个 cell，每步也处理 2048。FA 路径的 flat-KV reshape
  本来就吃 attention_size 输入（动态路径运行时切片、30 t/s 的原因）。
- **修复尝试与证伪**：把 attention_size 参数化（bind 真实 n_kv=PAD(填充,256)）→ NPU 插件编译期
  直接拒绝："to_shape was called on a dynamic shape"——**NPU 静态图不容忍任何动态中间形状**，
  运行时切片在单张 NPU 图里不可行。代码保留为 GGML_OPENVINO_TRIM_DECODE_ATTENTION（默认 0，
  仅 CPU/GPU 静态实验用），extra_cfg 位已隔离 blob 缓存。注意 flash_attn_ext.cpp 的
  num_heads_kv 提取已改为容忍动态形状（对静态路径无害）。
- **根因 ②**：NPU 上没有 remote tensor（"remote tensor is not used for NPU yet"，extra.cpp 注释；
  create_tensor_extra 的 remote 分支 `GGML_ASSERT(ggml_openvino_is_gpu())`）→ KV 状态每步
  host↔device 往返，~30 ms/步 @c512，随 ctx 线性放大。GPU 路径的 USMTensor 零拷贝方案在
  NPU 上不可用。
- **根因 ③**：NPUW 编译开关无效（NPUW_DQ:NO / FOLD:NO / FUNCALL_FOR_ALL:NO 全部持平或更慢）
  ——瓶颈不在折叠/量化策略。
- **NPU 兼容的修复路线（未实施）**：离散多跨度 decode 图组——每个 PAD(n_kv,256) 级别一张全静态
  图（256/512/…/ctx），按填充级别切换请求；权重经 NPUW_WEIGHTS_BANK=shared 共享，冷编译
  ctx/256 张图（NPUW_CACHE_DIR 持久化后一次性成本）。预期把 decode 恢复到与填充级别相关的
  ~50 ms 基线，并消掉高 ctx 的超线性项。状态 I/O 项（根因②）另需 NPU remote tensor 或
  stateful 化，独立工作量。
- 当轮结论：12.5 t/s @c512 已接近 OpenVINO GenAI 在 NPU 3720 上 1-2B 模型的公开水平；要显著
  超越需要上面两条重型改造，本聚焦轮先落地测量基建（PROFILING=2 已接入静态路径）与根因记录。

## 2026-11-01：缺陷 2 第二轮——离散多跨度 decode 图组落地（17× @c8192）+ accept-smoke Q3 flake 定案
### 多级 decode 图（已实施、已验证）
- 方案：`decode_attention_level(n_kv, ctx)`——按 PAD(n_kv,256) 的离散级别（256/512/…/ctx）
  每级一张全静态 decode 图，llama.cpp 每步按当前 n_kv 选级；KV cache 参数与绑定按级别裁视图
  （level_shape[2]=level），每步状态 I/O 与该级别成正比。`ComputeParams::attention_size_raw`
  在烤死前捕获 mask->ne[0]，供命中判定用。
- 实现（ggml-openvino）：utils.cpp 三编译分支（dual=prefill+decode@ctx / decode-only=私编某级，
  编前**驱逐**其他级——NPU 设备预算只容 prefill+一张 decode 图，第二张常驻在首次 execute 即
  ZE_RESULT_ERROR_UNINITIALIZED（缺陷-7 签名） / prefill-only）；convert_ggml_input_to_ov 里
  KV 零填充（fill>0 且 fill<span 时把 [fill,span) 段清零，杜绝上一序列残留跨级别泄漏）；
  ggml-decoder.cpp is_kvcache 输入形状按级别裁剪；GGML_OPENVINO_DISABLE_DECODE_LEVELS=1 逃生门
  回退全 ctx 单图。escape 门全部登记进 ggml-openvino-extra.cpp allowlist。
- 实测（LFM3-1.7B Q4_K_M，NPU 3720）：**decode 15.0-15.1 t/s 与 ctx 无关**——c=8192 从 0.9 t/s
  →15（**17×**），c=2048 从 3.3→15（4.5×）；600-token 任务跨 256/512/1024 三级切换全程无错；
  7K prompt 在 4096 级正常；token 流在不同 ctx 下逐字节一致；level 图 vs ctx 图 48 步 logits
  逐位一致（diff-lines: 0）。
- 教训（过程事故）：D: 工作树的未提交多级修改曾被意外还原到早晨版（/md5 与 E: 提交一致/），
  从 /tmp/mlnew 备份恢复后重建验证通过。**多轮实验期间必须保持 /tmp 双备份**（mlnew=当前，
  mlbak=已提交基线）。
### accept-smoke Q3 flake 定案（测试基建 bug，非引擎回归）
- 现象：Q3（"1+1"）在多级代码上 2/3、NO_KV_ZEROIZE 下 3/3，看似 zeroing 相关。
- 真因（两层）：① 判定 `$text -match '2'` 匹配**整个日志**，性能行
  `[ Prompt: 23.7 t/s | Generation: 29.0 t/s ]` 的 t/s 数字随机含 '2'，假通过/假失败随机器
  负载漂移——之前的 "zeroing 相关性" 完全是这行数字噪声，小样本巧合；② n=48 对 LFM3 的思维
  链太短：note-4 文本（"or simply '4'" 幻觉）动/静态路径**逐字节一致**（非引擎回归），n=96
  时两路径都到 "Thus 1+1 = 2"。
- 修复：accept-smoke.ps1 改为只匹配答案区段（回显 prompt 与 `[ Prompt:` 性能行之间），默认
  -n 96。修复后 3 轮 3/3 全过、完全确定。
- zeroing 结论：保留（level 切换时清 [fill,span) 是跨级别正确性保障；A/B logits 逐位一致，
  无数值代价）；GGML_OPENVINO_NO_KV_ZEROIZE 保留为调试逃生门。

## 2026-11-01：缺陷 2 第三轮先导探针——NPU stateful（VariableState）路线证伪
- 探针（tools/npu-probes/，OpenVINO 2026.4.1 Python API，LFM3 同机）：
  - `npu-stateful-probe.py`：read_value/assign 最小图。**NPU 支持 VariableState**——query_state()
    正常、状态跨 infer() 在设备上累积（out2=2 证明；初始值张量被忽略、按 0 初始化）。
    注意 OV Python 构造坑：Model([results], [sinks], [params], name) 的 sinks 在参数**之前**，
    且 sink 必须是 Assign 节点本身（Result 不算 Sink）。
  - `npu-state-vs-param-bench.py`：8.4 MB f16 KV 量级状态，每步耗时对比：
    **参数绑定 6.1-6.3 ms/步（≈1.4 GB/s） vs 设备驻留 state 43-45 ms/步**——stateful 慢 7 倍。
  - 状态大小扫描（2/8/32 MB）：11.4 / 43 / 205 ms/步，≈**5-6 ms/MB（0.18 GB/s）**，
    成本随大小线性——每次 infer() 都走慢速状态检查点路径，不是固定开销。
- **结论**：stateful 化（设备驻留 KV）在当前驱动/插件上是性能反模式，路线证伪；多级 decode 图的
  参数绑定 + 级别裁剪就是当前 OpenVINO NPU 上的最优架构。defect-2 剩余分量里，state I/O 已被
  级别裁剪大幅缩小，下一个独立杠杆是 lm_head（11 ms，[2048]×[128000] 单发 GEMV）。
- 过程注意：**平铺 [1, N] 大形状的 elementwise 图会让 NPUW 编译爆炸**（0.5 MB 平铺 add 图编译
  数分钟、CPU 占满）——探针一律保持 4D 结构。
