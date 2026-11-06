# 汪柴语音交互专项方案：ASR & TTS 重构 + 热词唤醒对话（v1.1 待批稿）

日期：2026-11-05 · 基线：main · 状态：**待拍板，未开发** · 本文件是语音专项唯一方案文档

---

## 1. 需求规格（用户已定，原话入规）

| 需求 | 规格 |
|---|---|
| 语音能力总开关 | **默认关闭**；关闭 = 不开麦克风、不加载模型，零 footprint（系统隐私角标可自证） |
| 唤醒监听 | 打开后设置热词唤醒监听，应用运行期常驻 |
| 默认唤醒词 | **汪柴**（拼音 wangcai / wangchai 双过） |
| 唤醒后 | 语音询问（「我在，请讲」），用户语音输入交互指令 |
| 会话结束 | 唤醒后默认 **10 秒**无输入视为结束（可设 3–30s） |
| 最长单次输入 | 默认 **1 分钟**，上限 **10 分钟**（可设） |
| 用户可调 | 唤醒词、监听时长、最长输入时间（+ 敏感度、续话窗、音色，见 §9） |

产品原则：**本地优先**（拔网线完成全链路）、**默认关**、**监听状态必须可见**（隐私）、**改状态类命令先确认后执行**（confirm-before-execute）。

## 2. 现状盘点与去留裁决（证据：main）

| 现有资产 | 证据 | 裁决 |
|---|---|---|
| sherpa_onnx pub 1.13.8（ffi+Windows 预编译 dll） | pubspec.yaml:49；generated_plugins.cmake:10,19 | **留**，升级验证 2.0.x（M0） |
| 流式 ASR `SherpaStreamingAsr`（worker isolate、零拷贝 PCM、endpoint 断句） | sherpa_streaming_asr.dart:15-466 | **留**（资产不是债） |
| 流式模型 streaming-zipformer-zh-int8-2025-06-30（160MB） | asr_model_manager.dart:19-34,68-69 | **留** |
| 热词双路（词表内 ContextGraph 偏置 + 词表外 lpinyin 同音校正） | hotword_corrector.dart:9-165 | **留**，升为 ASR 后处理公共层（SenseVoice 共用） |
| 按住说话（长按 mic 按钮、上滑取消、松手缓冲） | home_screen.dart:435-545,2859-2864 | **留**，收编 VoiceService |
| 转录→输入框→发送；新消息/停止生成打断播报 | home_screen.dart:514-545；chat_provider.dart:535-548,559-560,2817-2818 | **留**（唤醒链路复用） |
| Edge TTS（在线、sha256 缓存、代次单播、分句逐段播） | edge_tts_service.dart | **降为可选「在线高品质音色」**——曾因微软强制 v2 token 全站 403 哑火两天（edge_tts_service.dart:140-142 留痕），不可作默认 |
| 离线 TTS（仅英文 VITS、手动放模型、主 isolate 合成） | offline_tts_service.dart:17-19,111-174 | **重做**：matcha 中文 + 进下载器 + worker isolate 化 |
| OfflineTtsPort 装饰器回落链 | host_speak_offline.dart:68-120 | **留模式**，反转默认（离线主、Edge 备） |
| 语音设置 UI ×2（CapabilitySettingsBody vs VoiceSettingsBody） | settings_screen.dart:3936-4483 vs 7105-7470 | **合并单源** |
| background_downloader 撑模型下载 | pubspec.yaml:51 TODO「换 dio 移除」 | **迁 dio**（与 b499111 catalog 下载链同源，一套两吃） |
| voice_input.dart/speech_to_text 兜底（文档指向不存在文件） | asr_engine.dart:5-6 | **删死引用** |
| InferenceBackend 语音三件套（Windows 恒空） | inference_backend.dart:82-86；local_server_inference.dart:795-799 | **删**：语音域归 VoiceService |
| TtsLevels volume 默认口径不一 | host_speak.dart:109 vs settings_service.dart:505 | 修 + 单测锁 |

唤醒（KWS）：**全 app 零实现**——本次净新增。

## 3. 行业对标（通用易用方式，全部纳入）

