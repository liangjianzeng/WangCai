# M1 施工台账（ASR&TTS 重构专项）

> 母方案 docs/asr-tts-refactor-plan.md v1.0 + 施工计划 docs/asr-tts-refactor-buildplan.md v1.0。
> 本台账记 M1 各任务的落地事实与 cron 授权下的拍板（M0 数据在 M0-EVIDENCE-VOICE.md）。

## T1.4 AsrPostProcessor（lib/asr/asr_post_processor.dart）

- 三级流水线：富转写剥离 → 同音热词校正（HotwordCorrector 原样复用）→ 指令归一化。
  任何一级抛错都退回上一级结果，识别永不因后处理丢字；`lastRawText` 留原文给调试。
- 剥离规则：`<|zh|>` 尖竖线整对删；`|HAPPY|` 竖线夹注要求首字母大写/全大写形态才删
  （「a|b」不误伤，实测样本不足按 sherpa 文档标签集宁滥勿缺——M0 test_wavs 未出口语标签）。
- **拍板（指令归一表）**：5 规则大小写吸收表——`(?<=[0-9])\s*[kK](?![a-zA-Z])→K`、
  G→G、M 只收空白保原形、`hz/HZ→Hz`、H→H（Hz 规则排在 H 前防拆散）。
  「16 k→16K」「285 H→285H」口径由 12 条单测钉死（test/asr/asr_post_processor_test.dart，12/12 绿）。

## T1.3 OfflineTts worker 化（lib/tts/offline_tts_service.dart）

- `OfflineTts` 全部进常驻 worker isolate（协议带 seq：load/synth/unload），
  PCM16 在 worker 侧转换 + TransferableTypedData 零拷贝回传；主 isolate 债清偿，
  对照 tool/m0_matcha_check.dart 实测过的 config 参数命名。
- `dispose()` 只 `unload` 引擎（释放几百 MB），isolate 留着复用。
- **多引擎布局**：OfflineTtsLayout 判 vits/matcha/kokoro（voices.bin→kokoro、
  vocoder*.onnx→matcha、否则 vits）；`chineseCapable` = matcha/kokoro/带 lexicon 的 vits。
- **拍板（supports 语种门）**：中文能力跟着布局走——英文 piper 老口径原样保留
  （拒汉字、要字母），中文布局接汉字；两边都要求至少一个实义字符。
  现有 17 条离线朗读回归零改动通过（host_speak_offline_test）。
- 补 `prewarm()`（纪律 2，之前文档里承诺但代码没实现）。
- Windows DLL：worker 内 `WANGCAI_SHERPA_DLL_DIR` 环境变量指定 bin 目录时先绝对路径
  预载 onnxruntime 再 initBindings（System32 劫持防护，打包态不设即默认搜索）。
- 真 FFI 冒烟：test/tts/offline_tts_worker_smoke_test.dart（本机模型在才跑；
  单独 13s 过，全量并行时给 10min 超时防 4 核饿死超时——拍板：不 skip，宁慢要跑）。

## T1.5 VoiceModelManager（lib/voice/voice_model_manager.dart）

- AsrModelManager 删除；消费方（hold_to_talk / sherpa_streaming_asr / settings_screen）
  已换接 `VoiceModelManager` + `VoiceModels.streaming`。
- **注册表 7 条目**（全部 sha256 取本机 M0 已验证 blob）：streaming-zipformer /
  sensevoice-int8 / vad-silero-v5 / kws（占位）/ matcha-zh-baker（vocoder 占位）/
  vits-zh-aishell3 / kokoro-v1.1-int8。
- 下载：dio `Range` 断点续传（.part；服务器不支持 Range 返 200 则 truncate 重下）、
  双源 hf-mirror→huggingface、sha256/尺寸校验不过即删文件换源、CancelToken 取消。
- **拍板：VAD 源** = `R4kSo1997/sherpa-onnx-silero-vad-v5`（下载实测 sha256
  `9e2449e1…` 与本机 M0 文件逐字节一致；csukuangfj/vad 与 deepghs/freddyaboulton
  均哈希不符）。
- **拍板：background_downloader 移除**（pubspec 删包 + pub get 通过，连带 logging；
  pubspec :51 的 TODO 了结）。测试用假 HttpClientAdapter（test/voice/
  voice_model_manager_test.dart 15/15 绿：注册表/续传/双源/拒收/取消/搬迁）。
