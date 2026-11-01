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

## 2026-11-01：缺陷 2 lm_head 杠杆探察——u4 化证伪，F16 常量即当前快路径
- 判定（IR 解析 + 代码路径）：LFM3 的 lm_head 与 token_embd 共享（GGUF 无 output.weight，
  token_embd 为 Q6_K）。NPU 上被 `ggml_openvino_get_requant_type` 强制 **F16 常量（~524 MB）**
  ——历史原因是 Q8_0_C cluster 布局在 NPUW 上 execute 崩（ZE_RESULT_ERROR_UNINITIALIZED），
  注释以"vocab 每 token 只读一次"接受之。多级 decode 图落地后它成了最大单项：
  **13.7 ms/步（38 GB/s，带宽界附近）**。CPU 静态路径则是 Q8_0_C（i8 262 MB）。
- 实验（新增 `GGML_OPENVINO_REQUANT_EMBD_Q4=1`，token_embd → Q4_0_128，与其余层同款 u4；
  已登记 extra_cfg allowlist）：NPU 实测 **13.0 → 2.5 t/s，慢 5 倍**——NPUW 压缩 MatMul
  （GatherMatMulCompressed）对 [1,2048]×[2048,128000] 高瘦形状不划算；三问验收 3/3 精度无损
  但性能反模式。**结论：u4 lm_head 证伪，F16 常量即当前快路径**；选项保留为默认关（零风险，
  blob 缓存键已隔离）。
- c512（level==ctx）decode 步现状（PROFILING=2，多级 build）：状态输入两 Parameter 合计
  ~33.7 ms（level 256 时 KV≈全 ctx，裁剪无收益）+ attention Multiply 22.4 ms + lm_head 13.7 ms。
  decode 15 t/s 下进一步提速的可行方向只剩：状态 I/O 的布局/搬运优化（非 stateful，已证伪）、
  attention Multiply 的算子降级路径、或 llama.cpp 侧 vocab 裁剪（只算候选 token 的 logits，
  涉及采样器改动，超出本轮）。**decode 攻坚就此收官，转 2.2 热启动。**

## 2026-11-01：里程碑 2.2 第一轮——热启动 23 s → 8.9 s（三项修复）
### 启动时间分解（-lv 5 + GGML_WARM_TRACE 逐段实测，c512、warm blob 缓存）
原 23 s 的构成：**权重 repack ~10 s** + 图转换 ~2.3 s + NPUW 编译/导入 ~2×1 s + 首次推理 ~1.1 s
+ 采样/其它。逐项发现：
- **repack 串行且标量**：`requantize_to_buffers` 的全量物化路径对每张 8.44 MB FFN 权重耗时
  ~0.09 s（94 MB/s），153 张张量串行 ≈ 10 s；token_embd（Q6_K→F16，205 MB）单张 0.75 s，其中
  大头是 1 GB 的一次性 f32 暂存分配。
- **ov::parallel_for 是串行回退**：本机 OpenVINO 构建无 TBB/OpenMP 时它退化为单线程
  （实测 worker threads = 0）——不能指望它并行化任何加载期工作。
### 修复（本轮落地）
1. **requant 全量物化路径按行分块并行**（ggml-quants.cpp）：std::thread 池（24 线程），chunk 边界
   对齐偶数块保持 u4 zp 字节对（对称 i4 无 zp，显式 symmetric 参数绕过元素类型推导——
   字节偏移 view 的 u8 包装会骗过 is_symmetric 判断）；每 chunk 独立 scratch，消掉 1 GB 暂存。
   token_embd 0.75→0.11 s，FFN 单张 0.09→0.01 s，**整体 repack ~10 s → ~1 s**。
   不满足行对齐/块偶数条件时回退原串行路径（Q4_1_64 一律串行）。
2. **make_dirs 的盘符 bug**（model-cache.cpp）：`_mkdir("D:")` 返回 EACCES 使
   GGML_OPENVINO_COMPILED_MODEL_CACHE_DIR 在任何 Windows 盘符路径下**静默失效**。跳过 "X:" 组件。
3. **多级 decode 图接入 COMPILED_MODEL_CACHE_DIR**（utils.cpp build_static_model）：prefill /
   decode@level 各自指纹（phase tag + level 混入 extra_cfg），import 跳过转换+编译。
