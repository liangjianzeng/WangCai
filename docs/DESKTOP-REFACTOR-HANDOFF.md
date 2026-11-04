# WangCai 桌面独立版重构 — 交接文档（进行中）

> **日期**：2026-11-04 · **ZCode 会话**：`sess_f30a1ff0-3b6b-4eeb-b0de-970751a79d68`
> **分支**：`feat/desktop-standalone-v0.0.3`（基于 `main` = `origin/main` @ `4216cd9`）
> **状态**：**Phase 0/1/2/3/4 ✅（代码+测试完成，未提交）**，五阶段编码全部收尾，仅剩桌面冒烟（§5.1 第 1 条）。工作区含大量未提交改动（用户令"先不提交"），本文档随后续改动一起提交。
> **接手人请先通读 §1（速览）→ §5（立即待办）→ §2/§3（计划全文）。**

---

## §1 速览：现在处于什么状态

| 项 | 状态 |
|---|---|
| 包名改名 `tongyi_lite` → `wangcai`（123 文件 + pubspec + 版本号 0.0.3+1） | ✅ 完成 |
| 品牌独立（App 标题/问候语/MCP clientInfo/UA/关于卡/GitHub URL） | ✅ 完成 |
| UPSTREAM.md 独立声明 | ✅ 完成 |
| 设计文档 §12（v0.0.3 独立化章节） | ✅ 完成（`docs/assistant-v0.0.2-design.md` 末尾 v0.0.3 章节） |
| 手机端死代码删除（termux/embedded/measure_cmd） | ✅ 完成（settings_screen Termux 向导 ~600 行已删；`native_env.dart` 删除；测试枚举/断言同步） |
| ADB | ✅ **保留**（用户明确"adb也需要"，已恢复我误删的文件） |
| 手机执行沙箱 → 桌面执行替换（`local_exec.dart`） | ✅ 新增完成 |
| `flutter analyze --no-pub lib test tool` | ✅ **0 error**（~280 条 pre-existing info/warning 为上游噪音） |
| `flutter test` | ✅ **1238 passed / 18 skipped / 3 failed = 上游基线债务**（thinking_runaway×2 + agent_stream_processor×1，见 §6.4），零新增失败（Phase 4 删掉 2 个手机端旧用例：GPU 防闪纹 / n_ubatch+vkNoSubgroup） |
| Phase 1 会话/项目重构 | ✅ **代码+测试完成**（`lib/project/` 三件套 + SQLite v7 + JSONL 项目树 + 迁移 + 左栏项目选择器 + 真源统一；`test/project/project_layer_test.dart` 8 测试绿）。**冒烟未做**（见 §5.1 第 4 条） |
| Phase 2 模型管理 | ✅ **代码+测试完成**（LocalModelConfig+localModels 持久化、4 条 NPU preset、loadModelByLocalConfig、ModelManagementBody 重写、自动加载三分支；全量 1215 绿） |
| Phase 3 引擎管理 | ✅ **代码+测试完成**（3a OPENVINO 探测 / 3b 参数体系 / 3c 按需下载闭环 / 3d 打包核对，见 §3 Phase 3 完成明细；新增测试 chain 10 + install 5 + routing 5 + settings 2 + paths 1） |
| Phase 4 手机端配置清理 | ✅ **代码+测试完成**（settings 字段/setter、卡片 515 行、JNI 三件套、device_info 链、app_bridge 整体删除；见 §3 Phase 4 完成明细） |

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

### Phase 0 — 独立项目（解耦上游）　✅ 完成

