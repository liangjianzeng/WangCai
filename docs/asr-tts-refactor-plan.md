# 汪柴 ASR & TTS 重构专项方案（v1.0 待批稿）

日期：2026-11-05 · 基线：main @ 1fa151d · 状态：**待拍板，未开发**
姊妹篇：`docs/voice-wakeup-design.md`（唤醒交互与设置规格，本文不重复，只做接口衔接）

---

## 1. 背景与目标

现状一句话：**ASR 是本地 sherpa-onnx 流式 Zipformer（按住说话），TTS 是微软 Edge 云端（有断供前科），唤醒词完全空白，语音设置 UI 有两份拷贝，若干半成品待清理。**

重构四目标：

| # | 目标 | 验收口径 |
|---|---|---|
| G1 | **本地优先**：断网可用全语音链路 | 拔网线完成「唤醒→听写→回答→朗读」全流程 |
| G2 | **双场景双引擎**：按住说话要即时上屏（流式），唤醒对话要高精度（SenseVoice） | 见 §4 分场景引擎调度 |
| G3 | **云端 TTS 从"唯一"降为"可选"**：离线 matcha 转正为默认 | Edge 403 事故不再能瘫痪产品 |
| G4 | **一套门面**：VoiceService 统一供给 按住说话/唤醒对话/插件/自动朗读 四方 | 消灭双份设置 UI 与散装调用链 |

## 2. 现状盘点与去留裁决（证据：main @ 1fa151d）

| 现有资产 | 证据 | 裁决 |
|---|---|---|
| sherpa_onnx pub 1.13.8（ffi+Windows 预编译 dll） | pubspec.yaml:49；generated_plugins.cmake:10,19 | **留**，升级验证 2.0.x（M0） |
| 流式 ASR `SherpaStreamingAsr`（worker isolate、零拷贝 PCM、endpoint 断句） | sherpa_streaming_asr.dart:15-466 | **留**（这是资产不是债） |
| 流式模型 streaming-zipformer-zh-int8-2025-06-30（160MB，hf-mirror 断点续传） | asr_model_manager.dart:19-34,68-69 | **留** |
| 热词双路（词表内 ContextGraph 偏置 + 词表外 lpinyin 同音校正） | hotword_corrector.dart:9-165 | **留**，升级为 ASR 后处理公共层（SenseVoice 也走它） |
| 按住说话（长按输入区 mic 按钮、上滑取消、松手 1s 缓冲） | home_screen.dart:435-545,2859-2864 | **留**，收编进 VoiceService |
| 转录→输入框→自动发送；新消息/停止生成打断播报 | home_screen.dart:514-545；chat_provider.dart:535-548,559-560,2817-2818 | **留**（唤醒链路复用此接线） |
| Edge TTS（在线、sha256 缓存、代次单播位、分句逐段合成播） | edge_tts_service.dart | **降为可选「高品质在线音色」**；曾因微软强制 v2 token 全站 403 哑火两天（edge_tts_service.dart:140-142 留痕）——不可作默认依赖 |
| 离线 TTS OfflineTts（仅英文 VITS、手动放模型、主 isolate 合成） | offline_tts_service.dart:17-19,111-174 | **重做**：matcha 中文模型 + 下载器 + worker isolate 化 |
| OfflineTtsPort 装饰器（离线优先→Edge 回落） | host_speak_offline.dart:68-120 | **留模式**，反转默认（离线主、Edge 备） |
| 语音设置 UI ×2（CapabilitySettingsBody vs VoiceSettingsBody） | settings_screen.dart:3936-4483 vs 7105-7470 | **合并单源**（借唤醒设置新增之机重做） |
| background_downloader 撑 ASR 模型下载 | pubspec.yaml:51 TODO「仅 Android/iOS，将换 dio 移除」 | **迁 dio 下载器**（与 b499111 模型 catalog 下载链同源，一套两吃） |
| 文档指向的系统识别兜底 voice_input.dart / speech_to_text | asr_engine.dart:5-6（文件不存在，依赖不存在） | **删死引用**（G1 下系统识别本就该退役） |
| InferenceBackend 语音三件套（Windows 恒 false/null 空实现） | inference_backend.dart:82-86；local_server_inference.dart:795-799 | **删除**：语音域从推理后端剥离，归 VoiceService |
| TtsLevels 默认 volume:100 vs 设置默认 0 口径不一 | host_speak.dart:109 vs settings_service.dart:505 | 修（单测锁口径） |

