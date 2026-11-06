# 汪柴 ASR & TTS 重构施工计划（v1.0 · 拍板后开工稿）

日期：2026-11-05 · 基线：main @ f2a3a3d（含方案文档提交）· 状态：**待批，未开工**
母方案：`docs/asr-tts-refactor-plan.md` v1.0 · 代码事实全部经工作树逐行核实（见 §7 勘误表）

---

## 0. 拍板结果（用户裁决 2026-11-05）

| # | 事项 | 裁决 | 施工含义 |
|---|---|---|---|
| D1 | Edge TTS 去留 | **保留**，角色=可选「在线高品质音色」，默认关 | 不删代码；主开关内单独勾选；文案明示「需联网，可能不可用」；保留 sha256 缓存与代次单播 |
| D2 | 唤醒对话自动发送 | **用户设置项** `voiceWakeAutoSend`，**默认自动** | 新增设置项：开=定稿上屏 3s 缓冲自动发（可随时打断取消）；关=手动点发。按住说话不受影响（保持松手即发） |
| D3 | SenseVoice 档位 | **int8 单档**（~250MB） | 下载器只注册 int8 条目；不做 fp16 |
| D4 | InferenceBackend 语音槽 | **直删** | 接口声明（inference_backend.dart:82-85）+ Windows 空实现（local_server_inference.dart:795-799）+ Android Dart 侧 MethodChannel 实现（inference_service.dart:335-364）一并删，并核删 Kotlin 侧对应 channel 分支 |

**开工前阻塞项（需用户处理）**：

- ⛔ **B1 姊妹篇缺失**：`docs/voice-wakeup-design.md` 不在仓库（全库检索无此文件，母方案 :4/:182 引用的 §5/§7 无源）。M3 唤醒合流的交互规格、唤醒词表、敏感度档位全部悬空。对策：用户补提交该文档，或授权在 M1 期间按母方案 §4.2 参数表先行整理出唤醒篇最小规格。**M0–M2 不受阻**。

---

## 1. 全局施工纪律

1. **提交纪律**：每个任务号（T-x.y）单提交，提交信息带任务号；母方案 §8 已定的「升级单列可回退提交」照办。
2. **isolate 纪律**：所有 sherpa FFI（含 matcha 合成、SenseVoice 推理）一律常驻 worker isolate，照抄 `lib/asr/sherpa_streaming_asr.dart` 模式（spawn :235，TransferableTypedData 生产 :311 / 消费 :423）。
3. **麦克风单点**：常驻 16k mono PCM16 单路（record 6.2.1），VoiceService 独占分发；任何新消费者不得自开麦克风。
4. **测试门**：每个里程碑出口 `app/` 目录 `flutter test` 全绿（基线 1147 例，CI 不跑测试，人工门禁）。新增能力必须带测试（清单见 §5）。
5. **默认值口径**：§6（母方案）设置项总表的默认值全部写进单测锁死，杜绝再出 TtsLevels volume 100 vs 设置默认 0 这类双口径。
6. **失败不静默**：任何引擎连续失败 → 设置页黄条；引擎可用状态永远有 UI 可见性。

---

## 2. M0 Spike（2d）——先跑数，后动工

出口判据：数字表进台账（`app/M0-EVIDENCE-VOICE.md`，沿用现有 M0-EVIDENCE.md 惯例）；任一硬指标不达标即回炉选型，**不进 M1**。

| 任务 | 内容 | 判据 |
|---|---|---|
| T0.1 pub 包升级冒烟 | sherpa_onnx 1.13.8 → 2.0.x 升级尝试，单列可回退提交。验证：Windows 预编译 DLL（sherpa-onnx-c-api.dll，来自 sherpa_onnx_windows 传递依赖）2.0.x 有无预编译产物；`app/tool/sherpa_check.dart` 冒烟；现役流式链路回归 | **若 2.0.x Windows 无预编译 DLL 或 C API 不兼容 → 锁 1.13.8 不升**（1.13.8 OfflineRecognizer 已支持 sense-voice，SenseVoice/matcha 不依赖升级） |
| T0.2 SenseVoice 本机实测 | 新建 `app/tool/sensevoice_check.dart`：从 hf-mirror 拉 `sense-voice-2023-12-12/model.int8.onnx`，5s 中文测试集（含指令词「16K」「每分钟」类），实测 字准 / 5s 段延迟 / ITN 效果 / 富转写标签形态（为 T1.4 剥离规则供样本） | CPU int8 4 线程 ≤500ms/5s 段；字准显著优于现役流式（抽同句对比）；不达 → 启动备胎 paraformer-streaming 同口径实测 |
| T0.3 matcha-zh 首声实测 | `matcha-icefall-zh-baker`（~40–70MB）离线合成实测：RTF、首声、主观可懂度三档评级（愿意听/能懂/勉强） | RTF<0.3、首声 ≤1s（分句逐段条件下）；自然度低于「能懂」→ 触发 vits 兜底评估，且产品文案不得吹「媲美在线」 |
| T0.4 多模型共存 | 流式 + SenseVoice + matcha 三引擎同载（模拟快速响应模式），测 RAM 增量与 dll 冲突 | RAM 增量在 +300–600MB 预算内；dll 单实例无符号冲突 |
| T0.5 KWS/VAD 预验 | `kws-zipformer-zh-en-3M-2025-12-20`（~8MB）+ silero-vad v5（~1MB）拉下即跑，常驻占用实测 | CPU ≤5% 单核、RAM <50MB（M3 的前置闸，提前扫雷） |

