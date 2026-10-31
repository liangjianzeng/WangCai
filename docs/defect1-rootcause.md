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
