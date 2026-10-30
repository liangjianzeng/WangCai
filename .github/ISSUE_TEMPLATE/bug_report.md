---
name: 缺陷报告
about: 构建失败、图编译失败，或输出不正常
title: "[bug] "
labels: bug
assignees: ''
---

<!--
请先读 https://github.com/liangjianzeng/WangCai/blob/main/CONTRIBUTING.md#提交缺陷之前 。
对"输出错误"类问题，最有用的附件是 compare-tensors.ps1 的输出；对"编译失败"类问题，最有用的
是完整日志。绝大多数报告最终归为三类：图没编译出来 / 跑起来了但数值不对 / 跑在了错误的设备上
——而只看控制台输出无法区分这三类。
-->

## 属于哪一类失效

- [ ] 构建失败（CMake / MSVC）
- [ ] 图编译失败（`ov::Exception`、`Check ... failed`）
- [ ] 跑起来了，输出错误（无异常）
- [ ] 跑起来了，但不在我指定的设备上
- [ ] 是性能问题，不是正确性问题

## 环境

| | |
|---|---|
| 系统版本 | |
| CPU / SoC | |
| NPU 驱动版本 | |
| OpenVINO 版本 | |
| llama.cpp commit | |
| WangCai commit | |
| 补丁能否干净应用 | 能 / 否（已 rebase） |
| 模型文件、大小、量化方式 | |

## 命令

```powershell
# 完整命令行，包含 -c / -b / -n / -fa / -np 以及每一个 GGML_OPENVINO_* 变量
```

## 输出

```
完整日志，不要节选
```

## 期望与实际

## 附件材料

- [ ] `llama-cli --list-devices` 输出
- [ ] 把 `GGML_OPENVINO_CACHE_DIR` 指到一个全新目录后重跑的运行日志
- [ ] 输出错误类问题：NPU 与 `-Backend static` 两侧的 `GGML_OPENVINO_DUMP_BIN` 转储，
      外加 `tools\compare-tensors.ps1` 输出
- [ ] `tools\top-token.ps1 -Dir <每个转储目录>`（用于对齐 pass）

## 已经试过的东西

<!-- 尤其是：每种配置是否用了全新的缓存目录？是否用 chat 模板（`-st`）而非裸续写？`-fa 1`？
     `-np 1`？是否核对过 GGUF 文件字节数与来源一致？ -->