- **拍板：M1 不做的事**：matcha dict 树与 vocoder、kokoro espeak-ng-data 树（372 文件）、
  KWS 三件套——条目留占位（`urls: []`），isReady 不为占位拒判，获取排 M2/M3。
  KWS 本轮回 hf-mirror 复核：`MigoXV/icefall-…`（safetensors 非 ONNX）、
  `moeru-ai/sherpa-onnx-…`（打包脚本仓库无模型文件）→ **继续阻塞**，M3 前 cron 重试。
- 目录统一 `%APPDATA%\WangCai\models\voice\<id>`；旧 `documents/models/asr/<modelId>`
  首用自动迁移（复制→字节校验→旧目录改名 `.migrated` 备份，v0.0.4 搬迁纪律；
  测试踩过两坑：rename 后 stat 源文件已不存在→先记尺寸；静态 Dio 跨用例缓存旧 adapter→
  注入 setter 即重置）。

## T1.1/T1.2 VoiceService 门面（lib/voice/voice_service.dart）

- 状态机 IDLE→LISTENING→CAPTURE→RECOGNIZE→SPEAK→IDLE；事件流
  states/partialText/finalTexts；端口化（VoiceCaptureEngine / SpeakGate 可注入假实现）。
- **会话互斥**：同时刻至多一路识别；**半双工**：播报位代次原语
  （beginPlayback/isCurrentPlayback/endPlayback）上收门面，播放器实现仍只有一份
  （EdgeTtsService）。
- **拍板（半双工方向）**：用户主动开麦时**自动停播报**再开麦（不硬拒——硬拒会让
  「语音引擎启动失败」的困惑提示回潮）；「关麦防自念自醒」由门控语义保证，KWS
  抑制窗 M3 接。
- **拍板（stopSpeak 无条件停）**：即使播报位不是门面开的（遗留路径直调
  EdgeTtsService.speak）也停——stopGeneration「用户喊停不应继续出声」不能失效。
- **mic 单点**：录音机只在 SherpaStreamingAsr 一处（record 平台通道约束），
  PCM 帧经 `SherpaStreamingAsr.pcmTap` 静态钩汇聚 VoiceService.pcmFrames 广播
  （M3 KWS/VAD 共用路；无人监听 broadcast 丢弃）。
- 超时器就位（wakeIdleTimeout 10s / maxUtterance 60s，毫秒级注入可测），
  M1 仅 wake 场景启用，按住说话零回归（有单测钉死）。
- 测试：voice_service_test（12 条）+ mic_arbitration_test（5 条）。

## T1.6 设置 UI 合并（settings_screen.dart）

- **拍板：CapabilitySettingsBody 的语音两节整段删除（净 -453 行逐行重复副本）**，
  换一行入口提示；语音播报/输入/热词/模型管理收口单一 VoiceSettingsBody
  （home_screen.dart:1536 侧栏「语音」节唯一挂载）。手术用一次性 Dart 脚本
  （UTF-8 安全；PS 5.1 会烧 GBK，禁用）。
- **拍板（M1 不造假开关）**：§6 总开关「语音交互」字段（voiceEnabled）与
  voiceWakeAutoSend 留 M2 T2.4/T2.7 与消费方一起落——M1 造无消费方的开关是死码。
  §6 默认值单测（test/settings/voice_settings_defaults_test.dart）已锁现有口径并
  注明 M2 待加字段。

## T1.7 死码清理与口径修复

- **D4 落地**：语音三件套（supportsAudio/startRecording/stopRecording）从
  inference_backend.dart 接口 + local_server_inference.dart Windows stub +
  inference_service.dart MethodChannel 侧全部删除（全库 grep 零调用方；无 Kotlin）。
- asr_engine.dart 头注释的 `speech_to_text`/voice_input.dart 死引用清除。
- TtsLevels 兜底口径 = 设置默认（0/0/0），host_speak.dart 加 levelsForTest()，
  test/tts/tts_levels_default_test.dart 钉死（双口径事故防复发锁）。

## T1.8 消费方收口（零回归验证过）

- HoldToTalkSession → VoiceService（引擎生命周期进门面，浮层/UI 留会话）；
  home_screen 调用点 API 不变零改动。