### 当前状态与剩余
- 热启动实测 **8.9 s**（llama-completion -n 4，warm blob 缓存）。距离 <5 s 目标剩两项：
  ① CM 缓存在 NPU 上 import 失败——**NPUW 导出的 blob 不含权重**（26 MB/图），import 需要提供
  WEIGHTS_PATH 或 MODEL_PTR（指向与导出时相同的权重存储）；三种图各报一次 WARN 后回退编译。
  下一轮把权重缓冲 dump 成文件并注入 NPUW 权重属性（预期再省 ~4.4 s：转换 2.3 + 编译 2.1）。
  ② 首次 prefill 推理 1.1 s（图首次下载到设备）。
- 无回归：NPU 14.5 t/s + 三问 3/3；CPU accept-smoke 3/3。
- 测量基建：GGML_WARM_TRACE=1 打开 repack/加载分段 trace（env 门控，标记 TEMP，2.2 收官时拆除）。

### 2.2 后续探针：NPUW 无权重 blob 的 import 契约（tools 探针 probe_stateful/probe_mp*.py）
- python（numpy 常量，OV 自持内存）编译导出的 blob **内嵌权重**（290 KB 小模型），import 无需任何
  property；带 `WEIGHTS_PATH` 指向同内容 .bin 也 OK，`MODEL_PTR` 传裸地址报
  "Incompatible model argument"（它要的是 ov::Model 实例，不是指针——名字有误导性）。
- 引擎 C++ 导出的 blob **无权重**（26 MB/图）：权重常量直接包装 backend 权重缓冲（避免每图复制
  1.3 GB），NPUW 识别为外部权重 → 导出 weightless blob，import 断言要求 WEIGHTS_PATH 或 MODEL_PTR。
- `WEIGHTS_PATH`/`MODEL_PTR` 字符串确认存在于 openvino_intel_npu_plugin.dll；但 NPUW 期望的文件
  布局/偏移基准无法从二进制推断（python 的成功案例不能外推——它的 blob 本就带权重）。
- **结论**：<5 s 的最后 ~4 s（转换 2.3 + 编译 2.1）需要拿到对应 OpenVINO 提交的 NPUW 源码，确认
  weightless blob 的权重重定位契约（或改用权重内嵌导出 + 每图 1.3 GB 暂存副本的方案）。已列入下一轮。
- 其它备选（记录）：dual 分支的 decode@ctx 图改惰性可省启动 ~1.5 s，但把 1.5 s 卡顿挪到 256-token
  跨级点，且后台预热会与 NPU 设备预算（缺陷-7）冲突，暂不动。

### 2.2 后续：NPUW 权重分离（WSH）契约已从源码完全打开
- NPUW 插件源码已定位并 sparse-clone 到本机：`D:\llm\npu\probe_stateful\ovsrc`
  （openvinotoolkit/openvino master，`src/plugins/intel_npu/src/plugin/npuw/`；注意 master 里 npuw
  已从 `src/npuw` 移到 `src/plugin/npuw`）。
- 关键代码路径：
  - `npuw/compiled_model.cpp:98` `should_use_weightless_flow`：NPUW_FOLD 开（默认）且
    const_to_offset 非空 → 导出 weightless blob；
  - `npuw/compiled_model.cpp:120` `make_import_weights_ctx`：import 时按优先级
    `WEIGHTS_HANDLE_PROVIDER`（ov::FileHandleProvider 回调，可给 mmap 句柄）→
    `WEIGHTS_PATH`（ov::weights_path，mmap 文件）→ `MODEL_PTR`（**ov::hint::model**，
    是 `shared_ptr<const ov::Model>`，不是裸指针——名字有误导）；
  - 权重引用 = blob 里记录的 `(bin_offset, size)` 对，`bin_offset` 由
    `src/core/src/weight_sharing_util.cpp`（ov::weight_sharing WSH pass）在编译预处理时打进
    `WeightlessCacheAttribute`——**指向 WSH 重建的共享权重存储**，不是我们的 backend 缓冲。
