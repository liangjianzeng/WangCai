# 更新日志

WangCai 所有值得记录的改动都在这里。格式遵循
[Keep a Changelog](https://keepachangelog.com/en/1.1.0/)，项目计划在打出第一个 tag 后遵循
[语义化版本](https://semver.org/spec/v2.0.0.html)。

Unreleased 段落里的日期是"该改动在硬件上被验证的日期"，不是写文档的日期。

## [Unreleased]

此处累积已入库、随下一版发布的改动。

### 修复 —— Linux 全新数据首启聊天区全屏转圈（2026-11-11 WSLg 用户实测「为什么一直转圈」）

- **根因（黑匣子实锤 `Unhandled Exception: Bad state: No element` @ home_screen:298）**：
  `conversationsProvider` watch `activeProjectIdProvider`；全新数据首启「创建默认项目」
  让激活项目从 null 变实 id → provider 重建。`_initConversation` 的 `ensureLoaded()`
  等的是旧实例、`create()` 写进的也是旧实例（销毁后 state 写入 **release 静默 no-op /
  debug 抛 StateError**——两形态修复全覆盖），await 窗口里重读拿到**新实例的初始空态**
  → `conversations.first` 抛 → `_initiallyLoaded=true` 永不执行 → 1132 行全屏
  `CircularProgressIndicator` 永转。Windows 装机机永远有存量会话不走播种分支，
  「干净机验证待人工」（packaging/README）欠的债被 Linux 首启踩出。
- **修复三层**：`try/catch create()`（吞掉旧实例销毁异常，落库已完成）→ 对**当前实例**
  `ensureLoaded()` 重读 → 仍空则 `_initiallyLoaded=true` 露空会话占位（可手动新建），
  竞态与落库失败都不再卡圈。
- **回归锚**：`test/providers/conversations_seed_race_test.dart` 双锚（跨重建裸 read
  复现空态 + 修复后重读可见；同实例基线），2/2 全绿；analyze 零新增（37 为存量基线）。
- **复验（WSLg 全新数据实跑）**：首启无异常 + 进程存活；黑匣子启动标记 `dataRoot=
  ~/.local/share/WangCai`；二次启动数据不丢、不重复播种。

### 修复 —— Linux 数据家落 /tmp：WSL 实例回收即数据蒸发（2026-11-11 同轮发现）

- **根因**：`WangCaiPaths.dataRoot()` 无 APPDATA 时兜底 `Directory.systemTemp`——
  Linux 上即 `/tmp/WangCai`，而 WSL `/tmp` 是 tmpfs，实例回收即整家蒸发
  （会话/设置/黑匣子日志全丢，「首启」天天重演，也是上一条竞态每次必现的帮凶）。
- **修复**：dataRoot 加 Linux 分支走 XDG（`XDG_DATA_HOME` 或 `~/.local/share/WangCai`）；
  Windows 无 APPDATA 极端环境维持 systemTemp 旧兜底不动。db/logs/projects.json
  实测落 `~/.local/share/WangCai/`，跨实例重启不丢。

### 新增 —— 汪柴生图服务：Qwen-Image-2.1-Turbo diffusers 直调第二链路（2026-11-10 用户「好，施工」）

- **tools/imagegen-server/ 三件套**（server.py / requirements.txt / README.md）：独立 FastAPI
  服务直接托管 `QwenImage21Pipeline`（ModelScope Qwen/Qwen-Image-2.1-Turbo），对外暴露与
  unsloth Studio 完全同构的三端点 OpenAI 协议壳——**汪柴客户端零改动**，设置页换地址即切链路；
  默认 8899 与 unsloth 8888 并存不打架。Turbo 特性由壳吸收：8 步调度烘焙在 checkpoint、
  CFG=1（steps/negative 照收不生效）；生成全局串行锁（排队不 429，客户端 120s/300s 超时档
  已含排队预算）；尺寸钳 [256,2560] 16 对齐（放得下官方竖图例 1696×2528）；
  env 全配置化（repo/key/port/dtype/offload）兼容本机 N 卡与 DGX Spark 128GB 双宿主。
- **协议契约 WSL 实弹冒烟 9 点全绿**：health 加载态仍 200（绿灯不吃冷启动）/ models 无 key·
  错 key → 401 unsloth 同款 `authentication_error` 体 / 对 key → `data[].id` 进设置页下拉 /
  缺 prompt·脏 size·url 格式 → 400 / 依赖缺失 → 503 带可操作指引（装 git 版 diffusers）。
  测量教训：WSL 冷启动 + DRVFS 9P 首读使 python 起服可达 10s+，固定 sleep 冒烟必假阴，
  改轮询「Uvicorn running」就绪判定后稳定。
- **许可 go/no-go 口径入 README**：Qwen RESEARCH LICENSE（2026-09-20 通义）原文实锤
  「Non-Commercial = research or evaluation purposes only」，商用须向 model-business@notice
  另行取得授权——服务启动横幅 + /api/health 双处打印此提示，部署方用途自审。
- **依赖钉版**：diffusers 必须 git 主（QwenImage21Pipeline + PR #14950 pipeline-configured
  sampling sigmas 未进 PyPI 正式版），requirements 注明官方收录后可换版本号。

### 新增 —— 兜底准入：问题模型自动回退定制 ctx，先保可用（2026-11-09 用户拍板「先兜底定制 ctx，确保先能用」）

- **机制**：`AdmissionRule` 新增 `fallbackCtx`（4B 线两条 ctx 门槛规则声明 512）——
  规则触发时网关不再硬拒载，而是把请求 ctx 收敛到 `max(兜底档, 该机实测档)`
  继续加载（实测只抬不压，与 `_ctxCeilingFor` 同一不变量），ℹ️ 日志留痕
  （兜底依据逐条透传，缺陷单引用不丢）；收敛后重评放行。无实测安全档的模型
  （Qwen3.5-4B 编译即死 / MiniCPM5-2B 全矩阵仅 1 点可用）不声明 → 维持硬拒载 +
  改道建议。路由层同口径：可兜底的违例不作死候选，全禁入照旧 blocked+不改道。
- **manifest 层**：`EngineManifest.evaluateAdmission` 返回 `{violations, fallbackCtx}`
  （触发规则全带兜底档取最小、任一缺省即 null）；`checkAdmission` 改为其薄壳，
  规则级锚不动。
- **测试**：manifest 兜底锚（规则声明纪律 + evaluateAdmission 全矩阵 + 实测豁免
  联运）、网关锚（Spark@4096→`-c 512` 加载、实测 1024 抬兜底到 1024、OOM demote
  后越档兜底 512、MiniCPM5 仍拒载）、真机锚（m2_dod Spark 拒绝锚改兜底锚、
  app_npu_flow 4B@4096 臂改 `-c 512`——该臂在 11-07 admission 收紧后已失实）。
  全锦 1437/23/0。

### 文档 —— README「NPU 模型支持现状」坦白版（2026-11-09）

- 新增模型支持矩阵（一行一模型带实测数字与缺陷单出处）：LFM3-1.7B/Omni-2B 主打线
  ✅、Spark/Qwen3-4B 🟡 仅 ctx≤512、NeoHorse ⬜ 留位、Qwen3.5/MiniCPM5 ❌ 禁入；
  附 4B 兜底机制说明与世代口径（3720 一台实机，二/三代未实测不外推）。
- 修正过时表述：副靶行（11-01「端到端跑通」→ 11-07/08 包线墙收窄口径）、4B decode
  行（12.26 标注 KVH=1 speed-only，生产 KVH=0 = 8.89/8.15）、NPU 视觉行与多模态段
  （11-07 引擎修复后带图三线全绿，不再「NPU 纯文本」）、硬约束表（1.7B 与 4B ctx
  口径分开）、版本横幅补 0.0.6。

### 新增 —— 生图整合：Unsloth Studio 文生图进聊天区（2026-11-10，Win/Linux 双端）

- **一个实现双入口**（`services/image_gen_service.dart`，纯 Dart + dio，零原生依赖）：
  ①聊天区 🎨 chip /「/图 提示词」确定性直调——不经 LLM、简单聊天模式可用、零 token，
  占位卡带取消/失败重试（同参重发）；②智能体 `generate_image` 工具
  （`agent/builtin_tools/generate_image_tool.dart`）LLM 自主配图，`enabled && lastHealthOk`
  才注册（照 weather/web_search 先例，关闭/断连时 LLM 看不到该工具、不幻觉调用）。
- **服务端口径**：Unsloth Studio（Windows FastAPI :8888）OpenAI 兼容
  `POST /v1/images/generations`（b64_json），Qwen-Image-2.1-Turbo GGUF Q5_K_M 8 步 Turbo；
  1024² 稳态实测 17–29 s、2048² ≈105 s；n≤4 客户端单飞队列串行（单卡独占）；错误分型
  （notConfigured/unreachable/timeout/unauthorized/serverBusy/decode）驱动 chip 置灰与文案。
- **数据口径**：图片落盘 `文档/imagegen/YYYYMMDD/img-<ts>-<seed>.png`，以 `imagePaths` 入
  ChatMessage（复用图片气泡渲染），seed/尺寸/耗时/模型随 `attachments.gen` 落库——溯源与
  同 seed 复现；`chat_message_image_invariant_test` 钉「引用死路径不打红气泡」不变量。
- **设置页**：「API 接入 → 图像生成」节（启用/服务地址/模型/默认尺寸/密钥 + 测连接绿灯，
  `screens/image_gen_section.dart`）；Windows 预填 `http://127.0.0.1:8888`，Linux 留空带帮助文案；
  密钥走 `SecureApiKeyStore`（id=`unsloth-image`，Win=DPAPI / Linux=libsecret）。
- **平台一致性**：生图路径无任何编译期平台分支——Linux（远端客户壳）连局域网 Windows 侧
  Unsloth 即得同等体验；图片复制剪贴板 Linux 需 xclip/wl-clipboard（deb 已声明依赖）。
  母方案与验收清单 `docs/image-gen-integration-plan.md`。
- **测试**：生图面四文件 36 锚全绿（2026-11-10 复跑）——`image_gen_service_test`（mock dio：
  成功/b64 解码/超时/401/单飞队列/model 字段口径）、`generate_image_tool_test`（条件注册/
  参数契约）、`image_actions_test`（动作行图标/选张弹层/右键菜单入口）、
  `chat_message_image_invariant_test`（图片消息不变量）；`image_gen_live_test` 真机联调臂
  三重门控（服务不可达/key 缺失自动跳过，CI 不假败）。

### 修复 —— 生图消息的图片复制/另存入口显式化（2026-11-10 用户点单）

- **根因**：生图消息的图片操作（复制进剪贴板/另存为）此前只藏在长按/右键
  **图片本身**才弹的弹层里——动作行复制键只管文本、消息右键只有「复制全文」，
  零可见性，用户体感 = 生成的图片没有复制和另存的能力。
- **修复**（可见入口三处 + 共享件一份）：①`MessageActionsRow` 新增
  `imagePaths`，带图消息动作行出现「复制图片 / 另存图片」两枚图标（单图直接
  执行，多图先弹选张；三处调用点——气泡页脚 / 智能体回合尾 ×2——全部接上）；
  ②消息右键菜单在「复制全文」之外补「复制图片 / 另存图片…」；③全屏预览
  右上加复制/另存工具栏（作用于当前页）。复制/另存逻辑收敛进新共享件
  `widgets/image_actions.dart`（气泡弹层/动作行/预览三处共用；气泡内原有的
  两份 toast/FilePicker 重复实现删除）。
- **加固**：气泡与选张缩略图 `Image.file` 补 errorBuilder——引用死路径
  （缓存被清等）不再把气泡列表打成红块。
- **测试**：新增 `test/widgets/image_actions_test.dart` 六锚（图标出现/隐藏、
  空串=无图、多图选张弹层、右键菜单图片项有无）。锚注释钉住一个手势事实：
  `MarkdownBody(selectable)` 内部选择手势件在桌面端吃掉正文上的右键，
  菜单测试落点必须选页脚时间戳等中性区。widgets+screens 面全绿；
  analyze 零新增（2413 为 vendored 存量基线）。

### 新增 —— Linux 打包链：deb + tar.gz 双产物，x64（WSL）与 ARM64（DGX 原生）通用（2026-11-10）

- **`packaging/build-linux.sh`**（单一入口，架构自动）：`flutter build linux --release`
  → tar.gz 便携包（含依赖清单 README）+ deb（`/opt/wangcai` + `/usr/bin/wangcai`
  符号链 + desktop 条目 + hicolor 图标按 logo 真实宽度挑档）。**Linux 包不含引擎**
  （NPU/OpenVINO 守卫降级，生图/引擎走 LAN HTTP，口径见
  `docs/image-gen-integration-plan.md`），区别于 Windows 包。
- **`packaging/linux/wsl-setup.sh` / `apt-deps-root.sh`**：一次性环境（apt 依赖 +
  Flutter 3.27.0 与 Windows 侧同版）；无免密 sudo 时 root 侧跑 apt 段或 `SKIP_APT=1`。
- **runner 归位**：`APPLICATION_ID` → `org.wangcai.wangcai`，窗口标题「汪柴 WangCai」。
- **构建坑四连（都写进脚本注释与 packaging/README）**：① rsync 裸 `--exclude src`
  会连 `packages/*/lib/src` 一起排掉（须 `/src` 锚根）；② 插件 configure 中途失败把
  CMakeCache 以 `prefix=/usr/local` 落盘且永不自愈（模板默认分支在
  `include(generated_plugins)` 之后）→ 打包前 `rm -rf build/linux`；③ audioplayers_linux
  需 GStreamer dev、tray_manager 需 ayatana-appindicator3-dev（Dart 侧有平台守卫但
  链接期就要）、secure_storage 需 libsecret；④ Git Bash→wsl.exe 的 MSYS 路径/引号
  三连坑，一律「脚本文件 + `bash -c "带引号整串"`」。
- **DGX Spark（aarch64）**：同脚本原生构建（不交叉编译），产物自动 `-linux-arm64`。

### 变更 —— 产品定位双平台化：Windows + Linux 桌面离线 AI 智能体（2026-11-10 用户点单）

- **关于页**：tagline「Windows 桌面…」→「Windows / Linux 桌面离线 AI 智能体」；
  「平台」行按运行系统显示（Windows 10/11（NPU 引擎全功能）/ Linux 桌面
  （X11 / Wayland））；Linux 运行 AdditionalInfo 补灰色小字声明固有局限——本地
  NPU 推理与系统托盘不可用（守卫降级）、模型引擎/生图请指向局域网 HTTP。
- **README**：横幅与下载安装段改双端口径（Linux 产物随 **2026-11-10 重出包的 0.0.6
  Releases** 一并发布——六产物直链 + 实测 sha256）；新增「Linux 桌面形态与限制」能力表
  （NPU/CUDA ❌、远端引擎/直连搜索/生图 ✅、托盘 ❌、自启 🟡 + 一句话定位「远端客户壳」）；
  README_en 横幅同步指引 + 补 Download 段与生图段（本轮）。

### 变更 —— 设置页 SearXNG 配置折叠化，端侧直连升为唯一露出主方案（2026-11-10 用户点单）

- 「API 接入 → 搜索」的 SearXNG 自架实例区默认收起，收成一行摘要
  （「SearXNG 实例（备用）」+ 未配置提示/当前地址 + 展开箭头），点开才露出
  地址/密钥/引擎/语言/条数/超时/测试全部配置项；说明文字改口「主方案是端侧
  直连引擎，自架 SearXNG 是备用路径」。不常用配置不再大量露出。

### 修复 —— Linux 端中文界面全乱码：CJK 字体缺失（2026-11-10 用户实测）

- **根因**：Ubuntu 基础镜像不带 CJK 字体（`fc-list :lang=zh` 计数 0），Flutter
  fontconfig 取不到中文字形 → 整屏豆腐块。这不是 App 缺陷，是**打包依赖漏项**。
- **修复三层**：① deb `Depends` 追加 `fonts-noto-cjk`（apt 装包自动带上）；
  ② tar.gz 便携包 README 依赖清单补位（注明「缺了整个 UI 全是豆腐块」）；
  ③ 验证机 WSL 装字体复验。WSL 侧 apt 拉 61MB 字体包走不稳定镜像反复
  `Ign→Get` 挂死，改 Windows 侧 `curl` 从清华镜像直下 + MD5 对 apt 索引后
  挂载进 WSL `dpkg -i` 装上。双端（WSLg/Windows）截图复验中文渲染正常。
- **同族第二案（emoji）**：设置页分节头 🧠🧩⚡🤖🔌 全是 **emoji 文本**（非
  Material 图标），Ubuntu 不带 emoji 字体 → 同样豆腐块。三层同法补
  `fonts-noto-color-emoji`（deb Depends / 便携包清单 / 测试机实装）。

### 修复 —— Linux 顶栏/任务栏无应用图标（wslu 默认占位图）（2026-11-10 用户实测）

- **根因**：`linux/runner` 从未设窗口图标（Windows 侧靠 `app_icon.ico`，Linux
  无对应机制），WSLg 于是拿 wslu 默认「绿山野」占位图当应用图标。
- **修复**：`my_application.cc` 新增 `set_wangcai_window_icon()`——从
  `/proc/self/exe` 定位 bundle，把 `flutter_assets/assets/wangchai_logo.png`
  （与 Windows `app_icon.ico` 同源 logo）`gtk_window_set_icon` 进窗口。
  踩坑：`g_read_link` 是 GLib 2.70+ API，runner 编译期被版本护栏隐藏报
  undeclared identifier → 改 `realpath("/proc/self/exe")`（glibc 恒有）。
  WSLg 截图复验：任务栏出现柴犬图标。

### 变更 —— 生图远程接入：Tailscale 地址口径 + 模型名改服务端下拉（2026-11-10 用户实测点单）

- **远程地址报错根因（非客户端缺陷）**：`https://liang-geekpro…ts.net:8888` 配
  置报错是**服务端 tailscale serve 形态问题**——实测 `:8888` 监听是**明文 HTTP**
  （openssl 握手 `wrong version number`、curl https 报 `SEC_E_INVALID_TOKEN`），
  tailnet 内 `http://…ts.net:8888/api/health` 直通 200。tailnet 流量本身端到端
  加密，端上应填 **http** 方案；设置页服务地址 hint 补远程示例并注明该口径。
- **模型名不再暴露服务端路径**：旧默认值 `kImageGenDefaultModel =
  'E:/Unsloth/models'`（服务端扫描目录当模型名露出，终端无从理解）。新口径：
  默认**空 = 省略 `model` 字段走服务端缺省**；`checkHealth` 解析
  `GET /v1/models` 的 `data[].id` 落 `ImageGenHealth.models`；设置页模型字段
  **测试连接成功后变下拉选单**（含「服务端缺省模型」空选项，存量值不在列表时
  回落缺省不吞值），未测过连接才退回手填（注明可留空）。
- **测试**：`image_gen_service_test` 锚同步新口径（空模型 body 无 model 键 /
  显式模型透传两锚）；生图面 30 全绿；analyze 零新增。

### 新增 —— DGX Spark（ARM64）原生构建落地（2026-11-10，用户拍板 Tailscale 过去打）

- **通道**：Tailscale `gx10-85f3`（aarch64 / Ubuntu 24.04.5 / 20 核）密钥免密
  SSH → tar 管道送源码 → `packaging/linux/wsl-setup.sh` + `build-linux.sh`
  同套脚本跑通，产物 `WangCai-0.0.6-linux-arm64.{deb,tar.gz}`（deb 21MB /
  tar 27MB）已回 `packaging/dist/`。
- **版本口径（如实记录）**：**Flutter 官方不发布 linux-arm64 SDK**（从国内镜像
  强下「Linux」包是 x86 版，arm64 上 QEMU 模拟段错误实锤）；DGX 构建用**机上
  3.29.0（arm64）**，与 Windows/WSL 侧 3.27.0 存在版本差——3.29 向后兼容、
  编译产物装机验证通过（arm64 ELF、ldd 0 missing），发布页需注明构建版本。
- **构建依赖坑两个（都进 setup 清单与注释）**：① `libgstreamer1.0-dev` 在
  arm64 上 `Requires: libunwind`，缺 `libunwind-dev` 时 pkg_check_modules 报
  「gstreamer-1.0 not found」误导性错误；② Ubuntu 24.04 **t64 改名**——
  `libgtk-3-0`→`libgtk-3-0t64` 等，deb `Depends` 改备选语法
  `libgtk-3-0 | libgtk-3-0t64`、`libsqlite3-0 | libsqlite3-0t64`，一份 deb
  兼容 22.04/24.04 客户机。
- `wsl-setup.sh` 加固：`FLUTTER_DIR`/`FLUTTER_VER` 可覆盖、目标目录版本不符
  挪 `.bak` 不覆盖机主现有安装、下载加国内镜像 fallback。

## [0.0.6] — 2026-11-08 · 装机版引擎根因修复 + 4B 重估（`b7cb158`/`7a7326b`）

### 修复 —— 装机版「NPU 引擎不可用」两层根因 + 退出卡顿（2026-11-07 用户装机实测）

- **engines.json 存储值改「缓存不夺权」语义**：内置实例启动时新鲜解析（wangcai-npu=
  装机位探测），有效时存储的 binaryPath 不夺权；指向不存在文件时丢弃回退
  manifest.binary（实锤：开发机缓存经 junction 指 D 盘，existsSync 间歇假阴 →
  候选 on/out → npus 空 → 全模型拒载「NPU 引擎不可用」）。
- **PATH 前置重建**：存储前剔除不存在目录后为空则回退内置新鲜解析——装机位非
  自包含（tbb/NPU 插件在 ovlibs 子目录），前缀被冲 → server c0000142 起进程即死。
- **退出卡顿修复**：`destroy()` 返回后立即 `exit(0)`——事件日志实锤退出 13s 后
  flutter_windows.dll c000041d 死后用户回调 + WER 全量转储 = 用户「退出整机卡一下」。
- **常驻黑匣子日志**：新增 `platform/app_log.dart`（`%APPDATA%\WangCai\logs\app.log`
  1MB 轮转），启动标记/引擎装配/engines.json 解析裁决/路由候选快照/退出各步全留痕。
- 验证：装机 App 全链路（路由 on/in → server 存活 → NPU 编译 → 预热完成引擎就绪）；
  engine 96 绿；全锦 1434/23/0；analyze 零新增。

### 变更 —— 4B 重估轮：Qwen3-4B NPU 诊断（2026-11-08）

- admission 消息修正：「Qwen3-4B 历史 1.3 t/s」为旧引擎时代遗留口径，本机实测 ctx≤512 档
  decode 8.15 t/s（生产 KVH=0 口径）；规则结构不动。
- P14e 杠杆（KV_HOST_WRITE=1）跨模型迁移实锤：Qwen3-4B tg 8.15→10.82（+33%），与 Spark
  （+38%）同族——P14e 根因修复收益面 +1 模型；文本闸未过前 KVH=1 仍禁入生产。
- 4B@NPU 包线墙实测：ctx>512（bench ctx2176）编译能过、首执行 UNINITIALIZED，
  ifCtxGt 512 由保守拦升级为实测拦。
- 明细与测量纪律教训见 docs/HANDOFF.md 2026-11-08 节。

### 新增 —— NPU 世代自适应（2026-11-05/06，Core Ultra 一/二/三代）

- 探测从「只取 `OPENVINO{n}` 下标」升级为 `NpuDeviceInfo` 全貌（型号名/npuCode/MiB）；
  世代表决 `npu_profiles.dart`（3720=一代 / 3820=二代 / 4000 系=三代 / 未知→一代保守
  基线；名称兜底走带 `\b` 正则，防 `NPU 37200` 松匹配误判）。
- clamp 链 `maxStableCtx`（该机实测）> 档案 `ctxOverrides`（当前空表）> `preset.ctx`；
  实测上探闭环（成功单调回写、`OUT_OF_HOST_MEMORY` 自动 `demoteCtx` 收回被证伪档位、
  admission 仅 ctx 门槛类规则让位实测证据）；CIM 驱动版本会话级缓存；引擎卡亮出
  「型号 · 世代 · -dev 档位」；口径入 `docs/npu-adaptation.md`（保守起步+实测上探，
  MiB 只当诊断不当预算）。回归锚：3720 行为逐位同 v0.0.5。

### 新增 —— 语音 ASR&TTS 重构 M0–M3（2026-11-06 合流，c944c1c）

- `lib/voice/` 统一编排：唤醒 KWS 双引擎仲裁、麦克风仲裁、`VoiceService`
  （识别/播报会话状态机）；Edge TTS 降为引擎层，新增 offline 链
  （matcha/vits → Edge 回落）与失败留痕；设置页语音区语义并入
  （`voiceEnabled && voiceAutoSpeak` 总开关）。母方案与施工计划见
  `docs/asr-tts-refactor-*.md`、`docs/voice-wakeup-min-spec.md`。

### 修复 —— 全面健康检查清账（2026-11-06）

- **基线三败清零，`flutter test` 全绿自此为常态**（1321 pass/18 skip/0 fail 首破）：
  `thinking_runaway`（2 例）与 `agent_stream_processor`（孤立 response 记号）对齐
  `AgentStreamProcessor` 位置门（Clover 2026-10-30）后契约，位置门行为由用例锁死；
  UPSTREAM.md 上游债务段转已清账。
- `TimingHints` 类默认 36000→600000：缺省被当就绪超时预算用，缺 `timingHints` 的
  自定义 manifest 在 NPU 冷编（实测 ~10min）下必被误杀。
- 测试腐化修：FakeProcess×5 逐字副本收编 `test/helpers/fake_process.dart`；
  m2_dod b12034 钉死目录改扫已装 `llamacpp-*-{cuda,vulkan}`（防商店升版后静默永久
  skip）；preset 钉字节 ±2% 容忍带（精确字节归 sha256 把关）；app_npu_flow 补
  `WANGCAI_NPU_E2E=1` 显式门。
- 可观测性：十三处静默 `catch (_) {}` 加 `debugPrint` 留痕（engine_store 安装/卸载、
  chat_provider 会话随删、ssh 安全存储取密钥、routing.json 档位读写），控制流零改动。
- 打包链：`wangcai-setup.iss` 取料统一走 `build-installer.ps1` 的 `stage\`（此前
  硬编码 `E:\dev-tools` OV 直取，与 ps1 的 vendored 优先解析成两条链）；
  packaging/README 从 v0.0.2 陈旧流程重写为 ps1 单一入口。
- 文档失实修正：roadmap Phase 1 状态注记、getting-started NPU decode 数（8→14–15 t/s）。
- 仓库卫生：`.git` 110MB→3MB（113MB 孤儿大 blob 系 reflog 持根，expire+gc 回收）；
  `.gitignore` 补 `.zcode/`。

## [0.0.5] — 2026-11-05 · 引擎线合流收官（`6c72416`）

- origin/main 引擎线 P15–P20 合入：`KV_HOST_WRITE` 默认翻转修复、P16 rope、
  P18 chunk 自动升档（`583d9ef`）。
- 引擎线三项：`lfm3-1.7b-deep` 16K NPU 预设；按需安装 **zip 流式解包**（CUDA 包
  800MB+ 全量驻内存导致「下载完成后崩溃」的根因修复）；引擎参数按设备条件显示。
- 侧边栏常显并收窄到按钮宽度（用户定案）。
- 版本串全线（pubspec / iss / ps1）+ 便携包打出。

## [0.0.4] — 2026-11-05 · 数据家统一与桌面基本件（`a1d05c6`）

- **数据家统一**：四家并一家进 `%APPDATA%\WangCai`（DSH 纪律；搬迁语义 6 用例：
  子目录搬迁/幂等/冲突 `.migrated`/`.migrating` 自愈/SQLite copy 迁移/无旧库不落盘）。
- **路由定调**（用户拍板）：NPU 主打，CUDA/Vulkan 是外挂，auto 档恒 NPU 优先。
- JSONL 真相源通电：write-through + fast path + cwd 盖章。
- 窗口与桌面基本件：几何记忆/最小尺寸/单实例/真标题/快捷键/右键菜单。
- 交互去手机化三辑：main 死代码清退+附件桌面化 → sheet 全量清退+审批 composer
  接管+缩放快捷键 → SafeArea 清退。
- 便携包 `WangCai-0.0.4-win-x64-portable.zip`（108.1MB）打出。

## [0.0.3] — 2026-11-04 · 桌面独立化 Phase 0–4

- **独立化定案**：脱离上游 TongYi-Lite 独立演进（UPSTREAM.md 转分叉存档；包名
  `tongyi_lite`→`wangcai`、品牌 WangCai/汪柴 全线换装，冻结提示词按字节一致同步）。
- 会话/项目重构：项目 × 工作空间层级 + SQLite v7（`%APPDATA%` 项目树）。
- 引擎管理：本地模型登记 + 参数优先级链（customArgs > defaultConfig > 模板）+
  cuda/vulkan 按需下载 + OPENVINO 探测 + 签名瘦身。
- 桌面 UI 重写 + 手机端配置清理（Termux 向导删除；ADB 按用户指令保留）。
- `local_exec` 桌面执行层（cmd.exe 壳 + `LocalGit` 凭据注入）替换嵌入式沙箱。

## [0.0.2] — 2026-11-03 · 汪柴助手壳 M1–M4 + 引擎横切修复

2026-11-01/02 在硬件上验证的四批改动。

### 新增 —— Assistant v0.0.2（汪柴助手，2026-11-02/03 在开发机验证）

- **M1 壳+汪柴驱动**：`app/` Flutter Windows 壳（TongYi-Lite Dart 同路径 vendored，
  分叉清单 `app/UPSTREAM.md`）+ 引擎核心（manifest/状态机/进程账本/env 纪律）+
  llama-server 子进程网关（平台分支唯一化）+ 设置页引擎管理面板（状态 chip/
  停止/按上次配置重启/日志 tail/启动命令取证）。NPU 三问 3/3、改 ctx 重启换缓存
  目录（D6）、杀进程看门狗复活，全部真机回归（`app/test/platform/`）。
- **M2 三引擎齐**：绑定表（sqlite，实测 t/s 每回合回写）+ 路由三档（速度优先/
  NPU 优先/自动·后台·拔电 NPU 加权；无写死参数量阈值）+ 引擎商店（官方
  llama.cpp release 下载/sha256 白名单/解包/设备探测，钉 b12034：vulkan+cuda）
  + 单 active 互斥 + 空闲超时卸载 + OpenAI 远端（key 迁 secure_storage/DPAPI、
  /v1/models 发现）。**DoD 四线真机 5/5**：NPU 1.7B ✓ / CUDA 4B（117.6 tok/s
  回写）✓ / Vulkan 双卡（Intel iGPU + RTX 5060 Ti）✓ / 远端协议 ✓
  （`app/test/platform/m2_dod_test.dart`）。
- **M3 驻留**：托盘（关窗=隐藏，M0-2 模式）、电源感知（FFI GetSystemPowerStatus
  → 拔电 NPU 加权）、HKCU 自启；**识图 DoD 达成**（官方引擎线）：SmolVLM2-500M
  （hf-mirror 下载入模型库）+ 商店 CUDA 引擎，壳网关 20s 全链路出准确语义描述
  （`app/test/platform/vision_official_test.dart`）；NPU 视觉编码缺陷归档
  （`docs/defect-npu-mtmd.md`：OV 后端 graph_compute -1，NPU 线做纯文本）。
- **M4 Agent 回归 + 安装包**：LFM3 --jinja 工具链全链路真机复归（tools/
  tool_calls/tool 结果 200；此前 agent 400 定案为 ctx 超限非协议缺陷，agent
  c4096 正常回合）；打包脚本双产出——便携包 `WangCai-0.0.2-win-x64-portable.zip`
  （App+引擎合包，干净进程自测 DLL 闭合通过；实案：漏 mtmd.dll/impl.dll 均
  0xC0000135）+ Inno Setup 脚本（每用户安装，装 ISCC 后一键出 Setup.exe）。
  ⬜ 干净机装机验证待人工（`packaging/README.md`）。

### 新增 —— 跨模型验证（副靶 Spark-X2.6-4B + Qwen3-4B 复测）

- **副靶立项并通过**：讯飞 Spark-X2.6-4B（标准稠密 Transformer，与 LFM3 混合架构不同系）端到端跑通
  全部路径：native ✓（151.9/19.9 t/s）、OV-CPU 动态 ✓（77.4/8.2）、OV-CPU 静态三问 3/3、
  **NPU 三问 3/3**（chunk128 + 禁 levels，decode 2.4 t/s）。
- **Qwen3-4B NPU 复测翻案**：2026-10-31 记录的"从第一步单 token 塌缩（GGGG…）"在当前引擎上
  不再复现——副靶配置（chunk128 + 禁 levels + c512）下输出连贯且**三问验收 3/3**。两个外部模型
  家族全部通过 NPU 精度验收，引擎翻译层跨模型成立的第一个实证。
- NPU 4B 预算实测：默认配置（chunk256 + levels）在图编译完成后**执行期**撞
  `ZE_RESULT_ERROR_OUT_OF_HOST_MEMORY`（系统 RAM 空闲 28.8 GB，驱动侧预算）；levels 开启反而更慢
  （level 图与权重 bank 竞争预算）。副靶配置脚本 `tools/spark-npu-accept.ps1`。

### 修复 —— u4 权重宿主视图 + 精确 f16 零点（横切所有模型）

- **u4 无法包宿主内存**：这份 OV 构建里 `ov::Tensor(u4, shape, ptr)` 与
  `ov::Constant(u4, shape, raw_ptr)` 都抛 `is_pointer_representable`（i4/u8 通过）——所有非对称
  4-bit 路径从未可用：native Q4_K/Q4_1 的 OV-CPU 路径（Q4_K_M 是最常见 checkpoint 格式）与
  `REQUANT_KQUANT=q4_asym64*`。三层修复：`wrap_or_detach` 内部分配+回写槽位、
  `make_int4_weights` unsigned 分支改由 Tensor 拷贝构造 Constant、`count_bad_f16` 只校验 f16
  元素类型的 scales/zp（u4 zp 上 `data<f16>()` 本身就是抛出点）。修复后 q4_asym64_all 实测
  151.6/28.9 t/s。
- **native 非对称提取统一精确 f16 零点**：整数 zp 的 `round(min/scale)` 舍入让 LFM3 静态图思考
  退化成 "\n" 死循环（动态路径侥幸正确；MoE 专家因同一误差早已改 f16）。推广到全部 native 非对称
  提取（Q4_K/Q4_1/Q5_1/Q5_K），`extract_quantized_weights`/`process_weight_tensor`/
  `get_extracted_layout` 三处同步。修复后 LFM3 与 Spark 的 OV-CPU 静态三问**无 env** 全 3/3，
  `accept-smoke.ps1` 的 requant env 已摘除。

### 新增 —— 引擎（decode 性能主攻）

- **多跨度离散 decode 图组（缺陷 2 根因①的修复）：NPU decode 14–15 t/s 且与上下文长度无关。**
  按 PAD(n_kv,256) 离散级别（256/512/…/ctx）每级一张全静态 decode 图，llama.cpp 每步按当前 n_kv
  选级；KV cache 参数与绑定按级别裁视图，每步状态 I/O 与该级别成正比；编译新级别前驱逐旧级别
  （NPU 设备预算 = prefill + 一张 decode 图，第二张常驻在首次 execute 即
  ZE_RESULT_ERROR_UNINITIALIZED）；级别切换时把 KV 的 [fill,span) 段清零（跨级别正确性保障，
  A/B logits 逐位一致）。实测：c=8192 从 0.9 → 14.1 t/s（**17×**）、c=2048 从 3.3 → 14.3（4.5×）；
  600-token 任务跨 256/512/1024 三级切换全程无错；token 流不同 ctx 逐字节一致。逃生门
  `GGML_OPENVINO_DISABLE_DECODE_LEVELS=1` 回退全 ctx 单图，`GGML_OPENVINO_NO_KV_ZEROIZE` 调试用。

### 新增 —— 引擎（音频）

- **NPU 音频输入端到端跑通。** raw-embd 块补齐（chunk-pad）与动态 token 维传播
  （`compute_node_dynamic_dims` 对 raw-embd 叶子置 1）；此前 Reshape 把捕获的 [1,1,38,2048] 烤进图，
  对补齐后的 [1,1,256,2048] 形状推理失败。NPU 回答连贯，与 f32 参照有 top-1 级分歧
  （与文本自由生成已记录的 f16 复利行为同类）。

### 新增 —— 测量基建

- `GGML_OPENVINO_PROFILING=1`（每步 Graph inference / OV raw infer 分解）与 `=2`（静态路径逐节点
  CSV；注意 CSV 写入进程 CWD、-n N 只覆盖前 N+1 个文件、逐节点总和可超 wall time——DPU/DMA 并行
  记账）。缺陷 2 的三项根因（状态往返 ~32 ms/步@c512、全 ctx 跨度注意力超线性、lm_head 11 ms）
  即由此定案。

### 探针 —— stateful 路线证伪（tools/npu-probes/）

- NPU（OpenVINO 2026.4.1）**支持 VariableState**：query_state 正常、状态跨 infer() 在设备侧累积
  （初始值张量被忽略、按 0 初始化）。但每步成本 ≈5–6 ms/MB（0.18 GB/s）线性放大——8.4 MB KV 量级
  state 43–45 ms/步，比参数绑定（全步骤 6.1 ms，≈1.4 GB/s）**慢 7 倍**：每次 infer() 都走慢速状态
  检查点路径。**结论：设备驻留 KV 路线反模式，参数绑定 + 级别裁剪是当前最优架构**；defect-2 下一
  独立杠杆为 lm_head（11 ms/步）。附带教训：平铺 [1,N] 大形状 elementwise 图会让 NPUW 编译爆炸。

### 修复 —— 工具

- **accept-smoke Q3 "flake" 定案为测试基建 bug**：判定 `-match '2'` 匹配整个日志，性能行
  `[ Prompt: 23.7 t/s | Generation: 29.0 t/s ]` 的 t/s 数字随机含 '2' 造成假通过/假失败；且 n=48
  对思维链模型太短（note-4 幻觉在动/静态路径逐字节一致，非引擎回归）。修复：只匹配答案区段
  （回显 prompt 与性能行之间）+ 默认 n=96；修复后 3 轮 3/3 完全确定。

### 修复 —— 引擎（音频回归 + 设备预算自愈）

- **NPU 音频回归三层因果链闭合，输出与 native Q8_0 参照逐字一致。** ①NPU 默认把 Q4_0 重分组到
  group-128 对称，对 mmproj conv 栈是纯损失（嵌入 cos 0.963、范数 +12%，答案在 <think> 后即 EOS）
  ——`a.`-前缀编码器张量豁免走 native（0.9997），LLM 权重保持 128（native 化掉 40% 吞吐）；
  ②CPU 静态与 NPU 的 LLM 量化需一致（`q4_sym128_all`），音频答案在边际敏感区被量化差翻转
  （文本同幅度 KV 分歧 layer12=0.73 不受影响）；③Omni-2B decode level 图撞设备预算
  （ZE_RESULT_ERROR_UNINITIALIZED，缺陷-7 族，非确定性）。
- **level 图设备预算自动降级重试**：level 图 `infer()` 撞 UNINITIALIZED 时自动清空全部 level
  缓存、置进程级开关并重试一次 full-ctx decode 图——Omni-2B NPU 音频零 env 跑通，1.7B 不触发。
  实现坑：entry mutex 非递归（持锁重入 EDEADLK，改 unique_lock + unlock）；降级后的 ctx 图
  必须发布进 ctx-pair 缓存，否则每 token 重编译。
- **热启动 23 s → 8.9 s**：requant 全量物化路径行分块并行（发现 ov::parallel_for 在无
  TBB/OpenMP 的构建里是串行回退，改用 std::thread 池；chunk 对齐偶数块保 u4 zp 字节对）；
  make_dirs 盘符 bug（`_mkdir("D:")` EACCES 曾使 COMPILED_MODEL_CACHE_DIR 在 Windows 静默失效）；
  多级图接入 COMPILED_MODEL_CACHE_DIR（NPU 上与共享权重 bank 冲突，保持 opt-in 关，探针定案）。

### 修复 —— 引擎（视觉静态精度，两个根因连定案；NPU 视觉端到端收官）

- **根因①：cacheless 图的 `compute_params.input_len == -1` + size_t 回绕 → 多平面位置表读越界。**
  cacheless 图（mtmd 视觉编码器走显式 softmax，不走 FLASH_ATTN_EXT）没有任何代码给 `input_len`
  赋值，K/V 路径（ggml-decoder.cpp）与 cacheless FLASH_ATTN_EXT 扫描都只覆盖 KV 注意力图。作为
  size_t 它回绕到 2^64-1，多平面 inp_pos 绑定的平面步长 `p * input_len` 回绕成 `-p`，第 2/3/4
  平面从缓冲区**前面**读 p 个元素——rope 角度按位置错位（out[p][s] = h(s-p)），编码器输出 cos 0.54。
  修复：平面长度是张量自身属性（`ne[0]` 已堆叠 4 个平面），改从 `ne[0]/n_planes` 读取。修复后
  CPU 静态 node_416 与 native **逐位一致**（cos 1.00000，maxabs 0）。
- **根因②：NPUW 配置三元组在 clip 图上静默损坏编码器。** 引擎 NPU 默认编译配置里
  `NPU_USE_NPUW + NPUW_FOLD + NPUW_FUNCALL_FOR_ALL` 的组合把视觉编码器在 NPU 上打歪
  （同一 IR python 直接编译 cos 0.995，引擎配置路径 0.557；python 逐键二分定位到最小坏三元组，
  单键与两两组合全部干净）。clip 图的 softmax 没有 mask 输入，`is_cacheless_attn` 不置位，
  于是它吃到的是完整 NPUW 配置而非 `without_npuw` 过滤后的——三元组因此漏进了视觉图。
  修复：视觉 rope 图（`GGML_ROPE_TYPE_VISION`）编译时擦除 `NPUW_FUNCALL_FOR_ALL`；
  `extra_cfg` 3→4 使旧坏 blob 失效。修复后 NPU 视觉端到端描述与 native 一致，文本三问 3/3。
- **视觉 rope tile 扩展回退**：本轮曾把 decode 图的 cos/sin 头轴 tile 扩展到 VISION prefill
  （假设 NPU 视觉缺陷是同一头轴广播）——被证伪（tile 生效后 cos 不变），按位中性但理由不成立，
  回退到 LLM decode 专用，避免误导后来人。
- **TEMP 插桩拆除**：VISROPE（openvino/utils.cpp、rope.cpp）、PERFTRACE（decode 分支）、
  WARMTRACE 标记 TEMP 的 requant 计时块全部移除。

### 性能 —— 引擎（NPU 视觉编码 12.6 s → 0.54 s：插件 blob 缓存补位）

- **上一轮的"5061 ms 编码"是冷态假象**：单次冷跑把每进程 clip 重编译计进了编码时间。
  行级计时分解：clip 图 NPU **纯推理**本来只要 147–191 ms（python 直测同一 IR），真正的开销是
  **每进程 ~12.2 s 的全量 NPUW 重编译**；warm `mtmd batch encoding` 实际 12.6 s。
- **根因**：NPU 编译配置只设 `NPUW_CACHE_DIR`（NPUW 自身的 funcall/子图分解缓存），从不设
  `ov::cache_dir`（插件 blob 缓存）。视觉编码器权重烤成 `ov::Constants`，NPUW 缓存对它**永不命中**；
  LLM 图走 shared weights bank 路线 NPUW 缓存正常命中（~2.3 s），所以缺陷只在视觉侧暴露。
  python 实证：NPUW-only 每次 12–13 s；补 CACHE_DIR 后同一 IR 命中 0.41–0.74 s；视觉 IR
  跨进程逐位稳定（md5 相同，可安全命中）。
- **修复**：`ggml-openvino-extra.cpp` NPU 分支补插 `compile_config.insert(ov::cache_dir(cache_dir))`
  （`without_npuw` 路径剥 CACHE_MODE 但保留 CACHE_DIR，非 NPUW 路线接受该键）。修复后
  **warm encode 亚秒级**：542 ms（blob 已进 FS 缓存稳态）～896 ms（blob 刚写回、FS 冷）
  （vs native 435 ms、OV-CPU 动态 956 ms），冷启动一次性 16.5 s；
  最终二进制验收：视觉描述正确、文本三问 3/3、音频 EXITCODE=0。
- **上游可报**：NPUW_CACHE_DIR 不覆盖权重烤成 Constants 的图——与 bank-aware blob import 同族。

### 新增 —— 引擎（视觉输入，探察）

- mmproj 含视觉编码器（133 v. 张量）。**native 与 OV-CPU 动态路径视觉端到端正确**（测试图描述
  与参照一致）；静态翻译与 NPU 卡在 4 段式视觉 rope 位置表（每 patch 4 行被当 4× token，
  Multiply [1,784,16,64] × [1,3136,1,64] broadcast 失败）——静态 rope lowering 的 mrope 分段
  支持列为下一工作项。

### 性能 —— 引擎（4B prefill：chunk256 预算封锁证伪，bench 流 pp +55–59%）

- **旧论断过时**："4B 默认 chunk 256 撞驱动主机内存预算"是三图驱逐修复前的测量。llama-bench 流
  冷缓存实测 chunk256 全绿（Spark-X2.6-4B，新缓存目录，r≥2）：pp512 84.6→**131.5**（+55%）、
  pp1900 41.3→**65.9**（+59%）、c8192 pp8064 42.8 可跑；decode 不变（带宽地板）。
- **缺陷定案（BUDGET-TRACE 遥测）**："srv 流特异缺陷"不存在——真规则是 **prefill 图(chunk) + 最大
  decode 图（级别 = KV 行跨度）联合驻留**：4B chunk256 只容 lv≤512（ctx≤512 实测 ✅，pp +55–59%），
  lv≥1024（ctx≥1024 的 srv decode）超预算，首 execute ZE append 失败（levels-off 报 OUT_OF_HOST_MEMORY
  同族；崩溃时系统余 21 GB+，是驱动 per-process 配额）。**"bench 同形状幸存"是假象**：bench tg 的
  decode mask 恒 ≤256，从没建过 lv>256 的图。1.7B chunk256 lv2048 ✅。生产配置不变：4B srv/chat
  chunk128；ctx≤512 可 chunk256；离线 bench chunk256 随便用。遥测保留（`GGML_OPENVINO_BUDGET_TRACE=1`）。
- **新独立缺陷（低优先）**：`llama-completion`（raw）4B 静态 decode 编译 0xC0000409 heap fastfail，
  c1024/c2048 确定性复现——与预算规则无关（cli -st 同形状是 ZE append 失败而非 fastfail），非生产流，待查。
- **引擎修复**：空批次 decode（sched_reserve warmup，`attention_size_raw==0`）**直接短路返回成功**
  （0 token 无 KV/logits 行可写，编图执行都是白做；此前 clamp-to-1 方案撤销——它让空批真编一张 lv256 图）。
  chunk128 生产路径回归通过（cli -st 长 prompt 出 token、lv2048 命中、无 ZE）。
- NPUW 权重 bank 复核：`NPUW_WEIGHTS_BANK="shared"` 早已在 compile_config——插件共享不跨
  CompiledModel 去重（与上游 issue #3 一致），无白捡的预算。
- **缺陷 7（Q8_0 阻塞）结案——非阻塞**：原故障配置原样重测（1.7B-Q8_0 与 Omni-2B-Q8_0 各 1.85 GB，
  cli -st，c512/c2048 × chunk128/256，全新缓存，清残留进程）四臂全过（c2048×chunk256：pp 35.8/tg 3.9）。
  "1.85 GB 必失败"边界 = 常驻 ~23 GB llama-server 的污染测量（10-31 重框已疑，今日干净复测坐实），
  叠加三图驱逐与空批短路两个后续修复。里程碑 3.x 的 Q8_0 行同步转 ✅。

## [0.0.1] — 2026-10-31 · 汪柴首个版本

基线 `abb76ab`（llama.cpp）、OpenVINO 2026.4.1。

### 修复 —— 引擎（精度主缺陷，0.0.1 的收官修复）

- **NPU decode 答案质量的根因找到并修复（三问验收 3/3 首次全对）。** 铁证链：decode 图 K 分支
  pre-norm/post-norm 在 NPU 上完全正确（cos 0.997+）→ 缺陷只剩 RoPE；缓存 K 行只有偶数 128 块
  正确（h0/h2 逐位精确、h1/h3 摧毁，256 元素周期）；**位置 0 上 post-rope vs pre-rope 数学恒等，
  NPU 却算出 h1/h3 cos 0.38/0.49** → 静态 decode 图 RoPE 的 cos/sin `[1,1,1,128]` 沿头轴广播到
  `[1,1,4,128]`，在 NPUW 的 1-token（GEMV）形状降级下错误 tile；prefill 同构广播在
  `[1,1,256,4,128]` 上正确，故 prefill 无恙。修复：`rope.cpp` 把 cos/sin 沿头轴显式 Concat tile
  绕开隐式广播；`translate_session.cpp` 把 `AlignEltwiseOperandRanks` 的注册门从 `is_gpu()` 扩到
  gpu/npu/`FORCE_STATIC`——此前 NPU 上所有"tile 无效"实验都是被这扇门挡住的死代码（教训：改
  pass 注册门前，先拿 IR hash 确认 pass 真的在跑）。完整证据链与被证伪假设清单见
  [defect1-rootcause.md](docs/defect1-rootcause.md)。

### 修复 —— 引擎

- **越界 KV 写入（status.md 缺陷 3）根因找到并修复（2026-10-31 验证）。** llama.cpp 的 interleaved-SWA

- **越界 KV 写入（status.md 缺陷 3）根因找到并修复（2026-10-31 验证）。** llama.cpp 的 interleaved-SWA
  缓存为全量缓存与 SWA 子缓存各建一个 KV 写索引输入，且 `build_input_k_idxs()` 把两者命名为同一个
  `attn_inp_k_idxs`；解码器按名字注册参数（先到先得），SWA 的索引张量被全量缓存的同名张量覆盖。窗口层
  于是拿着全量缓存的 cell id（线性长到 `-c`）散射进只有 `n_swa` 大小的环——序列总长一越过 768（LFM3 的
  3×256），CPU 插件死于 `scatter_update.cpp:915` 断言，NPU 插件直接 `ZE_RESULT_ERROR_DEVICE_LOST`；
  `llama-perplexity` 也因此一直无法用作精度指标。这与注意力 mask 的同名冲突是同一类失败（mask 那次已按
  张量身份区分）。最终形态：prefill 图与动态路径按目的缓存所在层加 `_swa` 后缀；**静态 decode 图保持
  单一合并参数**（NPUW 对该图参数表结构敏感，多一个数值等价的参数会让每个 decode 步输出 NaN），越界
  改由图内 `Mod(索引, 环行数)` 处理——环内恒等，越环回绕。改名还要求每相位各自的 decoder 对象
  （`ptr`/`ptr_prefill`），否则一个对象被两相位经 `update_io` 反复重注册后必炸。原生 ggml 后端按张量
  指针绑定，所以从未受影响。修复后 `-p 1024 -n 32 -fa 1` 三条路径全通：原生 605 / OV-CPU 626 /
  NPU 368 t/s（pp1024）。证据：`GGML_OPENVINO_DEBUG_INPUT` 抓到第二 ubatch 的绑定值为 512..1023、
  cgraph 里 SWA 缓存仅 768 行。
- **`GGML_OPENVINO_DEBUG_NODE` 在 NPU 上改为显式拒绝（status.md 缺陷 4，2026-10-31 验证）。** 附加
  `Result` 节点此前会让 NPUW 在编译期死掉；现于 `translate_session.cpp` 直接拒绝并提示改用
  `GGML_OPENVINO_DUMP_BIN`。附带的新测量：在 OpenVINO 2026.4.1 上硬中止不再复现，但带附加 Result 编译
  出的 NPU 图 logits 全 NaN——拒绝同时挡住了一种静默劣化。

### 对照 —— 缺陷 5（异架构模型）

- 补上了缺失的对照模型（2026-10-31）：Qwen3-4B / 1.7B（纯 transformer）。NPU 的数值缺陷在 Qwen3 上同样
  出现（4B 在 `-c 1024` 还会执行期 `OUT_OF_HOST_MEMORY`），所以缺陷跟着"静态 NPU 路径"走，**不是 LFM3
  特有**；4B 放不下这一点也为 Phase 3 的"1–3 B 甜点区"猜想提供了第一个数据点。

### 新发现 —— 驱动状态污染

- 一次执行期的 `ZE_RESULT_ERROR_OUT_OF_HOST_MEMORY` 会把 NPU 驱动带进跨进程存活的坏状态：之后所有进程
  的原始输出回读（`get_output_tensor`）返回 NaN，而绑定缓冲的正常输出路径完全正确——**文本连贯、
  benchmark 正常、`GGML_OPENVINO_DUMP_BIN` 转储全 NaN**。换 DLL 版本、清 blob 缓存均无效；
  `pnputil /restart-device` 可恢复计算路径。见 [troubleshooting.md](docs/troubleshooting.md) 与
  [status.md 缺陷 6](docs/status.md)。

### 修复 —— 工具链

- `tools/build.ps1` 给 `$parallel` 和 `$clean` 赋值，而在 PowerShell 里它们**就是** `[int]$Parallel` 与
  `[switch]$Clean` 这两个参数（变量名大小写不敏感），于是 CI 在编译任何东西之前就死于
  `Cannot convert value "--parallel" to type "System.Int32"`。改名为 `$parallelArg` / `$cleanArg`。

### 更正 —— 文档

- [`docs/npu-internals.md`](docs/npu-internals.md) 里的逐层发散表原本是在 llama.cpp 的**预热** pass 上算的。
  `prefill_0`、`prefill_1`、`decode_2` 在"同一模型、不同 prompt"的两次运行之间逐字节相同，所以那条曲线描述
  的是合成输入，而不是 prompt。已在真实 chunk 上重测并替换（`l0 0.9956 · l9 0.873 · l13 0.534 · l17 0.163`）；
  该节现在以"用哈希比对给 pass 归类"的方法开头，并给出新的线索：**V 精确写入，K 只有第 0 行错**
  （余弦 `0.288`，最大绝对差 `1.06e10`）。
- `docs/env-vars.md` 曾写道 `GGML_OPENVINO_REQUANT_KQUANT` 在 NPU 上无效。在上面那个引擎修复之前这是对的；
  该行现在描述的是这个覆盖行为本身以及如何拒绝它。
- 本文件"已知问题"里的第一条曾引用 warmup 数据（`0.9987 / 0.72 / 0.215`），与上面的更正自相矛盾，已一并
  更正为真实 pass 的数字。

### 新增 —— 测量

- 原生 Q4_0 对照：`LFM3-1.7B-QAD-Q4_0.gguf`（ModelScope `LiquidAI/LFM3-1.7B-GGUF`，核对为 1 049 615 680
  字节）：220 token 的续写在原生 ggml CPU、OpenVINO-CPU 静态和 NPU 上**逐字节一致**；而 64 token 的中文指令
  任务仍然只在 NPU 上退化（conv 状态余弦 `decode_2 0.989 → decode_9 0.51 → 平台期 ≈0.25`，top-1 从第 10 步
  起发散）。作为方法论规律记录在案：**续写任务是通路测试，不是连贯性测试**——设备算错时它照样一致。
- 为多模态阶段编目 `LFM3-Omni-2B-GGUF`：`Q4_0` / `Q4_K_M` / `Q8_0` / `F16` 权重，外加
  `mmproj-LFM3-Omni-2B-{Q8_0,F16,BF16}.gguf` 投影器（540 MB / 950 MB）。

### 修复 —— 构建

- 后端 `CMakeLists.txt` 里的 `find_package(OpenCL REQUIRED)` 让后端在任何没装 OpenCL SDK 的机器上连*配置*
  都过不去（`Could NOT find OpenCL (missing: OpenCL_LIBRARY OpenCL_INCLUDE_DIR)`）——也就是每一台纯 NPU
  机器。这个依赖是虚构的：后端调用的每个 `cl*` 入口点在 `ov_opencl_shim.hpp` 里都有内联桩，所以根本没有
  东西需要链接。现在改为"找到就用、可选"，并且配置步骤会打印它的决定。这个问题之所以在本地开发时没暴露，
  是因为 `PATH` 上某个 CUDA 工具包留下了一份 `OpenCL.lib` 被 `find_package` 捡到；是 CI 发现的。

### 修复 —— 工具链

- `configure.ps1` 与 `build.ps1` 给 `$isWindows` 赋值，而它会在 PowerShell 7 下与只读自动变量 `$IsWindows`
  冲突（名字大小写不敏感）并以 `Cannot overwrite variable IsWindows` 中止。两者在 Windows PowerShell 5.1
  下都正常、在每个 CI runner 上都失败——一次"本地绿、CI 红"，因为子进程 `pwsh -File` 把消息吞了，找了五轮
  才定位。改名为 `$onWindows`；`scripts` CI job 现在会 grep 对只读自动变量的赋值，构建步骤会把捕获到的失败
  以 `::error::` annotation 重新抛出，于是真实那行能通过公开的 check-runs API 看到。
- CI 安装 `cmake<4`（CMake 4 移除了 `cmake_minimum_required(<3.5)` 兼容，而 llama.cpp vendored 的项目与
  OpenVINO 打包的 config 文件仍然声明着它），并且 `configure.ps1` 在检测到 CMake ≥ 4 时传
  `-DCMAKE_POLICY_VERSION_MINIMUM=3.5`。
- `compare-tensors.ps1`：跳过 `.txt` 边车文件（自定义 `-Filter` 会把它们当 f32 读，于是报告里全是 `3e+32`
  的张量）；`Top-K` 现在受比对前缀长度约束（它以前为了打印 5 个数字去给几 MB 的缓冲区排序）；新增
  `-RowSize`/`-MaxRows`/`-RowTol` 行模式——这正是让 KV 缓存比对变得有意义的前提，因为对一个 chunk 根本没写过的
  行做整缓冲区统计毫无意义。

### 新增 —— 仓库

- `src/ggml-openvino/` 现在**纳入版本管理**：完整的后端目录（95 个文件）带着汪柴的改动，于是引擎可以在
  "什么都不用应用"的前提下被直接阅读。`tools/bootstrap.ps1` 把钉住版本的 llama.cpp 克隆进 `src/llama/`
  （仍被 git 忽略）并用这个目录覆盖之，随后打印 `git diff --stat` 作为"代码确实落地了"的证据。`patches/`
  保留下来作为可评审的 diff 与上游化产物；`bootstrap.ps1 -UsePatch` 切回打补丁路径。来源与改动规矩见
  `src/ggml-openvino/WANGCAI.md`。
- README 改为中文为主，`README_en.md` 作为次要语言文档。

### 新增 —— 构建

- `patches/ov_opencl_shim.hpp`：`<CL/cl.h>` 与 `openvino/runtime/intel_gpu/ocl/ocl.hpp` 的自包含替身。
  OpenVINO 后端从 `ggml-openvino.cpp`、`utils.cpp` 与 `ggml-openvino-extra.{h,cpp}` include 了这些头文件，
  使得纯 NPU 构建需要 Khronos 的 `cl2.hpp` 与 GPU SDK——而这两样在干净的 Build Tools 安装上都不存在。shim
  声明了编译那段只服务于 GPU 的远程上下文代码所需的少量 OpenCL typedef、互不相同的不透明句柄类型与内联桩，
  而 NPU 从不执行那段代码。结果：OpenVINO 后端能从一个干净的 Visual Studio Build Tools + OpenVINO 运行时
  安装直接构建，全程见不到 GPU SDK。
- `GGML_OPENVINO_NPU_COMPILE_OVERRIDES=KEY=VALUE,...`：在运行期新增或替换 NPU 编译配置里的顶层条目。没有它，
  要回答"是不是这一个 flag 的问题"就得每个 flag 重编一次，而 NPU 图编译慢到（LFM3-1.7B 冷启动约 36 s）一次
  扫描要花掉几小时。
- `GGML_OPENVINO_DUMP_BIN=<dir>`：把一次 compute 调用的每个图输出写成原始的
  `<dir>/<tag>_<seq>_<name>.bin`，外加一个记录形状与元素类型的 `.txt` 边车；静态与动态路径都支持。与
  `GGML_OPENVINO_DEBUG_NODE` 不同，它不追加 `Result` 节点——这点要紧，因为追加额外输出时 NPU 插件会让整个
  进程中止。
- `GGML_OPENVINO_MASK_MODE=1`：在静态 prefill 路径上，用 token 位置构造注意力 mask，而不消费 llama.cpp
  递过来的 mask。加它是为了把"mask 内容错了"与"图被错误执行"分开；在这个模型上它证明了 mask 是无辜的。
- `tools/`：`configure.ps1`、`build.ps1`、`run-npu.ps1`、`npu-sweep.ps1`、`compare-tensors.ps1`、
  `top-token.ps1`。

### 新增 —— 正确性

- `GgmlOvDecoder::get_mask_ctx_size()`：决定一个注意力 mask 输入必须有多宽的唯一一处。混合结构模型交给后端的
  是每个注意力模块一块 mask、并补齐到模型里*最大*的那块 KV 缓冲区，而每一层实际只对各自的缓存做注意力。动态图
  下 K 会被切片去迁就 mask；静态（NPU）图下两个形状都被焊死，于是窗口层需要环长、全局注意力层需要上下文长度。
  编译进参数的形状与为主机构建用于绑定的张量，现在都从同一个函数推导；此前它们各算各的、可以不一致——NPU
  插件会用 `input tensor size is not equal to the model input type` 拒绝它，opset-13 的 SDPA 会用
  `attention_mask_input_correctness` 拒绝它。
- `openvino/op/flash_attn_ext.cpp` 里的 `trim_mask_to_kv()`：把比 K 操作数更宽的 mask 裁到 KV 范围，并遵守
  `seq_active_start`，作为"两者仍然不一致"那些情况的护栏。

### 修复

- LFM3-1.7B（13 门控短卷积 + 5 滑动窗口@256 + 6 全局注意力层）此前在 NPU 设备上连图都建不出来。现在两张图
  （分块 prefill 与单 token decode）都能编译，并能在 `Intel(R) AI Boost` 上端到端生成。

### 已知问题

- 精度缺陷的逐层测量（真实 chunk 上的 conv 状态输出）：余弦从 `l0 0.9956` 一路到 `l9 0.873`、`l13 0.534`、
  `l17 0.163`。误差在第一层就存在并被复利放大，所以它是逐算子的精度问题——既不是图深处某个坏掉的算子，也不是
  状态记账。K/V 侧几乎干净：V 精确，K 除第 0 行外都在 `0.90–0.9998`。
- NPU 输出与 CPU 参照尚未数值对齐：与参照 logits 的余弦在 prefill 结束时是 `0.969`、在前几个解码步是
  `0.73–0.79`，且 logit 分布被明显压平（top-1 在 CPU 是 `19.58`、在 NPU 是 `17.53`）。贪心解码与参照一致
  2–3 个 token 后发散。已排除项见 [docs/npu-internals.md](docs/npu-internals.md)。
- NPU 解码吞吐（`8.3–8.7 t/s`）比 CPU 参照（`54.1 t/s`）低 6 倍、比 CPU 上的 OpenVINO
  （`21.7–29.2 t/s`）低 2.5 倍——约为可用 TOPS 的 0.03。预填充并**没有**以同样的方式受影响
  （`pp512` 415 t/s，对比原生 570），这把问题定位到每步路径，而不是整体的编译配置。
- 比 KV 缓存更长的序列会把 OpenVINO 后端拖垮：任意设备上的 `llama-perplexity`，以及 1024 上下文下的
  `llama-bench -p 1024 -n 32`，都会以
  `Check 'idxValue < static_cast<int64_t>(srcDimAxis) ...' failed at intel_cpu\src\nodes\scatter_update.cpp:915`
  失败——一个越界的 KV 写入索引。同样形状在 `-p 512` 下跑得干净。在 NPU 上，同样的条件不报检查失败，而是
  产生 `ZE_RESULT_ERROR_DEVICE_LOST`（`zeCommandQueueExecuteCommandLists`，`0x70000001`）。这挡住了把
  perplexity 用作精度指标。*（此处早前有一条把原因归咎于多输出图；`-p 512` / `-p 1024` 的差分不支持那个说法，
  故已撤回。）*

### 更正

- 此前公布的 NPU prompt-eval 数字（`6.0–12.2 t/s`）是一个假象，不是对加速器的测量。静态 prefill 图永远是
  `GGML_OPENVINO_PREFILL_CHUNK_SIZE`（256）列宽，所以 4 个 token 也要付 256 列的钱，而 llama.cpp 上报的是有效
  token 每秒——比图自身的列吞吐低了 60 倍。在真实 token 数下测量，NPU 在 `pp512` 达到 **415 t/s**（OpenVINO-CPU
  的 68%、原生参照的 73%）。NPU 上短 prompt 的 prompt-t/s 根本不该与 CPU 数字对比；见
  [docs/benchmarks.md](docs/benchmarks.md)。
- 通过 `GGML_OPENVINO_DEBUG_NODE` 追加图输出会在 NPU 上让进程中止。改用 `GGML_OPENVINO_DUMP_BIN`，它读的是
  已有的输出。

### 关于被推翻假设的备注

记下来，免得再有人为它烧一周：

- **权重重量化不是原因。** 在 NPU 上后端把所有非 embedding 重量化成 `Q4_0_128`（group 128，对称），而 CPU
  保持原生 `Q4_K`。在 CPU 上强制同样的重量化后输出依然连贯，所以单靠重量化解释不了这个缺陷。*（补充：两侧
  策略对齐后，最差 conv 状态从 `0.215` 升到 `0.9589`——原来三分之二的差距来自"两台设备加载了两个不同的模型"。）*
- **chunk 尺寸不是原因。** `GGML_OPENVINO_PREFILL_CHUNK_SIZE` = 1 / 2 / 7 / 32 / 128 / 256 表现一致。
- **mask 内容不是原因。** `GGML_OPENVINO_MASK_MODE=1`（按位置推导的因果 mask）让 CPU 静态路径保持连贯，
  NPU 依旧错。
- **多列卷积不是原因。** 单 token prompt 执行的是同一张补到 256 列的 prefill 图，在 NPU 上连贯。
- **没有任何 NPUW 开关能修好它。** `NPU_USE_NPUW=NO` 编译不过；
  `NPU_COMPILER_DYNAMIC_QUANTIZATION=NO` 死于 `ZE_RESULT_ERROR_OUT_OF_HOST_MEMORY`；`NPUW_DQ=NO`、
  `NPUW_DQ_FULL=YES`、`NPUW_FOLD=NO` 让生成塌缩成重复的同一个 token；`NPUW_WEIGHTS_BANK=none` 无变化。
  这个缺陷在所有有文档记载的开关下都存活。
- NPU 上 `GGML_OPENVINO_STATEFUL_EXECUTION=1` 没有帮助（有状态模式按设计只支持 CPU/GPU）。
- `-fa 0` 在 NPU 上是死路：强制走非 SDPA 路径会让 llama.cpp 有意把 V 摊成每行一个元素
  （`llama_kv_cache.cpp`），随后 scatter 写回就会拒绝该索引。

[Unreleased]: https://github.com/liangjianzeng/WangCai

### 修复 —— 4B NPU decode 性能（性能轮：2.4 → 4.9 t/s）

- **根因（level 预算三图问题）**：NPU 设备预算 = prefill + 一张 decode 图（权重 bank 按
  CompiledModel 计），而 prefill 在新 entry 上还会预编 legacy 全 ctx decode 图——三图常驻。
  1.7B 模型三张权重 bank 装得下（LFM3 的 levels 一直正常），4B 必爆：level 图编译成功后首个
  execute 即 `ZE_RESULT_ERROR_UNINITIALIZED`，自动降级后每步都跑全 ctx 图（436 ms/step）。
- **修复**（utils.cpp）：levels 激活时 prefill 跳过 legacy decode 预编；level 编译时连同
  legacy 图一并驱逐（fallback 重进按需重编）；level==0 的 cache_hit 按相位拆分（并修复
  复用检查解引用 null decoder 的段错误）。
- **实测**（热缓存稳态）：Spark-X2.6-4B 2.4 → **4.9 t/s**（raw infer 436→~150 ms）、
  Qwen3-4B 2.3 → **4.0 t/s**、LFM3-1.7B 13–15 t/s 无回归；三模型 NPU 三问验收全 3/3。
- **剩余**：~200 ms/步为 36 层标准注意力的算子降级开销 + 权重带宽下限（~7 t/s）；杠杆与
  排查链（PROFILING 分解、算子级 CSV、ctx 对照）见 HANDOFF 2026-11-01 性能轮。
