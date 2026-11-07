# 缺陷单：Qwen3.5-4B @ NPU 编译期死——GatedDeltaNet 融合算子 driver opset 不支持（2026-11-07）

## 症状

b12034 引擎（llama.cpp + ggml-openvino，OV runtime 2025-10-01）+ NPU 3720（ultra1，driver 32.0.100.4512），
加载 Qwen3.5-4B-Q4_K_M（unsloth，qwen35 混合 SSM/attention 架构，248320 填充词表）后
**首次 graph 计算即失败**，server 空转（「model loaded / listening」但任何推理 -3）：

```
[NPU_VCL] Failed to read/deserialize model. Used OpenVino version 11.
[NPU_VCL] Cannot create GatedDeltaNet layer GatedDeltaNet_2114_node_49#n46 id:154
          from unsupported opset: extension
Compilation failed. Level0 pfnCreate2 result: ZE_RESULT_ERROR_UNKNOWN
```

根因：qwen35 的线性注意力层（GATED_DELTA_NET）被 ggml-openvino 前端翻译为
`ov::op::internal::GatedDeltaNet` **自定义 opset 融合层**，序列化进 IR 后由 NPU driver
侧编译器（VCL）反序列化——driver 32.0.100.4512 的 VCL（OpenVino version 11）不认该
opset。注意这发生在 driver 编译期，OV runtime（frontend/插件侧）本身有该算子。

## 收口尝试（三路，全部不可行，引擎代码已回滚 pristine）

| 路线 | 做法 | 死因（真机逐层复现） |
| --- | --- | --- |
| ① ref 分解 | NPU 上改走 `translate_gated_delta_net_ref`（纯核心算子 Loop 分解，文件内已有，上游为 kda 写） | static NPU 路径编译 **chunk 宽度 padded 图**（decode 亦是——真实 token 2、前端把 GDN 六个输入全解析到 T=128，`chunk_valid_len` 掩码机制），ref 按 ggml 元数据（T=2）取形状 → Reshape 元素数 64× 不匹配崩。即便改用 resolved 形状适配 padded 语义，decode Loop 每 token 跑满 chunk 宽度，性能不可用 |
| ② CPU 分段 | NPU 对 GATED_DELTA_NET 返回 unsupported → 调度器 CPU 回退，分段走 naive | 分段本身成立（自证：GDN 输出成为分段入参 Parameter），但 a) 无 ROPE 分段（首段 embd→投影、输出尾段）进不了 LLM 路径（`get_inp_pos_tensor` 无条件抛）；b) naive 分段 NPUW 断言 `from_submodel != NO_LINK`；c) 绕开 NPUW 后，GDN **打包输出 [attn\|state]**（decode 130 行 = 2 attn + 128 state）跨 CPU/NPU 边界的拷贝/重建 VIEW 又烤死 phase 维度（prefill 常量 128 行 vs decode 130 行 packed，Reshape 不整除）——打包边界在调度器拷贝语义下层层复发 |
| ③ whole-model 禁入维持现状 | 不打补丁，等 driver | 即最终态：三路补丁全部回滚，引擎 pristine，driver 升级支持该 opset 后零改动复验 |

补丁残留：无（`ggml-openvino.cpp` / `utils.cpp` / `utils.h` / `gated_delta_net.cpp` 全部恢复原状，
与 2026-11-05 pristine 构建逐位一致；期间 5 次 DLL 重建 + Omni@NPU 回归确认无副作用）。

## 定案

**Qwen3.5-4B 在 b12034 + NPU 3720（driver 32.0.100.4512）上无配方**——卡点在 driver 编译器
opset 支持，引擎侧无解。用户侧健康路径 = **CUDA（实测 88+ t/s，264 tok prefill + 120 tok
decode 2.2s 无塌方）/ Vulkan（真回复验证通过）**；NPU 档继续配 LFM3-1.7B / Omni-2B
（21.6/21.9 t/s）。app 侧已按 Spark 先例前置禁入（admission ifModelGlob + 改道建议），
CUDA/Vulkan manifest 已加 qwen3.5-4b-gpu preset。

