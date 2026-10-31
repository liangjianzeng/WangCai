# 会话交接（上下文耗尽时读我）

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
