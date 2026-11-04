# WangCai 桌面独立版重构 — 交接文档（进行中）

> **日期**：2026-11-04 · **ZCode 会话**：`sess_f30a1ff0-3b6b-4eeb-b0de-970751a79d68`
> **分支**：`feat/desktop-standalone-v0.0.3`（基于 `main` = `origin/main` @ `4216cd9`）
> **状态**：**Phase 0 进行中（约 80%）**，Phase 1–4 未动。工作区含大量未提交改动，本文档随改动一起提交。
> **接手人请先通读 §1（速览）→ §5（立即待办）→ §2/§3（计划全文）。**

---

## §1 速览：现在处于什么状态

| 项 | 状态 |
|---|---|
| 包名改名 `tongyi_lite` → `wangcai`（123 文件 + pubspec + 版本号 0.0.3+1） | ✅ 完成 |
| 品牌独立（App 标题/问候语/MCP clientInfo/UA/关于卡/GitHub URL） | ✅ 完成 |
| UPSTREAM.md 独立声明 | ✅ 完成 |
| 设计文档 §12（v0.0.3 独立化章节） | ⬜ **欠着** |
| 手机端死代码删除（termux/embedded/measure_cmd） | 🔄 **差最后一块**：settings_screen 的 Termux 向导未删完（当前编译报错就在这） |
| ADB | ✅ **保留**（用户明确"adb也需要"，已恢复我误删的文件） |
| 手机执行沙箱 → 桌面执行替换（`local_exec.dart`） | ✅ 新增完成（未验证测试） |
| `flutter analyze --no-pub lib test tool` | 🔄 **13 个 error**（全部为本次重构引入，清单见 §5.1），零 error 是 Phase 0 出口 |
| `flutter test` | ⬜ 本次未跑（基线债务见 §6.4） |
| Phase 1 会话/项目重构 | ⬜ 未开始 |
| Phase 2 模型管理 | ⬜ 未开始 |
| Phase 3 引擎管理 | ⬜ 未开始 |
| Phase 4 手机端配置清理 | ⬜ 未开始 |

**当前 git**：`main` 与 `origin/main` 同步；本次全部改动为未提交工作区改动 + 2 个未跟踪新文件（`app/lib/agent/dev/tools/local_exec.dart`、`app/test/enter_send_focus_test.dart`——后者是早前会话遗留的合法回归测试，一并提交）。`models/*.gguf`、`packaging/dist` 均已被 .gitignore 排除，仓库无大文件风险。

---

## §2 背景与用户决策记录

1. **独立项目大重构**（2026-11-04 用户拍板）：Windows 分叉与手机端 TongYI-Lite 差异过大，**彻底脱离上游**，可自由重构。包名、品牌、数据目录全部转 WangCai。UPSTREAM.md 保留为历史账本，不再回流。
2. **会话管理整改**：现状是手机形态（conversations 平铺、无项目维度、JSONL 在 ApplicationSupport 与 `%APPDATA%\WangCai` 数据区不一致）。按标准 CLI 智能体（dsh / Claude-Code 风格）加**项目层级**：会话归属项目，项目可选**工作空间（工作目录）**。
3. **引擎架构**（合并前会话 `sess_6dd7843a-a155-4c5a-af27-b8d7f587e9b8` 的模型管理+引擎管理任务）：WangCai 既是 agent 也是 NPU 引擎实现；**NPU 引擎随安装包内置**；**llama.cpp CUDA/Vulkan 按需下载**（模型加载时本地无引擎→按预置官方地址下载到默认或用户指定目录）；引擎装好后有**可配置保存的默认启动参数**；模型不设自定义参数就用默认；**手机端引擎配置全删**。
4. **"adb也需要"**（执行中途的用户纠正）：我曾把 `lib/agent/adb/**` 当手机死代码删除，**用户要求保留** —— 桌面版要用 ADB 控制 Android 设备。已从 HEAD 全量恢复（`lib/agent/adb/` 6 个文件 + 4 个 adb 测试 + `fake_adbd.dart`），并重新完成 `package:wangcai/` import 改名，`builtin_tools.dart` 里 adb 注册链（`adbEnabled/adbTargets/adbKeyStore` 参数 + `createAdbTool`）完好。**Phase 4 清理时不得再删 adb 任何文件。**
5. 四个设计问题（AskUserQuestion）用户未答，按计划书中声明的推荐方案推进：**彻底独立并改名 wangcai**；**JSONL 项目树为真相源 + SQLite 为索引**；**保留 SSH 远程工作区、语音（sherpa ASR + edge TTS）、MTP/dspark（降级为模型级参数）**；**左栏项目选择器**。