## 复验条件（driver 升级后）

Intel NPU driver 大版本更新（VCL 支持 GatedDeltaNet opset）后：
1. `llama-server -m Qwen3.5-4B-Q4_K_M.gguf -dev OPENVINO3 -c 4096`（env 同 manifest：
   chunk 128 / KV_HOST_WRITE=0）不再报 `Cannot create GatedDeltaNet layer`；
2. 真回复 + decode 速度健康（参照 Omni 4096 档 ≈21.9 t/s；4B 更大，显著低于此则另立单）；
3. 翻 admission 锚（manifest_test qwen35 禁入组）放行。

## driver 升级实验（2026-11-07 下午）：5540 半截升级实测——单独升 driver 不可行

**试验**：driver 32.0.100.4512 → 32.0.100.5540（2026-08-28 WHQL，SHA256 官方校验），
OV runtime 保持 2026.4.1（本仓已是最新），llama.cpp 前端 = 本仓 b12034 快照。装机 + 重启后全序列实测：

| 测试 | 结果 |
| --- | --- |
| Qwen3.5 GDN opset | **过了**——`Cannot create GatedDeltaNet layer` 消失，prefill 图编译且 **25 token 真实执行**（旧 driver 0.08s 编译期死） |
| Qwen3.5 decode | **DEVICE_LOST**（`zeCommandQueueExecuteCommandLists ZE_RESULT_ERROR_DEVICE_LOST - driver update occurred`），重启后同样 |
| Omni（健康主力，带 CACHE_DIR/OPTIMIZE_SIZE） | 加载期 `No WeightlessCacheAttribute ... weights separation flow` 校验炸——新 driver 收紧了 NPUW 缓存导入契约 |
| Omni 无缓存 | 编译期**静默硬崩**（0xC0000409 形态，进程蒸发无异常日志） |
| Omni OPTIMIZE_SPEED override | 同硬崩 |
| 首次编译尝试 | 卡死（用户态 CPU 20 分钟冻结在 1328s，93 线程）——driver 装完未重启的半新半旧态 |

**定案：driver 5540 与 b12034 快照前端（为 2026.4.1 契约所写）全面不兼容，生产栈全灭。**
「升级最新」的正确路径 = **前端（ggml-openvino，上游 llama.cpp 的 OpenVINO 后端已随
新 driver 契约更新）+ driver 成对升级**，单独升 driver 是半截工程。

**回滚执行完成（2026-11-07 14:09，`D:\llm\npu\rollback4512_log.txt`）**：oem273.inf（5540）
卸载 + DriverStore 删除，重扫后设备回绑 **32.0.100.4512 status=OK**（首轮 .bat 因 UAC
未批被重启取消，提权 ps1 二次执行成功）。生产栈复验（全新 cache 冷编译，
`tmp/omni-matrix/run-rollback-verify.sh`）：Omni@4096 **19.78 t/s / 零异常**（对上历史
19.8 档位）；Spark@512 warm **4.7 t/s / 零预算异常**（干净窗口取证）。注意回滚后首轮
spark512 两测（0.41 / 0.84 t/s）均被并行 mtmd 战役的 NPU 编译撞窗污染作废——NPU 单租户，
跨会话并行跑 NPU 负载互相毒化测速，矩阵「单实例锁」纪律必须扩展到一切 NPU 进程。
**闭案：生产水位恢复，4512 + b12034 + OV 2026.4.1 仍为生产栈。** Qwen3.5@NPU 的复验
条件不变（前端+driver 成对升级后重跑本节全部用例）。

## 与 Spark 线的关系

Spark-X2.6-4B 昨晚（2026-11-06 换机矩阵）在 NPU 上**能加载能出字**（不崩不 OOM，128 token
完整出完）——但 decode 落 0.42 t/s 引擎地板（defect-npu-spark-b12034），不可用级，故禁入。
Qwen3.5-4B 则是**编译期即死**（一个字都出不来）——两案病根不同（Spark = decode-level 图撞
设备预算；Qwen3.5 = driver 编译器不认 GDN opset），同一处置模式（禁入 + 改道建议 + driver
升级复验条件）。