1. `pubspec.yaml` name `tongyi_lite`→`wangcai`；全仓 import `package:tongyi_lite/`→`package:wangcai/`（含 test/、tool/、eval/、packages/）。 ✅
2. UPSTREAM.md 顶部"已独立，不再回流"声明；`docs/assistant-v0.0.2-design.md` 追加 v0.0.3 独立化章节。 ✅✅
3. 删手机端死代码：termux_intent、embedded 工具链、measure_cmd、settings_screen Termux 向导（~600 行 sed 自底向上删除）、`native_env.dart`。 ✅；**adb 例外保留**。third_party/dartssh2、edge_tts、sherpa 与 ASR/TTS **保留**。
4. 出口：`flutter analyze --no-pub lib test tool` 零 error + `flutter test` 对齐基线。 ✅（1210 passed / 3 failed = §6.4 基线）

### Phase 1 — 会话管理重构（项目 × 工作空间）　✅ 代码+测试完成（2026-11-04）

**Phase 1 完成清单（已实现，测绿）**：
- `lib/project/project.dart`：`Project{id,name,workspacePath,sshConfigId?,createdAt,lastOpenedAt}`，`kDefaultId='p_default'`，`newProjectId()`=`p_<ms>_<rand8hex>`（**随机尾缀不可省**：Windows 时钟毫秒粒度，纯时间戳同循环撞车，测试实锤），`safeProjectDirName`。
- `lib/project/project_store.dart`：`projects.json` + `active_project.json`（落 `WangCaiPaths.dataRoot()`）；CRUD/active/默认项目保护/坏条目容错；`projectDir/sessionsDir/projectSubDir`（create-on-get，**subDir 是给 goals/traces/metrics 预留的 API，尚未接线**）。
- `lib/project/migration.dart`：`migrateLegacySessions` 幂等——ensureDefault → 旧 sessions 目录整目录备份 `.backup`（备份失败即中止搬运）→ move *.jsonl → `assignNullProjectConversations(p_default)`；`main.dart` 首启调用（异常仅 debugPrint，双读兜底在）。
- SQLite v7：`conversations.projectId` 列+索引（列级幂等 PRAGMA 检查）；`createConversation({projectId})`、`getAllConversations({projectId})`（**`p_default` 查询含 NULL**——未归户旧会话在默认项目可见；其他项目不串门）、`projectOfConversation`、`assignNullProjectConversations`。
- JSONL 项目树：`JsonlSessionStore.pathFor` → `projects/<pid>/sessions/<convId>.jsonl`；静态 `projectIdResolver`（main.dart 接 `StorageService().projectOfConversation`）；legacy 平铺双读兜底 + 首触达整体复制（"绝不劈成两半"）+ delete 清两处；SessionHeader 增可选 `workspacePath/cwd`（DSH 纪律：可选字段不 bump 版本）。
- Provider 层：`lib/providers/project_provider.dart`（`ProjectsNotifier`：load/create/rename/remove/setActive；**激活项目时派生 DevWorkspace `ws_<projectId>`**（localMirror=workspacePath）经 DevSessionController 切换——工作目录唯一真源）；`conversationsProvider` watch `activeProjectIdProvider` 自动重建。
- 真源统一：`DevStore.workspaceRootFor(ws)`（localMirror 优先）被 file_tools `_workspaceDir` / local_exec `devShellRoot` / git_tools `_resolveGitRoot` 共用；chat_provider 的 workspaceResolver 不再 devMode 门控，且 agentEnabled 时注入 `buildWorkspaceContextSection`；会话删除联动删 JSONL。
- UI：home_screen 左栏头部项目选择器（名+工作目录+面板：列表含会话计数/新建（FilePicker 选目录）/重命名/移除确认/打开所在文件夹）。
- 测试：`test/project/project_layer_test.dart` 8 项全绿（CRUD/id 形态/树写/header 字段/双读复制/迁移幂等/SQLite v7 过滤语义）。