---

## §3 已批准的五阶段计划（全文，接手即按此执行）

### Phase 0 — 独立项目（解耦上游）　🔄 约 80%

1. `pubspec.yaml` name `tongyi_lite`→`wangcai`；全仓 import `package:tongyi_lite/`→`package:wangcai/`（含 test/、tool/、eval/、packages/）。 ✅
2. UPSTREAM.md 顶部"已独立，不再回流"声明；`docs/assistant-v0.0.2-design.md` 追加 v0.0.3 独立化章节。 ✅ / ⬜（§12 欠）
3. 删手机端死代码：termux_intent、embedded 工具链、measure_cmd 等。 🔄（差 settings_screen 向导）；**adb 例外保留**。third_party/dartssh2、edge_tts、sherpa 与 ASR/TTS **保留**。
4. 出口：`flutter analyze --no-pub lib test tool` 零 error + `flutter test` 对齐基线。 ⬜

### Phase 1 — 会话管理重构（项目 × 工作空间）

**数据层（新 `lib/project/`）**
- `Project` 模型：`id`(uuid)、`name`、`workspacePath`（本地目录，必需）、`sshConfigId?`（可选远程，复用 DevWorkspace remotePc 语义）、`createdAt/lastOpenedAt`。
- 注册表 `%APPDATA%\WangCai\projects.json` + `active_project.json`（仿 `lib/agent/dev/workspace_store.dart` 的 active 机制）；目录名安全化复用 `workspace.dart` 的 `sanitizeWorkspaceDirName`（Windows 盘符+路径合法化）。
- **会话归属**：SQLite v7 迁移 —— `conversations` 加 `projectId` 列（+索引）；新 `projects` 表（缓存 name/workspacePath 供 JOIN）。`StorageService.createConversation` 收 projectId；`getAllConversations({projectId})` 过滤。迁移仿 `storage_service.dart` `_onUpgrade` 的**列级幂等检查**纪律，动手前**备份 db 文件**。
- **JSONL 真相源改项目树**：`JsonlSessionStore`（`lib/agent/session/store.dart`）路径 `%APPDATA%\WangCai\projects\<projectId>\sessions\<convId>.jsonl`；header 增 `workspacePath/cwd`；goals/traces/metrics 目录挂项目目录下（`chat_provider.dart` :381/:1902/:1912 传项目基目录）。
- **一次性幂等迁移**：首启检测旧平铺 `ApplicationSupport/sessions/` + projectId 为空的会话 → 合成"默认项目"（workspacePath = documents/workspace）全部归入；旧文件 move 进项目树，整目录备份 `sessions/` → `sessions.backup/`，读取侧保留旧路径兜底。
- **智能体上下文**：项目 workspacePath 注入 agent 的 `<workspace:context>`（复用 `dev_context.dart` 注入路径）；shell/file 工具 cwd 由项目工作目录提供（取代沙箱默认），成为**唯一真源**。

**UI（home_screen 左栏）**
- 左栏顶部**项目选择器**：当前项目名+工作目录（省略号截断）；面板含项目列表（会话计数）、新建（file_picker 选文件夹→命名）、重命名/移除（不删数据）、"打开所在文件夹"。`file_picker ^8.1.2` 已在依赖。
- 会话面板主体（`home_screen.dart` :3084 抽屉）按 active 项目过滤；新建会话自动归属当前项目；**Dev 工作区胶囊与项目选择器合一**（消灭双真源，呼应 `chat_provider.dart` :232 "真源唯一"注释纪律）。
- 会话链路关键锚点：`ConversationsNotifier.create/delete` = `chat_provider.dart` :185-230；`JsonlSessionStore` 唯一消费点 :337；`SessionLog`（`session/log.dart`，DSH 风格 shadow ranges/deriveModelMessages/closeOpenTurns）。

### Phase 2 — 模型管理桌面形态