| 产品 | 借鉴 |
|---|---|
| Apple「嘿 Siri」 | 唤醒引擎跑低功耗核（**不上 AI 加速器**）；「聆听时间」5/8/12/15s 可设 → 监听时长可配同款 |
| Alexa / Google Assistant | 设备本地 KWS、明示不上传原始音频；环形灯=正在听 → **托盘状态灯** |
| 特斯拉 / NOMI | 唤醒后连续对话窗口、免唤醒续话 → **续话窗**；中文唤醒词范式 |
| ChatGPT/Gemini 语音 | 免提全双工+barge-in（AEC 成本高，我们 P2） |
| 讯飞输入法 / 微信 PC / Win+H | 流式上屏 + 文本可编辑 → 「语音=快速输入」定位，桌面有键盘不必纯免提 |

铁律清单：默认关；首启向导（下载→试听→完成）；唤醒词**试听按钮**；敏感度滑杆（误醒↔漏醒）；监听可视化；push-to-talk 兜底；「没听清」二段式再给一次机会。

## 4. 目标架构

```
┌─────────────────────────── 消费方 ───────────────────────────┐
│ 按住说话(输入区按钮) │ 唤醒对话(KWS态机) │ app.speak 插件 │ 自动朗读 │
└────────────┬────────────────┬───────────────┬─────────┬─────┘
             ▼                ▼               ▼         ▼
┌──────────────────────── VoiceService（门面，主 isolate）────────────────────┐
│ 会话状态机 IDLE→WAKED→CAPTURE→RECOGNIZE→(后处理)→SPEAK→FOLLOWUP            │
│ mic 独占仲裁（TTS 播报期半双工门控）· 超时器 · 事件流(部分文本/定稿/状态)    │
└───┬───────────────┬───────────────────┬───────────────┬───────────────────┘
    ▼               ▼                   ▼               ▼
 KwsEngine      VadEngine          AsrEngine×2       TtsEngine 链
 (3M zipformer) (silero-vad)   ┌流式zipformer┐    ┌matcha-zh(默认)┐
  常驻 ~5%单核    复用PCM流      │按住说话·边说 │    │edge-tts(可选)  │
                               │边见字(现役)  │    │(OfflineTtsPort │
                               │SenseVoice-i8 │    │  装饰回落链)   │
                               │唤醒对话·高精度│    └───────────────┘
                               └──────────────┘
                    所有 sherpa FFI 跑 worker isolate（对齐既有常驻 worker 模式）
┌──────────────────────── VoiceModelManager ────────────────────────────────┐
│ 5 模型条目 · dio 断点续传 · sha256 · hf-mirror 主源/github 兜底 · 进度 UI   │
└────────────────────────────────────────────────────────────────────────────┘
```

- **麦克风单点**：常驻 KWS 与一切录音共用一路 PCM（16k mono PCM16，record 包），VoiceService 独占分发。
- **isolate 纪律**：KWS/VAD/ASR/TTS 全部 FFI 进 worker isolate（顺带治好离线 TTS 主 isolate 自注卡债）。
- **NPU 策略（明确否决「唤醒常驻上 NPU」，三条硬理由）**：① NPU 串行队列是 LLM 的，100ms 插队 = 对话与唤醒互相饿死（行业 always-on 唤醒从不用 AI 加速器主分区）；② 3M 模型上 NPU 零收益，反染静态图 blob 世代堆积病（22GB 取证殷鉴）；③ sherpa-onnx 无 Intel NPU 官方后端（仅 QNN/昇腾/rknn）。SenseVoice 的 NPU 化列 **P2 独立实验**（LLM 空闲仲裁 + OV 静态桶），不阻塞。

## 5. 唤醒对话交互环（状态机 + 可见性承诺）

```
IDLE ──KWS命中(阈值过+ASR置信确认)──▶ WAKED：TTS「我在，请讲」(播报期 mic 门控+KWS 抑制窗，防自念自醒)
  ▲                                        ▼
  │                              CAPTURE：VAD 流式分段
  │        ┌─ 累计静音≥10s(用户参数) ──────────────▶ 会话结束回 IDLE（需求定义）
  │        ├─ 段尾静音≥800ms 且已有语音 ─▶ 即刻送 ASR，partial 上屏（假流式回显）
  │        └─ 单次输入达最长时长(默认60s) ─▶ 强制截断送 ASR
  │                                        ▼
  │                              RECOGNIZE：SenseVoice 分段识别 → 后处理
  │        ├─ 空/低置信 ─▶ TTS「没听清」重试一次 ─▶ IDLE
  │                                        ▼
  │                              定稿进输入框（可编辑；自动发送口径见 §12-2）
  │                                        ▼
  │                              THINK：既有 chat/agent 管线（流式）
  │                                        ▼
  │                              SPEAK：matcha 逐句合成流式播报（mic 门控）
  └── 续话窗(默认10s)内免唤醒续说 ◀─ FOLLOWUP：回复完继续听，超时回 IDLE
```

