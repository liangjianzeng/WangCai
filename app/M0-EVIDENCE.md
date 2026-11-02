# M0 Spike 证据（assistant-v0.0.2-design §9）

日期：2026-11-02 · 机器：RTX 5060 Ti + Intel iGPU + AI Boost NPU · Flutter 3.27.0 / Dart 3.6.0

## M0-0 环境 · ✅

- Flutter `C:\src\flutter`（3.27.0 stable），Windows desktop 已启用。
- VS BuildTools 2022（D 盘）初检**不完整**：缺 `Microsoft.VisualStudio.Workload.NativeDesktop`
  （flutter 硬要求）。经 `vs_installer modify --add ... --quiet` 补装后 `[√]`。
  日志：`tmp/vslogs/dd_installer_elevated_20261102125321.log`。
- **开发机前置清单**（写进装机文档候选）：①开发者模式（符号链接，Flutter 插件构建硬前提，
  `AppModelUnlock/AllowDevelopmentWithoutDevLicense=1`）；②VS NativeDesktop workload；
  ③**VC.ATL/VC.ATLMFC 组件**（`flutter_secure_storage_windows` 用 ATL，`atlstr.h` C1083；
  NativeDesktop 的推荐集不含，需单独 `vs_installer modify --add`）。
- 教训入档：`flutter build ... | tail` 会把 flutter 真实退出码吞成 tail 的 0——
  所有 CI/脚本构建必须 `flutter build > log 2>&1; echo FLUTTER-EXIT=$?` 形式留真码。

## M0-3 llama-server (NPU) 手聊 · ✅

启动（同 run-npu.ps1 的 env 语义，端口 8123，缓存目录 `tmp/cache_m0_server_npu`）：

```
llama-server.exe -m models/LFM3-1.7B-Q4_K_M.gguf -c 1024 --temp 0 --seed 42 \
  -np 1 -fa 1 -dev OPENVINO3 --jinja --host 127.0.0.1 --port 8123
→ 20s 后 /health = {"status":"ok"}（日志 tmp/m0_server.log：model loaded / listening）
```

- **发现 #1**：`-st` 是 **llama-cli 专属** flag，server 传了直接 `invalid argument`。
  server 端 manifest 参数集应为 `-fa 1 -np 1 -dev OPENVINO3 --jinja`（设计 §4.1 的
  argsTemplate 本就未含 `-st`，M1 实现时不得从 run-npu.ps1 抄入）。
- **发现 #2**：该模型 chat 模板是 thinking 风格，回答进 `reasoning_content`；tool 调用需
  `max_tokens` 给足（64 token 时只 think 不 emit，512 时正常吐出）。Agent 档位默认预算要按此设。

文本对话（tmp/m0_req_chat.json）：

```
content 正常返回；decode = 14.75 t/s（与 status.md 记录的 LFM3-1.7B NPU 14.7 t/s 吻合）
prefill：首包 1.84 t/s（冷编译计入），热态 31.7–38.3 t/s
```

原生 tool_calls（tmp/m0_req_tool_v2.json，`--jinja`）：

```json
"finish_reason":"tool_calls"
"tool_calls":[{"function":{"name":"get_weather","arguments":"{\"city\":\"北京\"}"}}]
```

中文参数原样保留 → **NativeToolProtocol 通路成立**（M1 Agent 关键依赖）。

## M0-3.附 孤儿进程实测（验证设计 §3 的必要性）

`TaskStop` 杀掉启动用的 bash 外壳后，`llama-server.exe` 以**孤儿进程存活**（PID 13976，
`Get-Process llama-server` 可见）。→ M1 `LlamaServerHost` 的
`port.json 账本 + 壳启动清扫 + 优雅停机（/health 反查 PID）`不是可选项，是硬需求。

## M0-1 app/ 工程 + Dart 导入 · ✅

- `flutter create --platforms=windows` + TongYi-Lite v0.3.7（基线 `50fc164`）Dart 同路径导入，
  **181 个 Dart 文件 Release 编译一次通过**：`√ Built build\windows\x64\runner\Release\WangCai.exe`
  （日志 `tmp/m0_build2.log`，FLUTTER-EXIT=0）。
- 导入治理：`lib/arm64-v8a/libapp.so`（6.5MB Android 遗留）剔除；pubspec `name: tongyi_lite`
  保持不变（import 路径与上游逐字一致）；CMake 产物名 → `WangCai`；账本见 `UPSTREAM.md`。

## M0-2 托盘冒烟 · ✅（发现 3 个 M1 必用坑）

Release 形态自动时间线全绿（`m0_tray_smoke.log`）：

```
13:18:04 launched: tray icon+menu ready, window shown
13:18:07 hidden-to-tray → 13:18:10 alive-while-hidden（驻留 3s 存活，核心 DoD）
13:18:10 shown-again → 13:18:12 close→hide-to-tray 拦截 → 13:18:14 拦截后存活 → 干净退出
```

三个实测坑（M1 `platform/` 实现必须照此做）：

1. **关窗拦截必须 `windowManager.setPreventClose(true)`**——只 override `onWindowClose`
   不生效：Release 关窗 = 整个 app 退（code 0），Debug 段错误。退出路径 =
   `_quitting=true → setPreventClose(false) → destroy()`。
2. **关窗 = 直接 `hide()`**，不悬挂 close 请求（拦截后不打理的写法 Debug 段错误）。
3. `exit(0)` 在 debug 引擎退出段错误；托盘菜单"退出"走 destroy，不用 exit()。
   另：tray_manager 0.2.x 无 `TrayManager.dispose()`。

## M0-4 sherpa_onnx DLL · ✅

- 打包：Release 目录含 `sherpa-onnx-c-api.dll` + `onnxruntime.dll`（构建经 NuGet 自动拉取）。
- 运行时：`dart run tool/sherpa_check.dart` → `dll loaded` + **`sherpa-onnx version: 1.13.8`**
  （与 pubspec 约束 1.13.8 一致）。ASR/TTS 的 Windows 路打通。

## M0-5 sqflite ffi 测试 · ✅（附债务归属判定）

- 目标测试 `test/services/storage_service_test.dart`：**All tests passed**（sqflite_common_ffi +
  Release 目录 `sqlite3.dll`，宿主 VM 直跑）。
- 全量套件：**1147 通过 / 6 跳过 / 6 失败**（日志 `tmp/m0_test_full.log`）。
- 失败判定：4 个失败（`thinking_runaway_test`×2、`model_catalog_test`、
  `agent_stream_processor_test`）在**上游 TongYi-Lite 同跑同样失败** → 上游既有债，
  非 Windows 移植回归。处置：记入上游修复清单，M1 收编 `AgentStreamProcessor` 时一并修。