## 3. M1 门面与重构（3–4d）——只搬不增，零回归是唯一主题

出口判据：按住说话 / 插件听写 / 自动朗读 **零回归**（现有测试 + §5 新增回归全绿）。

| 任务 | 内容 | 涉及文件（已核实） |
|---|---|---|
| T1.1 VoiceService 门面 | 新建 `lib/voice/voice_service.dart`：会话状态机 IDLE→LISTENING→CAPTURE→RECOGNIZE→SPEAK、超时器、事件流（partial/final/state）；四方消费者（按住说话/唤醒对话/插件/自动朗读）只准走门面 | 新文件 |
| T1.2 mic 独占与半双工门控 | 常驻 PCM 流分发归 VoiceService；beginPlayback/isCurrentPlayback/endPlayback（现 EdgeTtsService :371/:380/:383）上收为 VoiceService 播报门控，TTS 播报期关麦 | edge_tts_service.dart、home_screen.dart |
| T1.3 OfflineTts worker 化 | OfflineTtsService 模型加载与合成搬常驻 worker isolate（还掉 offline_tts_service.dart:17-19 自注的主 isolate 债） | offline_tts_service.dart |
| T1.4 后处理公共层 | HotwordCorrector（hotword_corrector.dart 全文 165 行）升格为 `AsrPostProcessor`：①富转写标签剥离（`|HAPPY|` 等，样本取自 T0.2，原始标签留 debug 字段）②同音热词校正（现资产）③指令归一化映射表（「十六 K/16 k → 16K」） | hotword_corrector.dart 扩展 |
| T1.5 VoiceModelManager | AsrModelManager 泛化：多条目注册表（流式现役 + SenseVoice-int8 + KWS + VAD + matcha + vits 备选共 6 条）；**dio 断点续传替换 background_downloader 并移除包**（pubspec :51 TODO 了结，与 b499111 catalog 链同源）；sha256；hf-mirror 主源 + 兜底；目录统一 `%APPDATA%\WangCai\models\voice\<id>`，旧 `applicationDocuments/models/asr` 搬迁沿用 dataRoot 搬迁纪律 | asr_model_manager.dart 泛化、pubspec.yaml（移除 background_downloader） |
| T1.6 设置 UI 合并 | CapabilitySettingsBody（settings_screen.dart:3922-4503）与 VoiceSettingsBody（:7105-7570，含 :7484-7569 热词编辑辅助）**合并为单一 VoiceSettingsBody**，结构照母方案 §6 总表；总开关「语音交互」默认**关**（关=不占麦不加载零 footprint） | settings_screen.dart |
| T1.7 死码清理与口径修复 | ①删 asr_engine.dart:5-6 死引用（voice_input.dart/speech_to_text 不存在）②删 InferenceBackend 语音三件套（D4：接口 + Windows stub + Android Dart 侧 + Kotlin 侧核删；已全库 grep 确认零调用方）③TtsLevels 口径修复（host_speak.dart:109 volume:100 vs settings_service.dart:505 edgeTtsVolume=0 → 统一口径 + 单测锁） | inference_backend.dart、local_server_inference.dart、inference_service.dart、asr_engine.dart、host_speak.dart、settings_service.dart |
| T1.8 消费方收编 | 按住说话（home_screen.dart:435-545、_buildMicKey :2856-2864、hold_to_talk.dart 423 行会话管理）收编进 VoiceService；chat_provider 自动朗读（:536-548）与打断（:560、:2818）改走 VoiceService.speak/stop；`app.speak` 插件（host_speak.dart）走门面 | home_screen.dart、hold_to_talk.dart、chat_provider.dart、host_speak*.dart |

## 4. M2 SenseVoice + matcha（3–4d）——新能力落地

出口判据：拔网线完成「按住说话→回答→朗读」全流程；唤醒对话（模拟态，KWS 在 M3）分段回显停顿 ≤0.5s；离线 TTS 首声 ≤1s。