**Phase 1 欠账（已知、故意留后）**：
1. **JSONL 写路径生产未接线**（上游遗留）：全仓只有 `chat_provider.dart:1597` 用 `importFromMessages` 纯函数；`appendEvent/load/rewrite/delete` 无生产消费者。存储层+迁移已就绪，等会话事件流真正接入时即插即用。冒烟时"新建项目→发消息→agent 建文件"验证的是**工作目录真源**，不是 JSONL 落盘。
2. **goals/metrics/traces 未挂项目目录**：`ProjectStore.projectSubDir(id)` API 已备好，`chat_provider.dart` :381/:1902/:1912 三处仍用全局基目录。
3. **桌面冒烟未做**（§9 出口清单里的 `flutter run -d windows` 序列）。
4. 会话面板"按 active 项目过滤"已通过 conversationsProvider 重建实现，但未做真机视觉核对。

（以下为**已批准计划书原文**，仅作依据备查，均已按上表落实：）

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

### Phase 2 — 模型管理桌面形态　✅ 代码+测试完成（2026-11-04）

**Phase 2 完成清单**：
- `lib/models/local_model.dart` 新：`LocalModelConfig{id,name,modelPath,engineId?,customArgs?,mmprojPath?,draftPath?,ctx?,chunk?,gpuLayers?}`（防御性 fromJson：任何脏值丢条目不炸设置）；共享件 `kLocalModelIdPrefix='lm_'`、`kNpuPresetIdPrefix='npu:'`、`newLocalModelId()`（随机尾缀纪律同 project）、`presetGlobToRegExp`（与加载侧 `_matchPreset` 同形态、case-insensitive）、`resolveNpuPresetConfig(name)`（modelsRoot 扫 glob → 虚拟条目）。
- `settings_service.dart`：`localModels` 持久化照抄 apiModels 三件套（字段/ctor/copyWith/toMap/fromMap/`_parseLocalModels` 坏条目静默丢弃）；`SettingsNotifier.addLocalModel/updateLocalModel/deleteLocalModel`（删除**不碰磁盘文件**、删默认连带清星标）。
- **bundled_manifests wangcai-npu 新增两 preset**：spark-x2.6-4b（glob `Spark-X2.6-4B*.gguf`，ctx512/chunk128/paramsB4.0）与 lfm3-omni-2b（glob `LFM3-Omni-2B*.gguf`，ctx512/chunk128/paramsB2.0），**都带 extraEnv `GGML_OPENVINO_DISABLE_DECODE_LEVELS=1`**（实测必需，spark-npu-accept.ps1/HANDOFF 对表）。顺带修断链：`local_server_inference.loadModel` 此前**没把 `preset.extraEnv` 传进 EngineConfig**（host 侧 :178 早已支持合并+profileId 指纹），已补一行。
- `ModelManagerNotifier.loadModelByLocalConfig(cfg)`：本地模型直接吃路径加载（文件存在校验/换载停旧/进度日志），手机链路（MoE/MTP 全局开关/oom 守卫/KV 精度推送）不进；`engineId`/`customArgs` **只存不接**（Phase 3 参数优先级链地盘，抢跑会和路由改动打架）。
- `ModelManagementBody` 整块重写（settings_screen :92 起 ~560 行，替换 ~965 行）：catalog 下载/续传/暂停/校验/删除弹层**全删**（`_scanModels/_startDownloadAndRescan/_modelMetaLine/_buildExpandArea` 等 helper 一并清；`_appLaunchScanDone` 死标志删除；`model_manager.dart` import 移除）。新结构=NPU 预置区（4 preset 扫描命中/缺文件指引+星标+加载）／本地模型区（FilePicker .gguf→编辑卡[mmproj/draft/ctx/chunk/-ngl/引擎下拉/自定义尾参多行]；行内星标/加载/卸载/编辑/移除登记）／StorageInfoWidget 保留。加载流沿用旧 `_handleLoadModel` 骨架（切换确认→停回合→进度弹窗→播报）。
- `home_screen._initAutoLoadDefaultModel` 三分支：`npu:` → resolveNpuPresetConfig（缺文件静默跳）；`lm_` → localModels 查条目+文件存在校验；其余 → 旧 catalog 链路原样。
- 测试：settings_service_test 新增「本地模型登记」5 例（JSON 往返/不落 null 键/坏条目/clear 标记/id 形态）34/34 绿；engine+platform 77/77 绿（extraEnv 断链修复无回归）。`app_npu_flow_test` 真机门控未扩（NPU 冒烟清单一起验）。
- **未做**：spark .tmp 断点续传提示（下表遗留项照旧）；桌面冒烟（与 Phase 1 冒烟合并）。

