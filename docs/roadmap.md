# 路线图

按"什么解锁什么"排序。贯穿全文的前提是：NPU 是有能力的，缺的那块是工程，不是硅片。

## Phase 0 —— 让它跑起来 · ✅ 完成

- [x] 为纯 NPU 目标构建 OpenVINO 后端，且不依赖 GPU/OpenCL SDK（`ov_opencl_shim.hpp`）。
- [x] 让 LFM3-1.7B 在 NPU 上编译出两张静态图。卡点是混合结构的 mask / KV 环尺寸：13 短卷积 + 5 滑动窗口
      + 6 全局注意力需要按模块各自的 mask 宽度，而在静态形状下，编译进参数的形状与主机绑定必须一致。
- [x] 确认短卷积路径（`GGML_OP_SSM_CONV` → depthwise `GroupConvolution`）及其逐步状态接续在 NPU 上可用
      ——用单 token prompt 跨 40 个解码步验证。
- [x] 仪表化：原始输出转储、逐 pass top-token 对齐、逐元素比对、按位置推导的 mask、运行期 NPU 编译配置
      覆盖。

## Phase 1 —— 让它算对 · 🟡 进行中

眼下唯一要紧的事。NPU 的 logits 在 prefill 阶段跟得上 CPU 参照（余弦 `0.969`），到 decode 就被压平
（`0.73–0.87`）；贪心解码在 2–3 个 token 后漂移。