- chat_provider：sendMessage 停播 + stopGeneration 停播 → VoiceService.stopSpeak()
  （自动朗读链 _maybeAutoSpeak 保持 EdgeTtsService.speak 直调——T2.7 语义并入时
  随 voiceEnabled 总开关一起重排，避免 M1 多一次自顶冲突）。
- EdgeTtsPort（host_speak.dart）播控四原语 → VoiceService；OfflineTtsPort 自动跟随。
- 真 FFI 冒烟修挂死：worker error 回包带 seq 时先认领 _pending（synth）再落
  loadCompleter——此前 load 失败永不完成（未设 DLL 环境变量时暴露）；
  SherpaOfflineTtsEngine 支持显式 dllDir 注入，load 加 120s 防挂死超时。

## M2 SenseVoice + matcha（T2.1–T2.7）

### T2.1/T2.3 SenseVoice 引擎（lib/asr/sensevoice_asr.dart）

- OfflineRecognizer int8 常驻 worker（协议同 _AsrWorker：session/audio/stop/discard）；
  VAD（silero v5）+ 识别 + AsrPostProcessor 全在 worker；模型热加载（目录签名幂等）。
- **拍板（假流式收尾）**：sherpa VAD `flush()` 实测只推出最后 ~0.3s（正文丢失）——
  弃用；改为游标追踪（seg.start 绝对样本坐标）裁已消费音频，**stop 时剩余音频直接
  送识别**（尾段 ≥0.2s 才识别）。真 FFI 冒烟（zh.wav 5.59s）验证出稿无标签。
- VoiceService 按场景路由引擎（holdToTalk/plugin=流式，wake=SenseVoice）；
  beginCapture 支持 per-session 超时（voiceWakeNoInputSec/MaxInputSec）。

### T2.2/T2.4 唤醒对话 UI（lib/voice/wake_session.dart + home_screen）

- 入口：输入栏 🎙️ 按钮（模拟态，KWS M3 接）；浮动转写条（partial 增量 + 手动结束）。
- D2：定稿 3s 缓冲倒计时自动发送（可取消/重说）；voiceWakeAutoSend=false 只上屏。
- 模型 gate 复用 AsrModelGate（参数化 id/标题）引导下载 sensevoice+vad。
- 测试：wake_session_test 6 条（纯状态机 + 缓冲毫秒注入；broadcast 事件微任务
  派发晚于 await——测试断言前排空 pumpEventQueue，产品语义不受影响）。

### T2.5 matcha 转正（vocoder 解锁）

- **vocoder 源找到**：`alexmultiagent/sherpa-onnx-matcha-zh-baker` 的
  `vocos-22khz-univ.onnx`（与 zh-baker 22050Hz 匹配；csukuangfj/sherpa-onnx-vocoders
  只有 16kHz 版不兼容）。注册表 matcha 条目已补 URL+sha256（本机 blob 验证）。
- **本机实测（i5-7400T，m0_matcha_check + lexicon）**：加载 3.0s / RSS 364MB /
  22050Hz / **RTF 0.148–0.190（预算 <0.3 达标）** / **首句合成 542ms（预算 ≤1s 达标）**
  ——母方案 §4.6 的 285H 口径上更快。M0 的「TTS 全不达标」结论被 vocoder 解锁推翻。
- 修复两处：m0 tool 与 worker 的 Matcha config 均需 `lexicon`（character-lexicon.cc
  强制）；`who/shei2` Unknown token 为 zh-baker lexicon 多音字缺口，仅日志噪音。
- 引擎链落 VoiceService.speakReply（逐句合成一句播一句）：offline（默认）=
  matcha>vits>kokoro（注册表目录探测）→ Edge 回落（D1 开关）；edge=在线优先。

### T2.6/T2.7 黄条与语义并入

- `VoiceService.lastSpeakFailure`（ValueNotifier）+ VoiceSettingsBody 顶部黄条。
- 自动朗读语义并入：`voiceEnabled && voiceAutoSpeak`（旧 edgeTtsAutoSpeak 存量
  fromJson 一次性迁移，单测锁）；chat_provider._maybeAutoSpeak 改走 speakReply。
- §6 设置卡落地：总开关/引擎选择（SegmentedButton 离线|在线）/自动朗读/快速响应/
  唤醒对话卡（D2 开关 + VAD 尾静音 600–1200ms + 无输入 3–30s + 最长 5–600s）。
  voice_settings_defaults_test 5 条锁默认值（含 D2=true、迁移）。