## 3. 目标架构

```
┌─────────────────────────── 消费方 ───────────────────────────┐
│ 按住说话(输入区按钮) │ 唤醒对话(KWS态机) │ app.speak 插件 │ 自动朗读 │
└────────────┬────────────────┬───────────────┬─────────┬─────┘
             ▼                ▼               ▼         ▼
┌──────────────────────── VoiceService（门面，主 isolate）────────────────────┐
│ 会话状态机 IDLE→LISTENING→CAPTURE→RECOGNIZE→(post-process)→SPEAK          │
│ mic 独占仲裁（含 TTS 播报期半双工门控）· 超时器 · 事件流(部分文本/定稿/状态) │
└───┬───────────────┬───────────────────┬───────────────┬───────────────────┘
    ▼               ▼                   ▼               ▼
 KwsEngine      VadEngine          AsrEngine×2       TtsEngine 链
 (3M zipformer) (silero-vad)   ┌流式zipformer┐    ┌matcha-zh(默认)┐
  worker isolate 复用同一       │按住说话·上屏快│    │edge-tts(可选)  │
  常驻 PCM 流                   │SenseVoice-INT8│    │(OfflineTtsPort │
                               │唤醒对话·高精度 │    │  装饰回落链)   │
                               └───────────────┘    └───────────────┘
                    全部跑 worker isolate（对齐既有 SherpaStreamingAsr 模式）
┌──────────────────────── VoiceModelManager ────────────────────────────────┐
│ 5 模型条目 · dio 断点续传 · sha256 · hf-mirror 主源/github 兜底 · 进度 UI   │
└────────────────────────────────────────────────────────────────────────────┘
```

要点：
- **麦克风单点**：常驻 KWS 与一切录音共用同一路 PCM（16k mono PCM16，record 包），VoiceService 独占并分发；不再各开各的麦。
- **isolate 纪律**：所有 sherpa FFI（含 matcha 合成）进 worker isolate（照抄 sherpa_streaming_asr 的常驻 worker + TransferableTypedData 模式，顺带治好 offline_tts_service 自注的「主 isolate 卡顿」已知债）。
- **SenseVoice 与流式并存不冲突**：同一时刻只有一个识别器在跑（会话互斥），KWS/VAD 常驻轻引擎。

## 4. ASR 专项

### 4.1 双引擎分场景调度

| 场景 | 引擎 | 理由 | 「识别对不对」可见时机 |
|---|---|---|---|
| **按住说话**（现有） | 流式 Zipformer（现役模型不动） | 真流式 partial，边说边进输入框；用户自己控制端点 | 边说边见字（现状保持） |
| **唤醒对话**（新增） | SenseVoice-Small int8 | 中文精度/标点/ITN 明显强于小流式模型；免提场景说话短，整段延迟可接受 | 分段回显：VAD 每停顿 ≤0.5s 上屏（假流式，§4.3） |
| 插件听写（en_dictation） | 维持现状（流式） | 不回归即可 | 现状 |

SenseVoice 关键事实（FunAudioLLM，Apache-2.0）：非自回归（无 Whisper 静音幻觉环）、zh/en/ja/ko/yue 五语、富转写（情感/声学事件标签，**后处理剥离**）、内置标点与 ITN（数字/单位归一，"16K""每分钟"这类指令词受益）、sherpa_onnx OfflineRecognizer 原生支持。**单段上限 ~15s 量级** → 长输入必须 VAD 分段（§4.3）。官方精度/RTF 数字以 M0 本机实测为准（不抄宣传数）。

### 4.2 端点与超时（唤醒对话模式）

| 参数 | 默认 | 来源 |
|---|---|---|
| 段尾静音定稿 | 800ms（可调 600–1200ms） | 新增 |
| 唤醒后无输入结束会话 | **10s**（3–30s） | 用户需求（voice-wakeup-design §5） |
| 单次输入最长 | **60s**（5s–10min） | 用户需求 |
| 空/低置信 | 语音提示「没听清」重试一次 → 结束 | 行业二段式 |

### 4.3 假流式回显（本专项的可见性承诺）