- **实时可见性承诺**：唤醒对话中每次停顿 ≤0.5s 上屏转写（VAD 滑窗把已累积语音送 SenseVoice 增量出字），说话中看得见、不必等说完；按住说话路径维持流式边说边见字。
- **纠错回路**：定稿可编辑（桌面本行）；播报期固定打断词「不对/取消」中止执行回编辑态（半双工即可，不依赖 AEC）；barge-in 全双工 P2。
- **改状态类命令**（切 preset/删会话/下载模型…）：TTS 复述确认后才执行；查询类直接执行+回显。
- **常驻成本**：IDLE 态 CPU ≤5% 单核、RAM <50MB（KWS+VAD）；托盘状态灯：绿=监听、橙=我在听你说、蓝=回复中；一键静音。

## 6. ASR 专项

### 6.1 双引擎分场景

| 场景 | 引擎 | 理由 |
|---|---|---|
| 按住说话（现有） | 流式 Zipformer（现役模型不动） | 真流式 partial 即时上屏，用户自控端点 |
| 唤醒对话（新增） | **SenseVoice-Small int8** | 非自回归（无静音幻觉环）、zh/en/ja/ko/yue、内置标点+ITN（「16K」这类指令词受益）、富转写标签后处理剥离；官方精度/RTF 以 M0 本机实测为准 |
| 插件听写 | 流式现状 | 不回归即可 |

SenseVoice 单段上限 ~15s 量级 → 长输入必须 VAD 分段逐段识别拼接（与 §5 假流式同一机制）。真流式 paraformer-streaming 仅作 M0 不达标备胎（P2，多养一模型、精度略降）。

### 6.2 KWS 热词配置（开放词表，免重训）

- 模型 `sherpa-onnx-kws-zipformer-zh-en-3M`，keyword file 一行一条：`分隔音节 :boost #threshold @原文`。
- 「汪柴」默认两行（wangchai / wangcai 双拼音天然覆盖）；boost 1.5 / threshold 0.5 起调，敏感度滑杆映射 threshold 0.3–0.7。
- 用户自定义词：汉字 → pinyin 转写表（lpinyin 复用）→ 声母韵母分节 → 同音多候选行全写入；**试听按钮**实测触发才算保存。
- 二段式防误醒：KWS 阈值 → 唤醒后短 ASR 置信确认；电视误醒靠调高阈值 + 抑制窗。

### 6.3 后处理公共层（双引擎共用，`HotwordCorrector` 升格）

1. 富转写剥离（情感/事件标签清出正文，留 debug 字段）；
2. 同音热词校正（现役词表 + 自定义 + 唤醒词防误判表）；
3. 指令字面归一化（「十六 K/16 k → 16K」映射表；语义仍交 agent）。

### 6.4 端点与超时

| 参数 | 默认 | 范围 |
|---|---|---|
| 段尾静音定稿 | 800ms | 600–1200ms |
| 唤醒后无输入结束 | **10s** | 3–30s |
| 单次最长输入 | **60s** | 5s–**10min** |
| 续话窗 | 10s | 0=关 / 3–30s |

## 7. TTS 专项

| 引擎 | 角色 | 说明 |
|---|---|---|
| **matcha-icefall-zh-baker** | **离线默认（新增）** | sherpa OfflineTts matcha 声学+vocoder；~40–70MB 进下载器；首声 ≤1s |
| vits-zh-aishell3 | 低端兜底 | 条目保留，自然度差一档 |
| Edge TTS（现役） | 可选「在线高品质音色」，默认关 | 需联网、明示可能不可用；sha256 缓存与代次单播保留 |

- 回落链：`matcha → (用户开启时) edge → 静默+失败留痕`；引擎连续失败设置页**黄条提示**（403 哑火两天事故制度化防复发）。
- 逐句合成流式播报：保留分句（≤600 字 markdown 清洗）+ 合成一句播一句。
- worker isolate 化（还 offline_tts_service:17-19 自注债）；TtsLevels 口径修复+单测；播报 primitives（beginPlayback/isCurrentPlayback/endPlayback）直接供给唤醒态机门控。
- 自动朗读语义并入：`voiceEnabled && voiceAutoSpeak`。

