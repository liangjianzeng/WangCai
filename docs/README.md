# 文档

第一次接触本项目请按顺序读；若是带着问题来排障，直接看最后两篇。

| # | 文档 | 回答的问题 |
|---|---|---|
| 1 | [getting-started.md](getting-started.md) | "怎么先在屏幕上跑出一趟 NPU" |
| 2 | [build.md](build.md) | "为什么构建要我根本没有的 GPU 头文件" |
| 3 | [architecture.md](architecture.md) | "什么跑在哪里，静态图的代价是什么" |
| 4 | [env-vars.md](env-vars.md) | "哪些东西不用重新编译就能调" |
| 5 | [benchmarks.md](benchmarks.md) | "有多快，以及这些数字不能证明什么" |
| 6 | [status.md](status.md) | "今天到底什么能用，附验证命令" |
| 7 | [npu-internals.md](npu-internals.md) | "NPU 难在哪，我们已经排除了什么" |
| 8 | [troubleshooting.md](troubleshooting.md) | "这个报错是什么意思" |
| 9 | [roadmap.md](roadmap.md) | "有什么值得动手" |

本目录之外还有两个入口：

- [../patches/README.md](../patches/README.md) —— 我们给 llama.cpp 打的每一个 hunk，以及为什么必须打。
- [../tools/README.md](../tools/README.md) —— 你真正会敲的那些脚本。

## 读任何东西之前值得先记住的三件事

1. **NPU 执行的是静态图。** 每一个可变维度都必须在编译期定死，而且编译进参数里的形状必须与主机绑定的
   张量一致——这是两条绝不允许漂移的代码路径。
2. **在 CPU 上设 `GGML_OPENVINO_FORCE_STATIC=1` 走的就是同一条代码路径**，且不必付 36 秒的 NPU 编译。
   这是本项目可行的根本原因：翻译期的 bug 能在 CPU 上复现，插件自身的 bug 不能。
3. **聚合统计会说谎。** 每个输出的 `min/max/mean` 会藏住一行错误，而"错一行"是这里最常见的失效形式。
   先按 top-1 token 对齐 pass，再逐元素比对张量。

## 参与写文档

本仓库的价值大多在文档里：补丁不过 8 个文件、约 260 行新增，真正帮下一个人省掉一周的是测量结果和被
推翻的假设。如果你证伪了什么，请写下来——[../CHANGELOG.md](../CHANGELOG.md) 就是为这个留的段落。

保持论断可证伪：**没有附出命令行的数字，只是轶事。**
