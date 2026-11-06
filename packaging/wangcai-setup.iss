; 汪柴 v0.0.5 安装包（Inno Setup 6；设计 §8/§9 M4）。
; 每用户安装（无管理员权限；卸载清 HKCU\Software\WangCai 由 Uninstall 清理项覆盖）。
; 产物：WangCai-0.0.5-win-x64-Setup.exe
;
; 构建步骤（packaging/build-installer.ps1 自动化，**唯一入口**）：
;   1. cd app && flutter build windows --release
;   2. 组装 staging：stage\App\* + stage\Engines\wangcai\*（含 ovlibs；OV 源由
;      ps1 统一裁决：仓库 vendored ov\openvino\libs 优先，回落本机 dev-tools）
;   3. ISCC wangcai-setup.iss —— 本文件一律从 stage\ 取料（2026-11-06 对齐：
;      此前直取 src\llama\build\bin 并硬编码 E:\dev-tools，与 ps1 的 OV 解析
;      成两条链——vendored 副本修正形同虚设、无 dev-tools 机器直接出不了包）。

#define MyAppName "汪柴"
#define MyAppNameEn "WangCai"
#define MyAppVersion "0.0.5"
#define MyAppExe "WangCai.exe"

[Setup]
AppId={{7C1B7E60-9C4A-4E0D-9A2E-WANGCAI00002}
AppName={#MyAppName} ({#MyAppNameEn})
AppVersion={#MyAppVersion}
AppPublisher=WangCai
DefaultDirName={localappdata}\Programs\WangCai
DefaultGroupName={#MyAppName}
UninstallDisplayIcon={app}\{#MyAppExe}
OutputBaseFilename=WangCai-{#MyAppVersion}-win-x64-Setup
OutputDir=dist
Compression=lzma2/max
SolidCompression=yes
PrivilegesRequired=lowest
ArchitecturesInstallIn64BitMode=x64compatible
WizardStyle=modern
; 引擎文件放数据区（升级不丢用户引擎目录之外的配置）
SetupLogging=yes

[Tasks]
Name: "desktopicon"; Description: "创建桌面快捷方式"; GroupDescription: "附加任务："
Name: "autostart"; Description: "开机自动启动汪柴"; GroupDescription: "附加任务：" ; Flags: unchecked

[Files]
; 全部取料自 packaging\stage\（由 build-installer.ps1 组装，见文件头）。
; 1) Flutter Windows 壳
Source: "stage\App\*"; DestDir: "{app}"; Flags: recursesubdirs ignoreversion
; 2) 汪柴引擎包：全部运行期 dll/manifest（ggml*/llama/mtmd/impl——漏哪个
;    都 0xC0000135）+ llama-server 可执行 → {userappdata}\WangCai\engines\wangcai\
Source: "stage\Engines\wangcai\*.dll"; DestDir: "{userappdata}\WangCai\engines\wangcai"; Flags: ignoreversion
Source: "stage\Engines\wangcai\*.manifest"; DestDir: "{userappdata}\WangCai\engines\wangcai"; Flags: ignoreversion
Source: "stage\Engines\wangcai\llama-server*.exe"; DestDir: "{userappdata}\WangCai\engines\wangcai"; Flags: ignoreversion
; 3) OpenVINO 运行时 DLL → {userappdata}\WangCai\engines\wangcai\ovlibs\
Source: "stage\Engines\wangcai\ovlibs\*"; DestDir: "{userappdata}\WangCai\engines\wangcai\ovlibs"; Flags: recursesubdirs ignoreversion

[Icons]
Name: "{group}\{#MyAppName}"; Filename: "{app}\{#MyAppExe}"
Name: "{autodesktop}\{#MyAppName}"; Filename: "{app}\{#MyAppExe}"; Tasks: desktopicon

[Registry]
; 开机自启（可选任务）：HKCU 不需要管理员
Root: HKCU; Subkey: "Software\Microsoft\Windows\CurrentVersion\Run"; ValueType: string; ValueName: "WangCai"; ValueData: """{app}\{#MyAppExe}"""; Flags: uninsdeletevalue; Tasks: autostart

[Run]
Filename: "{app}\{#MyAppExe}"; Description: "启动 {#MyAppName}"; Flags: nowait postinstall skipifsilent

[UninstallDelete]
; 引擎目录整体清掉（用户模型/绑定库保留——engines 之外的数据不动）
Type: filesandordirs; Name: "{userappdata}\WangCai\engines\wangcai"