- `settings_service.dart` 新增 `localModels: List<LocalModelConfig>` —— **照抄 `apiModels` 三件套先例**（字段声明 :96 / toMap :944 / fromMap :1062）：`modelPath`、`name`、`engineId?`（空=Auto 路由）、`customArgs?`（模型级自定义参数，见 Phase 3）、`mmprojPath?`、`draftPath?`(MTP/dspark)、ctx/chunk/gpuLayers 覆盖项。
- `ModelManagementBody`（settings_screen.dart :102，home_screen.dart :1524 复用）重写：
  - **删**手机端下载目录 UI：`loadModelCatalog()` / `assets/models_catalog.json` / 下载·续传·删除弹层（:743/:815 等）。
  - **NPU 预置区**：从 `bundled_manifests` presets 自动列已绑模型 —— lfm3-1.7b / qwen3-4b + **新增 spark-x2.6-4b、lfm3-omni-2b 两条 preset**（extraEnv `PREFILL_CHUNK_SIZE=128`、`DISABLE_DECODE_LEVELS=1`，对齐 `tools/spark-npu-accept.ps1` 与 `docs/HANDOFF.md` 实测），显示在库/缺文件状态与加载按钮。
  - **本地模型区**：「添加本地模型」→ file_picker 选 `.gguf` → 配置卡（mmproj/draft/ctx/设备/自定义参数）→ 入 `localModels`；默认模型勾选保留。
- `home_screen.dart` :204 `_initAutoLoadDefaultModel` 走同一解析（defaultModelId 可为 localModels id）。
- 遗留：`%APPDATA%\WangCai\models\spark-x2.6-4b-*.gguf.tmp`（1.1GB 断点）→ 续传/重下提示（hf-mirror + 既有 `download_service`）。

### Phase 3 — 引擎管理（内置 NPU + 按需下载 + 参数体系）

