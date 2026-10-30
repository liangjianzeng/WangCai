# 安全策略

## 报送漏洞

安全问题请通过 [GitHub 私有漏洞报送](https://github.com/liangjianzeng/WangCai/security/advisories/new)
私下提交，不要开公开 issue。我们承诺 7 天内回应。

## 哪些算安全问题

- 任何能让恶意 GGUF 文件、分词词表、chat 模板或生成 token 流在 OpenVINO 后端或本仓库工具中造成内存
  破坏、越界访问或代码执行的问题。
- 诊断转储、缓存处理，以及任何依据模型提供的文件名写盘的路径中的目录穿越（path traversal）。
- 可由模型文件或请求触发的无上限内存分配（NPU 的主机内存预算本来就很紧，一个精心构造的模型把它撑爆
  就是拒绝服务）。

## 哪些不算

- **模型输出错误或质量下降。** 那是正确性缺陷——请按 [CONTRIBUTING.md](CONTRIBUTING.md) 开普通 issue 并
  附上材料。它对本项目极其重要，但不是安全通告。
- **OpenVINO NPU 插件自身的崩溃**（`ov::Exception`、`ZE_RESULT_*`）。请上报 Intel，同时在这里开一个
  issue，以便我们记录规避方案。
- **通过模型输出进行的 prompt 注入。** 本项目不执行模型输出；如果你把它接到会执行输出的系统上，请把
  生成的文本当作不可信输入处理。

## 范围

WangCai 是叠在 llama.cpp 与 OpenVINO 之上的一组补丁加工具链。这两个上游的漏洞归它们的维护者所有；
若我们的补丁集参与其中，我们会协助转报并在这里出修复。

## 版本支持

只支持当前 `main` 分支。尚未发布任何版本，因此任何报送都以
[docs/status.md](docs/status.md) 中钉住的 llama.cpp 与 OpenVINO 版本作为安全基线。