## M3 常驻唤醒（T3.0–T3.5，voice-wakeup-min-spec）

### T3.0 KWS 模型定源（解锁记录）

- **拍板：源 = `Jeryuk/kws-zipformer-wenetspeech-3.3M-MNN`（hf-mirror）**。官方
  `csukuangfj` 仓在镜像 404、huggingface.co 直连 000（curl exit 28）、github
  kws-models release 本机不可达（moeru-ai manifest 钉的 source URL 复核 404）。
  Jeryuk 包 = 官方 wenetspeech-3.3M 同名 blob（encoder/decoder/joiner
  -epoch-99-avg-1-chunk-16-left-64.onnx + tokens.txt + test_wavs 七条）。
- sha256 双工具钉死（certutil + PowerShell Get-FileHash 一致）并进注册表：
  encoder `859cd6de…`（12,152,560B）/ decoder `fb581d67…`（675,349B）/
  joiner `fcf43a2e…`（253,410B）/ tokens `72316508…`（1,627B）。
  注册表 id 改 `kws-zipformer-wenetspeech-3.3M`（id 常量 `VoiceModels.kws` 不变）。
- **tokens 是带调拼音初/终音（无汉字）**：「汪柴」= `w āng ch ái`（w=38/āng=46/
  ch=34/ái=99 全在表内）；关键字行 `w āng ch ái @汪柴`（test_keywords 同款形态），
  唤醒词表写死（spec §5 不做多唤醒词）。
- **本机实测（tool/m3_kws_check.dart）**：加载 1.3s / RSS +约 60MB /
  **RTF 0.033（常驻 ≤5% 单核预算达标）**；官方 test wav 4/7 命中（其余 3 条与
  test_keywords 非配对，属测试集口径非模型问题）；**matcha 合成「汪柴，汪柴！」
  → KWS th=0.25 首档命中（56ms/1.71s 音频）——「合成→检测」与真实唤醒链同源，
  E2E 闭环**。
- **拍板（灵敏度上限）**：阈值 ≥0.3 合成「汪柴」必漏（干净人声 0.5 仍中但出现
  误配倾向，th=0.5 时 test_4 被吸成「女儿」）→ 映射 `clamp(1−v, 0.1, 0.45)`：
  滑条 v∈[0.3,0.9] 默认 0.75 → 阈值 0.25 实测安全档。

### T3.1–T3.5 实现面（lib/asr/kws_engine.dart + VoiceService + UI）

- **T3.1 KwsEngine**：KeywordSpotter 常驻 worker isolate（协议 load/reset/audio/
  exit，命中回包 `{'hit':kw}` 后自复位）；主 isolate 自有录音机（KWS 待命期
  **唯一麦主**）；PCM16 块 100ms 粒度喂入。
  **拍板（喂入节奏）**：KWS 命中判定走**块间解码**路径——8.5s 一次性
  acceptWaveform 后集中解码不吐命中（冒烟两次实测），按生产麦克风节奏分块即中。
- **拍板（mic 仲裁）**：KWS 待命麦让位规则全收口在 VoiceService——命中/识别
  会话/播报三处 `_suspendKws`，endCapture/endSpeak/stopSpeak 后
  `resumeWakeListening()` 自检（唤醒仍开 && 无识别 && 无播报）才回待命；
  总开关/唤醒开关关闭即时 `stopWakeListening`（绝不暗中留麦）。
- **T3.2 状态机**：不新增 VoiceState 枚举值——`wakeMicOn` ValueNotifier 表达
  ARMED（待命麦在跑），tray 四色映射优先级 播报>识别>待唤醒>待命。
- **T3.3 UI**：设置页唤醒卡「语音常驻唤醒」开关 + 灵敏度滑条（30–90，防抖
  600ms 重启引擎）；**首启向导**（spec §4.5）勾选即依次引导 KWS→SenseVoice→
  VAD 三个模型（复用 AsrModelGate，中途取消不翻开关）。
- **T3.4 托盘四色**：assets/tray/voice_{armed,capture,speak}.ico（16x16 32bpp，
  tool/gen_voice_assets.dart 生成、随仓固定）；TrayService.setVoiceStatus 幂等
  （状态未变不重设图标）；inference_gateway 订阅 states+wakeMicOn 驱动。