- **NPU 内置**：`WangCaiPaths.bundledEngineDir()`（`%APPDATA%\WangCai\engines\wangcai\`）+ `packaging/wangcai-setup.iss` 打包 `llama-server.exe` + `ovlibs\`（注意历史教训：dll 必须 `*.dll` 全量 glob，漏 `mtmd.dll`/`llama-server-impl.dll` 会 0xC0000135）；开发机回退链保留。修 `bundled_manifests.dart` wangcai-npu 的 `{devArg=OPENVINO3}` → 启动时 OpenVINO 设备探测（枚举 OPENVINO0..3，NPU 命中为准），探测失败回退 **OPENVINO2**（本机实测值）。
- **按需下载闭环**：`local_server_inference.dart` `_route()`(:272) 无已装候选且目标 cuda/vulkan 时返回 `decision.needInstall`(variant+release)；`model_provider.loadModel` 收到 → UI 弹「下载引擎」（进度条，复用 `EngineStore.install` 的 onProgress）→ 装完自动重试加载。`EngineStore` 增 `enginesDirOverride`（settings 新字段 `enginesDir`，默认 `dataDir/engines`，设置页可选目录）。官方地址 + sha256 白名单（`StoreCatalog.verified` b12034 现成）+ 镜像兜底维持；GitHub 不稳是用户侧现实 → settings `engineMirror` 可配 + 「从本地包安装」（`EngineStore.installFromLocal` 已有，UI 补入口）。
- **参数体系（默认+模型级自定义）**：
  - `EngineInstance` 增 `defaultConfig`（EngineConfig 形状：ctx/chunk/gpuLayers/device/extraEnv/尾参），`EngineManagerSection` 每引擎「默认启动参数」编辑卡存进 engines.json；`lastConfig` 语义不变（仅诊断）。
  - `EngineConfig` 增 `extraArgs: List<String>`（追加在 `renderArgsTemplate` 结果之后；组装点 `llama_server_host.dart` :172 start() 透传）。
  - **优先级：模型 `customArgs`（LocalModelConfig）> 引擎 `defaultConfig` > manifest 模板/preset**。`_matchPreset`(:335) 保留为出厂档，preset 命中值作 defaultConfig 初值展示。
- **手机参数链删**：`InferenceBackend.loadModel` 签名砍 gpuBackend/vkNoSubgroup/nUbatch/moe*/enableGpu 等（`inference_backend.dart`、`local_server_inference.dart` :354、`inference_service.dart` 同步）；`model_provider.dart` :520 调用点改从 LocalModelConfig/NPU preset 取值。

### Phase 4 — 手机端引擎配置清理

- `settings_service.dart` 删字段与 JSON 兼容读取：gpuBackend、enableGpu、vkNoSubgroup、MoE offload 组、oomGuard、MTP/dspark 全局开关（能力移 `LocalModelConfig.draftPath`）、Dimensity 逻辑。**adbEnabled/adbTargets/adbKeyStore 保留**。`settings_screen.dart` 删对应卡片（:1172 Android GPU 卡整块、:1308/:1328 全局开关、turnip/MoE 卡、:1514 oomGuard）。fromJson 对遗留 key 静默忽略（老 JSON 不炸）。
- 全局搜删残留：`/sdcard`、`/data/local`、`termux`、`arm64-v8a`。**`adb` 关键字不清**（保留功能）。`ssh_diagnostics.dart` 里 `SshTargetKind.termux` 分类可作为错误提示保留或顺手清理，不影响编译。

### 验收（全阶段完成后）

- `flutter analyze --no-pub lib test tool` 零 error；`flutter test` 对齐基线（新增测试见下）。
- 新测试：ProjectStore CRUD/active 持久化、JSONL 项目树+迁移幂等、参数优先级（customArgs>defaultConfig>模板，用 `llama_server_host_test.dart` 现有注入口）、EngineStore 按需下载（复用其 `_downloader`/`CmdRunner` 注入假下载器，参考 `test/engine/engine_store_test.dart`）。
- 桌面冒烟 `flutter run -d windows`（需管理员的构建用 `E:\dev-tools\flutter-build-elev.bat`）：新建项目选 `E:\Work\WangCai\WangCai` → 新会话 → 发消息（NPU 默认模型 15 t/s 路径）→ 智能体在项目目录建文件验证真源；卸载 `engines/llamacpp-vulkan-*` 后加载 Vulkan 模型触发按需下载弹层；设置页改引擎默认参数→日志核对命令行、模型配自定义参数→覆盖生效。
- 真机验证后跑 `tools/accept-smoke.ps1`。

---

## §4 Phase 0 已完成明细（逐文件）

### 4.1 改名与品牌
| 文件 | 改动 |
|---|---|
| `app/pubspec.yaml` | `name: wangcai`；`version: 0.0.3+1` |
| 123 个文件（lib/test/tool/eval/packages） | `package:tongyi_lite/` → `package:wangcai/` 机械替换 |
| `app/lib/main.dart` | 删 MeasureCmdProbe Stack/debug 块及 `services/measure_cmd.dart`、`kDebugMode` import（child 直通）；`TongYiLiteApp`→`WangCaiApp`；`title: '汪柴 WangCai'` |
| `app/lib/agent/agent_prompt.dart` + `app/test/agent/frozen/agent_prompt_pre_7aabe65c.dart` | 品牌身份互换："TongYi-Lite 智能体"→"汪柴智能体"（**两份必须同步改**，字节一致性测试守门，见 §6.6） |
| `app/lib/agent/mcp/mcp_client.dart` | clientInfo `{name:'WangCai', version:'0.0.3'}` |
| `app/lib/agent/web_search/web_search_provider.dart` | UA `... WangCai/0.0.3` |
| `app/lib/screens/home_screen.dart` | 标题 :1036 '汪柴 WangCai'；问候语 '你好！我是汪柴\n端到端离线的 AI 助手'；`_workspaceIcon` switch 收敛为 `{localApp: Icons.folder, remotePc: Icons.desktop_windows}`；工作区文案 手机→本机/本机目录 |
| `app/lib/screens/settings_screen.dart` | `_appVersion='0.0.3'`；`_githubUrl='https://github.com/liangjianzeng/WangCai'`；关于卡 '汪柴 WangCai' / 'Windows 桌面离线 AI 智能体'；工作区后端下拉只剩 localApp（本地目录（本机文件夹））/ remotePc（远程电脑），`if (backend == WorkspaceBackend.remotePc)` 分支条件 |
| `app/UPSTREAM.md` | 顶部 ⚠️ 已独立（2026-11-04）声明，不再回流；指向设计文档 §12（§12 本身还没写） |

### 4.2 死代码删除（保留删除状态）
- `app/lib/agent/dev/termux_intent.dart` — 删
- `app/lib/agent/dev/tools/embedded_tools.dart`、`embedded_git.dart` — 删（内嵌沙箱/toybox/JGit）
- `app/lib/services/measure_cmd.dart` — 删
- `app/test/agent/dev_embedded_test.dart` — 删
- `app/lib/agent/dev/dev.dart` — 删 `export 'termux_intent.dart' ...`
- `app/lib/agent/builtin_tools/builtin_tools.dart` — 删 embedded 的 export/import 与 `createDevShellTool(),` 注册行；**adb 的 export/import/参数/`createAdbTool` 注册原样保留**

### 4.3 ADB 恢复（用户指令"adb也需要"）
`git checkout HEAD --` 恢复后重新改名 import：`app/lib/agent/adb/`（adb_client/adb_connection/adb_protocol/adb_rsa/adb_targets/adb_tool.dart）、`app/test/agent/adb_{protocol,rsa,tool,client}_test.dart`、`app/test/agent/fake_adbd.dart`。

### 4.4 工作区后端收敛为二值
- `app/lib/agent/dev/workspace.dart`：`enum WorkspaceBackend { localApp, remotePc }`；`isRemoteBackend => this == remotePc`；`isRemote => backend == remotePc`；文档注释桌面化。
- `app/lib/agent/dev/dev_context.dart`：backendName switch `{localApp:'本地目录', remotePc:'远程电脑'}`；工具提示 switch —— remotePc → ssh_exec/ssh_read_file/ssh_write_file；localApp → "本地执行用 shell_exec / run_tests（系统 shell，工作目录内）；git 用 git_* 工具（系统 git）"。
- `app/lib/agent/dev/dev_workspace_actions.dart`：`workspaceBackendLabel` 二值；`createWorkspaceOnActiveConnection` 里 `const backend = WorkspaceBackend.remotePc`（原按 SshTargetKind 分支已删）。
- `app/lib/agent/dev/tools/ssh_tools.dart`：删 TermuxIntentService import、`_tryTermuxIntent/_termuxRead/_termuxWrite` 三个辅助 + 全部 4 处调用点；文案"远程电脑"化。
- `app/lib/agent/dev/tools/git_tools.dart`、`verify_tool.dart`：改 `import 'local_exec.dart' show LocalGit / devShellRoot, executeDevShell;`，文档措辞去 Termux。

### 4.5 新增：桌面本地执行层 `app/lib/agent/dev/tools/local_exec.dart`
取代手机 embedded 沙箱的本机执行实现，API 对齐原 embedded 版使 git_tools/verify_tool 只改 import：
- `DevShellResult{exit,stdout,stderr,ok}`；`localShellCommandLine(cmd)` → Windows `cmd.exe /d /c <cmd>`，否则 `sh -c`。
- `runLocalShell(command,{workingDirectory,timeout=10s,stdinInput})`：`Process.start` + systemEncoding 解码 + `Timer(timeout, proc.kill(ProcessSignal.sigkill))`；测试注入口 `localShellRunnerForTest`。
- `devShellRoot(wsId,{store})`：默认工作区→`defaultWorkspaceDir`（documents/workspace），否则 `workspaceLocalMirror(wsId)`。
- `executeDevShell(command,{required root,timeout=60s,outputLimit=4000}) → Future<ToolResult>`。
- `LocalGit` 静态类（系统 git）：`invokerOverride` 测试钩子；`_git(args,workingDir)` 经 `Process.run('git',...,stdoutEncoding:utf8)` 合流 stdout+stderr；`isRepo/status/diff(staged,file)/log(n)/commit(add+commit)/push({remote,branch,username,password})`（凭据经 `git remote get-url` → userinfo 注入 → 显式 URL 推送；非 https 带凭据给明确错误）/`clone(url,target,{username,password,branch,depth})`；无 git 时报"请安装 Git for Windows 并确认 git 在 PATH"。

### 4.6 顺带入库
- `app/test/enter_send_focus_test.dart`（未跟踪，早前会话遗留的合法回归测试：Focus 拦截 Enter 不加换行）——本次一并提交。

---

## §5 立即待办（Phase 0 收尾清单，按序执行）

### 5.1 现存 13 个编译错误（2026-11-04 analyze 实录，`flutter analyze --no-pub lib test tool` 全量 305 issues 中的 error 行）

```
error - Undefined name 'TermuxIntentService' - lib\screens\settings_screen.dart:5545:49
error - Undefined name 'TermuxIntentService' - lib\screens\settings_screen.dart:6015:53
error - Invalid constant value - test\agent\dev_context_test.dart:35:18
error - There's no constant named 'termux' in 'WorkspaceBackend' - test\agent\dev_context_test.dart:35:35
error - There's no constant named 'termux' in 'WorkspaceBackend' - test\agent\dev_workspace_active_test.dart:156:35
error - There's no constant named 'termux' in 'WorkspaceBackend' - test\agent\dev_workspace_active_test.dart:172:28
error - There's no constant named 'termux' in 'WorkspaceBackend' - test\agent\dev_workspace_active_test.dart:191:53
error - There's no constant named 'embedded' in 'WorkspaceBackend' - test\agent\dev_workspace_active_test.dart:193:53
error - Invalid constant value - test\agent\dev_workspace_test.dart:33:18
error - There's no constant named 'termux' in 'WorkspaceBackend' - test\agent\dev_workspace_test.dart:33:35
error - There's no constant named 'termux' in 'WorkspaceBackend' - test\agent\dev_workspace_test.dart:44:49
error - Invalid constant value - test\agent\plan_tools_test.dart:133:45
error - There's no constant named 'termux' in 'WorkspaceBackend' - test\agent\plan_tools_test.dart:133:62
```

### 5.2 删 settings_screen 的 Termux 向导（消掉前 2 个 error）

行号为删除前快照（`app/lib/screens/settings_screen.dart`，改动后会漂移，用符号定位更稳）：

| 位置 | 内容 | 处置 |
|---|---|---|
| ~:26 | import 的 `show` 列表中 `DevNativeEnv,` 及 `native_env.dart` import 本身 | 向导删完且确认无其他使用者后移除 |
| :97 | `enum _SshdProbe { listening, refused, timeout }` | **先查** `_probeSshd`（:6409，被向导内在 :5859 调用）是否也被 `_showRemotePcSetupDialog`（:6122 起）使用；只有 termux 用才连 `_probeSshd` 一起删，否则保留给远程电脑向导 |
| :4975-4986 | `_DevSettingsBodyState` 字段 `_testingIntent/_downloadingTermux/_intentTestResult/_intentTestOk` | 删 |
| :5500-5516 | `Wrap` 里 `📱 连接 Termux`（`_showTermuxSetupDialog`）按钮 | 删按钮及其 Wrap 子项；**保留 `💻 连接远程电脑`（`_showRemotePcSetupDialog`）** |
| :5518-5523 | 提及 Termux key 流程的提示文案 | 改写为远程电脑语义 |
| :5524-5646 | 免 SSH 通道测试 TextButton（`TermuxIntentService.instance.run 'echo ok'`，**:5545 报错点**）、下载 Termux 按钮（`DevNativeEnv.downloadTermuxApk` + `/storage/emulated/0/Download/TongYi-Lite/termux.apk` 轮询 + installApk）、`_intentTestResult` 展示块 | 整段删 |
| :5829-6121 | `Future<void> _showTermuxSetupDialog(BuildContext, SettingsNotifier)` 整个方法（**:6015 报错点**；下一成员 `_showRemotePcSetupDialog` 起于 :6122） | 整删（含内部 `_probeSshd` 调用） |
| :6464+ | `String _buildTermuxInstallCommand(String publicKey)` | 删 |

删除后回归检查：`flutter analyze` 关注新增 unused_import（`DevNativeEnv`、可能的 `AppBridge`）；`lib/agent/dev/native_env.dart`（DevNativeEnv，手机 APK 下载器）若再无使用者可整文件删——先 grep 确认。

### 5.3 修 4 个测试文件的已删枚举用例（消掉其余 11 个 error）
- `test/agent/dev_context_test.dart:35` —— termux 后端注入断言：改为 localApp/remotePc 或删除该 case。
- `test/agent/dev_workspace_active_test.dart:156/172/191`（termux）、`:193`（embedded）——同理；`:191/:193` 是一对（termux/embedded 判定），改断言到 remotePc/localApp。
- `test/agent/dev_workspace_test.dart:33/44`。
- `test/agent/plan_tools_test.dart:133`。

### 5.4 欠账
1. `docs/assistant-v0.0.2-design.md` 追加 **§12 v0.0.3 桌面独立化**（记录：独立决策、改名、后端二值化、adb 保留、local_exec 替换 embedded、五阶段计划指针）。UPSTREAM.md 已指向它。
2. 复跑 analyze 至**零 error** → `flutter test` 对齐基线（§6.4）→ 提交 "Phase 0 complete"。
3. grep 清扫可删未用引用：`dev_workspace_actions.dart` 是否残留 `sshTargetKindOf/SshTargetKind` unused import（analyze 会报，届时清）。

### 5.5 Phase 0 出口后
依次 Phase 1 → 2 → 3 → 4（每阶段独立可编译、独立提交；改名类机械改动单独 commit 的纪律保持）。

---

## §6 已知问题与环境坑（务必先读）

### 6.1 NPU 引擎参数（实测事实，Phase 3 直接引用）
- `bundled_manifests.dart` wangcai-npu argsTemplate 硬编码 `-dev {devArg=OPENVINO3}` —— **本机能用的是 OPENVINO2**（LFM3-1.7B ≈15 t/s）。临时 workaround：env `GGML_OPENVINO_DEVICE`。正式修法 = §3 Phase 3 设备探测。
- LFM3-1.7B preset ctx 1024；Qwen3-4B preset ctx 512（admission rule：4B@ctx>512 → OUT_OF_HOST_MEMORY）。
- **Spark-X2.6-4B 与 LFM3-Omni-2B 必须** env `PREFILL_CHUNK_SIZE=128` + `DISABLE_DECODE_LEVELS=1`（依据 `tools/spark-npu-accept.ps1`、`docs/HANDOFF.md`）。
- NPU 上 mtmd 视觉有缺陷（见 `docs/defect-npu-mtmd.md`）：视觉走官方 cuda/vulkan 引擎线，NPU 仅文本。
- `%APPDATA%\WangCai\models\spark-x2.6-4b-*.gguf.tmp`（约 1.1GB）断点未续传 —— 非代码阻塞，列入验证清单。

### 6.2 Flutter 工具链（不在 PATH！）
- 一切 flutter 命令用 `E:\dev-tools\flutter\bin\flutter.bat`（Flutter 3.27.4 / Dart 3.6.2）。
- `flutter build windows` 历史需管理员：用 `E:\dev-tools\flutter-build-elev.bat`（提权脚本）。
- 真机跑 NPU：`E:\dev-tools\run-npu.bat`。
- **分析口径**：必须在 `app/` 下跑 `flutter analyze --no-pub lib test tool`（app 根目录直接 analyze 会带出 packages/* 的 ~2800 条 package:test/matcher dev-dep 噪音）。CI 不跑 dart analyze。

### 6.3 Git Bash 坑（Windows）
- `grep -rl | xargs sed -i` 会吞反斜杠路径（exit 123，"can't read testagent…"）。正确姿势：`find ... -print0 | xargs -0 grep -l ... | tr -d '\r' > list` 再 `xargs -d '\n' sed -i`。
- 外部工具（sed/git checkout）改过文件后 Edit 工具会报 "File has been modified since read" —— 重新 Read 或直接改用 sed 精确删行。
- 计划模式下 git/python/复合命令会被权限层拦，正常模式下无碍。

### 6.4 测试基线债务（本次重构前就有的失败，别当回归）
UPSTREAM.md 记录：`thinking_runaway_test` ×2、`model_catalog` ×1、`agent_stream_processor_test` ×1。`flutter test` 结果对齐该基线即视为绿。

### 6.5 网络与部署约束（本机记忆）
- 可用源：PyPI、hf-mirror；**GitHub 不稳、aka.ms 与 hf.co 不通**。→ 引擎按需下载必须走 `StoreCatalog` 镜像列表，且 settings 要留 `engineMirror` + 「从本地包安装」离线口。
- 工具链/产物只放 **E: 盘**（MSVC 是唯一例外）。
- 构建 gotchas（记忆文件）：vswhere 绕过、`cmd /c` 包装、pip cmake 的 PYTHONPATH。

### 6.6 纪律类
- **字节一致守门**：`test/agent/api_prompt_byte_identity_test.dart` 比对 `buildSystemPrompt` full-tier 与 `test/agent/frozen/agent_prompt_pre_7aabe65c.dart`。改 `agent_prompt.dart` 品牌/身份文案必须**同步改 frozen 副本**（本次已同步）。
- **adb 是功能不是死代码**（用户明令）：Phase 4 全局搜删时跳过一切 `adb` 命中。
- **故意保留的手机味**（勿再"顺手删"）：`lib/services/storage_permission_service.dart`（有 `if (!Platform.isAndroid) return true;` 桌面守卫，相机/麦克风仍走 permission_handler）；`lib/services/app_bridge.dart` + chat_provider 刷新率调用（MethodChannel 在 Windows 是 no-op，Phase 4 再议）；`third_party/dartssh2/edge_tts/sherpa_onnx_web` + ASR/TTS；SSH 远程工作区全线。
- MTP/dspark 在 Windows 有实际用途，只能**降级为模型级参数**（`LocalModelConfig.draftPath`），不能直接删功能。

### 6.7 关键文件地图（改哪个功能去哪个文件）
| 子系统 | 文件 |
|---|---|
| 会话存储 | `app/lib/services/storage_service.dart`（tongyilite.db v6；`_onUpgrade` 幂等模板）、`app/lib/agent/session/store.dart`（JsonlSessionStore）、`session/log.dart`、`app/lib/providers/chat_provider.dart`（:185-230 ConversationsNotifier、:337 store 消费、:381/:1902/:1912 goals/metrics/traces 路径） |
| 工作区 | `app/lib/agent/dev/workspace.dart`、`workspace_store.dart`（ApplicationSupport/dev/workspaces + active_workspace.json；`workspaceLocalMirror` = documents/workspace/projects/<id>）、`dev_controller.dart`、`dev_context.dart` |
| 引擎 | `app/lib/engine/engine_manifest.dart`（renderArgsTemplate `{name}/{name?}/{name=default}`、Preset、AdmissionRule）、`bundled_manifests.dart`、`engine_store.dart`（StoreCatalog.verified、镜像、Dio、sha256File、`_downloader`/`CmdRunner` 注入口）、`engine_registry.dart`（engines.json、`EngineRegistry.dev()`）、`engine_config.dart`（profileId sha1 → per-profile OV cache）、`bindings_store.dart`（bindings.db）、`routing_policy.dart`、`llama_server_host.dart`（:172 组命令行）、`process_ledger.dart`（孤儿清扫）、`remote_openai_host.dart` |
| 推理路由 | `app/lib/platform/local_server_inference.dart`（`_route()` :272、`_matchPreset()` :335、`loadModel()` :354 手机参数残留处、ChatSseDecoder、routing.json tier/idleUnloadMinutes）、`inference_service.dart`、`inference_backend.dart`、`app/lib/providers/model_provider.dart`（:520 loadModel 调用点） |
| 路径 | `app/lib/platform/wangcai_paths.dart`（dataRoot=%APPDATA%\WangCai、modelsRoot/WANGCAI_MODEL_DIR、modelSearchDirs、repoRoot 标记 `tools\chat-npu.ps1`、bundledEngineDir、wangcaiServerExe/WANGCAI_SERVER_EXE、ovLibsDirs） |
| 设置 | `app/lib/services/settings_service.dart`（apiModels 三件套 :96/:944/:1062 = LocalModelConfig 模板；35 处手机引擎字段待 Phase 4）、`app/lib/screens/settings_screen.dart`（ModelManagementBody :102、GPU 卡 :1172、开关 :1308/:1328、oomGuard :1514、EngineManagerSection 已挂载） |
| UI | `app/lib/screens/home_screen.dart`（左栏抽屉 :3084、标题 :1036、问候 :2220、工作区胶囊 :729-930、模型管理复用 :1524、默认模型自动加载 :204）、`app/lib/widgets/rail/rail_scaffold.dart` |

---

## §7 新开发机上手步骤

```bash
# 1. 拉分支
git clone https://github.com/liangjianzeng/WangCai.git && cd WangCai
git checkout feat/desktop-standalone-v0.0.3

# 2. 工具链（本机参考路径）
#    Flutter 3.27.4 → E:\dev-tools\flutter（不在 PATH，用全路径调 flutter.bat）
#    需要：VS2022 C++ 工作负载（MSVC 可在 C 盘）、Git for Windows、NPU 侧 OpenVINO ovlibs

# 3. 恢复现场（当前 13 error 应原样复现）
cd app
E:/dev-tools/flutter/bin/flutter.bat pub get
E:/dev-tools/flutter/bin/flutter.bat analyze --no-pub lib test tool   # 305 issues，13 error（§5.1）

# 4. 按 §5 清单收尾 Phase 0 → 提交 → 依次 Phase 1-4
```

**红线复述**：adb 不删；`package:wangcai` 已是唯一包名；frozen prompt 副本同步改；数据目录统一 `%APPDATA%\WangCai`；分析只跑 `--no-pub lib test tool`；GitHub 依赖要有镜像/离线兜底。

---

*本文档由 ZCode 会话 sess_f30a1ff0 生成于 2026-11-04，随 Phase 0 半成品一同入库。完成 Phase 0 后请更新本文档状态表并把已完成项打 ✅。*
