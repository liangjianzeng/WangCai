# 汪柴 Windows 安装包（v0.0.2 · M4）

## 构建

```powershell
# 前置：Inno Setup 6（ISCC.exe 在 PATH 或默认安装位）、Flutter 3.27、本仓库
cd app
flutter build windows --release
cd ..\packaging
ISCC wangcai-setup.iss
# 产物：packaging/dist/WangCai-0.0.2-win-x64-Setup.exe
```

## 包内容

| 目标位置 | 内容 | 来源 |
|---|---|---|
| `{localappdata}\Programs\WangCai\` | Flutter 壳（WangCai.exe + dll + data） | `app/build/windows/x64/runner/Release/` |
| `{userappdata}\WangCai\engines\wangcai\llama-server.exe` | 汪柴引擎（NPU 驱动） | `src/llama/build/bin/` |
| `{userappdata}\WangCai\engines\wangcai\ovlibs\*` | OpenVINO 运行时（含 NPU 插件/tbb） | `ov/openvino/libs/` |

引擎二级解析：`WANGCAI_SERVER_EXE` env > `{userappdata}\WangCai\engines\wangcai\` > 开发机 repo（见 `lib/platform/wangcai_paths.dart`，M4 起支持安装器形态）。

## 语义

- **每用户安装**（`PrivilegesRequired=lowest`，无需管理员；卸载项在 HKCU）。
- 可选任务：桌面图标、开机自启（写 HKCU Run；运行期也可在 App 内开关）。
- 卸载：清壳与 `engines\wangcai`；**用户数据保留**（会话库/绑定表/编译缓存/模型库）。

## 已验证 / 待人工

- ✅ 本机（有 VS/OV 开发环境）`flutter build windows` + 路径解析单测
  （`app/test/platform/wangcai_paths_test.dart`：安装位优先于 repo）。
- ⬜ **干净机装机验证**（无 VS / 无 OV 运行时 / 无 repo）—— 需人工在干净
  Windows 机器执行安装并跑一次 NPU 问答（DoD §9 M4 最后一条）。
- ⬜ ISCC 未装时本机无法出最终 exe；装 Inno Setup 6 后按上文两行命令产出。