- **下一轮实现方案（按优先级）**：
  1. 引擎侧自行走 WSH 等价流程：把三张图共用的 1.3 GB 权重缓冲写一次
     `<cache_cm>/weights.bin`，并给 create_weight_nodes 产出的常量打上对应 bin_offset 的
     WeightlessCacheAttribute（或改从 ov::read_model(xml,bin) 读回），使 NPUW 导出/导入的
     offset 语义对齐——import 即 mmap weights.bin（~0.45 s/图）。
  2. 或者放弃 weightless：让常量在编译期持副本（每图 +1.3 GB 暂存），blob 内嵌权重，
     import 免属性——磁盘 3.9 GB、净省 ~2.6 s。
- 预期账目（即使全部打通）：CM 缓存净省 ≈2.6 s（转换 2.3 + 编译省差），热启动 8.9 → ~6.3 s；
  到 <5 s 还需解决首次设备图下载 1.1 s 与 NPUW blob import 的 ~1 s——需要 NPUW 深处（LLM
  compiled model 的 init schedule）或接受 6 s 量级作为 2.2 的阶段性目标。

### 2.2 后续：CM 缓存 NPU 实测——机制性不可行，保持 opt-in 关闭（本轮终态）
- 打通后发现：prefill 能 OPTIMIZE_SPEED 内嵌权重导出/导入（4.1 GB 缓存目录，import 0.3 s ✓），
  但 **imported 模型的权重 bank 与后续编译的 decode 图不共享**——设备权重重复，执行劣化 10×
  （decode 729 ms/token vs 正常 75 ms），踩缺陷-7 的设备预算。decode 图也不能 CM import：
  shared bank 的 `read_and_add_tensor` 对重复 UID 直接 assert（NPUW import 无去重——GenAI 流程
  每进程只 import 一个模型）。
- 结论：**NPU 上不要设 GGML_OPENVINO_COMPILED_MODEL_CACHE_DIR**（默认未设，无影响）。CM 缓存
  代码保留（CPU/GPU 路径可能受益），<5 s 的剩余 ~4 s 需等 NPUW 支持 bank 感知的 blob import
  （权重句柄 provider / bank 去重），已记录于此。
- 热启动终态：**默认路径 8.9-9.4 s**（repack 并行化贡献 ~14 s）。无回归：NPU 三问 3/3、
  CPU accept-smoke 3/3。

## 2026-11-01：音频"回归"定案——三层因果链闭合（NPU 音频恢复正确输出）
- 现象回顾：NPU/CPU 静态音频在多级 decode 提交后输出坍缩为 "<think>"+EOS/静默退出；NPU 另有
  level 图 UNINITIALIZED 崩溃。逐层 dump 对比（GGML_OPENVINO_DUMP_BIN + 逐层 KV cos）定位：
- **因果①（已修复）音频编码器 requant 精度**：NPU 默认把 Q4_0 重分组到 group-128 对称，对
  mmproj conv 栈（"a."-前缀张量）是纯损失——projected 嵌入对 CPU 静态参照 cos 0.963（范数系统性
  +12%），音频答案在 <think> 后立即 EOS。修复：NPU 默认对 "a."-前缀 Q4_0 走 native（其余 Q4_0
  保持 Q4_0_128——LLM 侧 group-128 是 GatherMatmulCompressed 的性能最优，native 化会让 1.7B
  decode 掉到 8.5 t/s）。修复后编码器嵌入 cos 0.9997（fp16 噪声级）。
- **因果②LLM 权重量化不一致**：CPU 静态（q4_sym128_all → Q4_0 native）与 NPU 默认（Q4_0→128）
  的 LLM 权重不同。逐层 KV cos 显示两条路径的 NPU-vs-CPU 分歧幅度同级（文本 layer12=0.734、
  音频 layer12=0.76），文本答案余量大不受影响、音频答案落在边际敏感区被翻转。NPU 用
  `REQUANT_KQUANT=q4_sym128_all`（与 CPU 参照同量化）后，NPU 音频输出与 CPU 静态/native Q8_0
  参照逐字一致："A high-pitched, pure"。
- **因果③（遗留）Omni-2B + level 图 = 缺陷-7 设备预算**：Omni-2B 的 decode level 图首次
  execute 即 ZE_RESULT_ERROR_UNINITIALIZED（非确定性，与设备碎片化相关；曾有一次全程成功）。
  Omni 上需 `DISABLE_DECODE_LEVELS=1`。1.7B 文本模型不受影响（15 t/s ctx 无关保持）。
