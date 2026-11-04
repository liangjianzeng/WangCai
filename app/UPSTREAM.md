# Dart 同步账本（UPSTREAM）

> **⚠️ 已独立（2026-11-04 用户定案）**：桌面条线脱离上游 TongYi-Lite，独立项目、独立演进。
> `pubspec name` 已改 `wangcai`，包名对齐纪律不再适用；**不再向上游回流、不再按基线搬运**。
> 本文件保留作导入历史与分叉清单（#1–#10）存档；「回流纪律」章节自本日起失效。
> 独立化决策记录见 `docs/assistant-v0.0.2-design.md` §12（v0.0.3）。

壳的 Dart 代码自 TongYi-Lite **同路径 vendored 导入**（设计 §1 D1）。历史同步纪律：
搬运 = 按基线 commit 做 diff/cherry-pick，Windows 分叉一律记录在下方清单，禁止无痕改动。

## 基线

| 项 | 值 |
|---|---|
| 上游仓库 | `E:\DTXY\TongYi-Lite` |
| 基线 commit | `50fc1643db6e6f098192a38e815e7a02943e9ee9`（2026-11-02 导入时 HEAD） |
| pubspec `name` | 保持 `tongyi_lite` 不改——`package:tongyi_lite/...` import 路径与上游逐字一致，diff 才能干净 |

## 导入范围

| 路径 | 处理 |
|---|---|
| `lib/` | 全量同路径拷贝（Android 用 `lib/arm64-v8a/*.so` 不导入，见分叉清单 #1） |
| `test/` | 全量同路径拷贝 |
| `packages/plugin_kernel`、`packages/plugin_sdk` | 拷贝（pubspec path 依赖） |
| `third_party/dartssh2`、`third_party/edge_tts`、`third_party/sherpa_onnx_web` | 拷贝（dependency_overrides） |
| `third_party/{llama.cpp,kleidiai,mesa-kgsl,OpenCL-Headers,opencl-stub}` | **不导入**（Android/NDK 构建资产） |
| `assets/models_catalog.json` | 拷贝 |
| `analysis_options.yaml` | 拷贝 |
| `android/**`、`build.gradle.kts`、JNI/cpp | **不导入**（Windows 下由 llama-server 子进程取代，设计 §1 D2） |

## 本地分叉清单（相对上游的有意差异）

| # | 文件/位置 | 改动 | 原因 |
|---|---|---|---|
| 1 | `lib/arm64-v8a/` | 导入时删除 | Android NDK 产物，Windows 无用且会被打进 bundle |
| 2 | `pubspec.yaml` | 版本 `0.0.2+1`；新增 `window_manager`/`tray_manager`/`sqlite3_flutter_libs`；`sqflite_common_ffi` 从 dev 提升为运行期依赖；`background_downloader` 保留但标 TODO（M2 移除） | 设计 §3 / §2.2 / §1 版本策略 |
| 3 | `windows/CMakeLists.txt` | 产物名 `wangcai_app` → `WangCai` | exe 命名拍板（2026-11-02） |
| 4 | `lib/engine/**`、`lib/platform/**` | Windows 新增件（M1 起），上游无对应物 | 设计 §2.3 |
| 5 | `lib/tray_smoke.dart`、`tool/sherpa_check.dart` | M0 Spike 冒烟/验证工具，上游无对应物 | 设计 §9 M0 |
| 6 | `eval/`（scoring/score_traces/tasks.json） | 导入范围补漏：上游顶层目录，`test/agent/eval_scoring_test.dart` 直接引用 | M1-a 全量测试暴露 |
| 7 | `test/plugins/plugin_host_dispose_test.dart` tearDown | 临时目录递归删除加 20×50ms 重试 | Windows 迟写文件与删除竞争（errno 145），上游 Android 无此现象 |
| 8 | `lib/screens/settings_screen.dart` 推理引擎 Tab 顶部 | 仅插 2 行：import + `if (Platform.isWindows) const EngineManagerSection()`；新 UI 全部在新增文件 `lib/screens/engine_manager_section.dart` | 设计 §2.3 M1-b，最小化与上游 diff |
| 9 | `lib/providers/settings_provider.dart` `_load`/`_persist` | 共约 8 行：API key 迁安全存储+内存叠加（_load）、落盘前清洗（_persist）；实现全在新增件 `lib/services/api_key_store.dart` | 设计 §6.1，密钥不落 settings JSON 明文 |
| 10 | vendored 接线总账（M1-c 起） | `lib/main.dart`+`lib/screens/home_screen.dart`（initInferenceEngine 门控初始化）；`lib/providers/shared_providers.dart`（inferenceServiceProvider 类型改 InferenceBackend）；`lib/providers/chat_provider.dart`/`model_provider.dart`/`lib/plugins/local_adapter.dart`/`lib/agent/llm/host_llm.dart`（类型换 InferenceBackend）；`lib/services/inference_service.dart`（implements InferenceBackend）；`lib/services/model_storage_service.dart`（4 处 Platform.isWindows 分支走 WangCaiPaths） | 设计 §2.3 D2/D3：平台分支唯一化到 inference_gateway |

## M0 实测记入的上游债务（非移植回归，上游同跑同挂）

- `test/agent/thinking_runaway_test.dart`（2 例）、`test/models/model_catalog_test.dart`、
  `test/providers/agent_stream_processor_test.dart`（1 例）——上游 TongYi-Lite 同样失败。
  修复归上游；本仓 M1 收编 `AgentStreamProcessor` 时顺带对齐。

## 回流纪律

上游（Android）改 `lib/` 共享代码时：`git -C E:/DTXY/TongYi-Lite diff <基线>..<新基线> -- lib/ test/`
逐文件搬运，Windows 侧改动点以本清单为准；清单外冲突默认上游赢，除非改动落在清单 #4 目录。
