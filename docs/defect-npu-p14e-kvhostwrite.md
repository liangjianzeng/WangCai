# 缺陷档案：P14e KV_HOST_WRITE 默认 ON 致 NPU 全线垃圾文本（2026-11-06）

> 状态：**已定根因，App 侧已止血（清单默认钉 0）；引擎侧根因未修**。
> 发现场景：ASR&TTS 重构 M0-M3 合入 main 后的便携包真机验收（用户报「智能体 400 + 简单聊天复读机」）。

## 一、症状

同一 GGUF、同一贪心采样（`--temp 0`）：

| 运行 | 设备 | 结果 |
|---|---|---|
| LFM3-Omni-2B-Q4_0 | CPU(OPENVINO0) | ✅ 正常（「你好啊！很高兴见到你…」EOS 正常，22.9 t/s） |
| LFM3-Omni-2B-Q4_0 | NPU(OPENVINO2)，env 不设（=DLL 默认） | ❌ 复读机「你好啊！你好啊！×4…」（逐字节可复现） |
| 同上，chunk 128/256、DECODE_LEVELS 开/关、fa 0/1 | NPU | ❌ 全部同样复读（输出逐字节一致 → 确定性图错误，非采样） |
| 同上，FOLD=YES+KV_HOST_WRITE=1 | NPU | ❌ 依旧复读 |
| **同上，显式 `GGML_OPENVINO_KV_HOST_WRITE=0`** | NPU | ✅ **完全正常，19.9 t/s 不掉速** |
| LFM3-1.7B-Q4_K_M（同族） | NPU，默认 | ❌ thinking 段「面面面面」结巴 |
| spark-x2.6-4b-q4_k_m（普通注意力） | NPU，默认 | ❌ token 乱码汤 + gen 崩到 6.6 t/s |

**爆炸半径 = NPU 上的一切模型**（LFM 混合 conv 与普通注意力同中招）；CPU 全干净。

## 二、根因链

1. `src/llama/build/bin/ggml-openvino.dll` 为 **2026-11-05 12:30 重建**（`src/llama` 未入 git，无历史可溯；当日源码含超出受控 `patches/0001` 的改动——加载期刷屏的 `dynamic dim value mismatch for VIEW node` 警告字符串不在补丁内）。
2. 同引擎线 HANDOFF「2026-11-05：P14e 转默认」把 `GGML_OPENVINO_KV_HOST_WRITE` **默认翻 ON**（4B tg128 +38% 摘链增益；见 docs/env-vars.md 同条）。
3. **翻转验收只测了速度**：「1.7B 双向回归绿」是 t/s 口径——垃圾 token 同样计 t/s，文本从未被看过。P14e 的「all-or-nothing 门控保证不合格图走链式」对 FULL-attention 层的 host 行写出（set_rows 摘 ScatterNDUpdate + idx%rows memcpy）显然没兜住。
4. 前科呼应：HANDOFF 记过 6077ff8 的「默认翻转探针失效」教训（getenv_int 缺省 0 把未设置当显式关）——那次修的是**翻转是否生效**，没防**翻转本身的质量**。12:30 DLL 已含 nullptr 修复，故默认 ON 真实生效，产出全坏。

## 三、止血（已落地，App 侧）

`app/lib/engine/bundled_manifests.dart`（wangcai-npu）：

- `envTemplate` 增 `"GGML_OPENVINO_KV_HOST_WRITE": "{kvHostWrite=0}"`——未注入即显式 `0`，压过 DLL 默认 ON；留 `{kvHostWrite=…}` 开关位。
- `lfm3-1.7b-deep` preset 的 `KV_HOST_WRITE: "1"` 改钉 `"0"`（原「9.1 t/s / 整段 8.3」是 P14e ON 下未验文本的**存疑数字**，note 已标注，待引擎修复后复测）。

引擎 DLL 与其余引擎（Vulkan/CUDA/远端）不动。用户侧应急等效：启动前设环境变量 `GGML_OPENVINO_KV_HOST_WRITE=0`。

## 四、复现命令（本机，绕开 App 直达 CLI）

```bat
set PATH=E:\dev-tools\ov\openvino\openvino\libs;%PATH%
set GGML_OPENVINO_DEVICE=NPU
set GGML_OPENVINO_PREFILL_CHUNK_SIZE=128
echo /exit | src\llama\build\bin\llama-cli.exe -m <模型> -c 512 -fa 1 --jinja --temp 0 -n 64 -p 你好啊 --no-display-prompt -dev OPENVINO2
REM 复读=缺陷现场；追加 set GGML_OPENVINO_KV_HOST_WRITE=0 后应恢复正常文本
```

（`-dev` 用探测值：本机枚举 = `OPENVINO2`；App 侧由 openvino_probe 探测注入。）

## 五、行动项（v0.0.5）

1. **引擎侧根因**：P14e decode 图 host 行写出路径（set_rows/attention Concat 补列/idx%rows memcpy）逐模型定位；修复验收必须含**文本口径**（同 prompt CPU/NPU 输出比对或人工目检）。
2. 修复后复测三模型（Omni-2B/1.7B/Spark-4B）与 16K deep（9.1 t/s 数字重出）。
3. **制度化**：任何默认翻转，除「env 不设」探针外，必须过文本质量闸——速度指标不覆盖正确性。
4. `src/llama` 未入 git 是本次无法 bisect 的直接原因：评估引擎线版本化（至少 DLL+源码快照随构建归档）。