- 验证矩阵（本轮终态）：NPU 音频正确输出 ✓（q4_sym128_all + levels off）；CPU 静态音频 ✓；
  1.7B NPU decode 14.0-14.7 t/s @c2048/c8192 ✓；CPU accept-smoke 3/3 ✓。
- 已知待办：①引擎级 fallback——level 图 execute 撞 UNINITIALIZED 时自动降级重编 ctx 图重试
  （消灭 Omni 上的 env 需求）；②mtmd-cli 无 perf footer 且尾部截断的退出路径（三方向都在，
  与本回归无关）；③"top-1 分歧定性"升级为"分岐幅度定性"——文本/音频同量级，答案余量决定
  是否可见，原"f16 复利"结论成立并已量化。

## 2026-11-01：level 图设备预算自动降级重试落地（消灭 Omni 的 env 需求）
- 机制：decode level 图 `infer()` 抛 ZE_RESULT_ERROR_UNINITIALIZED 时（defect-7 族：设备预算装不下
  prefill + level 图），置进程级 `g_decode_levels_disabled` 开关、清空全部 level 缓存/decoder、解锁
  entry mutex 后递归重入一次——重入时 decode_level=0，走 full-ctx decode 图（decode-only 分支编译
  ctx 图并**发布到 ctx-pair 缓存**而非 level 缓存，否则每步重编译）。
- 两个实现坑（已记）：①entry mutex 非递归——重入前必须 `lock.unlock()`（unique_lock），否则
  "resource deadlock would occur"；②decode-only 分支的发布目标按 decode_level==0 分流。
- 实测：Omni-2B NPU 音频**无 env、全新缓存**自动触发降级（level 256 撞预算 → 重试）并输出正确
  完整描述（"A high-pitched, pure"）；1.7B 文本不触发（levels 保持，14.4-14.8 t/s @c2048/c8192），
  CPU accept-smoke 3/3。
- NPU 音频已知可用配置简化为：`REQUANT_KQUANT=q4_sym128_all`（LLM 量化对齐参照；编码器已由
  "a."-豁免自动保护）。mtmd-audio-c512.ps1 已同步更新。

## 2026-11-01：视觉输入首探——native 参照通过，静态翻译有一个明确的 rope 形状烘焙缺陷
- native（-dev none，Q8_0）：**视觉端到端直接可用**——测试图（448² 深底红圆+绿条）输出
  "A flag with a black upper field containing a large solid red circle ... green horizontal band"，
  描述精确。mmproj 含视觉编码器（133 个 v. 张量）+ 音频（313 a.）+ 投影（12 mm.）。
- OpenVINO 静态路径（CPU FORCE_STATIC）在 ViT 内失败：
  `Multiply_153226: [1,784,16,64] × Concat [1,3136,1,64]` broadcast 失败。784=28²（448/16 patch conv
  输出），3136=56²——rope/位置频率 Concat 按 56×56 烘焙而 conv 走 28×28，与音频 reshape-bake 同类
  （cont.cpp dst_shape 全烘焙 / 静态形状捕获错位）。附带一串
  "cannot determine dynamic dim for RESHAPE node 'conv_spatial-N'" 告警——视觉 patch 维未标动态。
- 下一轮方案（按音频 XIV 的成熟打法）：①compute_node_dynamic_dims 给视觉 patch 轴标动态；
  ②定位 3136 烘焙源（rope freqs 的静态捕获），对齐 conv 输出的 patch 数；③NPU 验证。
- mtmd-cli"退出路径"项核销：修复后 NPU 音频输出与 native 参照含停止点逐字一致（EOS 是模型行为），
  perf footer 本就是 mtmd-cli（experimental CLI）不打印的——非缺陷。
- 测试资产：D:\llm\npu\test_image.png（合成图，红圆+绿条）；ctrl/vis_native.ps1、vis_ov.ps1。

