# 缺陷 1 根因：NPU scatter 静默丢弃 index-0 写入（2026-10-31 深夜定案）

## 证据链（全部可复现）

1. **上下文初始化的 decode 预热**（pass `decode_1`，`--no-warmup` 也关不掉——它在
   `llama_context` 构造的 `sched_reserve` 里）用哑 token 写缓存 row 0。
2. **静态 prefill 图从不落 row 0**：逐 pass 差分显示行 1..N 都在变、row 0 永不
   变（`prefill_2` 写行 0-39，差分只有 1-8+；`prefill_3` 写 40-43）。
3. **decode 图写入正常**：`decode_1` 落 row 0、`decode_4` 落最后一个 prompt token
   的行（llama.cpp 语义：最后一个 prompt token 走第一次 decode）。
4. **chunk 2 的写入全部落地**（索引 40-43，不含 0）。
5. `NPUW_FOLD=NO` 无效；同一图翻译在 CPU 静态路径上 row 0 正确 → 设备侧
   scatter 执行问题，不是本仓库的图翻译。
6. 跨 prompt 逐位相同的"第 0 行常量" = 哑 token 的 K（之前误判为"单分量反号
   向量"的结构，其实就是另一个 token 的 K）。
7. V 缓存同样中招（`decode_2` 的 V row 0 == `prefill_5` 的 V row 0，cos=1.0000）
   ——早前"V 完好"的结论是因为预热的 V 恰好与真实值相关性高。

## 一个 bug，三个症状

- K 缓存 row 0 错（全部注意力层）；
- V 缓存 row 0 错；
- **卷积状态"写回垃圾"**（status.md 缺陷 1 的另一个病灶）：状态的写同样是
  index-0/首槽 SET_ROWS——待专项确认，若成立则缺陷 1 的两个现场合并为一句
  话：**NPU 的 scatter 把索引 0 当跳过哨兵**。

## 修复方向

静态 prefill 图的写范围在编译期已知且**连续**（[pos_begin, pos_end)）——
把 scatter 换成静态切片写（Slice/Concat 或 SetRows 的静态特化），完全绕开
索引 0；或者对索引编码做 +1 偏移并在线性层补偿（更丑）。decode 图索引通常
非零、不受影响，无需改动。

## 排查过程中的弯路（值得记住）

- "驱动楔住"→ 实为主机内存预算（缺陷 6/7 重框）；
- "单分量反号向量/k_norm 分母错轴"→ 实为另一个 token 的 K 残留；
- "预热转储污染"的旧叙事（npu-internals §4）**一直都是对的**——本日下午的
  "重测推翻"本身才是错的：当时没有做逐 pass 写入差分。

## 2026-11-01 修正：根因不是 scatter 丢写入，而是**全零卷积状态下的 NPU 计算**

scatter 理论被四个实验推翻：裸 ScatterUpdate（python，索引 0）正常；精确复刻 SET_ROWS
形状/轴的 ScatterUpdate 正常；pad+shift+slice 和 ScatterND 两种替换写入路径结果
完全相同（row0 不变）——写入算子无关。

真正的机制（DEBUG_INPUT 索引转储 + 逐 pass 差分定案）：

1. `llama_context::sched_reserve` 的初始化 decode 预热（`--no-warmup` 关不掉）用
   **BOS（= prompt 的 position 0）**写 cell 0；之后 prefill 的索引从 1 开始
   （`DEBUG_INPUT` 实证：chunk-1 = [1..39]，两台设备一致）——这是正常的 llama.cpp
   cell 记账，BOS 的 K 从此只来自这一次预热。
2. 预热 pass 是**唯一以全零卷积状态运行**的 pass。CPU 上它算出正确的 K(BOS)
   （范数 30.29，生成连贯佐证）；NPU 上同一个输入算出 65.49 的错误 K
   （cos 仅 0.29）。**NPU 的短卷积/状态路径在全零初始状态下计算错误。**
3. 真实第一个 chunk 同样读全零状态 → conv 输出错 → 写回的状态错 → 级联
   ——这正是本文档早前记录的"conv 状态写回垃圾"现场的统一解释。

