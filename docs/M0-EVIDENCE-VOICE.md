# M0 语音引擎实测台账（ASR&TTS 重构专项）

> 本机口径：**i5-7400T（4 核 4 线程，无 NPU，AVX2 无 VNNI）**，非母方案 §4.6 的 i7-12700H(285H?) 口径。
> 所有绝对时长按本机 CPU 实测，预算线仍按母方案（285H）数字卡——本机为下限参考。
> 引擎：sherpa_onnx pub **1.13.8**（T0.1 裁决锁定，见施工计划）。
> 测量工具：`app/tool/m0_*.dart`（`dart run tool/<name>.dart`，DLL 目录 `C:\dev-tools\voice-models\bin`）。

## T0.2 SenseVoice-Small int8（唤醒对话 ASR，D3 单档）

目录 `C:\dev-tools\voice-models\sensevoice`（来源 hf-mirror `csukuangfj/sherpa-onnx-sense-voice-zh-en-ja-ko-yue-2024-07-17`）。

| 指标 | 实测 | 预算/期望 | 判定 |
|---|---|---|---|
| 模型体积 | 228.2 MB | ~230 MB | ✓ |
| 加载时长 | ~2.1 s | 一次性（常驻） | ✓（M1 worker 预热） |
| RSS（加载后） | ~495 MB | ≤600 MB | ✓ |
| zh 5.59s 音频解码（热） | **248 ms**（RTF 0.044） | ≤500 ms | ✓ |
| yue 5.15s（热） | 235 ms | — | ✓ |
| en 7.15s（热） | 341 ms | — | ✓ |
| ITN | 「9点至5点」正常产出 | 开 | ✓ |

**结论：SenseVoice int8 在 4 核老 CPU 上 5s 段解码 ~250ms，满足 ≤500ms 预算，D3 单档成立。**
富转写标签：test_wavs 输出未含 `|HAPPY|` 等情感标签（干净文本），T1.4 剥离规则仍按 sherpa 文档标签集实现（宁滥勿缺）。

## T0.2b 流式 Zipformer（按住说话现役，回归基线）

目录 `streaming-zipformer`（`sherpa-onnx-streaming-zipformer-zh-int8-2025-06-30`）。

| 指标 | 实测 | 判定 |
|---|---|---|
| 加载 | 6.6 s | 常驻 ✓ |
| RSS | 431 MB | ✓ |
| RTF（100ms chunk） | **0.40–0.42** | ✓（流式要求 <1） |
| zh 样本尾字 | 「开放时间早上九点至下午五点」（同音「开饭→开放」，正需热词纠错） | 佐证 T1.4 |

## T0.3 离线 TTS（D1：Edge 保留可选默认关；主链路 离线→Edge→静音）

### vits-zh-aishell3（matcha 缺 vocoder 的 §8 兜底档）

目录 `tts-offline-zh`（hf-mirror `csukuangfj/vits-zh-aishell3`，int8 39.8MB + 4×fst + lexicon + rule.far）。

| 指标 | 实测 | 预算 | 判定 |
|---|---|---|---|
| 加载 | 1.86 s | — | ✓ |
| RSS | 292 MB | ≤400 | ✓ |
| 采样率 | 8000 Hz | — | 听感一般（兜底档） |
| **首句合成（=首声代理）** | **5.1 s** | ≤1000 ms | ✗ **超 5 倍** |
| RTF | ~1.0 | <0.3 | ✗ |

### matcha-icefall-zh-baker

`model-steps-3.onnx` 75.6 MB + jieba dict + 3×fst 就位，**官方包与 HF repo 均不含 vocoder**（hf-mirror API 复核过文件清单；`matcha-voice-22050` 等 vocoder repo 名 404）→ 无法实测，按 §8 走兜底。vocoder 获取列入 M2 待办（换 repo 名重试/换 Kokoro）。

### Kokoro int8（M2 主力候选）

hf-mirror `csukuangfj/kokoro-int8-multi-lang-v1_1` 372/373 文件就位（唯一失败 `espeak-ng-data/voices/!v/Mr serious` 为英文变体音色，中文链路无关）。

