# 换机测试工作交接（2026-11-06 深夜快照）

> 给拿着便携包去第二台机器（或新会话继续排障）的人。半页看完能干活，细节有指针。

## 0. 一句话现状
全局 ctx 单口子 + Omni 深层崩速手术（摘 `DISABLE_DECODE_LEVELS=1`）已入库推送；
便携包 = `packaging/dist/WangCai-0.0.5-win-x64-portable.zip`（解压即用，含引擎全家+OV 运行时）。
本机已验：锦全绿（含 4096 放行回归锚）；**待验**：Omni 新包速度/复读复验 + 换机全套。

## 1. 物料
- **便携包**：`packaging/dist/WangCai-0.0.5-win-x64-portable.zip`（约 108MB，layout：`App/WangCai.exe` + `Engines/wangcai/`）。重打 = `powershell -ExecutionPolicy Bypass -File packaging/build-installer.ps1`（**flutter 不在 PATH 时先** `$env:PATH='E:\dev-tools\flutter\bin;'+$env:PATH`）。打包前必须退掉运行中的 WangCai.exe（文件锁 → 构建假死）。
- **模型**（换机要自带或 App 内下载，ModelScope catalog 已配好）：
  `LFM3-1.7B-Q4_K_M.gguf`、`LFM3-Omni-2B-Q4_0.gguf`（+mmproj）、`Spark-X2.6-4B-Q4_K_M.gguf`。
  放 `%APPDATA%\WangCai\models\`。
- **离线矩阵工具**（排障主力，换机可复用）：`E:\Work\WangCai\tmp\omni-matrix\run-matrix.sh`（v3：
  端口守卫 + /props 串台守卫 + 单实例锁；派生法见 `run-queue2.sh`）。换机后改脚本头三个变量即可：
  `BIN`（llama-server 目录）、`MODEL`、`-dev OPENVINO{n}`（**先跑 `llama-server --list-devices` 数 NPU 下标，
  机器不同枚举不同**，无 dGPU 机常见 OPENVINO2）。

## 2. 换机验收清单（NPU 主打口径）
1. **世代识别**：设置→引擎管理卡应显示 `型号 · 世代 · -dev 档位`。npuCode 3700s=一代/3800s=二代/4000s=三代，
   认不出=unknown 按一代保守兜底（这是设计行为，不算故障）。红线：**4096 对一切模型放行**。
2. **滑杆**：设置「上下文大小」4096 起、每刻度 512、顶 16384；改档后重新加载模型生效。
3. **Omni-2B@4096**（本次手术主角）：预期 decode ≈20 t/s 量级（本机 19.8）。**慢 10× 以上 = 有机器把
   DDL env 配回来了**（查 `engines.json` lastConfig.extraEnv，不该有 DISABLE_DECODE_LEVELS）。
4. **超档**：滑到 8192/16384，加载日志应出现「🧬 深上下文臂 … NPUW_FOLD=YES」；
   无 FOLD 深档会塌到 <1 t/s（引擎地板），这是引擎病不是配置病（defect-npu-p14e-kvhostwrite.md）。
5. **复读复验**：Omni 连发「你好啊」→「怎么那么慢啊」两轮，看「哈哈哈哈」是否复现
   （崩速修复后大概率自愈；仍在 → 按 §4 取证另立缺陷单）。
6. **智能体模式**：系统提示 860 token，512 老档必 400；4096 默认档应通。
7. **ASR/TTS**：`docs/ACCEPTANCE-VOICE.md` §三清单（语音线重构后未走完验收）。
8. **4B@超4096 准入**：应弹「OUT_OF_HOST_MEMORY 先验」提示 + 建议调回 4096（护栏在位）。

## 3. 换机取证三件套
- 引擎日志弹层（加载期状态 + `🧬/回落/启动命令` 留痕行）；
- `%APPDATA%\WangCai\engines.json` 的 lastConfig（ctx/chunk/extraEnv/devArg 全快照）+ lastNpuInfo（型号/世代/驱动）；
- 出问题先跑 §1 矩阵脚本对照（**独占跑**：32GB 机器上「矩阵 llama-server + flutter 编译」并发会内存爆、
  构建进程被系统无声掐死——2026-11-06 打包两次假死实锤，别当成代码问题）。

## 4. 未跑项（回来补数据再拍板）
- **Spark 的 DDL 去留**：`run-queue2.sh` q2/q3（spark4096 ddl1 vs ddl0）没跑。若 ddl0 不崩不 OOM →
  Spark preset 那条 env 也摘掉；若 OOM/乱码 → 保留并注明「Spark@4096 必需」。**Omni 已摘是定案**
  （锦 `manifest_test` 回归锁：Omni extraEnv 永不得再有该键；Spark 那条另有锚）。
- q1（Omni 16384 ddl0+FOLD，滑杆顶端体验档）、q4（1.7B@4096 抽查）。
- 本机跑法：`bash E:/Work/WangCai/tmp/omni-matrix/run-queue2.sh`（自动串行+锁）。

## 5. 已知坑（省你两小时）
- TaskStop/关终端**不杀子进程 llama-server**：残留 server 占端口把矩阵数据串台过两轮（全作废重跑）。
  矩阵间已内置 `taskkill //IM llama-server.exe //F`，手工排查也别忘。
- PowerShell `>&1 | Out-File` 包 flutter build 偶发吞输出假失败：直接跑 `flutter build windows --release`
  再手补 staging 可绕（本次三次失败之一因是 rebase 冲突态目录在打）。
- 32GB 机器矩阵+编译不并发（见 §3）；16K 档编译峰值内存最高。
- 世代档案 `ctxOverrides`、实测豁免、demoteCtx 管路都在但 preset 档「水未通」（npu-adaptation.md §3 口径，
  勿高估自动化）；换机首跑一切走 4096 保守档是**预期**。
- 基线三败（thinking_runaway ×2、agent_stream_processor）仍在 test/agent 域；CI flutter job（远端 d30c1b6）
  test 全阻断，推上去若红先看是否这三个。

## 6. 本轮提交链（rebase 后以 origin/main 为准）
- `cd0b7ee` P14e 钉死 KV=0（缺陷单 defect-npu-p14e-kvhostwrite.md）
- `9e0b958` 加载期预热 + 加载进度可见
- `87475c5→(rebase)` 全局 ctx 单口子（4096 最基本/滑杆 512 档至 16K/preset 无 ctx/准入线 4096）
- `d76d64d→(rebase)` Omni 摘 DDL + 回归锁 + HANDOFF 矩阵段
- 与远端健康检查六连（fd631f0 测试腐化五修等）rebase 合流：三个测试文件手工解冲突
  （helpers/fake_process.dart 收编 vs 本方口径改写），解后四套锦 32 用例全绿。
