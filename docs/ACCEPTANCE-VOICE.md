# ASR&TTS 重构验收报告（M0→M1→M2→M3 全量完成，2026-11-06）

> 施工依据：docs/asr-tts-refactor-plan.md v1.0（母方案）+ docs/asr-tts-refactor-buildplan.md v1.0。
> 过程台账：docs/M0-EVIDENCE-VOICE.md（M0 实测）、docs/M1-EVIDENCE-VOICE.md（M1/M2/M3 拍板与落地）、
> docs/voice-wakeup-min-spec.md（M3 最小规格）。
> 全部工作未推送远端（按约定）。

## 一、结论

**M0（选型实测）、M1（门面与重构）、M2（新能力）、M3（常驻唤醒合流）四个里程碑全部完成，代码侧测试全绿，待人工验收。**

- `flutter test` 全量：**1368 通过 / 4 失败（全部为施工前既有基线失败，agent/engine 域，与语音零交集）/ 18 skip**。
- `flutter analyze`（lib/test/tool）：**0 error**（314 条 info/warning 为既有风格基线，本次改动零新增）。
- 新增测试 94 条全绿（grep 实测计数）：asr_post_processor 12、voice_model_manager 15、voice_service 15、mic_arbitration 5、wake_session 9、tts_levels 2、voice_settings_defaults 6、offline_tts_layout 11、offline_tts_worker_smoke 1（真 FFI）、sensevoice_smoke 1（真 FFI）、wake_kws_arbitration 10、kws_keyword 6、kws_smoke 1（真 FFI）。

## 二、里程碑明细

### M0 选型实测（闸1 放行）
- SenseVoice int8：5s 段解码 248ms（预算 500ms ✓）；流式回归 ✓；VAD RTF 0.008 ✓；三引擎共存 RSS Δ602MB（预算压线过 ✓）。
- 详见 M0-EVIDENCE-VOICE.md（含闸1 拍板与 4 条环境坑）。

### M1 门面与重构（T1.1–T1.8）
- **T1.1/T1.2 VoiceService**：状态机 IDLE→LISTENING→CAPTURE→RECOGNIZE→SPEAK、会话互斥、半双工门控（播报位代次原语上收，播放器实现仍一份）、mic 单点（pcmTap→pcmFrames 分发）、唤醒超时器（10s/60s 可注入）。
- **T1.3 OfflineTts worker 化**：全部 FFI 进常驻 isolate；多引擎布局（vits/matcha/kokoro）；真 FFI 冒烟通过。
- **T1.4 AsrPostProcessor**：剥富转写标签 + 同音热词 + 指令归一（5 规则），12 条单测。
- **T1.5 VoiceModelManager**：7 条目注册表（sha256 钉 blob）、dio 断点续传（Range/双源/校验拒收/取消）、旧目录搬迁；**background_downloader 已移除**。
- **T1.6 设置 UI 合并**：CapabilitySettingsBody 语音两节删除（净 -453 行重复副本），单一 VoiceSettingsBody。
- **T1.7**：D4 落地——InferenceBackend 语音三件套三处直删（零调用方核实）；asr_engine 死引用清除；TtsLevels 双口径单测锁。
- **T1.8 消费方收口**：hold_to_talk/home_screen/chat_provider/host_speak 全部走门面，零回归。

### M2 新能力（T2.1–T2.7）
- **T2.1/T2.3 SenseVoice 假流式引擎**：常驻 worker + VAD 分段 + 游标裁剪（弃用 sherpa flush()——实测只出 0.3s 尾段）；真 FFI 冒烟（zh.wav→中文终稿、标签剥离）；**空稿二段式**（终验复查补齐）：首空稿「没听清」自动重开一次麦，再空稿收尾（视觉提示，TTS 会与半双工互斥）；「重说」按钮真重开麦再听一轮。
- **T2.2/T2.4 唤醒对话（模拟态）**：输入栏 🎙️ 入口 + 浮动转写条 + D2 自动发送（3s 缓冲可取消/重说）+ 模型下载引导（sensevoice+vad）。
- **T2.5 matcha 转正**：vocoder 解锁（alexmultiagent 镜像 vocos-22khz，sha256 钉死）；**本机实测 RTF 0.148–0.190、首声 542ms，双双达标**（M0 时缺 vocoder 的「全不达标」结论被推翻）；回落链 matcha→Edge(可选)→静默留痕 进 VoiceService.speakReply。
- **T2.6 失败黄条**：VoiceService.lastSpeakFailure + 设置页黄条。
- **T2.7 语义并入**：voiceEnabled && voiceAutoSpeak（旧值迁移），§6 设置卡全落地（总开关/引擎选择/唤醒卡/超时滑条）。