| 指标 | 实测 | 判定 |
|---|---|---|
| model.int8.onnx / voices.bin | 108.9 MB / 51.3 MB | 体积最大 |
| 加载 | 2.3 s；RSS 420 MB | ✓ |
| 采样率 | **24000 Hz** | 三者最佳 |
| 首句合成 | **8.7 s** | ✗（本机 RTF 2.1，比 vits 更慢） |

**Kokoro 本机否决**：质量（24k）最好但 4 核 7400T 跑不动（RTF 2.1 vs vits 1.0）。285H 口径外推 ~0.4  borderline。裁决：vits 为本机类低配机的离线默认；Kokoro 条目在注册表保留（285H 验收机复测后定）。

**T0.3 阶段判定：离线 TTS「合成一句播一句」首声预算在 vits-aishell3 上不可达（RTF≈1）。**
→ M2 决策依据：① 优先 Kokoro/matcha(vocoder 补齐后) 达标者转正；② 均不达标时首句兜底=先播 Edge（若开）或先出文字+黄条，离线继续合成（「合成一句播一句」链保留，但首句允许边合边等）；③ vits-aishell3 仅作最终兜底。

## T0.5 KWS + silero-VAD（M3 唤醒前置）

| 项 | 结果 |
|---|---|
| silero_vad.onnx（v5）加载 | 87–110 ms ✓ |
| RSS | 218 MB |
| VAD process_rt（3 样本） | **0.008** | ✓（预算 0.05，余量 6×） |
| 分段行为 | 3 文件→3 段，尾静 800ms 定稿参数生效 | ✓ |
| KWS 模型 | `kws-zipformer-zh-en-3M-2025-12-20.tar.bz2` gh-proxy 持续 404，待 M3 前补 | ⏳ |

## T0.4 三引擎共存（流式 + SenseVoice + 离线 TTS 全预热）

| 指标 | 实测 |
|---|---|
| 峰值 RSS | 797 MB |
| **Δ vs 基线** | **602 MB**（预算 +300–600MB 压线过） |
| dll 单实例符号冲突 | 无（三引擎同载各跑一发冒烟通过） |
| 分项加载 | 流式 6.5s / SenseVoice 2.1s / TTS 1.9s（4 线程合计 ~10.5s，快速响应模式启动预热可行） |

## 闸1 拍板（M0→M1，2026-11-05 深夜，cron 授权「按最佳建议直接拍板」）

- **SenseVoice（闸心）达标 ✓、流式回归达标 ✓、VAD 达标 ✓、共存预算压线过 ✓** → **放行 M1**。
- **离线 TTS 本机全不达标属预期口径差**：预算（RTF<0.3/首声≤1s）按母方案 = 285H 14 核口径；本机 i5-7400T 4 核性能约为其 1/5–1/6，vits RTF 1.0 外推 285H ≈ 0.17–0.25 **达标**；Kokoro 外推 ~0.4 borderline；matcha（首选）缺 vocoder 未测。不构成「引擎自身缺陷」，不触发回炉。
- 前置待办带入 M2：① matcha vocoder 获取（换 repo 名重试/离线导入）；② 285H 验收机复测 TTS 组；③ 低配机失败回落链（T2.5/T2.6）是可用性底线，必须落地。
- KWS 不阻塞 M1/M2（M3 依赖），cron 周期重试下载。

## 环境坑（本台账专用记录，M1 开发须知）

1. **System32 的 `onnxruntime.dll` 会劫持 c-api 依赖加载**（error 193）。任何进程用 `initBindings()` 前必须先用**绝对路径**打开我们 bin 里的 onnxruntime，见 `app/tool/m0_common.dart::initSherpaBindings()`；M1 worker isolate 初始化照此办理。
2. pub.dev 直连需 `curl --ssl-no-revoke`（吊销服务器脱机）。镜像站 `pub.flutter-io.cn` 分发的 sherpa_onnx_windows-1.13.8 **DLL 是坏的**（PE 截断），已用 pub.dev 官方归档（sha256 校验 `d91fb9c4…`）覆盖本地缓存。
3. PowerShell 5.1 读 UTF-8 脚本/源文件按 ANSI 解码——**PS 脚本纯 ASCII、绝不用 PS 读写含中文源文件**（本次曾把 `m0_matcha_check.dart` 烧成 GBK 乱码）。
4. Dart 对 GBK 字节源文件编译通过但字符串变乱码——含中文源文件损坏时 dart 不报编译错，靠 `dart run` 输出异常发现。