| 任务 | 内容 |
|---|---|
| T2.1 SenseVoice 引擎 | `lib/asr/sensevoice_asr.dart`：OfflineRecognizer + model.int8.onnx，常驻 worker isolate；快速响应模式=会话预热常驻（默认开，RAM +~400MB） |
| T2.2 VAD 分段 + 假流式回显 | silero-vad v5 滑动窗口；段尾静音 **800ms**（设置 600–1200ms）定稿；每停顿增量上屏（气泡上方浮动转写条）；会话结束文本进输入框可编辑（沿用 `_finalizeVoice` 拼接，home_screen.dart:514） |
| T2.3 端点与超时 | 唤醒后无输入 **10s**（3–30s 可设）结束会话；单次输入最长 **60s**（5s–10min 可设）；空/低置信 → 语音提示「没听清」重试一次 → 结束 |
| T2.4 自动发送设置（D2） | 新增 `voiceWakeAutoSend` 默认 true：定稿上屏 3s 缓冲自动发、期间可打断取消；false=手动确认。设置页开关 + 默认值单测 |
| T2.5 matcha 转正与回落链 | 引擎链反转：`matcha（默认）→ edge（用户开启时，D1）→ 静默+失败留痕`；OfflineTtsPort（host_speak_offline.dart:68-120）保模式反方向；vits-zh-aishell3 注册表保留兜底条目；matcha 进下载器（终结「手动放模型」）；逐句「合成一句播一句」（tts_text.dart 分句 ≤600 字复用） |
| T2.6 失败黄条 | 任何 TTS 引擎连续失败 → 设置页黄条（Edge 哑火两天无人察觉的事故制度化防复发） |
| T2.7 自动朗读语义并入 | `edgeTtsEnabled && autoSpeak` → `voiceEnabled && voiceAutoSpeak`（总开关语义，母方案 §5.2） |

## 5. 新增测试清单（随任务同刀提交）

- `test/voice/voice_service_test.dart`：状态机迁移、会话互斥（同时刻单识别器）、超时器（10s/60s）、事件流时序
- `test/voice/mic_arbitration_test.dart`：PCM 单路分发、播报期半双工门控
- `test/voice/asr_post_processor_test.dart`：富转写剥离、同音校正幂等（继承 hotwords_test.dart 用例）、指令归一映射
- `test/voice/voice_model_manager_test.dart`：注册表 6 条目、dio 断点续传（mock adapter）、sha256 拒收、旧目录搬迁幂等
- `test/asr/sensevoice_vad_test.dart`：mock PCM → VAD 分段 → 假流式增量序列
- `test/tts/tts_levels_default_test.dart`：TtsLevels 与 settings 默认值单口径锁定
- `test/settings/voice_settings_defaults_test.dart`：母方案 §6 总表全部默认值（含 D2 voiceWakeAutoSend=true、总开关=关）

## 6. 里程碑排期与总闸

```
M0(2d) ──闸1──> M1(3–4d) ──闸2──> M2(3–4d) ──闸3──> M3(与唤醒篇共线，另排)
```

- **闸1（M0→M1）**：数字表达标；SenseVoice 不达标走 paraformer-streaming 备胎再评
- **闸2（M1→M2）**：三方消费者零回归 + flutter test 全绿；任何回归未清零不得进 M2
- **闸3（M2 出口）**：拔网线全流程验收（用户在场执行）
- M3 依赖 B1（唤醒篇文档），**不阻塞本计划 M0–M2**；总工作量（不含 M3）：**8–10 人日**

## 7. 证据勘误表（母方案 §2 行号 → 工作树实测，供批注时修订）

| 母方案引用 | 实测 | 偏差 |
|---|---|---|
| edge_tts_service.dart:140-142（403 留痕） | :139-140 | 起始行差 1，语义属实 |
| settings_screen.dart:3936-4483（CapabilitySettingsBody） | :3922-4503 | 两端均偏，以实测为准 |
| settings_screen.dart:7105-7470（VoiceSettingsBody） | :7105-7570（含 :7484-7569 热词编辑辅助函数） | 结束行差 100 |
| inference_backend.dart:82-86（语音三件套） | :82-85 | 属实（:86 为空行） |
| 其余（pubspec:49/51、sherpa_streaming_asr、asr_model_manager、hotword_corrector、offline_tts_service、host_speak_offline、host_speak:109、settings_service:505、home_screen、chat_provider、asr_engine:5-6、local_server_inference:795-799） | 逐条属实 | — |

**核实新增事实**：Flutter 应用在仓库 `app/` 子目录；dio ^5.7.0 已在依赖（:31），background_downloader 8.9.5（:52）待 M1 移除；`VoiceService` 全库不存在（净新建）；KWS/VAD 代码零存在；`docs/voice-wakeup-design.md` **不存在**（B1 阻塞项）。

## 8. 风险台账（增量，母方案 §8 之外）

| 风险 | 对策 |
|---|---|
| sherpa_onnx 2.0.x Windows 无预编译 DLL | T0.1 首个任务先验；不通即锁 1.13.8（SenseVoice/matcha 均不依赖升级，母方案 M0 项降级为「验证通过即可弃升」） |
| 唤醒篇缺失导致 M3 规格悬空 | B1 已列；M1-T1.6 设置 UI 只做唤醒对话开关骨架，唤醒词/敏感度等项留白待文档 |
| 删语音三件套牵出 Android Kotlin 侧编译依赖 | T1.7 同刀核删 Kotlin channel 分支；Android 构建冒烟纳入 T1.7 出口判据 |
| 旧 ASR 模型目录搬迁丢档 | T1.5 搬迁做成「复制→校验→删源」三步 + 失败留痕，搬迁前后各留清单日志 |
