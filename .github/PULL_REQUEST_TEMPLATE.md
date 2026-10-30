## 改了什么

<!-- 一段话：改了什么，解决什么问题。 -->

关联 issue / 路线图条目：

## 类型

- [ ] 正确性修复（图构建 / 算子降级 / 缓存契约）
- [ ] 性能
- [ ] 新增环境变量 / 诊断手段
- [ ] 构建或工具链
- [ ] 文档（包括被推翻的假设——这类同样欢迎）

## 测量数据

任何改变执行行为的改动都必须附。请贴真实输出，不要写摘要。

| | 改动前 | 改动后 |
|---|---|---|
| prompt eval (t/s) | | |
| decode (t/s) | | |
| 与 CPU 参照的 top-1 一致率 | | |
| 与 CPU 参照的余弦（decode） | | |

命令行、`-c`、`-b`、`GGML_OPENVINO_PREFILL_CHUNK_SIZE`、prompt / 生成 token 数、编译图缓存是冷是热：

```
```

## 验证

- [ ] `tools\run-npu.ps1 -Backend native` —— CPU 参照仍然连贯
- [ ] `tools\run-npu.ps1 -Backend static` —— CPU 上的静态路径仍然连贯
- [ ] `tools\run-npu.ps1 -Backend npu` —— NPU 运行已记录
- [ ] 附 `tools\compare-tensors.ps1` 输出（任何触及图构建的改动都要）
- [ ] 比对前先用 `tools\top-token.ps1` 对齐 pass
- [ ] 每种配置都使用了全新的 `GGML_OPENVINO_CACHE_DIR`
- [ ] `AGENTS.md` / `CLAUDE.md` 等智能体记忆文件不在 diff 里

## 给评审的提示

- 如果你改了输入形状，静态契约的两侧必须一起动（`get_graph_input_shape` **和**静态绑定器）——
  说明是哪两处。
- 如果你加了环境变量，它必须登记在 `ggml-openvino-extra.cpp` 的表里，并写进
  [docs/env-vars.md](../docs/env-vars.md)。
- 如果你是"先关掉"而不是"修好"，请直说，并记进 [CHANGELOG.md](../CHANGELOG.md)。