### 视觉缺陷精确定位（cgraph dump 证据）
- cgraph（vis_cg/cgraph_ov.txt）全程 784 token（448/16 patch ✓），ROPE 节点 Q[64,16,784]/
  K[64,8,784] 正常。3136 只在 OV 翻译产物里出现：失败 Multiply 的 Concat 输入 [1,3136,1,64]
  = **4×784——视觉 rope 的 4 段式位置表（每 patch 4 行，2D 轴向 rope 的 4 个分段）被当成
  784×4 个 token 直接喂进 Multiply**，而 native 动态翻译会对分段做切片。
- 修复方向：静态 rope lowering 支持 mrope 分段（读 rope src 的分段配置，按段切片 cos/sin 再
  逐段乘回），或视觉图走动态翻译（编码器图非 decode，动态路径本就支持——查它为何被路由进
  静态：编码器图 is_static 判定 + FORCE_STATIC 强制；FORCE_STATIC 下编码器图也可考虑豁免走
  动态，先验证数值再谈性能）。
- 快速验证建议：FORCE_STATIC=0 + 设备 CPU（动态路径）跑视觉——若通过则"豁免编码器图走动态"
  即为最小修复；NPU 上编码器图动态执行是否可行另测（编码器非 decode，设备预算压力小）。

### 视觉探针补充：OpenVINO 动态路径 CPU 通过，NPU 仍卡 NPUW
- CPU 动态路径（FORCE_STATIC=0，native 同款翻译）：**视觉端到端正确**（输出与 native 一致）——
  4 段式 rope 在动态翻译里本就被正确处理，最小修复假设证实。
- NPU（动态路径）在 NPUW 编译期撞同一 broadcast 断言——NPUW 有自己的 shape inference/降级管线，
  对 4 段位置表同样不兼容。NPU 视觉的两条路线：①静态 rope lowering 支持 mrope 分段（与 CPU 静态
  同修）；②NPUW 侧配置/变换规避（NPUW_DQ/FOLD 类开关逐个试）。均列下轮。
- 里程碑 4.x 现状：音频 ✓（NPU/CPU），视觉 native ✓ / OV-CPU 动态 ✓ / 静态与 NPU 待修。

### 视觉 rope 最终证据：positions 叶子 [3136] 与 784 patch 的静态绑定错位
- cgraph：ROPE src[1] = `positions` [3136,1,1,1]，标记 **CPU 后端叶子**——视觉 2D 轴向 rope 的
  4 坐标/patch 位置表（784 patch × 4）。静态绑定路径把它当 3136 个 token 喂进 rope 的
  theta 计算（cos_theta reshape [1,3136,1,64]），与 data [1,784,16,64] 失配。动态路径绑定
  "positions" 的方式不同（native/OV-CPU 动态均正确），说明修复点在静态绑定/下钻：
  按 rope sections（op_params 内）每 token 取 4 坐标展开，与文本 inp_pos 的绑定对齐。
- 状态留档：cgraph dump 证据在 ctrl/cgraph_ov.txt（临时，下轮开工时重新生成即可）。

## 2026-11-01：副靶立项 Spark-X2.6-4B——跨模型验证 + u4 权重宿主视图修复

**目的**：主靶一直是 LFM3 系（混合架构），引擎的算子翻译层是否只对 LFM3 成立需要一副靶回答。
选定讯飞 **Spark-X2.6-4B**（bartowski Q4_K_M GGUF，2.5 GB，标准稠密 Transformer，上游 llama.cpp
已原生支持，vendored abb76ab 直接加载无需改模型代码）。

### 结果矩阵（同机 275HX / OV 2026.4.1）

| 路径 | LFM3-1.7B | Spark-X2.6-4B |
|---|---|---|
| native CPU（`-dev none`，参照） | ✓ | ✓ 151.9/19.9 t/s |
| OV-CPU 动态 | ✓ 96.3/23.1 t/s（裸跑，无 requant env） | ✓ 77.4/8.2 t/s（裸跑） |
| OV-CPU 静态（三问验收） | ✓ 3/3（无 env） | ✓ 3/3 |
| NPU 静态 | ✓ 14.7 t/s（c1024） | ✓ 3/3（2.4 t/s，chunk128+禁 levels） |

**跨模型结论：引擎翻译层不是 LFM3 专用**——另一家族、另一架构、另一模板（含 thinking）的 4B
模型在同一套 ggml-openvino 路径上端到端跑通并通过全部精度验收。