## 8. 模型资产管理（VoiceModelManager，AsrModelManager 泛化）

| 用途 | 模型（hf-mirror `csukuangfj/*`） | 大小（约） | 状态 |
|---|---|---|---|
| 流式 ASR | streaming-zipformer-zh-int8-2025-06-30 | 160MB | 现役迁移 |
| 整段 ASR | sense-voice-2023-12-12（int8） | 250–500MB | 新增（M0 定档） |
| KWS | kws-zipformer-zh-en-3M-2025-12-20 | ~8MB | 新增 |
| VAD | silero-vad v5 | ~1MB | 新增 |
| TTS | matcha-icefall-zh-baker | 40–70MB | 新增 |

dio 断点续传 + sha256 + 多镜像（hf-mirror 主、github 兜底）；目录统一 `%APPDATA%\WangCai\models\voice\<id>`（旧 `models/asr` 走 dataRoot 搬迁纪律）。dll 共存冒烟（ORT vs ovlibs/llama）M0 过。

## 9. 设置项总表（双份 UI 合并为单一 `VoiceSettingsBody`）

| 组 | 项 | 默认 |
|---|---|---|
| 总开关 | 语音交互（关=零 footprint） | **关** |
| 唤醒 | 唤醒词（汉字→拼音、多别名、试听）；敏感度滑杆；监听时长 10s；最长输入 60s（上限 600s）；续话窗 10s | 汪柴 |
| ASR | 增强识别模式（现役）；热词分类/自定义（现役） | |
| TTS | 引擎（离线晓 / 在线 Edge 可选）；自动朗读；语速/音调/音量；试听 | 离线/关 |
| 模型 | 5 条目状态/下载/删除 | |
| 快速响应 | SenseVoice/TTS 常驻（+~400MB 换首唤不卡） | 开 |
| 开机自启 | 随应用（常驻监听前提） | 跟随 |

## 10. 隐私与安全

全部语音处理 100% 本地（sherpa-onnx 离线模型）；原始音频转录后即弃，默认不落盘（「保存会话音频」仅调试、默认关）；主开关关闭不持麦克风句柄；Windows 麦克风权限弹窗被拒时设置页红字引导；托盘灯+系统角标双确认「正在听」。

## 11. 里程碑与验收

| 阶段 | 内容 | 出口判据 |
|---|---|---|
| **M0 Spike（2d）** | pub 2.0.x 冒烟；SenseVoice/matcha/KWS hf-mirror 拉下即跑；5s 中文段延迟/字准/ITN、matcha 首声、KWS 命中率本机实测；dll 共存 | 数字表进台账；不达标回炉备胎（paraformer-streaming / vits） |
| **M1 门面重构（3–4d）** | VoiceService + isolate 统一 + 后处理公共层 + VoiceModelManager（dio）+ 设置 UI 合并 + §2 裁决落地 | 按住说话/听写插件/自动朗读**零回归** |
| **M2 对话闭环（3–4d）** | 唤醒对话接 SenseVoice 假流式回显 + 端点超时 + matcha 转正 + 回落链 + 失败黄条 | 拔网线完成「按住说话→回答→朗读」 |
| **M3 唤醒上线（2–3d）** | KWS 常驻 + 全状态机 + 托盘灯 + 首启向导 + 试听 | 下表指标全达标 |

**验收指标**：安静唤醒率 1m/3m ≥95%/85%，电视噪声 ≥80%；误唤醒 ≤1 次/24h；唤醒→提示音 ≤300ms；唤醒→开始回复 ≤3s；停顿回显 ≤0.5s；指令域字准 ≥95%（200 条指令集）；IDLE 常驻 CPU ≤5% 单核、RAM <50MB。合计 **~10 天**到 M3 可验收线。

## 12. 待拍板（5 项）

1. **Edge TTS**：可选保留（默认关，建议）vs 彻底移除？
2. **唤醒对话定稿后自动发送**：上屏 3s 缓冲自动发（建议，可随时取消）vs 必须手动确认？
3. **SenseVoice 档位**：int8 单档（建议）vs 加 fp16 高清档（M0 对比后定）？
4. **InferenceBackend 空语音槽**：直删（建议）vs deprecate 一版？
5. **快速响应模式默认开**（+~400MB 内存换首唤不卡）：要 / 不要？

—— 批准后按 M0→M3 开工。本文件为语音专项唯一方案，后续修订直接改本文件。
