# 汪柴 Windows 打包（便携包 + 安装包）

单一入口是 `build-installer.ps1`（版本串以脚本内 `$ver` 为准，当前 0.0.6）；
`wangcai-setup.iss` 只从脚本组装的 `stage\` 取料，不再各走各的源（2026-11-06 对齐）。

## 构建

```powershell
# 前置：Flutter 3.27、本仓库；**先退出运行中的 WangCai.exe**（staging 复制会撞文件锁）；
# Inno Setup 6 可选——装了才产出 Setup.exe，没装只出便携包并在日志里提示。
powershell -ExecutionPolicy Bypass -File packaging/build-installer.ps1
# 产物 1：packaging/dist/WangCai-<ver>-win-x64-portable.zip （解压即用）
# 产物 2：packaging/dist/WangCai-<ver>-win-x64-Setup.exe    （Inno Setup，每用户安装）
```

脚本四步：`flutter build windows --release` → 组装 `stage\`（壳 Release + 引擎
`src/llama/build/bin` 全部 dll/manifest + `llama-server*.exe` + OpenVINO 运行时）→
便携 zip → （可选）ISCC 出 Setup.exe。

OpenVINO 运行时源由脚本统一裁决：仓库 vendored `ov/openvino/libs` 优先，回落本机
`E:\dev-tools\ov\openvino\openvino\libs`；两边都没有 `openvino.dll` 直接报错停包
（只带 ggml-openvino.dll 壳 = llama-server 起不来，v0.0.3 定案）。

## 包内容（安装器形态）

| 目标位置 | 内容 | stage 来源 |
|---|---|---|
| `{localappdata}\Programs\WangCai\` | Flutter 壳（WangCai.exe + dll + data） | `stage\App\` |
| `{userappdata}\WangCai\engines\wangcai\` | 汪柴引擎（llama-server + 全部运行期 dll/manifest，漏哪个都 0xC0000135） | `stage\Engines\wangcai\` |
| `{userappdata}\WangCai\engines\wangcai\ovlibs\` | OpenVINO 运行时（含 NPU 插件/tbb） | `stage\Engines\wangcai\ovlibs\` |

便携包同布局（`App\` + `Engines\wangcai\`），解压后直接跑 `App\WangCai.exe`。

引擎二级解析：`WANGCAI_SERVER_EXE` env > `{userappdata}\WangCai\engines\wangcai\` >
开发机 repo（见 `lib/platform/wangcai_paths.dart`）。

## 语义

- **每用户安装**（`PrivilegesRequired=lowest`，无需管理员；卸载项在 HKCU）。
- 可选任务：桌面图标、开机自启（写 HKCU Run；运行期也可在 App 内开关）。
- 卸载：清壳与 `engines\wangcai`；**用户数据保留**（会话库/绑定表/编译缓存/模型库）。

## Linux 打包（deb + tar.gz，2026-11-10 新增）

**定位**：Linux 端是**远端客户壳**（口径见 `docs/image-gen-integration-plan.md`
与 README 系统行）——模型引擎/生图走局域网 HTTP，NPU/OpenVINO/托盘等在本仓
已有平台守卫、Linux 自动降级。所以 **Linux 包不含引擎**（区别于 Windows 包），
纯 Dart 壳，产物 `WangCai-<ver>-linux-<amd64|arm64>.{deb,tar.gz}`。

**一次性环境**（Ubuntu 22.04 系；Flutter 固定 3.27.0 与 Windows 侧一致）：

```bash
bash packaging/linux/wsl-setup.sh        # apt 依赖 + Flutter → $HOME/flutter + precache
# WSL 无免密 sudo 时拆两步：
#   wsl -u root  <apt 段>   或   SKIP_APT=1 bash packaging/linux/wsl-setup.sh
```

**构建 + 组包**（`packaging/build-linux.sh`，x64/ARM64 同一份，架构自动）：

```bash
# 必须 ext4 工作区（/mnt/c、/mnt/e 跨 fs 构建慢一个数量级）：
rsync -a --delete --exclude .git --exclude /src --exclude build \
      --exclude .dart_tool /mnt/e/DTXY/WangCai/ ~/wc-build/
# /src 必须带斜杠锚定根目录（裸 src 会连 packages/*/lib/src 一起排掉）。
bash ~/wc-build/packaging/build-linux.sh
cp ~/wc-build/packaging/dist/WangCai-* /mnt/e/DTXY/WangCai/packaging/dist/
```

**DGX Spark（ARM64）原生构建**：同一套脚本，在 DGX 的 Ubuntu（aarch64）上
`git clone` 本仓 → `bash packaging/linux/wsl-setup.sh`（有 sudo，一把跑完）→
`bash packaging/build-linux.sh`（DGX 上仓库本就在 ext4，跳 rsync）。产物自动
命名 `-linux-arm64`。**不要**在 x64 WSL 交叉编译 ARM64（multiarch 工具链不值
当，DGX 原生更快）。

**安装**：`sudo apt install ./WangCai-<ver>-linux-amd64.deb`（依赖自动拉：
libgtk-3-0 / libsecret-1-0 / xclip|wl-clipboard）；便携包解压跑
`WangCai-<ver>-linux-<arch>/wangcai`。

**WSL 构建踩坑记录（Git Bash 侧）**：① 向 `wsl.exe` 传 `/mnt/...` 裸路径会被
MSYS 转换成 `C:/Program Files/Git/mnt/...`——路径必须包进带引号的
`bash -c "…"` 整串；② 复杂命令带 `(`/PATH 注入同理炸解析，一律走**脚本文件**；
③ WSL 用户无免密 sudo → apt 用 `wsl -u root` 或脚本 `SKIP_APT=1`。

## 已验证 / 待人工

- ✅ 本机（有 VS/OV 开发环境）`flutter build windows` + 路径解析单测
  （`app/test/platform/wangcai_paths_test.dart`：安装位优先于 repo）；
  便携包干净进程自测 DLL 闭合（v0.0.4/v0.0.5 均出包实机跑过）。
- ⬜ **干净机装机验证**（无 VS / 无 OV 运行时 / 无 repo）—— 需人工在干净
  Windows 机器执行安装并跑一次 NPU 问答（DoD §9 M4 最后一条）。
- ⬜ iss↔ps1 取料改走 stage 后（2026-11-06），Setup.exe 未重新产出实包验证；
  下次发布跑 ps1 时一并确认。