- **T3.5 ARMED 提示音**：assets/wake_cue.wav（880Hz 90ms 淡入淡出，
  audioplayers AssetSource）；**端口化注入**（`VoiceService(wakeCue:)`）——
  audioplayers 构造器会发**异步**平台通道异常，try/catch 拦不住，必须隔离出
  测试区；播放失败静默短路（提示音是增强，浮条即时可见才是硬反馈）。
- 测试：wake_kws_arbitration 10 条（命中路由/抑制窗/回待命/关停闭环，假句柄）
  + kws_keyword 6 条（关键字行/阈值映射单调）+ kws_smoke 1 条真 FFI（官方
  test_3.wav 命中文森特卡索，numTrailingBlanks 需尾静音）+ 注册表/默认值更新。
- **终验加固（拍板）**：voice_service_test 超时器组注入值 60/80ms 档在 4 核全量
  并行饿死下被调度抖动误触发（两次全量各挂一例、单跑恒绿）→ 注入统一放宽到
  200/300/500ms 抗饿死量级（比值不变，总量仍秒内）；饿死类 flake 封口。

### 终验复查补缺（2026-11-06，用户「重新再检查一次」指令）

- **T2.3 欠条兑现：空稿二段式落地**（wake_session.dart）。此前代码注释挂账
  「重试一次的二段式在 M3 补全」，复查发现 M3 并未接——补齐：首空稿浮条
  提示「没听清，请再说一次」（countdown -2 态）并**自动重开一次麦**；再空稿
  才「未识别到内容」（-1 态）收尾；用户主动结束（stop）不再重试。
  **拍板**：提示为浮条视觉态而非 TTS 语音——beginSpeak 半双工会停麦，与
  「重开麦等用户再说」互斥；浮条即时可见即硬反馈。「低置信」分支：sherpa
  OfflineRecognizer 无置信度出口不可测，空稿即「没听清」口径，含糊出稿由
  D2 3s 缓冲可取消/编辑兜底。
- **拍板（重说兑现）**：retry() 原实现只清态+撤浮条，注释称「直接再开一轮」
  实际不开麦（宿主 onEnded 后无人重启）→ 改走 _reopenMic 真重开（浮条留
  聆听态，新一轮定稿照常 D2 流程）。
- 竞态防护三件：重开麦代次 `_epoch`（stop/abort/retry 推进使在途重开失效，
  绝不暗中复活会话）+ `_reopening` 标志（active 真空期防 KWS 命中误开第二
  会话）+ 重试窗口 `_settling` 复位（stop 的 -2 分支可达）。wake_session_test
  6→9 条钉死（二段式/重试回聆听/喊停不复活/重说真重开）。
- **测试清单计数勘误**：验收报告旧计数（「46 条」「63 条」）算错且漏文件，
  实测（grep `test(` 计数）新增 **94 条**：asr_post_processor 12 /
  voice_model_manager 15 / voice_service 15 / mic_arbitration 5 /
  wake_session 9 / tts_levels 2 / voice_settings_defaults 6 /
  offline_tts_layout 11 / offline_tts_worker_smoke 1（真 FFI）/
  sensevoice_smoke 1（真 FFI）/ wake_kws_arbitration 10 / kws_keyword 6 /
  kws_smoke 1（真 FFI）。
- **§5 清单偏差拍板**：buildplan 要求的 `test/asr/sensevoice_vad_test.dart`
  （mock PCM→VAD 分段→假流式增量）以 `sensevoice_smoke_test`（真 FFI 全链）
  + `wake_session_test`（假流式增量序列）替代——VAD 内嵌 worker isolate
  （sherpa FFI），为 mock 抽接缝不值当，真 FFI 证据强于 mock。

## 待办/阻塞快照

- [M3] ~~KWS ONNX 三件套仓库~~ **已解锁**（2026-11-06：Jeryuk wenetspeech-3.3M
  镜像 = 官方同源 blob，sha256 钉死，E2E 实测通过）。
- [真机] KWS 真麦克风误唤醒/漏唤醒人工统计（spec 指标 ≤1 次/天 / ≤10%，开发期
  人工口径；模型与链路代码侧已全绿）。
- [验证] 285H 验收机复测 TTS 组 + KWS（matcha 现已达标预期显著）。
- [听感] matcha wav 落盘 C:\dev-tools\voice-models\out\tts_sent_*.wav（人工三档评级）。
