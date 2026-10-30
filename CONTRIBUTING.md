# 参与 WangCai 贡献

谢谢你愿意把时间花在笔记本里最不受待见的那颗加速器上。

## 提交缺陷之前

本项目里大多数"跑不通"的报告，最终都归到下面三种之一，而它们的区别**在控制台里看不出来**：

1. 图根本没编译出来（有 `ov::Exception` / `Check ... failed` 这类行），
2. 编译并运行了，但数值是错的（静默），
3. 跑得好好的，但跑在了错误的设备上（静默）。

所以请附上：

```powershell
# 实际被用到的设备
.\build\bin\llama-cli.exe --list-devices

# 运行本身，带设备决策日志
$env:GGML_OPENVINO_DEVICE = 'NPU'
$env:GGML_OPENVINO_CACHE_DIR = 'D:\npu_cache'      # 每种配置一个新目录，见下
.\build\bin\llama-cli.exe -m models\<model>.gguf -c 1024 -n 32 --temp 0 -fa 1 -dev OPENVINO3 -st -p '...' 2>&1 |
    Tee-Object issue.log
```

如果结果是胡话而不是异常，请再附上这两样能让报告真正可跟进的材料：

```powershell
$env:GGML_OPENVINO_DUMP_BIN = 'D:\dumps\npu'   # 逐输出原始张量
# ... 跑一次 ...
# ... 然后用 GGML_OPENVINO_DEVICE=CPU 跑同一次，转储到 D:\dumps\cpu ...
..\tools\compare-tensors.ps1 -A D:\dumps\cpu -B D:\dumps\npu
```

同时说明：系统版本、`Intel(R) AI Boost` 驱动版本、OpenVINO 版本、llama.cpp commit、补丁能否干净应用，
以及模型文件的大小与量化方式。

**每种配置用一个全新的 `GGML_OPENVINO_CACHE_DIR`。** 过期的编译图缓存会悄无声息地复用一张在别的 flag
组合下编译出来的图——这是本项目里最让人困惑的失效模式，它会让一个 flag 看起来"完全没起作用"。

## 搭一个开发树

```powershell
git clone https://github.com/liangjianzeng/WangCai
cd WangCai
tools\bootstrap.ps1        # 克隆钉住 commit 的 llama.cpp 并应用补丁
tools\configure.ps1 -OpenVinoDir C:\openvino\openvino\cmake
tools\build.ps1
```

构建是 Release + Ninja + MSVC。后端增量重编约 1–2 分钟；冷配置约 3 分钟。已知可用的工具链版本，以及
"为什么 OpenVINO *运行时* wheel 可以当作开发头文件的来源"，都写在 [docs/build.md](docs/build.md)。

## 你真正想要的迭代循环

LFM3-1.7B 的 NPU 图编译冷启动要约 36 s，而且没法绕开。所以凡是能在设备外调试的，都在设备外调：

- `GGML_OPENVINO_FORCE_STATIC=1` 配 `GGML_OPENVINO_DEVICE=CPU`，**在 CPU 上跑 NPU 的静态代码路径**，
  不用 NPU 编译，从分钟级降到秒级。翻译期的 bug 在那里能复现，插件自身的 bug 不能。"静态模式的 mask
  尺寸"与"NPU 的数值行为"就是靠这道切口分开的。
- `tools/npu-sweep.ps1` 跑一张环境变量覆盖矩阵，每格一个独立缓存目录，每格打印一行。
- `tools/compare-tensors.ps1` 按余弦相似度、top-1 一致率、以及超过阈值的元素个数比对两份转储。聚合统计量
  会骗人，余弦不会。

## 风格与结构

- 与周围的 llama.cpp 风格保持一致：4 空格缩进、120 列、函数用 `snake_case`、成员带 `m_` 前缀。这个后端是
  上游代码，diff 要为"拿去提上游 PR"保持可读。
- 每一处行为改动都需要一个能恢复上游行为的环境变量逃生门，并在 [docs/env-vars.md](docs/env-vars.md) 里
  登记一条。新变量要注册进 `ggml-openvino-extra.cpp` 的表——没注册的变量会被读成"未设置"而且不报错。
- 注释要解释"是什么约束逼出了这段代码"，而不是复述代码。本代码树里有价值的注释长这样："llama.cpp 会把
  mask 补齐到最大的那块 KV 缓冲区，所以静态图必须从消费方的缓存取宽度"，而不是"设置 mask_kv"。
- 一个环境变量能解决的事，不要上 `#ifdef` 特性开关；也不要"以防万一"地留下死代码。

## 可以做什么

[路线图](docs/roadmap.md) 列的都是各自可独立完成的事。其中两条特别适合第一次贡献，因为它们是"有确定答案的
测量任务"，而不是无边界的排障：

- 逐层量化精度差距（有了转储仪表，这是一天的活，不是一周的活），
- 找出为什么 NPU 解码在这个模型上比 OpenVINO-CPU 慢约 2.5 倍。

## 仓库卫生

智能体 / 助手的项目记忆文件（`AGENTS.md`、`CLAUDE.md`、`.claude/` 及同类）在本仓库是 **git 忽略**的。它们
带着机器清单、内网端点和构建流水备注，这些不属于一个公开克隆。把它们留在你的私有文档仓里；如果其中某个
决定需要公开，就写成 `docs/` 下的一篇文档，而不是让记忆文件漂回索引里。第一次提交之前先 `git status
--ignored` 看一眼。

## Pull Request

- 一个 PR 只谈一件事；链接对应的 issue 或路线图条目。
- 附上改动前后的实测数据。没有 `t/s` 数字和产出它的命令行的"更快了"，不算结果。
- 如果你改了图构建，请同时给出一次 CPU 静态和一次 NPU 运行。
- 更新 [CHANGELOG.md](CHANGELOG.md)；被推翻的假设与修复同样有价值，也该写在那里。

贡献即表示你声明：该贡献由你本人所写，或你有权在 Apache-2.0 许可下提交它；并且你理解本项目与该贡献都是
公开的，且记录会被无限期保留。