- [x] **逐层发散图谱。** 已完成——而且必须重做一遍。第一版是在 llama.cpp 的**预热** pass 上算的
      （`prefill_0/1`、`decode_2` 换 prompt 后逐字节不变）；真实数字见
      [npu-internals.md § 4](npu-internals.md#4-the-accuracy-gap)：第一个真实 chunk 上 conv 状态余弦
      `l0 0.9956 → l9 0.873 → l13 0.534 → l17 0.163`。结论：**误差从很早、且贯穿各层**，不在输出投影——
      而且注意力侧基本干净（V 精确，K 除第 0 行外都干净），于是工作范围收窄到短卷积路径。
- [ ] **隔离输出投影。** `output.weight` 是 Q8_0_C，投影规模 128000×2048。跨设备比对 `result_norm` 与
      `result_output`；若隐状态一致而只有 logits 不同，那缺陷就是一个 `MatMul`。（受阻：追加 `Result` 节点
      会让 NPU 插件中止，所以需要一个不同于 `GGML_OPENVINO_DUMP_BIN` 的挂钩。）
- [ ] **单算子精度二分。** 一次只把一个算子类升到 f32（RMS-norm 链、`MatMul`、SDPA），观察余弦是否移动。
- [x] **一个对照模型。** 完成（2026-10-31）：`LFM3-1.7B-QAD-Q4_0.gguf`（原生 Q4_0，ModelScope）去掉了重量化的
      不对称，并按任务表现出不同行为——续写任务与 CPU 逐字节一致，指令任务则退化。**异架构对照也已补上**
      （Qwen3-1.7B / 4B，纯 transformer，见 [status.md 缺陷 5](status.md#5-缺少对照模型--已补上2026-10-31)）：
      NPU 的数值缺陷在 Qwen3 上同样出现（4B 还在 `-c 1024` 下 OOM），所以问题跟着"静态 NPU 路径"走，不是
      LFM3 特有。仍然开放的只剩"上游已在 NPU 上验证过的模型"这一条对照。
- [x] **重量化对齐。** 已完成，而且暴露出一个 bug：`GGML_OPENVINO_REQUANT_KQUANT` 的解析位于一个
      `is_npu()` 提前返回之后，把*所有*取值都吞掉了，于是三种配置产出完全相同的转储。改为在"用户没有显式
      选择"（`!rq`）时才施加覆盖。两侧策略对齐后，最差 conv 状态从 `0.215` 升到 `0.9589`——三分之二的差距
      其实是两台设备加载了两个不同的模型。
- [ ] **未审查的 NPU 专有分支。** 审计降级代码里每一处 `ggml_openvino_is_npu()` 分叉的精度含义（有些一元
      算子的降级是故意跳过 f32 提升的）。
- [ ] **验收测试装置。** 一套固定 prompt 集 + 每设备的参照 logits，让"正确"成为一个数字而不是一种感觉。
      在 CI 里做回归门禁。prompt 集必须包含**指令跟随**用例：续写任务在设备算错时也能逐字节一致，因此它
      不能充当验收测试。

*退出标准：* 在固定 prompt 集上，贪心解码与 CPU 参照逐 token 一致 ≥ 64 个 token，且逐层余弦 ≥ 0.99。

## Phase 2 —— 让它跑得快 · 🟡 进行中

被测量重新定义了问题：**prefill 已经有竞争力**（`pp512` 415 t/s = 原生 CPU 参照的 73%），所以加速器和编译
配置并非全盘坏掉。**损失在 decode**——8.3–8.7 t/s，对比原生 54.1，约为可用 TOPS 的 0.03——而 prefill 的
13 TOPS 里只用了 1.4，说明那边同样有余量。

- [ ] **把 decode 的每步开销归因清楚。** 主机↔NPU 之间 11 层 K/V 与 13 个 conv 状态的进出传输、激活量化、
      以及每 token 执行一次的约 1000 节点图的 NPUW funcall 提交开销。先拿数字，再谈优化。
- [ ] **针对解码形状的图做编译提示扫描**（`optimization-level`、funcall 粒度、weights-bank 策略），用
      `GGML_OPENVINO_NPU_COMPILE_OVERRIDES`，每格一个缓存目录。
- [ ] **削减每步状态流量**：把 conv 状态写回批量化；索引已知处，用静态切片替换按运行期索引的 `Gather`。
- [ ] **chunk 尺寸与负载匹配。** 静态 prefill 图永远按整 chunk 计费，于是短 prompt 读起来慢得离谱（256 列
      的图跑 4 个 token，一个 0.66 s 的 chunk 被上报成约 6 t/s）。为常见使用规模给出合理默认值，并把
      `GGML_OPENVINO_PREFILL_CHUNK_SIZE` 按其真实身份——直接乘数——写进文档。
- [ ] **冷启动。** 36 s 编译是最糟糕的第一印象：随模型附带预编译图缓存，或在安装时预热。目标热启动 < 5 s。
- [x] **修掉越界 KV 写入**（2026-10-31，提前完成了）。根因不是上游 llama.cpp，而是本解码器把 interleaved-SWA
      两个同名 KV 写索引输入按名字合并成一个参数，SWA 散射因此拿到越过环长的全量缓存 cell id——CPU 上
      `scatter_update.cpp:915` 断言，NPU 上 `ZE_RESULT_ERROR_DEVICE_LOST`。修复（按目的缓存所在层给索引参数
      加 `_swa` 后缀）之后 `-p 1024 -n 32` 三条路径全通（NPU pp1024 385 / tg32 15.3 t/s），
      **`llama-perplexity` 解锁**——上面 Phase 1 想要的精度指标现在可以用了。机制与证据见
      [status.md 缺陷 3](status.md#3-超出-kv-缓存的序列会把-openvino-后端拖垮--根因已找到并修复2026-10-31)。

*退出标准：* 同一模型下 NPU 解码快过 OpenVINO-CPU，封装功耗相当或更低，且热启动 5 s 以内。

## Phase 3 —— 拓宽模型线 · ⬜

上游的已验证模型表把混合 / SSM 家族在 NPU 上标为 ✗，所以这段路是真的没人走过。要有意地拓宽，而不是撞上去：

- [ ] 同家族的兄弟尺寸（0.3 B → 8 B）找出实用上限；约 13 TOPS INT8 说明 1–3 B 是甜点区，需要确认的数字是
      "解码延迟在何处越过用户能忍受的边界"。已有第一个数据点（2026-10-31）：Qwen3-4B 的静态 prefill 图在
      `-c 1024` 下放不进 NPU（执行期 `OUT_OF_HOST_MEMORY`），`-c 512` 能跑但数值塌缩——
      见 [status.md 缺陷 5](status.md#5-缺少对照模型--已补上2026-10-31)。
- [ ] 纯 transformer 模型作为回归对照。
- [ ] 长上下文：KV 环与 mask 逻辑目前只在 `-c 1024` 下被跑到。扫一遍上下文长度，记录内存与 t/s。
- [ ] 量化矩阵：目前只测过 `Q4_K_M`。

## Phase 4 —— LFM3 全模态 · ⬜ 规划中

这条模型线本身就是全模态的；文本只是它栈里的第一层。

- [ ] **音频输入。** 编码器侧卷积/注意力密集，而且对静态形状友好——最可能的下一个胜点。需要为编码器建立
      GGUF/流水线的说法，以及让非 token 输入穿过 ggml 图的通道。
- [ ] **视觉输入**，同样形状的工作。
- [ ] **音频输出**，前提是 NPU 能满足声码器的实时率；先测再承诺。
- [ ] **混合调度**：编码器在 NPU、语言模型在 NPU，以及一个"什么（如果有）允许跑到别处"的策略。本项目的
      立场是"模型纯跑 NPU"，所以任何离开 NPU 的东西都需要给出理由。

## Phase 5 —— 产品面 · ⬜

- [ ] 以 NPU 上的 `llama-server` 作为交付物，并把 chat 模板端到端跑通。
- [ ] 预编译的 Windows 二进制 + 一份钉住版本的驱动 / OpenVINO 兼容性说明。
- [ ] 一个 `wangcai doctor`：打印设备枚举、驱动与 OpenVINO 版本，并跑一个 30 秒的正确性探针比对参照——
      大部分支持负担来自配置，不是代码。
- [ ] 功耗 / 温度数字：为 NPU 说话的最诚实论据是"每瓦性能 + CPU 保持空闲"，而这个测量我们还没有。
      本机没有 NPU 计数器、没有电池、电源方案是"高性能"，所以先用可复现的代理证据（CPU 占用积分、温度
      爬升、降频事件），精确瓦特需要外部功率计或带电池的机器补测。

## Phase 6 —— 端侧多模态助手「汪柴」 · ⬜ 规划中

引擎不是终点。汪柴的终局形态是一个**由 NPU 低功耗驱动的端侧轻量级多模态 AI 助手**：应用层复用 TongYiLite
（Flutter），引擎层就是本仓库。三层结构见 [README](../README.md#wangcai-assistant)。

- [ ] **与 TongYiLite 已有的 Windows 移植方案对齐**（`Windows移植_CPU_GPU_NPU_实施方案_2026-10-30.md`）：
      要么复用它，要么显式写明与它的关系，避免出现两份互相矛盾的规划。
- [ ] **把 `tongyilite_jni.cpp`（3887 行）抽成平台无关的 C ABI**，产出 `tongyilite_core.dll`；JNI 只留薄壳。
      这是移植里唯一真正重的块。
- [ ] **服务层做成后端可插拔**：`ggml-cpu` / `ggml-vulkan` / **`ggml-openvino`（本引擎）**，由一个设备策略
      选择；模型侧默认纯 NPU，离开 NPU 需要理由（与 Phase 4 的立场一致）。
- [ ] **Dart 侧复用验证**：TongYiLite 的 Agent 主循环、工具、记忆、语音管线不依赖 Android API，目标是在
      Flutter Windows 上零改动跑通；MainActivity 的 8 个 `MethodChannel` 换成 Dart FFI 桥。
- [ ] **可行性证据已经在仓库里**：`.upgrade-tmp/host-mingw/bin/llama-mtmd-cli.exe` 证明 llama.cpp 能在本机
      MinGW 下原生构建 Windows x64。
- [ ] **多模态接入**：模型目录已含 `LFM3-VL-2B QAD-Q4_0` + mmproj，视觉与语音走 Phase 4 的同一套后端。
- [ ] **功耗感知调度**：在 Phase 5 的实测数字之上，决定什么留在 NPU、什么让给 CPU，并让用户看得见代价。

*退出标准：* TongYiLite 在 Windows 上端到端跑通一次含视觉或语音的对话，模型部分全部在 NPU 上，且热启动
5 s 以内。

## 非目标

- 去追独立显卡或核显。全部意义就在于那颗没人用的加速器。
- 分叉 llama.cpp。差异是补丁；把它保持得小而可上游化，本身就是一项特性。
- 不附连贯输出的基准测试。

## 怎么认领一件事

挑一条，开一个 issue 说明你在做，然后**即使修复没落地，也要把*测量*落地**。被推翻的假设进
[CHANGELOG.md](../CHANGELOG.md)——本项目里好几个死胡同比修复本身更值钱。