（以下为计划书原文备查：）

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

#### Phase 3 完成明细（2026-11-04）

| 子项 | 落点 | 要点 |
|---|---|---|
| 3a OPENVINO 探测 | `lib/engine/openvino_probe.dart`（新）+ `llama_server_host.dart._launch` | `llama-server --list-devices` 解析 `(OPENVINO\d+).*GGML_OPENVINO_DEVICE=NPU`；**env 组装移到 args 渲染前**（探测需与真启动同构的 PATH）；只接管 NPU 目标（显式 CPU/GPU/OPENVINO{n} 是用户意图不覆盖）；失败回退 `kOpenvinoNpuFallbackDevArg='OPENVINO2'`；per-exe 缓存 + `probeRunnerForTest` 注入。测试 `llama_server_host_test.dart` 注入假枚举（本机 OPENVINO2 / 开发机 OPENVINO3 / 失败回退三态） |
| 3b 参数体系 | `engine_registry.dart` `EngineDefaults`（新）；`engine_config.dart` `extraArgs`（进 profileId 指纹 `'a'` 键）；`llama_server_host.dart` 模板后 `args.addAll(extraArgs)`；`local_server_inference.loadModel` 优先级链 | **模型级（loadModel 参数，来自 LocalModelConfig）> 引擎 defaultConfig（engines.json）> manifest preset/模板**；customArgs 非空**整档替换** dc.args（非合并）；extraEnv 是**合并**（dc 同键覆盖 preset）；ctx 收敛纪律保留（preset 实测上限压过一切显式值）；草稿头经 `--model-draft` 尾参入场（用户尾参排最后天然覆盖）。UI：`engine_manager_section.dart` 每实例「默认启动参数 ✓」编辑弹层（ctx/chunk/ngl/device/extraEnv KEY=VALUE/尾参）。测试 `test/platform/engine_defaults_chain_test.dart` 10 用例 |
| 3c 按需下载 | `routing_policy.dart` `RoutingDecision.needInstall` + `suggestInstallVariant`；`local_server_inference.installEngine` + `lastInstallSuggestion`；`engine_store.dart` `enginesDirOverride`/`enginesRoot`；settings `enginesDir`/`engineMirror` 三件套 + `SettingsNotifier.setEnginesDir/setEngineMirror`（clear 标记）；`settings_screen._runLoad` 失败分支 → `_EngineInstallDialog`（进度条、自动开跑、失败可重试）→ 重试 load；`engine_manager_section` 安装目录选择（file_picker）+ 镜像输入 | 无本地候选且 cuda/vulkan 已启用未装 → needInstall（cuda 快道优先）；远端可用时优先兜底不发下载信号；installEngine = 白名单 latest → EngineStore.install（镜像+sha256）→ `reg.upsert` binaryPath+enabled → save。测试 `on_demand_install_test.dart` 5 用例（假 EngineStore 子类注入 `engineStoreForTest`）+ routing_policy_test 5 用例 + settings_service_test 2 用例 |
| 3d 打包核对 | `packaging/wangcai-setup.iss`/`build-installer.ps1` 版本串 → 0.0.3；`wangcai_paths.dart` **便携形态缺口修复**：`bundledEngineDirs()` 双候选（exe 邻侧 `Engines\wangcai\` 优先 → %APPDATA% 装机位），`wangcaiServerExe/ovLibsDirs` 全走候选链 | v0.0.2 便携包 README 声称「首启自动识别」但代码无 exe 邻侧分支（引擎只在 %APPDATA% 找）—— 真装机用户 portable 形态会找不到引擎。Inno 侧本就正确（dll `*.dll` 全量 glob + ovlibs 子目录，历史 0xC0000135 教训已固化）。测试 `wangcai_paths_test.dart` +1 候选序用例 |
| 3e 签名瘦身 | `inference_backend.dart` 新签名 `{nCtx,chunk,gpuLayers,mmprojPath,draftPath,customArgs,engineId}`（全可空=null 走回落链）；`inference_service.dart`（Android JNI 死路径）对齐签名、MethodChannel 字典填历史默认值（原生协议不动）；`local_server_inference.loadModel` 重写 + `_route(engineId:)` **钉选**（命中直通+admission 仍查、未命中留痕回落 Auto）；`model_provider` catalog 路径 815→561 行（MTP/dspark 全局开关、split-MoE 路由、oomGuard/KV/FA 推送整段退场，含 `_readMemAvailableMb/_moeManifestBankGeo` 死 helper） | `loadModelByLocalConfig` 不再兜底手机端全局（contextSize/gpuLayers），未表态项让位 defaultConfig/preset |

### Phase 4 — 手机端引擎配置清理

- `settings_service.dart` 删字段与 JSON 兼容读取：gpuBackend、enableGpu、vkNoSubgroup、MoE offload 组、oomGuard、MTP/dspark 全局开关（能力移 `LocalModelConfig.draftPath`）、Dimensity 逻辑。**adbEnabled/adbTargets/adbKeyStore 保留**。`settings_screen.dart` 删对应卡片（:1172 Android GPU 卡整块、:1308/:1328 全局开关、turnip/MoE 卡、:1514 oomGuard）。fromJson 对遗留 key 静默忽略（老 JSON 不炸）。
- 全局搜删残留：`/sdcard`、`/data/local`、`termux`、`arm64-v8a`。**`adb` 关键字不清**（保留功能）。`ssh_diagnostics.dart` 里 `SshTargetKind.termux` 分类可作为错误提示保留或顺手清理，不影响编译。

#### Phase 4 完成明细（2026-11-04）

| 文件 | 改动 |
|---|---|
| `app/lib/services/settings_service.dart` | 删 16 字段 + 3 方法：enableGpu/gpuBackend/gpuNUbatch/vkNoSubgroup/smartMoeEnabled/moeBankOverrideByModel/oomGuardEnabled/oomPre-PostHeadroomMb/enableMtpFeature/mtpEnabledByModel/enableDsparkFeature/dsparkEnabledByModel/inferenceLimitRefreshRate/kvCacheType/flashAttn + `mtpEnabled()/dsparkEnabled()/moeBankOverride()`；fromJson 遗留 key **静默忽略**（老 JSON 不炸）；copyWith/toMap 同步；孤儿 doc 块清理。**保留**：gpuLayers/contextSize/enableThinking/visionEnabledByModel/autoLoadMmproj/**adbEnabled/adbTargets**/enginesDir/engineMirror/localModels |
| `app/lib/providers/settings_provider.dart` | 删 16 个对应 setter（150 行）；Phase 3c 的 setEnginesDir/setEngineMirror 不受影响 |
| `app/lib/screens/settings_screen.dart` | 删 **515 行**（锚定 python splice）：Android GPU 卡（`if (!Platform.isWindows)` 整卡含后端选择器+层数滑条）、MTP/dspark 全局开关卡、防闪纹卡、GPU 稳定性卡（n_ubatch/vkNoSubgroup/智能MoE/专家池）、OOM 守卫卡、KV 精度卡、Flash Attention 卡 + `_isDimensitySoC/_gpuBackendHint/_gpuLayersEditable/_gpuLayersHint/_buildHeadroomSlider` 辅助 + 天玑 postFrame 自动切后端逻辑。保留卡：思考模式/上下文大小/视觉投影器/引擎状态 |
| `app/lib/providers/chat_provider.dart` | 删 `_updateInferenceRefreshRate`（小米13 防闪纹锁 60Hz）+ `_rateLimitEngaged` + AppBridge import |
| `app/lib/services/app_bridge.dart` | **整文件删**（Termux 拉起/零粘贴/刷新率 MethodChannel 桥，AppBridge 全仓零消费者） |
| JNI 三件套 | `inference_backend.dart` 接口 + `local_server_inference.dart`（no-op 实现 + `_kvType/_flashAttn` 字段）+ `inference_service.dart`（MethodChannel 推送）删 `setOomGuard/setKvCacheType/setFlashAttn`；桌面语义 = manifest admission + 引擎参数链 |
| `app/lib/services/inference_service.dart` | loadModel 请求体仍填 enableGpu/gpuBackend 等**常量默认**（Android 原生契约形状，字段本身已不在 Dart 侧暴露） |
| device_info 链 | `getDeviceInfo`（接口+两实现）+ `deviceInfoProvider`（shared_providers）+ index.dart 导出删除——唯一消费者是已删的天玑禁用 OpenCL 判定（android/ 构建目标已不存在） |
| 全局搜删 | `/data/local` 命中全在 adb（保留）；`/sdcard` 仅 safety.dart 历史注释；`arm64-v8a` 零命中；termux 命中全部属于**保留的 SSH 远程工作区**（SshTargetKind.termux 诊断话术、ssh_credentials termuxTemplate、测试"历史后端丢弃"回归），非手机端残留 |
| `app/test/services/settings_service_test.dart` | 删「GPU 防闪纹」「GPU 稳定性调优」两用例；「旧配置（无 agent 字段）加载」保留（enableGpu/gpuBackend 作遗留 key 的静默兼容回归） |

**出口**：analyze 0 error（280 issues，较 285 基线净减 5）；全量 test 1238 passed / 18 skipped / 3 failed（= §6.4 基线三件套，零新增）。

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

## §5 当前待办（2026-11-04 更新：Phase 0/1 已收尾，原 Phase 0 清单全部完成）

> 原 §5.1–5.4（13 个编译错误清单、Termux 向导删除行位表、测试枚举修复、Phase 0 欠账）**已全部完成**：
> analyze 0 error；Termux 向导 ~600 行删除（含 `_probeSshd/_readSharedUserName/_buildTermuxInstallCommand/_SshdProbe`，`native_env.dart` 整文件删，`ssh_diagnostics` unused import 清）；
> 4 个测试文件枚举改 remotePc/localApp；设计文档 §12 已追加；品牌断言（agent_tier/persona → 汪柴智能体）已同步。

### 5.1 现在立即要做的（2026-11-04 第三次更新：Phase 4 完成 ✅ + 便携包已打出，见下）
0. **打包 ✅（2026-11-04）**：`packaging/dist/WangCai-0.0.3-win-x64-portable.zip`（107.9 MB）已产出并自检通过——解压至空目录后 `Engines\wangcai\llama-server.exe --list-devices` 完整枚举 CPU/iGPU/NPU 3720（OPENVINO2=NPU，OV 链由 ovlibs 加载成功），App\WangCai.exe 就位。**打包脚本路径修正**：build-installer.ps1 与 wangcai-setup.iss 原写死的 `ov\openvino\libs`（仓库根，不存在）已改为候选链（仓库 vendored 副本优先 → `E:\dev-tools\ov\openvino\openvino\libs`，注意双层 openvino）。**Setup.exe 未产出**：本机未装 Inno Setup 6（ISCC 查无），装后重跑脚本即出；.iss 已修好同路径问题。注意：打包前须杀掉运行中的 WangCai.exe（LNK1104 实案）。
1. **桌面冒烟欠账（唯一剩余事项，Phase 1/2/3/4 合并验证清单）**：`flutter run -d windows` → 新建项目选目录 → 新会话发消息（NPU 默认模型路径）→ agent 项目目录建文件 → 切项目验证过滤与真源 → 模型管理页添加本地模型+星标 → 引擎默认参数改后日志核对命令行（含「启动命令」弹层看 extraArgs 尾参）→ 卸 `engines/llamacpp-vulkan-*` 触发按需下载弹层（settings 改 enginesDir/engineMirror 各验一次）→ `tools/accept-smoke.ps1`。
   Phase 4 冒烟追加两点：① 设置页「推理引擎」tab 肉眼确认只剩 思考模式/上下文/视觉投影器/引擎状态/引擎管理 几卡（手机卡已全删不炸布局）；② 用旧版 `inference_settings.json`（含 gpuBackend/oomGuardEnabled 等遗留 key）启动，确认静默忽略不弹错。
2. **易用性整改（用户反馈 2026-11-04 晚，"很多地方也是差不多，为用户考虑多一点"）**：
   - ① 引擎获取易用性 ✅ **已完成**（第二轮反馈"cuda/vulkan 怎么选/一键下载/目录识别干了么"）：引擎管理页新增「获取引擎」卡 —— 每变体一行（CUDA/Vulkan · b12034）**一键下载**按钮（共享 `EngineInstallDialog`，从 settings_screen 抽到 `engine_install_dialog.dart`）+ **扫描识别**按钮（`EngineStore.discoverEngineExes`：扫安装目录 ≤2 层找 llama-server.exe，目录名含 cuda/vulkan 即认领 → 写 engines.json，保留已有 defaultConfig）；`on_demand_install_test` +2 用例。模型选引擎 = 模型卡「引擎绑定」下拉（已有）或留空 Auto。
   - ② 模型库目录不可选（第一轮反馈直接诱因）：NPU preset 只认 `modelsRoot()`，设置页无「模型库目录」——照 enginesDir 先例补 FilePicker + 持久化 + 「恢复默认」，`WANGCAI_MODEL_DIR` 降级为高级逃生门。**待做**。
   - ③ 全仓审计其他"只认默认/写死位置"的点逐个补可选入口：工作区默认目录（documents/workspace）、SSH 配置、NPU cache 目录、模型默认下载位置等；交付前自问"普通用户不读文档能不能改到这个位置"。**待做**。
3. 冒烟通过后按 §3 验收收尾并提交（分支已有 ~50 文件未提交改动，建议按 Phase 分组 commit；提交前 `git status` 核对 models/*.gguf、packaging/dist 未混入）。

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
| 设置 | `app/lib/services/settings_service.dart`（apiModels 三件套 :96/:944/:1062 = LocalModelConfig 模板；手机端引擎字段已于 Phase 4 全删）、`app/lib/screens/settings_screen.dart`（ModelManagementBody、推理引擎 tab 只剩 思考模式/上下文/视觉投影器/引擎状态 + EngineManagerSection） |
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

# 3. 恢复现场（应复现：0 error，~280 条既有噪音；test 1238 绿 / 基线 3 败）
cd app
E:/dev-tools/flutter/bin/flutter.bat pub get
E:/dev-tools/flutter/bin/flutter.bat analyze --no-pub lib test tool
E:/dev-tools/flutter/bin/flutter.bat test

# 4. 按 §5.1 做桌面冒烟 → accept-smoke.ps1 → 分组提交
```

**红线复述**：adb 不删；`package:wangcai` 已是唯一包名；frozen prompt 副本同步改；数据目录统一 `%APPDATA%\WangCai`；分析只跑 `--no-pub lib test tool`；GitHub 依赖要有镜像/离线兜底。

---

*本文档由 ZCode 会话 sess_f30a1ff0 生成并于 2026-11-04 随 Phase 0–4 全部编码完成更新。五阶段编码收尾，剩 §5.1 冒烟 + 提交。*