唤醒对话中 VAD 滑动窗口：每次停顿即把已累积语音段送 SenseVoice，**partial 文本增量上屏**（气泡上方浮动转写条），会话结束文本进输入框（可编辑，沿用现有 `_finalizeVoice` 拼接逻辑；「自动发送」在唤醒模式改为**先见定稿再发**，见 §6 决策项）。效果：说话中每次停顿 ~0.5s 内见字，不必等说完。

### 4.4 后处理公共层（双引擎共用）

现有 `HotwordCorrector`（lpinyin 同音校正 + 长词优先 + 幂等）升格为 ASR 后处理管线唯一入口，串三步：
1. 富转写剥离（SenseVoice 情感/事件标签 `|HAPPY|` 等清除，原始标签留 debug 字段）；
2. 同音热词校正（现资产，词表 = 分类热词 + 用户自定义 + 唤醒词防误判表）；
3. 指令归一化（新增轻量映射表：「十六 K/16 k → 16K」等，随指令集演进；语义解析仍交 agent，ASR 只做字面归一）。

### 4.5 模型与下载

| 用途 | 模型（hf-mirror `csukuangfj/*`） | 大小（约） | 状态 |
|---|---|---|---|
| 流式 ASR | streaming-zipformer-zh-int8-2025-06-30 | 160MB | 现役 |
| 整段 ASR | sense-voice-2023-12-12（model.int8.onnx） | ~250–500MB | **新增**（M0 实测定档 int8 粒度） |
| KWS | kws-zipformer-zh-en-3M-2025-12-20 | ~8MB | 新增（唤醒篇） |
| VAD | silero-vad v5 | ~1MB | 新增 |

VoiceModelManager（由 AsrModelManager 泛化）：多条目注册表、sha256、dio 断点续传（替换 background_downloader，与 b499111 的 catalog 下载链合流）、目录统一 `%APPDATA%\WangCai\models\voice\<id>`（现 `applicationDocuments/models/asr` 一并迁入并做旧目录搬迁，沿用 dataRoot 搬迁纪律）。

### 4.6 资源与延迟预算（285H，M0 校准）

| 项 | 预算 |
|---|---|
| KWS+VAD 常驻 | CPU ≤5% 单核，RAM <50MB |
| 流式 ASR 会话 | 现状（2 线程）不动 |
| SenseVoice 5s 段推理 | ≤500ms（CPU int8，4 线程） |
| 首次加载 SenseVoice | ≤2s（快速响应模式=会话预热常驻，RAM +300–600MB） |
| 唤醒→开始回复（含 ASR+LLM 首包+TTS 首声） | ≤3s |
| NPU | **不占**（NPU 归 LLM；SenseVoice NPU 化 = P2 独立实验，sherpa 无 Intel NPU 后端，见姊妹篇 §1 三理由） |

## 5. TTS 专项

### 5.1 引擎策略：离线转正，云端降级为可选

| 引擎 | 角色 | 说明 |
|---|---|---|
| **matcha-icefall-zh-baker（新增，默认）** | 离线主力 | sherpa OfflineTts 支持 matcha 声学+vocoder；中文自然度优于 vits；模型 ~40–70MB；**进下载器**（终结「手动放模型」） |
| vits-zh-aishell3（备选） | 低端兜底 | 单文件、更差自然度；注册表保留条目 |
| Edge TTS（现役） | **可选「在线高品质音色」** | 主开关内单独勾选；保留 sha256 缓存与代次单播；文案明示「需联网，可能不可用」（403 事故教训产品化） |

回落链（沿用 OfflineTtsPort 装饰器模式，方向反转）：`matcha → (用户开启时) edge → 静默+失败留痕`。失败不再静默：任何引擎连续失败在设置页黄条提示（哑火两天无人察觉的事故制度化防复发）。

### 5.2 工程改造

