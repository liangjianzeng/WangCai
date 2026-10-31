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