### M3 常驻唤醒（T3.0–T3.5，全部完成）
- **T3.0 KWS 模型定源**：`Jeryuk/kws-zipformer-wenetspeech-3.3M-MNN`（hf-mirror）= 官方 wenetspeech-3.3M 同名 blob，四文件 sha256 双工具钉死进注册表（`VoiceModels.kws`，~13MB）。本机实测：加载 1.3s / RSS +约 60MB / **RTF 0.033（常驻 ≤5% 单核预算达标）**；matcha 合成「汪柴」th=0.25 命中（56ms/1.71s 音频），E2E「合成→检测」闭环。
- **T3.1 KwsEngine**：KeywordSpotter 常驻 worker isolate（load/reset/audio/exit 协议，命中后自复位）；主 isolate 自有录音机（KWS 待命期唯一麦主）；**拍板：KWS 命中判定走块间解码**——8s 一次性喂入不吐命中（两次冒烟实测），按 100ms 生产节奏分块即中。
- **T3.2 mic 仲裁收口 VoiceService**：命中/识别会话/播报三处 `_suspendKws`，endCapture/endSpeak/stopSpeak 后 `resumeWakeListening()` 自检回待命；总开关/唤醒开关关闭即时停且绝不暗中留麦；ARMED 表达为 `wakeMicOn` ValueNotifier（不新增状态枚举）。
- **T3.3 UI**：设置页唤醒卡「语音常驻唤醒」开关 + 灵敏度滑条（0.3–0.9 默认 0.75 → 阈值 clamp(1−v, 0.1, 0.45) 默认 0.25，600ms 防抖重启）；首启向导依次引导 KWS→SenseVoice→VAD 三个模型下载（AsrModelGate 复用）。
- **T3.4 托盘四色**：idle 灰（原图标）/ 待命黄 / 识别绿 / 播报蓝——三个新 16×16 32bpp ICO 随仓固定，TrayService.setVoiceStatus 幂等（优先级 播报>识别>待命>idle），inference_gateway 订阅 states+wakeMicOn 驱动。
- **T3.5 ARMED 提示音**：880Hz 90ms 资产 + audioplayers 端口化注入（`VoiceService(wakeCue:)`，平台通道异常不进测试区），播放失败静默短路。
- 详见 M1-EVIDENCE-VOICE.md §M3（全部拍板与实测锚）。

## 三、人工验收清单（建议顺序）

1. **按住说话（零回归重点）**：长按 mic 说话 → 实时回显 → 松手发送；上滑取消；增强模式开关。
2. **唤醒对话（手动入口）**：设置 → 语音 → 开「语音交互」+「唤醒对话」→ 输入栏 🎙️ → 说话 → 停顿自动出稿 → 3s 自动发送（试点「取消」「重说」——重说会真重开麦再听一轮）；不说话等空闲超时 → 浮条「没听清，请再说一次」自动重听一次，再不说话才收尾；关 D2 开关再试手动口径。
3. **常驻唤醒（M3 新增）**：设置 → 语音 → 唤醒卡开「语音常驻唤醒」→ 首次引导三个模型下载（KWS ~13MB → SenseVoice ~240MB → VAD ~1MB；下载中可取消/重进断点续传）→ 听到一声短提示音 + 托盘变黄（待命）→ 对麦克风说「汪柴」→ 再一声提示音 + 浮条弹出会话开始听写；播报/识别期间说「汪柴」不应自醒；拖动灵敏度滑条（默认 75）约 600ms 后引擎热重启。
   - 模型获取：自动下载到 `%APPDATA%\WangCai\models\voice\kws-zipformer-wenetspeech-3.3M`；离线机可把 `C:\dev-tools\voice-models\kws` 的 4 个文件（encoder/decoder/joiner-*.onnx + tokens.txt）复制进去。
4. **自动朗读**：开总开关 + 自动朗读 → 发消息 → 回复逐句朗读（本机无注册表模型时走 Edge；把 C:\dev-tools\voice-models\matcha-zh-baker 目录复制到 %APPDATA%\WangCai\models\voice\matcha-zh-baker 可试 matcha）；停止生成/新消息发送时打断朗读。
5. **失败黄条**：断网后自动朗读 → 设置 → 语音 顶部黄条出现失败原因。
6. **模型管理**：设置 → 语音 → 识别模型下载/删除；中断断点续传（下载中杀进程重进）。
7. **听感**：C:\dev-tools\voice-models\out\tts_sent_*.wav 为 matcha 22050Hz 实测样音（对比 vits 8kHz）。

## 四、遗留与风险

- **KWS 真机统计（M3 代码侧已全绿）**：误唤醒 ≤1 次/天、漏唤醒 ≤10% 为开发期人工口径，需日常使用累计；合成音 E2E 已闭环。
- **285H 验收机复测**：TTS 组 + KWS（matcha 现已达标，预期显著好于 M0 时结论）。
- matcha zh-baker lexicon「谁(shei2)」多音字缺口：仅日志噪音，不影响合成。
- Kokoro：本机 RTF 2.1 维持否决为默认，285H 复测后再定（注册表保留）。
- 既有基线失败 4 条（agent/engine 域）与语音无关，未动。