### 修复一：u4 无法包宿主内存（阻塞所有非对称 4-bit 路径）
这份 OV 构建里 `ov::Tensor(u4, shape, host_ptr)` 与 `ov::Constant(u4, shape, raw_ptr)` 都抛
`is_pointer_representable`（u4/i8 通过）——**所有非对称 4-bit 权重路径从未可用**：native
Q4_K/Q4_1（Q4_K_M 最常见格式的 OV-CPU 路径，README 的 OV-CPU 数字当年必然带了 requant env，
accept-smoke.ps1 里的 env 注释即为佐证）和 `REQUANT_KQUANT=q4_asym64*`。三层修复：
1. `process_weight_tensor` 的 `wrap_or_detach`：u4 槽位改为内部分配 + 提取后回写（槽位契约不变）；
2. `make_int4_weights` unsigned 分支：`Constant` 从 ov::Tensor 拷贝构造，不再裸指针共享；
3. `count_bad_f16` 校验只对 f16 元素类型的 scales/zp 做（u4 zp 上 `data<f16>()` 本身就是那条断言
   的抛出点——detach 打通前两关后才暴露）。

### 修复二：native 非对称提取统一精确 f16 零点
修完 1 之后 native Q4_K 首次可用，随即暴露：整数 zp 的 `round(min/scale)` 舍入让 LFM3 静态图
思考退化成 "\n" 死循环（动态路径侥幸正确）。MoE 专家早因同一误差改用精确 f16 零点（bias 形态，
仍可融合 GatherMatmulCompressed）；现在推广到全部 native 非对称提取（Q4_K/Q4_1/Q5_1/Q5_K），
`extract_quantized_weights` / `process_weight_tensor` / `get_extracted_layout` 三处同步。修复后
LFM3 与 Spark 的 OV-CPU 静态三问无 env 全 3/3，`accept-smoke.ps1` 的 requant env 已摘除。

### NPU 4B 预算实测
- 4B（requant 后 ~2.3 GB 权重）默认配置（chunk256 + decode levels）在图编译完成后**执行期**撞
  `ZE_RESULT_ERROR_OUT_OF_HOST_MEMORY`（系统 RAM 空闲 28.8 GB，是驱动侧预算，非系统内存）。
- `GGML_OPENVINO_PREFILL_CHUNK_SIZE=128` + `GGML_OPENVINO_DISABLE_DECODE_LEVELS=1` + c512 可跑：
  prefill 16.8 t/s（chunk 口径失真偏保守）、decode 2.4 t/s。**开 levels 反而更慢**（1.5 t/s）——
  level 图与权重 bank 竞争预算。副靶配置脚本：tools/spark-npu-accept.ps1。
- 4B 是当前驱动/驱动配置下的实际上限候选；2.3 GB 权重 + 单图编译的预算结构见
  npu-internals.md（未再深挖，留给上游 NPUW bank-aware import）。

### 遗留
- NPU 4B decode 2.4 t/s 未优化（lm_head F16 常量在 4B 上更贵——152k×4096 词表；u4 化已被
  里程碑 2.2 轮证伪，但那是 1.7B 的结论，4B 值得复测一次）。
- 视觉 4 坐标 positions 静态绑定修复仍是下轮主任务（本节未动）。

### 补充（同轮）：Qwen3-4B NPU 复测翻案
2026-10-31 记录的 Qwen3-4B NPU"从第一步单 token 塌缩（GGGG…）"在当前引擎上不再复现：副靶配置
（chunk128 + 禁 levels + c512）下输出连贯，三问验收 **3/3**（decode 2.3 t/s）。两个外部模型家族
（Spark-X2.6-4B、Qwen3-4B）全部通过 NPU 精度验收。当时塌缩的根因未单独定案（其间落地了 KV 环
修复、level 自动降级、u4/f16-zp 修复等多个改动），按复测证据翻案。

## 2026-11-01：性能轮——4B NPU decode 2.4 → 4.9 t/s（level 预算三图问题）

**用户核心目标调整：性能优先。** 副靶 4B 的 2.3–2.4 t/s 不可用，本轮全程定位。