- **worker isolate 化**：matcha 合成进常驻 isolate（offline_tts_service 自注债一并还）。
- **逐句合成流式播报**：保留现有分句（≤600 字，tts_text 清洗 markdown）+「合成一句播一句」；离线合成 RTF<0.3，首声目标 ≤1s。
- **播报期半双工门控**（唤醒篇依赖的 primitives，现有 beginPlayback/isCurrentPlayback/endPlayback 直接够用）：播报期关麦 + KWS 抑制窗（防自念自醒）；「不对/取消」打断词 P2。
- **参数统一**：音色/语速/音调/音量设置项继承 Edge 现状语义，离线引擎映射到 sherpa speed 参数；TtsLevels 默认值口径修复 + 单测。
- 自动朗读（edgeTtsEnabled && autoSpeak）语义并入 VoiceService 新总开关：`voiceEnabled && voiceAutoSpeak`。

## 6. 设置项总表（合并双份 UI 为单一 `VoiceSettingsBody`）

| 组 | 项 | 默认 |
|---|---|---|
| 总开关 | 语音交互（关=不占麦、不加载模型，零 footprint） | **关** |
| ASR | 唤醒对话（含热词词/试听/敏感度→唤醒篇 §5）；监听时长 10s；最长输入 60s（上限 600s）；增强识别模式（现役）；热词分类/自定义（现役） | |
| TTS | 引擎选择（离线晓/在线 Edge-可选）；自动朗读；语速/音调/音量；试听 | 离线/关 |
| 模型 | 5 条目状态/下载/删除（含 SenseVoice、KWS、VAD、matcha；现役流式条目迁移） | |
| 快速响应 | SenseVoice/TTS 常驻内存（+~400MB 换首唤不卡） | 开 |

**自动发送口径**（拍板项）：按住说话保持「松手即发」；唤醒对话默认「定稿上屏可编辑 3s 后自动发，可随时打断取消」。

## 7. 里程碑

| 阶段 | 内容 | 出口判据 |
|---|---|---|
| **M0 Spike（2d）** | pub 包 2.0.x 升级冒烟；SenseVoice 拉下即跑（hf-mirror）：5s 中文段延迟/字准/ITN 实测；matcha-zh 首声实测；双模型与现役 dll 共存 | 数字表进台账；不达标即回炉选型（paraformer-streaming 备胎） |
| **M1 门面与重构（3–4d）** | VoiceService + worker isolate 统一 + 后处理公共层 + VoiceModelManager（dio 迁移）+ 设置 UI 合并 + §2 裁决表落地（删死码/删 InferenceBackend 语音槽） | 按住说话/插件听写/自动朗读**零回归**（现有测试 + 新增回归） |
| **M2 SenseVoice+matcha（3–4d）** | 唤醒对话接 SenseVoice 假流式回显 + 端点超时 + matcha 转正 + 回落链 + 失败黄条 | 拔网线完成「按住说话→回答→朗读」；唤醒对话分段回显达标 |
| **M3 唤醒合流（与唤醒篇共线）** | KWS 常驻 + 状态机全环 + 托盘状态 + 首启向导 | voice-wakeup-design §7 全指标 |

## 8. 风险与对策

| 风险 | 对策 |
|---|---|
| SenseVoice 实测字准/延迟不达预期 | M0 硬闸；备胎 paraformer-streaming（sherpa 原生支持，接入口同构） |
| pub 包升 2.0.x 破坏现役流式 | M1 前先锁 1.13.8；升级单列可回退提交 |
| matcha-zh 自然度不达「愿意听」线 | vits 兜底 + 保留 Edge 可选；文案不吹「离线媲美在线」 |
| 双模型同载内存超预算 | 会话互斥 + 快速响应开关（关=懒加载） |
| record 包 AEC 在部分耳机失真 | 半双工不依赖 AEC（v1 不用 barge-in）；设备选择项 P2 |
| Edge 再断供 | 已是"可选"角色，产品不瘫痪；失败黄条制度 |

## 9. 待拍板（4 项）

1. **Edge TTS 去留**：可选保留（默认关）——还是彻底移除代码换包体？（建议保留，听写插件与音色党需要）
2. **唤醒对话自动发送口径**：定稿上屏 3s 缓冲自动发（建议）vs 必须手动确认？
3. **SenseVoice 档位**：int8 单档（~250MB，建议）vs 同时提供 fp16 高清档（+250MB，M0 对比后再定）？
4. **InferenceBackend 语音槽位删除**：确认无人依赖后直删（建议），还是 deprecate 一个版本？

—— 批准后按 M0→M3 开工；本文件与 voice-wakeup-design.md 同留工作区待批注，未提交。