### 下一步
- 最小复现：SSM_CONV（GroupConvolution）零状态 vs CPU，逐算子定案（TBO
  `-o SSM_CONV` 或 python GroupConvolution 直接对拍）；
- 修复方向：conv 状态零初始化的 NPU 语义（memset/fill 顺序、状态切片视图），
  或 conv 算子的零状态特例。

## 复现进展（同日续）
- 裸 GroupConvolution（depthwise, 4D data + 5D kernel, python 对拍）：NPU vs CPU
  max diff = 0.003（f16 噪声级）——**conv 算子本身干净**。
- 缺陷收窄到 SSM_CONV 的**状态路径**：零状态的 state 缓冲视图/切片 + 写回。
  下一步：用真实形状（state [d_conv-1,C] 前缀 + 输入拼接的 view、写回末
  d_conv-1 列的 SET_ROWS/COPY）做 python/引擎级对拍，重点看 view 偏移在
  NPUW 降级下的行为。

## 2026-11-01 最终定位：静态 decode 图的 K 分支写入垃圾值（量化对齐后铁证）

量化对齐对（Q4_K_M + 两侧 q4_sym128_all）逐 pass 时间线：

| pass | l02 row0 | l02 row43 |
|---|---|---|
| prefill_0（ctx 预热） | **1.0000 ✓** | — |
| decode_2（首次 decode） | **0.2868 ✗ (67.63)** | — |
| prefill_3/4（真实 prompt） | 0.2868（残留） | **0.9999 ✓** |
| decode_5（首次真实 decode） | 0.2868（残留） | **0.1619 ✗ (51.48)** |

- **prefill 的每一次 K 写入都逐位正确**（含 row0！之前的"row0 从不被写"是
  llama.cpp 正常 cell 记账：ctx 预热 decode 消耗 cell 0 后 prompt 从 cell 1 开始）；
- **每一个 decode pass 写入的 K 值都是垃圾**（首次 decode 把 cell 0 从正确值改写成
  67.63 范数的错误向量；之后每个生成 token 的 K/V 全部写坏 → 后续注意力全吃垃圾
  → 答非所问）；
- conv 状态在量化对齐后完全正常（0.9998-1.0000）——早前"conv 状态写回垃圾"是
  native-Q4_0 对 Q4_0_128 的量化差异假象；
- 同权重同算子，prefill 图对、decode 图错 → 缺陷在 **decode 图 K 分支的
  计算/视图切片**（W_k 之后、SET_ROWS 之前的某环节；注意 decode 图独有的
  Mod(idx, rows) 包装与 1-token 形状下的 k_norm/RoPE 视图）。

### 修复入口
对拍 decode 图与 prefill 图对同一 token 的 K（例如 2-token prompt：第二个 token
分别走 decode 与 2-token prefill），把差异压到 Mod/k_norm/RoPE/MUL_MAT 视图之一。

## 2026-11-01 算子级定位（decode_5 同 pass 内对照）
- V row43：0.9998，四头全部精确 → hidden、W_v、scatter、状态全链路正确；
- K row43：h0 cos+1.000（13.03 vs 13.03）、h2 +1.000（14.90=14.90）逐位精确，
  h1 -0.600（范数 17→33）、h3 +0.410（13.8→34.1）摧毁；
- 同一 token 同一 pass：prefill 的 K（N=4 matmul）逐位正确，decode 的 K（N=1）错
  → 排除权重打包/量化/hidden/scatter；破坏在 decode 图 K 独有的 k_norm+RoPE 链；
- 损坏周期 = 256 元素（每 512 元素行内 [0-127]✓ [128-255]✗ [256-383]✓ [384-511]✗）
  → 视图/偏移类错误，非数值精度；
- 下一步：转储 decode 图 IR（GGML_OPENVINO_DUMP_IR），对照 prefill 图的 K 分支
  k_norm/RoPE 视图节点；嫌疑集中在 1-token 形状下 k_norm 的 [4,128] reshape 视图
  与 RoPE 的 cos/sin 常量索引。

