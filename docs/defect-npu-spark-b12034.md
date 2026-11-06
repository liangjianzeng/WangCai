# 缺陷单：Spark-X2.6-4B @ NPU 在 b12034 引擎上双配方皆病（2026-11-06 换机矩阵）

## 症状（两案皆本机矩阵实测，串行独占，app 同款 env/参数口径）

| 配方 | 结果 |
| --- | --- |
| `GGML_OPENVINO_DISABLE_DECODE_LEVELS=1`（历史配方，spark-npu-accept.ps1 3/3 验过） | 首请求即 500 `Compute error.`；server 日志 `L0 pfnAppendGraphExecute result: ZE_RESULT_ERROR_UNINITIALIZED (0x78000001) - driver is not initialized`。干净复跑（杀净 llama-server + 8s 间隔）同错 → **稳定复现，非时序假阴性** |
| 无 DDL（HANDOFF §4 q3 候选） | 128 token 完整出字、不崩不 OOM，但 decode **0.42 t/s**（引擎地板，同 Omni 摘 FOLD 的塌方形态——「引擎病不是配置病」口径） |

环境：Intel Core Ultra 9 275HX + AI Boost NPU 3720（ultra1，即全仓实测基准机同款）、引擎 b12034-vulkan 架构 NPU 臂（`src/llama/build/bin` + OV runtime 2025-10-01）、ctx 4096 / chunk 128 / `-fa 1 -dev OPENVINO3 --jinja`、`/v1/chat/completions` 口径。

## 根因（推断）

「DDL 必需」口径出自旧引擎构建（2026-11-01 前后）；P14e 重建（b12034，KV_HOST_WRITE 默认翻 ON 那次）后，DISABLE_DECODE_LEVELS 的图裁剪与 Spark 4B 的 NPU 编译图不再兼容——L0 图执行期驱动句柄未初始化。同引擎上 Omni（2B）摘 DDL 是正解（35cf5fc），Spark（4B）摘 DDL 后落入深层 decode 崩速地板：4B 图在新引擎上的 decode level 编译本身有病，**两个配方都无法恢复历史速度**。

## 拍板（按 HANDOFF §4 条款执行）

ddl0「不崩不 OOM」→ **Spark preset 摘除 DDL env**（与 Omni 同锁，manifest_test 回归锚翻转：该键永远不得加回）。摘除后 Spark@4096 = 0.42 t/s 地板，保守可跑但不可用级——**Spark NPU 线在 b12034 上无健康配方**，用户侧建议走 CUDA/Vulkan 引擎跑 Spark。

## 复验条件

引擎（llama.cpp + ggml-openvino）升级或 NPU 驱动大版本更新后，重跑矩阵（`tmp/omni-matrix/run-matrix.sh`，spark 两案）：
- DDL=1 不再 Compute error 且速度健康 → 可回填（改回 preset + 翻锚）；
- 无 DDL 地板消失（预期 4B@4096 ≈5+ t/s）→ 缺陷闭案。