### 排查链（每步都有实测证据）
1. `GGML_OPENVINO_PROFILING=1`：每步 436–480 ms **全部在 NPU 图执行内**（主机绑定 <10 ms）。
2. ctx 对照：c256 = 164 ms/步、c512 = 436 ms——成本 ∝ 环/span 超线性。
3. 算子级 profile（`PROFILING=2`）：KV ScatterNDUpdate 每实例 8 ms（写 4 KB 进 1 MB 环）、
   rope 路径 Add 30 ms（16 KB f32）——小算子按 span 缩放的执行/调度开销；LFM3 同设置
   全步 92 ms、Add 仅 3.8 ms（24 层 vs 36 层 + 全局注意力层数差异）。
4. **levels 为何失效**：level-256 图编译成功后**首个 execute 即
   ZE_RESULT_ERROR_UNINITIALIZED**（-lv 5 日志实锤），自动降级后稳态全程跑全 ctx 图。
   根因：**设备预算 = prefill + 一张 decode 图（权重 bank 按 CompiledModel 计），而 prefill
   在新 entry 上还会预编 legacy 全 ctx decode 图 → 三图常驻**。1.7B（3×1 GB 权重 bank）
   装得下三图所以 LFM3 从未暴露；4B（3×2.3 GB）必爆。
5. 编译开关矩阵（FUNCALL/DQ/FOLD overrides）全部无效（2.4→2.6/2.7，DQ=NO 编译失败）——
   结构性问题，不是开关问题。

### 修复（utils.cpp，三处）
- `decode_levels_active` 常量：levels 激活时 prefill **不再预编 legacy 全 ctx decode 图**。
- level 编译分支：连同 legacy decode 图一并驱逐（level==0 时的发布逻辑不变，fallback 重进时按需重编）。
- level==0 的 cache_hit 按相位拆分（prefill 只看 prefill 半区；复用检查改绑实际使用的
  decoder——原实现解引用 null `entry->ptr` 会段错误，已实测踩过并修复）。

### 结果（275HX / NPU 3720，热缓存稳态）
| 模型 | 修复前 | 修复后 | 验收 |
|---|---|---|---|
| Spark-X2.6-4B c512 | 2.4 t/s | **4.9 t/s**（raw infer 436→~150 ms） | 3/3 |
| Qwen3-4B c512 | 2.3 t/s | **4.0 t/s** | 3/3 |
| LFM3-1.7B c1024 | 14–15 t/s | 13.1 t/s（无回归） | 3/3 |

level 基数 256 vs 128 实测持平（4.7 vs 4.5），保持 256（少一次 level 编译）。

### 剩余差距与下一步（按杠杆排序）
4B 理论下限 ≈ 2.3 GB 权重 ÷ 15.7 GB/s（LFM3 实测带宽）≈ 145 ms/步 ≈ 7 t/s；当前 4.9。
1. **标准注意力的算子降级开销**：36 层 × span 的 scatter/rope 小算子群（LFM3 只有 11 层
   注意力 + 短卷积）。方向：把 QK^T/softmax/PV 链折叠进 DPU 大子图（NPUW FOLD 对标准
   GQA 的模式覆盖），或 llama.cpp 侧换 flash-attn 式 KV 写路径。
2. host ~50 ms/步（150 参数逐个 set_input_tensor）——静态参数预绑定。
3. 4B 权重字节：token_embd F16（~795 MB）+ output Q8_0_C（~400 MB）占一半；EMBD_Q4 在
   1.7B 上证伪过，4B 上权重占比更大，值得复测。

### 性能轮补记（同日）：稳态真实数字与算子开销定案

PERFTRACE 插桩（WARMTRACE 门控，decode 步 bind/outbind/infer 分解）+ 长生成消歧：
- **稳态分解（Spark level-256）**：infer 141 ms ≈ 权重带宽下限 145 ms（2.3 GB ÷ 15.7 GB/s），
  bind 3 ms、outbind ~0——**设备已贴带宽地板，主机侧无肉**。
- **headline 失真修正**：`Generation t/s` 含每次进程的 level 图编译停顿与 gen 相位固定开销，
  n=64 时 4.2–4.7，n=128 摊薄后 Spark **5.9 t/s**（逐 token 时间戳实测 145 ms = 6.9 t/s）；
  Qwen3-4B n=128 稳态 **4.5 t/s**（修复前 2.3）。测 4B 必须热缓存 + ≥128 token。