## 2026-10-31 定案：根因 = 静态 decode 图 RoPE 的 cos/sin 头轴广播在 NPUW 降级下坏掉（已修复并验收）

（commit `63179ef`；本节时间按硬件验证日回填。上文"2026-11-01"字样的条目实际同属本工作日的深夜段。）

### 决定性证据链（graph-output 调试构建，`ggml_dup` + `ggml_build_forward_expand` 制造图输出）

1. decode_1 的 K **pre-norm / post-norm 在 NPU 上完全正确**（cos 0.997+，范数逐位一致）
   → MatMul(W_k)、k_norm 全链无辜；缺陷只可能在 post-norm 之后的 **RoPE**；
2. 缓存 K row 0 只有**偶数 128 块正确，奇数块是跨构建逐位相同的确定性垃圾**——与上文
   "h0/h2 逐位精确、h1/h3 摧毁、256 元素周期"同一签名；
3. NPU post-rope vs pre-rope（**位置 0，数学上恒等**）：h0/h2 cos = 1.0，h1/h3 cos 0.38/0.49
   → 缺陷 = 静态 decode 图 rope 的 cos/sin `[1,1,1,128]` **沿头轴广播到 [1,1,4,128]** 的隐式
   broadcast，在 NPUW 的 1-token（GEMV）形状降级下错误 tile。prefill 图同构广播在
   [1,256,4,128] 上正确，故 prefill 无恙。

### 修复

- **`rope.cpp`**：静态 decode 图把 cos_full/sin_full 沿头轴**显式 Concat tile** 到 `[1,1,4,X]`，
  绕开隐式广播。位置 0 恢复恒等；缓存 row0 四头 cos 0.997+、范数逐位一致。
- **`translate_session.cpp`**：`AlignEltwiseOperandRanks` 的注册门从 `is_gpu()` 扩到
  gpu/npu/`FORCE_STATIC`——此前所有"tile 无效"实验都是被这扇门挡住的**死代码**（教训 a，见下）。
- **`align_eltwise_ranks.cpp`**（同秩 tile 扩展，norm 门 + 跳过 Constant；已验证对结果中性，
  保留是因为它在 decode 图上把 343 处隐式广播材料化，属防御纵深而非本缺陷的必需修复）。

### 验收

三问验收（`accept.ps1`，贪心解码 48 token）**首次全对：3/3**——Q2 明确答 "Beijing"、Q3 明确答
"Paris"、Q1 推理正确。缺陷 1（status.md）就此关闭；milestone 1.1 / 1.2 转 ✅。

### 弯路清单（已被实验证伪的假设，勿重测）

scatter 三种实现（ScatterUpdate/ScatterND/pad+shift+slice）、NPUW FOLD/FUNCALL/DQ（`NPUW_DQ=NO`
逐位不变）、广播 tile 的旧版 AlignEltwiseOperandRanks（只处理秩不同广播，从未覆盖同秩与 Constant）、
conv 算子（python 对拍 0.003 噪声级）、权重量化、hidden 链（V 完美佐证）、RMS 512 池化
（IR 复核：ReduceMean 是 [1,1,4,128]→[1,1,4,1] 每头 128 分组，图翻译本身正确）、驱动状态/内存预算。

### 当日方法论教训

a. **先确认 pass 真的在跑，再解释它的"无效"。** AlignEltwiseOperandRanks 曾被 `is_gpu()` 门住，
   NPU 上全部"tile 无效"实验都是死代码——一次无效实验浪费了多轮重建。改 IR 后 IR hash 必变，拿它当
   生效判据。
b. **"解码行全坏 / h0h2 精确"等旧结论是 pass 错位比较的产物。** 转储比对前先按字节对齐 pass。
c. `ggml_set_output` 不足以制造图输出（遍历不可达）；要 `ggml_dup` + `ggml_build_forward_expand`。
d. LFM3-1.7B 走 `lfm3.cpp` 不是 `lfm2.cpp`——打补丁前先确认模型到 builder 的映射。
