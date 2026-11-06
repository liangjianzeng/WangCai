# 最小唤醒规格（M3 前置，按母方案 §4.2 口径自拟）

> 授权背景：母方案引用的 B1《voice-wakeup-design》不在仓内（施工计划 §4.2 标注
> 「B1 doc 缺失，授权自拟」）。本文档是 M3 KWS 合流的**最小实现规格**，指标以
> 母方案 §4.2/§7 为锚，实现面以 M1/M2 已落地的 VoiceService/注册表为准。
> 状态：2026-11-06 施工台账 docs/M1-EVIDENCE-VOICE.md §M2 之后。

## 1. 唤醒词（D 裁决继承）

- 唤醒词：**「汪柴」**（WangCai）。防误判：唤醒词进热词防误判表（asrHotwords
  分类外的自定义词表），对话中再出现「汪柴」不二次唤醒（会话内抑制）。
- 注册表条目 `kws-zipformer-wenetspeech-3.3M`（三件套 ~13MB）。**已定源
  （2026-11-06）**：`Jeryuk/kws-zipformer-wenetspeech-3.3M-MNN`（hf-mirror）=
  官方 wenetspeech-3.3M 同名 blob（zh-en-3M 官方仓全镜像链不可达），sha256
  钉死（台账 T3.0）。E2E：matcha 合成「汪柴」th=0.25 命中，RTF 0.033。

## 2. 状态机（VoiceService 扩展）

```
IDLE --KWS命中(阈值T1)--> ARMED(10s 无确认超时) --SenseVoice起听--> CAPTURE(wake)
ARMED --未确认--> IDLE
CAPTURE --VAD段尾800ms--> 定稿 → D2 自动发送（复用 WakeSession 收尾）
CAPTURE --播报期--> 半双工（现 beginSpeak 自动停麦/开麦自动停播不变）
```

- ARMED：KWS 命中后先**本地回一声短提示音**（<100ms，静音资源合成缓存），
  随即起 SenseVoice 会话；失败回落 IDLE 留痕。
- KWS 抑制窗：TTS 播报期关闭 KWS 判定（防自念自醒；与半双工闸同源
  `VoiceService.speaking`）。
- 托盘状态：IDLE=灰、ARMED=黄、CAPTURE=绿、SPEAK=蓝（tray_manager 现有图标位）。

## 3. 指标（验收口径，母方案 §4.2/§7 + 本机实测锚）

| 项 | 预算 | 依据 |
|---|---|---|
| KWS 常驻 CPU | ≤5% 单核 | §4.6（M0 实测 VAD 0.008 RTF 余量 6×） |
| KWS 常驻 RAM | <50MB | §4.6 |
| 唤醒→开始回复（ASR+LLM首包+TTS首声） | ≤3s | §4.6；matcha 首声 542ms（本机）已留足 |
| 误唤醒 | ≤1 次/天（开发期人工统计） | 行业二段式（阈值 T1 0.5 起调） |
| 漏唤醒 | ≤10%（安静室内 1m 距离） | 同上 |
| 无输入超时/最长输入 | 10s / 60s（已实现可调） | §4.2 |

## 4. 实现清单（KWS 模型到位后 ~1d）

1. `lib/asr/kws_engine.dart`：KeywordSpotter 常驻 worker（协议同 sensevoice worker，
   PCM 取 `VoiceService.pcmFrames` 广播——mic 单点已备好）。
2. VoiceService 加 `wakeArm()`：命中→ARMED→自动 beginCapture(wake)；ARMED 超时回 IDLE。
3. WakeSession 复用（收尾/浮条/D2 不动）；入口按钮保留（无 KWS 时的显式通道）。
4. 托盘状态四色 + 设置页「唤醒灵敏度」滑条（threshold 0.3–0.8，默认 0.5）。
5. 首启向导：总开关开→勾选唤醒→引导下载 KWS 条目（复用 AsrModelGate）。

## 5. 明确不做（P2/后续）

- 「不对/取消」打断词（§5.2 标注 P2）；多唤醒词；远场（麦克风阵列）；声纹。
- ~~KWS 模型 hash 钉死后注册表补 sha256~~ 已做（T3.0，双工具校验）。

## 6. 实现状态（2026-11-06）

- §4 全部 5 项已落地（kws_engine / startWakeListening 仲裁 / WakeSession 复用 /
  托盘四色 + 灵敏度滑条 / 首启向导三模型引导）+ ARMED 提示音。
- 拍板差异（均记录在台账 T3.x）：ARMED 表达为 wakeMicOn ValueNotifier 而非新增
  VoiceState 枚举；KWS 命中判定走块间解码（8s 一次性喂不吐命中）；阈值映射
  clamp(1−v, 0.1, 0.45)。
