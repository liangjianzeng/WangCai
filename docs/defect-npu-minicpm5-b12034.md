# 缺陷：MiniCPM5-2B 在 NPU 引擎上过不了 4096 基本档（双配方双死法）

- 发现：2026-11-07（用户实测「minicpm加载失败」，b12034 引擎 + driver 32.0.100.4512）
- 模型：`MiniCPM5-2B-Q4_K_M.gguf`（1.56GB，OpenBMB，llama-arch thinking 模型）
- 用户口径：**4096 是最基本档**——只验 4096，短 ctx 配方无产品意义。

## 现场取证（app 同款参数/env，logs/mcpm_repro.server.log、mcpm4096c128.server.log）

| 配方 | 结局 |
|---|---|
| `chunk256`（preset 现配方，1.7B-like 臂） | 1308 节点图编译通过（1:52）→ **首执行即 `ZE_RESULT_ERROR_DEVICE_LOST`（device hung, reset, was removed）** → `llama_process() failed -3` → server health 200 假活 → 首个真实请求后进程死 |
| `chunk128`（4B 家族先例臂） | 编译管线**卡死 >8 分钟零日志**（无错误行、无 DEVICE_LOST）→ **进程静默崩溃**（heap fastfail 风格，P18 注释同型） |

- 旧机验收 `tools/minicpm5-npu-accept.ps1` 的 `$Ctx = 512` 默认——**chunk256 臂从未在任何机器上验过 4096**；preset 配方是旧机 512 验收的遗留。
- 对照组：`LFM3-Omni-2B` 同 ctx 同 DLL 同 env 全天健康（21.9 t/s 矩阵 + 当日读图三线验收）——排除机器/env/驱动全局态，**MiniCPM5 arch 特异性**。
- DEVICE_LOST 后设备可自愈（Omni 探针立即可用），无需重启。
- MiniCPM5 图形态：1308 节点，`first='embd'`（embd 输入命名），thinking 模型。

## 处置

- admission 禁入（wangcai-npu manifest `ifModelGlob: MiniCPM5-2B*.gguf`）：
  与 Qwen3.5（GatedDeltaNet）同型——后端/驱动对新架构的支持缺陷，壳层
  拦在门外给改道指引，不让用户对着 23 分钟预算干等后崩。
- preset 留位（CUDA/Vulkan 线可用）。

## 复验条件

- NPU driver 升级后重跑两配方 @4096：chunk256 看 DEVICE_LOST 是否消失、
  chunk128 看 1308 节点图能否在 3 分钟内编译完且首执行不挂设备。
- 引擎侧若与 defect-npu-qwen35-b12034 同根（opset/算子序列化问题），
  按 Qwen3.5 的三路收口结论先行比对 opset 序列化形态再定刀法。