- 算子级 profile（level 图 360 实例）：MatMul ≈ 带宽下限；Add/Multiply/Scatter/Parameter/
  Concat 合计 ~258 实例 × ~0.6 ms 调度开销——但它们与 MatMul 重叠流水，净空 <25 ms/步。
  "把注意力链折叠进 DPU 大子图"的期望收益被实测压缩到 ~10–15%（非此前估计的 2×）。
- KV zeroize（NO_KV_ZEROIZE 探针）：~0.3 t/s，保留（正确性必需）。
- 编译开关（FUNCALL/DQ/FOLD overrides）已证无效；EMBD_Q4 复测（4B 权重字节占 1/3）仍是
  唯一未试的权重侧杠杆。
- **结论：4B 稠密 Q4_K_M 在 NPU 3720 上的 decode 上限 ≈ 7 t/s（带宽决定），已达成 ~85%。**
  再往上只剩上游依赖（NPUW bank-aware blob import、更高带宽的驱动/硬件）。

### prefill chunk 扫描（4B 首 token 延迟）
chunk 64/128/32 实测（Spark-4B c512，13 token prompt，冷启动含编译）：prefill 20.0 / 17.1 /
15.5 t/s，端到端 51 / 58 / ~60 s。chunk64 短 prompt 最优；32 以下每 chunk 固定开销反噬。
EMBD_Q4（权重侧唯一未试杠杆）经复查对 decode 无效——decode 只读 output.weight（Q8_0_C），
token_embd 每步只读一行；且 lm_head u4 化在 1.7B 已证伪（同一下降路径），不复测。

### 4B prefill 正确口径补测（pp512，回应"prefill 为啥差那么多"）
llama-bench -p 512 -n 0：native 166.6 / OV-CPU 95.1 / **NPU(chunk128) 89.4 t/s** = native 的
54%，与 OV-CPU 持平。此前 15-20 t/s 是 13 token 短 prompt + chunk64/128 的 pad 失真（13 token
付 64-128 列）。与 1.7B 的 69% 相比的 15 个点差值 = 预算把 chunk 压到 128/64 的 pad 浪费 +
每 chunk 固定开销；回到 chunk256 需要上游 NPUW bank 去重。测量纪律：短 prompt 看首 token
延迟（秒），长 prompt 看 t/s。

## 2026-11-01：视觉静态翻译跑通——多平面 positions 双计修复（残留精度缺陷另立）

**根因（VISROPE 插桩 + IR 对照实锤）**：视觉编码器是无 KV 的 cacheless 图，`utils.cpp` 里
`prefill_chunk_size = inp_pos->ne[0]` 取了 **3136**——但 llama.cpp 视觉 rope 的 positions 本身
已把 4 个平面打包进 ne[0]（4×784）；decoder 定参时再乘 n_planes → **[1,1,1,12544]** 参数，
make_sin_cos 的多平面 reshape 按每平面 3136 个"token"切 → [1,3136,1,64] 的 cos/sin 表对
[1,784,16,64] 的数据——即此前记录的 Multiply 形状验证失败。音频编码器未爆是因为其 positions
是单平面（除数为 1）。translate_session 的共享 sin_cos（无 mode 参数）已被注释是死路径；
rope.cpp 的 op_case 映射（VISION→3）与绑定侧的多平面处理本身都是对的。

**修复**：cacheless 图取 chunk 时按 ROPE 的 op 分辨多平面并除以平面数（vision → 784）。

**结果**：LFM3-Omni-2B + mmproj 视觉编码器 + LLM 静态翻译端到端跑通（CPU FORCE_STATIC），
此前直接死于形状验证。对照 native：描述方向对（识别出红色图形）但整体描述错误
（native："一面旗帜，上半部分纯黑"；static："三个红色的椭圆形"）——**残留精度缺陷**，
模式与音频轮的编码器精度回归相似（内容要素对、结构错）。下轮：先隔离是视觉编码器还是
LLM 侧图像 token 的 4 平面位置处理（音频路径已验证过 LLM 静态 + 单平面，图像 token 的
mrope 位置是新领域），再对照 patch embeddings 级别找差异。VISROPE/WARMTRACE 插桩暂留
（门控环境变量，精度缺陷关闭后统一拆除）。
