# 汪柴助手 v0.0.2 设计方案 —— Windows 壳首版

> 状态：**M0 Spike 已通过（2026-11-02，证据 [`app/M0-EVIDENCE.md`](../app/M0-EVIDENCE.md)）**，M1 可开工。
> 命名与仓库归属已拍板：**汪柴（WangCai）**，全部代码入本仓库（§1 D1）。
> 上游决策：本文承接 [README 三层结构](../README.md#wangcai-assistant) 与
> [路线图](roadmap.md) Phase 2 的"App 在 Windows 跑通"，并落实
> Windows 多引擎（NPU / llama.cpp / OpenAI 兼容）接入与调度策略的讨论结论。
> 调研依据：TongYi-Lite v0.3.7（181 个 Dart 文件）资产盘点 + 本仓库
> `src/llama/tools/server/`、`ggml-openvino-extra.cpp`、`docs/env-vars.md` 实测接口。

---

## 0. 版本定位

**v0.0.1 = 引擎**（NPU 端到端，精度主缺陷收官）。
**v0.0.2 = 助手第一个能装的 exe**：Windows 桌面壳跑通，NPU / 官方 llama.cpp（CPU·GPU）/
远端 OpenAI 兼容三类引擎可路由，聊天·图片·语音输入·Agent 达到"基本可用"。

### 目标（DoD 见 §9）

1. 一键安装的 `WangCai.exe`（显示名：**汪柴**），可最小化到托盘驻留。
2. 引擎驱动注册表：WangCai-NPU、llama.cpp-Vulkan、llama.cpp-CUDA、llama.cpp-CPU、自定义 OpenAI。
3. 统一模型库（GGUF + mmproj 配对 + 三源下载器）与模型×引擎绑定表。
4. 流式聊天 + 图片多模态（`--mmproj`）+ 微信式按住说话（sherpa ASR）+ TTS 播报。
5. ReactLoopAgent 原生工具调用（llama-server `--jinja` 走 OpenAI `tools` 协议）回归通过。
6. 路由策略三档：速度优先 / NPU 优先 / 自动（单 active + 空闲卸载）。

### 明确不做（留给后续版本）

- C ABI / FFI 直链（Phase 1 并行线，成熟后替换传输层，壳无感）。
- 功耗实测与功耗感知调度（Phase 4）、后台任务通道的任务类型细化（v0.0.3）。
- Dev Agent 的 Termux/adb/JGit 路线（Android 专属，Windows 版删除，本地 shell workspace 骨架保留）。
- 插件市场（plugin_kernel 随壳带上，但不作为 v0.0.2 验收面）。

---

## 1. 总体架构

```
┌─ WangCai.exe · 汪柴 (Flutter Windows 桌面壳, 单实例, 托盘驻留) ──────┐
│  UI 层: 复用 TongYi-Lite screens/widgets (riverpod)                   │
│  Agent 层: ReactLoopAgent + ToolRegistry + 双协议(原生优先)  ← 复用   │
│  会话层: sqlite(ffi) + JSONL + settings JSON                  ← 复用  │
│  ┌────────────── 引擎驱动注册表 EngineRegistry ────────────────────┐  │
│  │ EngineHost(进程/模型生命周期) + LlmAdapter(token 流, 已有)      │  │
│  ├───────────┬────────────────┬────────────────┬──────────────────┤  │
│  │ wangcai   │ llamacpp-vulkan│ llamacpp-cuda  │ openai-remote    │  │
│  │ -npu      │ (官方release)  │ (5060Ti, cu12) │ (base URL+key)   │  │
│  │ manifest  │ manifest       │ manifest       │ 无进程,纯HTTP     │  │
│  └───────────┴────────────────┴────────────────┴──────────────────┘  │
│  调度器: 会话→(engine,model,device) 绑定; 策略三档; 单active+空闲卸载  │
│  Windows 集成: tray_manager · window_manager · 热键 · 通知 · 电源      │
└───────────┬───────────────────────────────────────────────────────────┘
            │ localhost HTTP/SSE, OpenAI 兼容(唯一契约), 127.0.0.1+随机端口
   llama-server.exe ×N 种构建 (每引擎独立进程, 自带 runtime, 互不共享 DLL)
```

### 关键决策记录

| # | 决策 | 理由 |
|---|---|---|
| D1 | **壳在 WangCai 仓库 `app/` 目录**（Flutter Windows 工程）；Dart 自 TongYi-Lite v0.3.7 **同路径 vendored 导入**，TongYi-Lite 保持 Android 版并作为 Dart 上游 | 助手与引擎同仓演进、发版原子化；agent/UI/TTS/ASR 全纯 Dart 可搬；Dart 改进经 UPSTREAM 账本双向回流 |
| D2 | **引擎集成只认 OpenAI 兼容 HTTP**，一律子进程 + localhost | 三类引擎收敛到一个契约；`OpenAiService`/`OpenAiAdapter` 已实现且注释明示支持 llama.cpp server；C ABI 是二期替换项 |
| D3 | **GPU/CPU 用官方 llama.cpp release 二进制，不改汪柴 fork** | fork 保持 NPU 单一战线（configure.ps1 刻意 OFF CUDA/VULKAN）；官方迭代快，免维护负担 |
| D4 | **每引擎独立目录自带 runtime**，共享 GGUF 模型库 | 避免 DLL 地狱；模型是一份文件、多条绑定 |
| D5 | **配置/换模型 = 重启引擎进程**（env 在进程启动时读一次，静态图 per-process） | `ggml-openvino-extra.cpp:104-154` 的硬事实；UI 按此语义设计状态机 |
| D6 | **per-profile 独立编译缓存目录** | docs/env-vars.md 反复强调：旧编译图无声胜出是精度事故的温床 |
| D7 | **路由不写死参数量阈值，按绑定表实测指标 + 用户策略档**（速度优先/NPU 优先/自动） | 前期讨论结论：4B@NPU 当前 6 t/s + c512 + 未赢 CPU 速度，默认 CUDA；达标即自动改道 |

### 仓库内布局（D1 落地）与命名

```
WangCai/
  app/                        # 汪柴桌面壳（Flutter Windows 工程）
    pubspec.yaml
    lib/                      # Dart 自 TongYi-Lite 同路径导入 + Windows 新增件
      engine/                 # 新增: EngineHost / LlamaServerHost / RemoteOpenAiHost / EngineRegistry / 调度器
      platform/               # 新增: 托盘·热键·通知·电源·port 账本·截图·权限 stub
      (agent/ asr/ tts/ plugins/ providers/ models/ screens/ widgets/ services/)  # 与上游同路径, 便于 diff/回流
    assets/models_catalog.json
    windows/                  # flutter create --platforms=windows 生成的 runner（C++，保持薄）
    UPSTREAM.md               # Dart 同步账本：TongYi-Lite 基线 commit + 本地分叉清单
  tools/release/              # 新增：引擎包产出 + Inno Setup 打包 + 版本清单（§5.1 白名单）
```

| 项 | 值（拍板于 2026-11-02） |
|---|---|
| exe / 显示名 / 快捷方式 | `WangCai.exe` / 汪柴 / 「汪柴」 |
| 安装目录（只读） | `%LOCALAPPDATA%\Programs\WangCai\` |
| 数据目录（可写） | `%LOCALAPPDATA%\WangCai\`（模型库、引擎商店、编译缓存，§8） |
| 设置镜像 / 注册表 | `%APPDATA%\WangCai\` / `HKCU\Software\WangCai` |
| 安装包 | `WangCai-<ver>-win-x64-Setup.exe`（Inno Setup，AppName=汪柴） |
| 版本策略 | **助手版本 = 仓库版本**，单序列 v0.0.2 起；CHANGELOG 增设 `Assistant` 小节与 `Engine` 并列 |

---

## 2. UI 复用策略（资产盘点 → 施工面）

调研结论：**agent/UI/数据/语音层直接复用，移植主战场是"引擎耦合收编"**。
下表路径为 TongYi-Lite 中的源路径；导入后即 `app/lib/` 下**同名路径**（基线 commit 与本地分叉记录在 `app/UPSTREAM.md`）。

### 2.1 直接复用（纯 Dart，零改动或近零改动）

| 资产 | 位置（TongYi-Lite） | 备注 |
|---|---|---|
| Agent 主循环 | `agent/loop/agent.dart` `ReactLoopAgent`（971 行） | 重试瀑布、压缩、取消、JSONL 会话权威存储 |
| LLM 抽象与实现 | `agent/llm/adapter.dart` `LlmAdapter`；`openai_adapter.dart` | `generate(GenerateOptions, onToken/onThinking/cancel)`；原生 `tool_calls` 流式组装现成 |
| 工具协议 | `agent/protocol/`（native 优先 100，prompt_json 兜底） | llama-server 带 `--jinja` 自动走 `NativeToolProtocol` |
| 工具集 | `agent/builtin_tools/`（27 个） | `shell_exec` 语义换 cmd/PowerShell；`python_exec` Chaquopy→`Process.start('python')`；Termux 系删除 |
| 状态管理 | `providers/`（flutter_riverpod ^2.6.1） | chat/agent_state/model/download/settings 等 |
| 聊天 UI | `widgets/chat_bubble.dart`（flutter_markdown 流式）、`image_preview.dart`、`agent_workflow.dart`(1688 行)、`turn_items.dart`、`rail_scaffold.dart` | 含 todo 卡、统计条、思考/工具流渲染 |
| 设置页骨架 | `screens/settings_screen.dart`（8806 行，6 Tab：模型管理/API 接入/推理引擎/智能体/开发者/关于） | Tab 结构直接承接本方案 §4–§7 的新面板 |
| 会话/消息模型 | `models/chat_message.dart`、`conversation.dart`、`api_model.dart`、`model_info.dart`(下载目录) | |
| TTS | `tts/edge_tts_service.dart`（网络）+ `offline_tts_service.dart`（sherpa VITS，缺模型自动回落） | `audioplayers_windows` 现成 |
| ASR | `asr/sherpa_streaming_asr.dart`（sherpa-onnx 流式 Zipformer，常驻 isolate）+ `hold_to_talk.dart` | `record`(record_windows) 现成；需 M0 实测 DLL 打包 |
| 下载器 | `services/download_service.dart`（dio，断点续传+sha256+多阶段 gguf/mmproj/dspark） | 三源目录 `assets/models_catalog.json`（modelscope/hf-mirror/HF） |
| 设置存储 | `services/settings_service.dart`（JSON 原子写） | |
| 插件内核 | `packages/plugin_kernel`/`plugin_sdk` + `lib/plugins/host/` | host_capture/host_speak 的 Windows 能力在 §3 补 |

### 2.2 换实现（保 Dart 接口，换底层）

| 项 | Android 现状 | Windows 实现 |
|---|---|---|
| DB | sqflite `tongyilite.db` v6（schema：conversations + messages + 索引） | **`sqflite_common_ffi`**（已是 dev_dep，测试同款）——只改 `StorageService._init()` 工厂，schema/API 零改动 |
| 模型目录 | `/sdcard/TongYiLite/models` | `%LOCALAPPDATA%\WangCai\models`，首装可迁移/自选 |
| ASR 模型下载 | background_downloader（仅 Android/iOS） | 换 dio 下载（复用 download_service 循环） |
| 权限 | permission_handler（storage/media/manageExternalStorage） | stub 直接放行；microphone 走系统弹窗 |
| GBK 解码 | fast_gbk（FFI 待验） | 纯 Dart GBK 表（仅 fetch_url_tool/stock_source 用） |
| PDF 抽取 | PdfBox via channel | 纯 Dart（`pdf`/`printing` 包）或 `Process.start` pdftotext，接口不变 |
| 文件分享/打开 | files channel | `Process.start('explorer.exe'/'Start-Process')` |
| 音频理解通道 | `startRecording`→原生 mtmd | 归引擎能力（llama-server 能力探测），通道 stub |

### 2.3 收编战役（移植主战场，代码改动核心）

现状：普通聊天路径**绕过 adapter 直调** `InferenceService.completionWithMessages`
（chat_provider:854）、`model_provider:520 loadModel`、`settings_provider` 的
setOomGuard/setKvCacheType/setFlashAttn、`main.dart` initialize——这些绑死了 JNI 通道。

做法：**新增 `EngineHost` 抽象，与既有 `LlmAdapter` 分层**——

```dart
/// 进程与模型生命周期（对应原 InferenceService 的引擎管理语义, 21 方法归位）
abstract class EngineHost {
  EngineDescriptor get descriptor;              // id/显示名/能力/设备列表
  Future<EngineStatus> status();                // 状态机当前态 (§4.2)
  Future<void> start(EngineConfig cfg);         // spawn + 注入 env + health 等待
  Future<void> stop();                          // 优雅退出(端口文件清理)
  Future<EngineCapabilities> probe();           // 设备枚举/tools/vision 能力
  Stream<EngineLogLine> logs();                 // 日志流(编译进度/预热/错误)
  Stream<EngineMetrics> metrics();              // t/s、显存/内存、当前模型
  Future<void> applyPreset(ModelBinding b);     // = restart(D5)
}
```

- `LlamaServerHost implements EngineHost`：`Process.start` + 随机端口 + `/health` 探活 +
  日志解析状态机；token 流**复用 `OpenAiService`/`OpenAiAdapter`**，不重写 SSE。
- `RemoteOpenAiHost implements EngineHost`：无进程，start/stop 为 no-op，probe=`/v1/models`。
- 收编规则：**冻结 chat_provider/model_provider/settings_provider 对外的 Provider 签名**，
  只换它们背后持有的 `EngineHost` 实现；对 4 处直调点逐个提交，每步带回归（agent 路径先绿）。
- `inference_log_screen.dart` 改接 `EngineHost.logs()`（原生加载日志 → 引擎进程日志+编译进度）。

---

## 3. Windows 原生交互

| 需求 | 实现 | 细节 |
|---|---|---|
| 托盘驻留 | `tray_manager` + `window_manager`（leanflutter 系，Windows 成熟） | **关窗拦截必须 `setPreventClose(true)`，关窗 = `onWindowClose` 内直接 `hide()`；退出 = `_quitting + setPreventClose(false) + destroy()`（M0-2 实测：漏了会 Release 关窗即退/Debug 段错误；`exit(0)` 亦段错误）**。关窗行为可配置（最小化到托盘/退出，默认托盘）；托盘右键菜单：显示/隐藏、**当前引擎徽标**、暂停引擎、速度模式切换、模型快速切换、退出；双击恢复 |
| 单实例 | 命名事件/互斥体（FFI `CreateEvent`）或 `flutter_single_instance` | 第二实例启动 → 唤起已有窗口后退出 |
| 开机自启 | `launch_at_startup`（注册表 `HKCU\...\Run`） | 可选"启动后最小化到托盘"；开机常驻 = 后台通道（v0.0.3）的宿主 |
| 全局热键 | `hotkey_manager` | `Ctrl+Alt+Space` 显隐窗口；`Ctrl+Alt+M` 按住说话（透传给 `hold_to_talk`） |
| 通知 | `flutter_local_notifications`（Windows 后端）；不成熟则退 `tray_manager.displayMessage` | 触发点：引擎就绪（尤其 NPU 首次编译 ~36s 完成）、模型下载完成、Agent 长任务步完成 |
| 电源状态 | `battery_plus` | 有电池机型：拔电 → 自动档倾向 NPU；台式机恒"插电"，策略退化为 §7 表 |
| 防休眠 | `wakelock_plus`（长生成/长 Agent 任务期间） | |
| 音频链路 | `record`(record_windows, 16k mono PCM) → sherpa 流式 isolate；`audioplayers_windows` 播 edge-tts mp3 缓存/VITS | 与 Android 同构，M0 spike 验 DLL 打包 |
| 截图（Agent 视觉输入） | host_capture 的 Windows 实现：`Graphics.CaptureScreen`（WinRT）或 PowerShell `CopyFromScreen` | 喂 image_url（§4.4） |
| 文件关联（可选，M4） | `.gguf` 右键"加入汪柴模型库" | 注册表 ProgID → `--import-model <path>` |
| 崩溃残留清理 | 引擎进程写 `port.json`（pid+port）；壳启动扫描 `data/engines/`，清理孤儿 llama-server | 防"上次崩了留下三个 server 抢显存" |

---

## 4. 管线怎么接 WangCai（NPU 驱动）

### 4.1 驱动 manifest（数据，不是代码）

每个引擎一份 `engine_manifest.json`（壳内置 + 可远程更新）：

```jsonc
{
  "id": "wangcai-npu",
  "display": "汪柴 · Intel NPU",
  "exe": "engines/wangcai/llama-server.exe",
  "argsTemplate": ["-m","{model}","--mmproj","{mmproj?}","--host","127.0.0.1","--port","{port}",
                   "-c","{ctx}","-t","{threads}",
                   "-fa","1","-np","1","-st","-dev","OPENVINO{deviceIdx}",   // 硬约束, UI 不可改
                   "--jinja","--no-webui"],
  "envTemplate": {
    "GGML_OPENVINO_DEVICE": "NPU",
    "GGML_OPENVINO_FORCE_STATIC": "1",
    "GGML_OPENVINO_PREFILL_CHUNK_SIZE": "{chunk|256}",
    "GGML_OPENVINO_COMPILED_MODEL_CACHE_DIR": "data/cache/{profileId}",   // D6: per-profile 隔离
    "GGML_OPENVINO_NPU_COMPILE_OVERRIDES": "{overrides}"
  },
  "capabilities": { "nativeToolCall": true, "vision": true, "audio": false },
  "presets": {
    "lfm3-1.7b": { "modelGlob": "LFM3-1.7B*.gguf", "ctx": 1024, "chunk": 256 },
    "qwen3-4b":  { "modelGlob": "Qwen3-4B*.gguf",  "ctx": 512,  "chunk": 128,
                   "overrides": "-DNPUW_...levels禁用组", "note": "status.md 副靶配置(3/3 验收)" }
  },
  "admission": [   // 准入规则: 违规时 UI 前置拦截并给改道建议, 不等崩
    { "if": "params.ctx > 512 && model.paramsB >= 3.5", "reject": "OUT_OF_HOST_MEMORY 风险", "suggest": "ctx≤512 或换 CUDA 引擎" }
  ],
  "timingHints": { "coldCompileMs": 36000, "warmMs": 9000 }
}
```

要点：
- **硬约束 `-fa 1 -np 1 -st -dev OPENVINO3` 写死在模板**，不进用户可编辑区；`--jinja` 必开
  （没有原生 `tool_calls` 就退化到 prompt_json 协议，Agent 质量掉档）。
- **M0-3 实测**：`-st` 是 llama-cli 专属，`llama-server` 传入即 `invalid argument`——
  server manifest 的参数集为 `-fa 1 -np 1 -dev OPENVINO{n} --jinja`，**不得从 run-npu.ps1 照抄**。
  thinking 模板模型（LFM3-Q4_K_M）需给足 `max_tokens` 才能吐出 tool_calls（64 不够、512 行）。
- `profileId = hash(引擎, 模型, ctx, chunk, overrides...)` —— 任一参数变即换缓存目录（D6）。
- env 注册表 30+ 项全量映射到"推理引擎" Tab 的**高级表单**（docs/env-vars.md 是表单 schema
  的真源；诊断类 DUMP_BIN/PROFILING 只在开发者 Tab 暴露）。

### 4.2 引擎状态机（UI 一等公民）

```
 stopped ──start──▶ launching ──parse log──▶ compiling ──▶ warming ──/health 200──▶ ready
   ▲                  │(崩溃)                   │(失败)                                │
   │                  ▼                         ▼                                      ▼
   └──stop──── drain ◀──────────────────── error ◀────────────────────────────── busy(生成中)
```

- **日志驱动进度**：解析 llama-server 输出（图编译/权重加载/`listening`）映射到状态与进度文案；
  `timingHints` 用于进度条预期（36s 冷编 / 9s 热）。
- **看门狗**：进程意外退出 → 指数退避重启（1s/4s/16s），3 连败 → 状态置 error + 通知 + "查看日志"。
- **应用即重启**：任何 preset/env 修改走 stop→start（D5），UI 明确提示"重启引擎（约 Ns）"。
- **换模型** = 同引擎 `applyPreset` 重启（无热切换，llama.cpp 多模型管理在本 build 不可用）。

### 4.3 与调度器的接口

调度器对 `EngineHost` 只说三种话：`start(cfg)` / `stop()` / `status()`。
单 active 规则、空闲卸载（NPU 10 min、llama.cpp 3 min，缓存目录**不删**）在调度层实现，
引擎层无感知。

### 4.4 多模态（NPU 侧）

- 启动带 `--mmproj`（模型库自动配对：同前缀 `*mmproj*.gguf`）；mtmd/clip 图同样进
  ggml-openvino 静态路径（warm encode 542ms，status.md）。
- 聊天图片附件 → `content:[{type:"image_url", image_url:{url:"data:image/png;base64,..."}}]`；
  多图沿用 `imagePaths/visionPaths` + 长图切块服务（复用）。
- 音频理解（mtmd audio）v0.0.2 **不承诺**：引擎侧端到端但未过验收，能力探测位留灰。

---

## 5. 本地 llama.cpp（官方）怎么搞

### 5.1 获取：壳内置"引擎商店"

- 数据源：GitHub Releases `ggml-org/llama.cpp`（国内镜像 ghproxy 列表兜底），
  取 `llama-<ver>-bin-win-vulkan-x64.zip` / `-cuda-cu12.zip`。
- **版本白名单**：manifest 钉"已验证版本"，UI 一键安装/升级/回滚；sha256 校验；
  解包到 `engines/llamacpp-<ver>-{vulkan,cuda}/`（D4：各自完整 runtime）。
- 不做：从源码编译（构建留给开发者文档）、多版本并存超过 2 个（磁盘预算）。

### 5.2 探测与选择

| 探测 | 方法 | 结果用于 |
|---|---|---|
| Vulkan 设备 | 启动 `llama-server --list-devices`（或 dry-run 解析日志） | 枚举 Intel iGPU + RTX 5060 Ti；`--device` 选择 |
| CUDA 可用性 | `nvidia-smi` 存在 + **版本下限**（Blackwell sm_120 需较新构建 + CUDA≥12.8 runtime） | 不满足 → CUDA 驱动置灰，引导 Vulkan |
| CPU | 恒可用 | Vulkan 探测失败时 `-ngl 0` 同包降级，不单独发 CPU 包 |

manifest 与 §4.1 同构（无硬约束 env；`argsTemplate` 含 `-ngl {gpuLayers|99}`、`--device {gpu}`）。

### 5.3 与汪柴 fork 的关系

互不掺和：不互链 DLL、不互用二进制、模型库共享、绑定表各记各的实测。
汪柴升级发布 = 本仓库 `tools/` 产出新引擎包 → 壳内"引擎更新"通道拉取。

---

## 6. OpenAI（远端兼容）怎么搞

**这块基本是"把已有的洞补严"，不是新建**：

- `models/api_model.dart`（端点配置）、`services/openai_service.dart`（dio SSE + 停摆看门狗）、
  `agent/llm/openai_adapter.dart`（原生 tool_calls）**全部复用**；设置页"API 接入" Tab 已有。
- v0.0.2 补的三件事：
  1. **API Key 安全**：迁入 `flutter_secure_storage`（Windows DPAPI 后端，pubspec 已有此依赖），
     不再存 `inference_settings.json` 明文；
  2. **模型发现**：`GET /v1/models` 列表 → 生成绑定条目（capabilities 探测：tools 能力用
     capabilities 试探请求判定）；
  3. **路由地位**：作为第 5 类引擎进注册表，可被策略选用也作**兜底**——NPU 精度事故
     （Phase 1 未收口的指令退化类）时自动档提示"切云端重试"。
- 计费护栏：远端调用在状态栏显示 token 计数（`context_usage_provider` 已有估算）。

---

## 7. 模型库、绑定表与路由

### 7.1 统一模型库

- 复用 `download_service.dart`（dio、断点续传、`.tmp`+sha256、主+mmproj 多阶段、并发 2）
  与 `models_catalog.json` 三源目录（modelscope/hf-mirror/HF）+ 远程热更新。
- 扫描 `%LOCALAPPDATA%\WangCai\models\*.gguf` → 解析 GGUF 元数据
  （参数量/架构/上下文/是否带 mmproj）→ 入库；目录条目与本地文件做"建议下载"撮合。
- mmproj 自动配对（同族前缀启发式 + 手动纠正入口）。
- catalog 中 dspark/split-MoE 等 Android fork 特有字段在 Windows 驱动下标记"不生效"，UI 隐藏。

### 7.2 绑定表（新 sqlite 表，路由的真源）

```
bindings( engineId, modelId, device, presetJson,
          lastDecodeTps, lastPrefillTps, maxStableCtx, qualityPass, lastUsedAt,
          status /* unknown|usable|recommended|broken */ )
```

实测由每次会话后的 `EngineMetrics` 回写；"推荐"档由质量门（三问类快检）+ 速度门手工/脚本置位。

### 7.3 路由三档（Auto 模式设置项）

| 档 | 规则 |
|---|---|
| 速度优先 | 交互聊天 → binding.status 中 t/s 最高者（今天=5060Ti CUDA）；无可用退 CPU，再退远端 |
| **NPU 优先** | ≤4B 一律 NPU（接受 c512/6 t/s——后台化使用场景的正当档位，一键可切） |
| 自动（默认） | 任务画像 + binding 实测：聊天/Agent 前台→最快可用；摘要/记忆蒸馏等后台队列→NPU；电池机型拔电→NPU 加权；准入违规→前置改道建议（§4.1 admission） |

调度护栏：同一时刻**至多一个** loaded 引擎（显存/NPU 共享内存预算表），空闲超时卸载。

---

## 8. 数据与目录布局

```
%LOCALAPPDATA%\WangCai\
  models\                  GGUF + mmproj（模型库物理目录, 用户可迁移）
  data\                    tongyilite.db(v6+bindings/engines 迁移) · sessions\*.jsonl
                           inference_settings.json · cache\<profileId>\(OV 编译缓存)
                           engines\port.json(进程账本)
  engines\
    wangcai\               v0.0.x 引擎包: llama-server.exe + OV 运行时 DLL（随安装包）
    llamacpp-<ver>-vulkan\ 引擎商店安装（§5.1）
    llamacpp-<ver>-cuda\
%APPDATA%\WangCai\  用户设置备份位（settings JSON 镜像）
```

安装包：Inno Setup（AppName=汪柴，产物 `WangCai-<ver>-win-x64-Setup.exe`，卸载清
`HKCU\Software\WangCai`）；`flutter build windows --release` + 引擎包 + VC++/OV DLL 合包；
无静默联网假设（模型与 llama.cpp 均为运行期按需下载）。

---

## 9. 里程碑与验收（DoD）

> M0 是半天~一天的 Spike，全部成立才进 M1（顺序即风险优先级）。

| 里程碑 | 内容 | DoD |
|---|---|---|
| **M0 Spike** ✅ 2026-11-02 | `app/` 建 Flutter Windows 工程（`flutter create --platforms=windows`），Dart 自 TongYi-Lite v0.3.7 同路径导入并编译通过（`UPSTREAM.md` 立账）；tray_manager/window_manager 冒烟；手工起 llama-server（NPU）手聊通；**sherpa_onnx Windows DLL 打包验证**；sqflite_common_ffi 跑通既有测试 | 六件事全绿，证据 [`app/M0-EVIDENCE.md`](../app/M0-EVIDENCE.md)；系统前置补装（dev mode/NativeDesktop/ATL）与 4 个上游既有失败测试均已记录 |
| **M1 壳+汪柴驱动** | EngineHost/LlamaServerHost + wangcai manifest + 状态机 + 4 处直调点收编；设置页"推理引擎"Tab（表单生成自 env-vars.md） | LFM3-1.7B NPU 三问 3/3（复用 `tools/accept-smoke.ps1` 口径）；改 chunk 触发重启且换缓存目录；杀进程→看门狗复活 |
| **M2 三引擎齐** | 引擎商店（vulkan/cuda）+ 探测 + llamacpp manifest + openai-remote host + 模型库/绑定表 + 路由三档 | 本机四线通：NPU(1.7B) / CUDA(4B 5060Ti) / Vulkan(iGPU) / 远端 API；绑定表回写 t/s；单 active 互斥与空闲卸载生效 |
| **M3 驻留+多模态** | 托盘/自启/热键/通知/崩溃清理/电源感知；图片→image_url→mmproj；按住说话（sherpa）+ TTS | 24h 托盘驻留（含一次夜间空闲卸载-复活循环）；截图→识图问答；语音输入出文字 |
| **M4 Agent 回归+收尾** | `--jinja` 原生 tools 全链路回归（web_search/文件工具/todo/memory）；admission 规则表；安装包与升级通道 | `ReactLoopAgent` 既有测试全绿 + 新增 4 引擎×工具矩阵用例；安装包在干净机（无 VS/无 OV）装机成功 |

版本出口：M1–M4 全绿 → 仓库 tag `v0.0.2`（首个助手版本；CHANGELOG 增设 `Assistant` 小节，
安装包 `WangCai-0.0.2-win-x64-Setup.exe`）；任何 DoD 缺失则按 README CHANGELOG 规则记 Unreleased。

---

## 10. 风险与对策

| 风险 | 等级 | 对策 |
|---|---|---|
| **收编战役**改动 chat_provider（2784 行）等核心 | 高 | 冻结 Provider 签名、逐点提交、每点带回归；agent 路径先行（它有测试护体），普通聊天路径后行 |
| sherpa_onnx Windows 打包 | 中高 | M0 第一件事验它；不过 → ASR 降级为 v0.0.3（按住说话先隐藏），不阻塞主线 |
| flutter_local_notifications Windows 成熟度 | 中 | 退路 tray_manager.displayMessage（功能等价子集） |
| CUDA on Blackwell（5060 Ti 版本下限） | 中 | Vulkan 默认、CUDA 单独开关（D3 探测置灰）；两包都进引擎商店可回滚 |
| 引擎进程残留（壳崩溃） | 中 | port.json 账本 + 启动清扫孤儿进程（§3） |
| 旧编译图无声胜出 | 中 | D6 per-profile 缓存目录由代码强制，UI 不提供手填入口；"清理编译缓存"按钮单独给 |
| NPU 指令精度回归（Phase 1 未收口） | 中 | 远端 OpenAI 作自动兜底选项；引擎状态页挂"三问快检"按钮（脚本已在 tools/） |
| 官方 llama.cpp 版本漂移 | 低 | 白名单 + "已验证"标记 + 一键自检（health/tools/vision 三查）后才进 Auto |

---

## 11. 待定决策（评审时拍板）

已定（2026-11-02）：命名 = **汪柴（WangCai）**；**全部代码入本仓库**——壳在 `app/`，
Dart 自 TongYi-Lite 同路径 vendored 导入（§1 D1 与仓库内布局）。仍开放：

1. **M2 是否含 Vulkan 核显线**：5060 Ti 在场时 Intel iGPU 的实际价值待实测，可先降级为"探测到才显示"。
2. **音频理解**（mtmd audio on NPU）要不要挤进 v0.0.2 尾巴——取决于引擎侧端到端验收进度，建议不做。

---

## 12. v0.0.3 桌面独立化（2026-11-04 定案）

**决策**：Windows 分叉与手机端差异过大，**脱离上游 TongYI-Lite 独立演进**，
`app/UPSTREAM.md` 转为历史账本（不再回流），包名 `tongyi_lite` → **`wangcai`**，
品牌统一「汪柴 WangCai」（标题/问候语/MCP clientInfo/UA/关于卡；
`agent_prompt.dart` 身份段与 frozen 字节一致副本同步改写）。

**手机端死代码清除**（含关联测试）：Termux 意图通道（`termux_intent.dart`）、
内嵌沙箱（`embedded_tools/embedded_git`）、`measure_cmd`、手机 APK 安装器
（`native_env.dart`）、`WorkspaceBackend` 收敛为 **{localApp, remotePc}** 二值、
设置页 Termux 连接向导。替代：`agent/dev/tools/local_exec.dart` —— 系统 shell
（`cmd.exe /d /c`）+ 系统 git 的本地执行层（超时 kill、测试注入口、凭据注入推送），
`git_tools/verify_tool` 无感切换。

**明确保留**（桌面功能，不是死代码）：**ADB 全线**（用户明令"adb也需要"，桌面经
ADB 控制 Android 设备）、SSH 远程电脑工作区、语音（sherpa ASR + edge TTS）、
MTP/dspark（Phase 4 降级为模型级参数 `LocalModelConfig.draftPath`）。

**三大整改**（详见 `docs/DESKTOP-REFACTOR-HANDOFF.md` §3 五阶段计划）：

1. **会话 = 项目层级**：新 `lib/project/`（Project{id,name,workspacePath,…}，
   `%APPDATA%\WangCai\projects.json` + `active_project.json`）；SQLite v7 给
   conversations 加 `projectId`；JSONL 真相源迁
   `%APPDATA%\WangCai\projects\<id>\sessions\<convId>.jsonl`（header 带
   workspacePath/cwd），旧平铺一次性幂等迁移入"默认项目"（备份 `sessions.backup/`）；
   左栏项目选择器与会话面板、Dev 工作区胶囊统一为**单一工作目录真源**。
2. **模型管理桌面化**：`localModels: List<LocalModelConfig>`（照 `apiModels` 三件套
   先例）取代手机端下载目录 UI；NPU 预置区自动列绑定的 gguf（LFM3-1.7B、Qwen3-4B、
   Spark-X2.6-4B、LFM3-Omni-2B，后者两条须带 `PREFILL_CHUNK_SIZE=128` +
   `DISABLE_DECODE_LEVELS=1`）；「添加本地模型」file_picker 选 `.gguf`。
3. **引擎 = 内置 + 按需 + 参数体系**：NPU 引擎随 Inno Setup 内置
   （`%APPDATA%\WangCai\engines\wangcai\`），CUDA/Vulkan 按需从官方地址下载到
   默认/用户指定目录（sha256 白名单 + 镜像 + 本地包安装兜底）；
   参数优先级 **模型 `customArgs` > 引擎 `defaultConfig`（可编辑保存）>
   manifest 模板/preset**；`{devArg=OPENVINO3}` 硬编码改 OpenVINO 设备探测
   （失败回退 OPENVINO2，本机实测值）。

**不变量**：`flutter analyze --no-pub lib test tool` 零 error；测试对齐既有基线
（thinking_runaway×2、model_catalog×1、agent_stream_processor×1 为上游遗留失败）。
