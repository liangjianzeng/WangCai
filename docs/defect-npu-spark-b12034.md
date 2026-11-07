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

## 补充（2026-11-07 凌晨）：智能体场景实锤回退机制 = 歇菜全链路

用户实测「4B 智能体模式直接歇菜」复现取证（`tmp/omni-matrix/logs/spark_agent_repro.server.log`）：
智能体 full 档系统提示 710 token（约 HANDOFF 口径 860，本次人格段精简）prefill **56 t/s 正常**（12.7s），
随后 decode：

```
6.40 W ggml-openvino: decode level 1024 graph hit the device budget
      (ZE_RESULT_ERROR_UNINITIALIZED); disabling decode levels and ret[rying]
7.58 W srv stop: cancel task, id_task = 0
```

机制统一：Spark 4B 的 decode-level 图（1024 深度）运行时撞设备预算 → 引擎**自动回退**
无-decode-levels 模式 → 即 0.42 t/s 地板（短 prompt 的 q3 案与长 prompt 的智能体案是同一
回退形态；显式 DDL=1 则连回退都没有，直接 500）。智能体侧观感 = prefill 12.7s + decode
每字 2.4s → 256 token 上限跑不完 → 轮次取消「本轮执行失败（详见推理日志）」。
会话库另有轻度中英夹杂输出（「quite 丰富」「都 me 哦」），与回退模式下的数值质量一致，
同根因不另立单。

**结论强化：Spark 4B 在 b12034 + NPU 3720（驱动 32.0.100.4512）上 decode-levels 特性
整体失效，无配置可救**；用户侧唯一健康路径 = CUDA/Vulkan（实测 99.2 t/s）。
智能体模式请在 Spark 上选 CUDA/Vulkan 引擎，或 NPU 档配 1.7B / Omni-2B（21.6 / 21.9 t/s）。

## 补充（2026-11-07 上午）：非确定性实锤 + ctx≤512 确定可用档

bindings.db 复盘推翻「4096 全面塌方」的单值结论——**预算共居失败是非确定性的**
（引擎注释原话 "nondeterministic with device fragmentation"，utils.cpp BUDGET-FAIL 处）：

| 证据 | 结果 |
| --- | --- |
| `wangcai-npu × spark binding`（昨晚 00:26 写入） | **8.4 t/s @ ctx4096 usable**——用户记忆「昨晚 Spark 能走 NPU」实锤，level-1024 图那次 fits 预算 |
| 本会话下午矩阵 + 智能体复现 | level-1024 撞预算 → 全局回退 0.42 t/s——同一张图换了个时间就塌 |
| 本会话 ctx=512 复测（engine pristine） | warm **≈6 t/s，零预算异常**——level 256/512 图确定装得下 |

处置：**Spark@NPU 禁入改为 ctx 分档**（admission ifModelGlob + ifCtxGt 512）：
- ctx≤512 = 确定可用档（聊天可用 ~6 t/s，智能体不建议），放行；
- ctx>512 = 非确定性预算彩票（8.4 或 0.42），拦。
bindings 旧档 maxStableCtx 4096→512 收回（stable 语义要求确定性，4096 那次是中奖不是档位）。
CUDA/Vulkan 仍是智能体/长上下文的正解（99.2 t/s）；引擎/驱动升级复验条件不变。

## 补充（2026-11-07 下午）：driver 回滚后 ctx≤512 档复验通过 + 跨会话并行污染教训

5540 实验回滚（详见 defect-npu-qwen35-b12034「driver 升级实验」节）后复验：

| 证据 | 结果 |
| --- | --- |
| Omni@4096（冷编，全新 cache） | **19.78 t/s / 零异常**——历史 19.8 档位对上，生产主力恢复 |
| Spark@512 warm（干净窗口） | **4.7 t/s / 零预算异常**——ctx≤512 可用档维持，admission ctx 分档不变，bindings maxStableCtx=512 成立 |
| 回滚后首轮 spark512 两测 | 0.41 / 0.84 t/s，**均作废**——并行 mtmd 战役（ctx=2560 发图线）的 NPU 编译撞窗（mtmdcli_fix9ir 14:23 / r2 14:36 各压测量段） |

取证教训：**NPU 单租户**，测速作废判据 = 测量窗口内出现其它 NPU 进程的新写日志
（本机 4–7 分钟一发的节奏极易撞窗）；矩阵脚本「单实例锁」只防本矩阵自身，防不了
其它会话/战役的 NPU 负载。正式测速前先 `tasklist` 清场 + 事后日志 mtime 取证。
