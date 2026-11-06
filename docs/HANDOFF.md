# 会话交接（上下文耗尽时读我）

## 性能攻坚计划（2026-11-03 立项，自主循环逐项做，做完即勾）

- [x] **P11 P3"decode 贴权重带宽地板"被证伪（2026-11-04，本轮最重要发现）**：权重字节判别实验
  （llama-bench 1.7B p512 tg128 r3，同机同构建，warm）——Q4_K_M（1.02 GiB）14.07 t/s、
  **Q5_K_M（1.16 GiB，字节 +14%）14.84 t/s、Q8_0（1.71 GiB，字节 +67%）14.96 t/s**：
  权重字节近乎翻倍、decode 步时零变化 → 步时与权重字节数**无关**，P3 的"15.7 GB/s DMA 地板"
  是两模型（1.7B 24 层 / 4B 36 层、注意力层数不同）在"每层算子开销 × 层数"上的巧合拟合。
  逐节点剖析（`GGML_OPENVINO_PROFILING=2`，1.7B lv256 decode 图；剖析总量 236.9 ms ≈ 实测
  67.7 ms × ~3.5 倍 profiling 放大，相对占比可用）：**MatMul 仅 18%**（n=56，0.76 ms/个——权重流
  大体被重叠隐藏）、Add 20%（n=28，单节点最高 24.8 ms）、Multiply 18%（n=120！）、Concat 17%
  （n=20，顶部单个 18.3 ms [DMA]）、Parameter 13%（n=57，状态输入 DMA）、GroupConvolution 6%
  （n=5）、Mod 4%（n=6，KV 环回绕）——**非 MatMul 算子汤占 ~80%**。
  **结论：decode 软件侧空间重新打开。** 主攻方向 = 压算子数 / 调度开销 / 状态 I/O，让权重流与
  计算重叠，理论地板 ~36 ms（1.37 GB ÷ 38 GB/s 实测常量流速率）≈ 27 t/s（对 14.07 基线 +91%）。
  基线表（本日 bench 口径）：1.7B pp512 406.5 / pp2048 283.7 / tg 14.07；4B pp2048(ck128) 42.8 /
  pp512(ck256) 135.6 / tg 6.89。
- [x] **P12 NPUW 编译开关重测 → `NPUW_FOLD=NO` 成为新默认（2026-11-04 定案）**：旧"证伪"是带宽论
  误判时代（level 图落地前、2.4 t/s 全 ctx 图域）的数据，全部翻案重测。1.7B（bench p512 tg128 r3，
  对基线 pp 406.5 / tg 14.07）：
  | 臂 | pp512 | tg128 | 备注 |
  |---|---:|---:|---|
  | **FOLD=NO** | **778.9（+91%）** | **22.54（+60%）** | 唯一大杠杆；冷编译 ~10×（blob 缓存吸收） |
  | FUNCALL_FOR_ALL=NO | 451.6（+11%） | 20.52（+46%） | 机制疑似与 FOLD 同族 |
  | FUNCALL_ASYNC=NO | 426.8（+5%） | 15.04（+7%） | 边际 |
  | FOLD+FCALL 组合 | 778.5 | 22.23 | 无叠加，FOLD 单独即最优 |
  | DQ=NO | — | — | 进程消失（4B 时代即编译失败，复现，未再追） |
  4B（Spark，对基线 pp2048/ck128 42.8、pp512/ck256 135.6、tg 6.89）：FOLD=NO →
  pp2048/ck128 50.6（+18%）、**pp512/ck256 192.2（+42%）**、**pp2048/ck256 86.0（+101%，见 P15）**、
  tg 8.9（+29%）；组合臂 52.3/8.92 无叠加。
  **精度**：1.7B 三问 3/3（n=96；n=48 时 Beijing 因 CoT 前导截断，语义在轨）、4B 三问 3/3。
  **默认值已翻转**（extra.cpp NPU 分支 NPUW_FOLD=NO，注释含数字与回退方式；两树同步）。
- [ ] **P15 预算规则重审**：旧"ctx≥1024 禁止 chunk256"（2026-11-02 定案）在 FOLD=NO 下部分松动——
  4B chunk256 c2048 **bench 流**三遍全绿且 pp +101%（86.0）；但 **cli -st 流 chunk256 c640 仍 flaky**
  （三问 1 pass / 2 fail，decode 首 execute "Compute error"——同旧 ZE_UNINITIALIZED 家族签名；
  干净磁盘 36 GB 复测排除磁盘满伪影）。**生产结论不变：4B 用 chunk128**（新默认下验收 3/3：
  reg4b128），chunk256 维持"离线 bench/批量 prefill 专用"。待查：lv256@c640 首执行失败后的
  fallback 缓存交互（Q3 在 Q1/Q2 编译过 fallback 后通过，疑似 fallback 图被盘缓存救活）。
  音频/视觉 NPU 图未在 FOLD=NO 下复验（不在 v0.0.2 已接受 surface 内，复验挂起）。
  **磁盘教训**：4B FOLD=NO 图缓存 ~14 GB/ctx 形状（c4fold 两形状 28 GB）——本轮曾把 D: 盘写满
  （100%），之后所有缓存写入静默失败、实验数字仍有效（编译在内存完成）但复跑全量重编。
  生产发布需在 packaging 文档写明缓存目录预留 ≥20 GB/模型/ctx。
- [x] **P13 prefill 逐节点剖析（2026-11-04，桩已入二进制）**：静态 prefill 循环原本没有
  `dump_ov_profiling_info`（只有 decode 分支有）——已补（utils.cpp 两树同步，1bbcc18）。
  FOLD=NO 下的构成：**1.7B prefill ck256**（剖析总量 2080 ms ≈ 实测 615 ms/chunk × 3.4 放大）：
  Add 33%（n=82）、MatMul 30%（n=175）、**Multiply 27%（n=196，rope 乘法链，Shave 执行）**、
  Scatter 3%；**4B prefill ck128**（20286 ms ≈ 实测 ~3 s/chunk × 6.8 放大）：MatMul 40%、
  Add 21%、Concat 13%、Func 8%（NPUW funcall 边界 ×10）、Scatter 7%。
  **4B decode lv256**（1157 ms ≈ 实测 112 ms × 10.3 放大，放大倍数随节点数增长，
  跨模型只比相对占比）：**Add 38%（n=180）+ MatMul 34%（n=289）+ ScatterNDUpdate 19%
  （n=72 = 每层 K/V 各一）**，Multiply 4%、Transpose 2%。节点名已携带 ggml 名
  （`ScatterNDUpdate_39717_cache_k_l2 (view)#n80`）。
- [x] **P16 server 流验证 + warmup 编译毒化定案（2026-11-04）**：FOLD=NO 下两模型 server 流
  （`--no-warmup` + `-dev OPENVINO3`）三问全过（1.7B c17s2 3/3、4B c4nw2 3/3，零编译失败）。
  **warmup-on 时 server 首个 warmup 编译失败（`Failed to compile Model0_1`），且毒化后续请求
  编译（Model9_1/40_1 连环败）**——`--no-warmup` 是硬性要求（P1 的建议从"净赢 2.7 s"升级为
  "不加则 FOLD=NO 编译毒化"）；网关预热请求（P9）不受影响。
  另：funcall_for_all=NO 在 4B 上同样无叠加（50.8/8.97 vs FOLD 单独 50.6/8.88）。
- [ ] **P14 decode 算子汤手术**（数据已齐，候选按杠杆排序）：
  ① ' **ScatterND 索引链 per-graph 共享——已落地（2026-11-04，本 commit）**：4B 每层 K/V 两个
  ScatterNDUpdate（n=72）各自重建的同一条 ~8 节点索引链（Squeeze/Convert/ShapeOf/Broadcast/
  Concat/Unsqueeze/Mod）改为 translate-session memo（键 = indices 节点 + dst_rows + mod_applied），
  ~570 小节点 → 4 实例；顺带删除动态分支的不可达 Mod 旧码（注释记录）。NPUW 的 CSE 从不跨子图
  合并这些链（P13 profiled Concat 计数与 scatter 一一对应为证）。
  **验收**：1.7B 三问 3/3 + 4B 三问 3/3（n=96，零 ZE）。**bench（暖 blob r3，对 P12 遗产）**：
  1.7B pp512 746.8 / pp2048 426.7 / tg 20.7–21.9（同量级无回归）；4B pp2048ck128 52.4（50.6→）、
  pp512ck256 191.4（192.2→）、tg 8.7（8.9→）——4B 噪声级。**对基线（P11 表）判定：1.7B
  pp512 +84% / pp2048 +50.4% / tg +47~56%（贴线）；4B pp2048 +22% / pp512 +41% / tg +26%——
  4B 两个轴都还没到 +50%，继续循环。**
  ①  **KV scatter 融合**（未做）——两视图同宿主可合并为单 scatter（translator 侧检测同父对；
  注意 K/V 是不同 ggml 缓冲，跨 Parameter 合并不可行，需先核实同宿主前提）；
  ② **rope 乘加链折叠**（下一刀）——1.7B prefill Multiply 27%、4B decode Add 里 rope 族；
  每个 rope 节点 ~10 节点中 cos_full/sin_full 双 Concat + decode head-tile 只依赖共享表，
  照 ①' 模式做 session memo（键 = 表节点 + half + n_heads + tile 标志），两模式（NORMAL expand /
  NEOX concat）都覆盖；
  ③ conv 状态 Concat/Mod 环操作（1.7B decode 专属）；④ 现成旋钮 A/B（免代码）：
  `GGML_OPENVINO_MANUAL_GQA_ATTN=1` 对 NPU decode——绕开 K/V 按头物化广播（tile_kv 的
  Broadcast+Reshape ×72/图）。
  **工具**：`ctrl/p14_eval.ps1 -Model 17b|4b`（三问 + bench r1暖+r3测，持久 cache_p14_*）、
  `ctrl/p14_prof4b.ps1`（PROFILING=2 一次性缓存）。
  **本轮两条硬教训**：(a) **内存预算**：NPU 冷编译（FOLD=NO ~10×）期间用户 GPU server 占 23 GB
  → 剩 5.4 GB → 编译僵死；跑重型 NPU 实验前先清出 ≥25 GB 物理（HANDOFF 旧规"大 ctx 前先问"
  的具体化）。(b) **磁盘预算升级**：4B FOLD=NO 盘缓存实测 **~19 GB/ctx 形状**（旧记 14 GB 低估），
  两形状即写满 D: ——缓存写满后实验数字仍有效（编译在内存完成）但缓存作废全量重编；
  复测前先 `df -h /d`，发布文档缓存预留改 **≥20 GB/模型/ctx 形状**。
  **P14d/P14c 两个 A/B 结案（2026-11-04）**：① `GGML_OPENVINO_ROPE_F16=1`（无状态 f16 rope 全链 f16 域，
  表在共享链内转一次）——**证伪**：4B 验收 3/3 零 ZE，但两模型全轴持平略负（4B pp2048ck128 51.75±1.14 /
  pp512ck256 186.4±0.72 / tg 8.52–8.62 vs 默认档 53.1 / 192.3 / 8.96；1.7B 775.6 / 429.1 / 22.0 vs
  779.0 / 432.6 / 22.6）。rope Add 族被 launch 计数限速，换计算域不改变受限面；默认保持 OFF，开关保留
  供 rope 实验复现。② `GGML_OPENVINO_MANUAL_GQA_ATTN=1`（4B bench-only）——**不可行**：四臂全灭于 NPU
  VCL 拒编（`ZE_RESULT_ERROR_INVALID_ARGUMENT` code 0x78000004，"Compilation failed" 无算子级信息，
  每臂 9–10 s rc=1）；该 lowering 面向 GPU 路径，NPU 静态图不容忍这套组合。至此 4B decode 剩余主攻
  只剩 **P14e（host 侧 KV 行写出、scatter 出图）**。两臂判据同前（暖 blob r1 暖 + r3 测）；日志存档
  `ctrl/p14bench_4bF16_*.log(.err)`、`ctrl/p14acc_4bF16_*.log`、`ctrl/p14bench_4bGqa_*.log(.err)`。

背景：~~decode 已贴权重带宽地板~~（P11 证伪）、prefill chunk256 甜点已交付、预算规则已定案。
剩余性能空间按性价比排序，逐项执行、证伪也记录、每项独立 commit：

- [x] **P1 `--no-warmup` 净赢验证（2026-11-03 定案：赢 2.7 s）**：同暖缓存 A/B × 2 轮（`ctrl/ck_wu_ab.ps1`），
  总到首答 warmup-on 25.3 s vs `--no-warmup` 22.6 s（ready −3 s，首请求 +0.5 s 噪声内）。**生产建议：
  llama-server 加 `--no-warmup`**（warmup 的 6 s prefill eval 不预热 decode 图，纯亏）；llama-cli 交互式
  不加（warmup 藏在用户打字时间里，且让首答更快）。
- [ ] **P2 push 积压**（网络恢复后）：6619d0d 之后 3 个本地 commit。
- [x] **P3 decode 天花板定案（2026-11-03，已入 status）**：每生成 1 token 必全量读一遍权重 → 步时下限 =
  权重字节 ÷ 带宽。两模型独立吻合：1.7B ≈1.0 GB/15.7 GB/s = 64 ms ≈ 实测 67 ms（14.9 t/s）；4B ≈2.3 GB
  → 145 ms ≈ 实测 145 ms（6.9 t/s）。KV/attention/状态 I/O 全在余量内（级别图组裁剪），decode **纯权重
  带宽受限**，软件侧关死（u4 证伪、零拷贝不改 LPDDR 带宽），除非换硬件。
- [x] **P4 remote tensor/USM 探针（2026-11-03 结案，不立项）**：插件 dll 含 `ZeroRemoteTensor`
  （intel_npu 内部类，L0 host memory）与 `ov::IRemoteTensor` vtable，但无对外创建属性名（无
  NPU_REMOTE_* 之类字符串）→ 用户侧零拷贝绑定不可达。即便可达也不改 LPDDR 物理带宽：decode 已贴
  P3 下限，prefill 每 chunk 输入仅 KB 级。两理由叠加，结案。
- [x] **P5 热跑基线表刷新（2026-11-03，已入 status）**：4B c2048×ck128 pp **38.0**、4B c512×ck256
  pp **55.5**（+46%）、1.7B c2048×ck256 pp **223.5**（t/s，暖 blob 第二遍口径；cli -st 的 Generation
  计时被 CoT 打印摊薄，decode 用 bench 口径 6.9/14.9）。同轮证伪：chunk512（span 超线性，两模型）、
  `-b 128`（ready 40.3 s）。注意：并行实验前先 `Get-Process llama*` 清残留——一轮被中断的基线跑
  污染过 4B c2048 臂（12.9 t/s 假象），清干净复测才是 38.0。
- [x] **P6 GPU 路径 stub 结案（2026-11-03）**：`ov_opencl_shim` 的 GPU/CL 路径保持 stub，理由：dGPU
  （5060 Ti）不在端侧 NPU 场景内；iGPU 共享同一 LPDDR5X（P3 带宽下限同样适用，CPU 参照 21.7–29.2 t/s
  即共享内存路径的实测上限量级），无吞吐红利且有维护成本。
- [x] **P7 每项独立 commit/push + 清单勾选**：P1–P6 全部完成（8577f20 + 本 commit），push 断网时
  本地积攒、恢复后重推。

## 2026-11-05：NPU 世代自适应（一代/二代/三代 Ultra）——从"一台机器调出来的常量"变成"按世代保守起步 + 该机实测上抬"

**背景（为什么必须做）**：v0.0.5 之前，全仓 NPU 调优常量都是**单机取证**的结果——
4B ctx512 / chunk128、`GGML_OPENVINO_DISABLE_DECODE_LEVELS=1`、admission 规则
「4B@ctx>512 → OUT_OF_HOST_MEMORY」、冷编 600s，全部来自这台 275HX + **NPU 3720**（32GB）。
换到 Lunar Lake（NPU 3820）或 Panther Lake（NPU 4000 系）上，这些数字既不是该机实测、
也没人敢直接删——装机用户拿到的是"别人家的最坏情况"，且探测只取 `OPENVINO{n}` 下标，
型号名与 MiB 一律丢弃（`openvino_probe.dart` 旧签名 `probeNpuDevArg`）。

**用户定案的两条口径（2026-11-05，AskUserQuestion 逐条确认，不可自行放宽）**：
1. **验证范围 = 只有这台 3720**——无二/三代实机。验收口径因此是"本机行为逐位不变 +
   模拟枚举文本的单测全绿"，不是"三代真跑通"。拿到二/三代机器再补真机取证。
2. **策略 = 保守起步 + 实测上探**——未知/未识别世代一律落到一代**已验证**的保守基线；
   二/三代档案**不预填任何乐观数字**（无实测不赌）；该机跑成功过的档位由
   `BindingsStore.maxStableCtx` 记住后自动放开，执行期驱动报 OOM 由 `demoteCtx` 收回。

**落成的五层（数据驱动，遵守 routing_policy「不写死阈值」）**：
- 探测：`probeNpuDevice(exe, env)` → `NpuDeviceInfo{devArg, deviceName, npuCode, totalMib, freeMib}`，
  纯函数 `parseNpuListDevices` 可测；**只缓存成功**（驱动热修后下轮自愈）。
- 世代：`npu_profiles.dart::npuGenerationFor`——型号码为锚（3700–3799/3800–3899/4000–4999），
  越界或缺号 → `unknown` → 按一代兜底。**枚举名兜底必须走带 `\b` 的正则**：
  `contains('3720')` 会把 `(NPU 37200)` 判成一代（错世代比 unknown 危险，unknown 只是保守）。
- clamp：`local_server_inference._ctxCeilingFor`，优先级固定
  `maxStableCtx（该机实测） > NpuProfile.ctxOverrides（当前空表） > manifest preset.ctx`。
- 闭环：成功侧 `recordRun` 单调上写（原有）；失败侧 `BindingsStore.demoteCtx(failedCtx)` 收回
  被证伪的上抬——**失败不证伪更低档**（`maxStableCtx < failedCtx` 时保留）。
- admission：`AdmissionRule.appliesGenerations`（缺省全适用）+ `measuredCtx` **豁免**——
  只有 ctx 门槛类规则让位实测证据，纯参数量规则（如 4B 与 OOM 的硬关系）永不让位。
  这条豁免是必需的，否则「4B@>512」规则会把实测上探永久堵死（设计期自查发现）。

**顺带修掉一个真竞态（不是测试脚手架问题）**：`loadModel` 失败路径 `unawaited(host.stop())`
与下一次 `start()` 并发时，`stop()` 迟到的 `_ledger.clear` + `ProcessExitedEvent(0)` 会把
**新** launch 误判成意外退出（wantRunning 已被新一轮 StartRequested 置真）并抹掉它的账本条目。
`LlamaServerHost.stop()` 加代际守卫（`final gen = ++_gen; … if (gen != _gen) return;`）。
另：探测失败回退 `OPENVINO2` 原先只进 `_logsCtl` 不进 `_logHistory`（日志弹层读历史 → 看不见），
改走 `_ownLogLine` 双写；驱动版本 `EngineStore.npuDriverVersion`（CIM `AI Boost|(R) NPU`）
best-effort，失败静默 null，成功加载后随 `lastNpuInfo` 摘要落 engines.json（可选字段不 bump 版本）。

**取证与踩坑（下次省一周）**：
- **MiB 只许当诊断，绝不当预算**：`totalMib/freeMib` 进 UI 与 engines.json，但
  NPU 的 OUT_OF_HOST_MEMORY 是**驱动 per-process 预算**而非系统内存（本文件 2026-11-02 深夜定案），
  拿设备上报显存做 ctx 判据会系统性错判。
- **sqflite_common_ffi 按路径共享底层库**：测试辅助 `BindingsStore.open(paths)` 后**绝不 close**——
  会把网关缓存的句柄一起关成 `database_closed`（m2_dod 同样只开不关）。这条坑本次又踩了一次。
- 本机真机核对走**命令行取证**（Computer Use 在本会话不可用，按纪律不换 UI 自动化技术）：
  直接对部署包二进制 + 真模型跑 `LlamaServerHost`，断言 `-dev OPENVINO3 / -c 512 /`
  `GGML_OPENVINO_PREFILL_CHUNK_SIZE=128 / lastNpuInfo{code:3720, generation:ultra1}`
  与 v0.0.5 逐位一致；生产 `cache/` 命中 blob 免 130–420s 冷编。
- `test/models/` 是 v0.0.5 合流时脱队的遗留测试（包名还是 `package:tongyi_lite/`，一 import
  就是 60 个 error），本次收编并同步过期 pin：目录 23→25 条；Spark-X2.6-4B 换成 **2.44GB 新量化**
  （sha256 `30b77e2e…`，旧 pin 的 3.3GB/`91cb2811…` 是 X2.6 首版数据）。

**下一步（谁接谁做）**：二/三代真机到位后，往 `NpuProfile.ctxOverrides` 填实测行、
按需给规则标 `appliesGenerations`，并补 `minDriverVersion`（现在故意留空——编造版本线会
误导用户升错驱动）；三代（Panther Lake）枚举名形态仍未实机核证，识别不出就走 unknown。

## 2026-11-06：世代自适应复查三修——驱动查询会话缓存 / NPU 行按指向 gate /「实测上探」口径收真

自查揪出三处，一刀修讫（行为红线不动：3720 仍逐位同 v0.0.5）：
1. **驱动版本 CIM 查询无缓存**：原先每次成功加载都 spawn powershell 全枚举
   （数秒级 CPU）。改会话级 memo（查而未得不缓存，下次重试；engines.json 已带
   driver 直接沿用），网关级用例锁「两次加载只付一次」。
2. **引擎卡 NPU 行不看设备指向**：`lastNpuInfo` 没有清除时点，切 CPU/GPU 加载后
   旧行误导排障。`_NpuInfoLine` 按实例最近配置 gate（非 NPU 指向一律隐藏）。
3. **「实测上探自动放开」表述超前（非 bug，口径收真）**：preset 命中模型上
   clamp 先压 requested ≤ prior → recordRun 只会记 ≤ prior → `measured > prior`
   今天不可达——上抬分支/实测豁免/demote 收回对 preset 档都是「管子在、水未通」
   （单测 seed 验证的是管路）。活化入口 = preset 上调 / 档案 ctxOverrides 填行 /
   无 preset 模型。已在 docs/npu-adaptation.md §3 落「重要口径」段。
   **教训：闭环设计的每条腿都要追问「今天谁喂它数据」——测试 seed 通过 ≠
   生产路径可达。**

## 2026-11-06：全面健康检查清账（红黄全处理）——基线三败清零 / CHANGELOG+tag 补立 / patches 如实建档 / CI 补 Dart 守护

三代理体检 + 实测基线的红黄项全部落地（明细见 CHANGELOG [Unreleased]「健康检查清账」段）。
口径与教训：

- **基线三败是"测试过时"不是"代码回归"**：Clover 位置门（10-30 真机实锤）改写了思考流
  契约，测试还按旧约写；独立化后"修复归上游"失效，测试跟现契约走，位置门本身用例锁死。
  自此 `flutter test` 全绿为常态（1412/21/0 首破），CI 的 flutter job 按零失败阻断。
  **教训：跑红的"基线失败"要拿取证时间线判归属（实现变or测试错），别默认测试是圣约。**
- CI 原只建引擎，Dart 侧裸奔——flutter analyze（error 阻断）+ test（全阻断）job 已补；
  runner 无 NPU/音频设备，真机套件靠三重门控自动跳过（gate 对齐的价值）。
- patches/ 与构建事实脱节如实建档：0001 是 10-31 快照、bootstrap pin 落后工作目录
  （abb76ab vs cd37cd9）；构建真相 = src/llama 工作目录 + src/ggml-openvino overlay。
- CHANGELOG 自 0.0.1 后三个 release 都没进账（release commit 只更版本串）——
  **教训：版本发布三件套（版本串/CHANGELOG/tag）要当一次事务，漏一件就是考古题。**
- 缓办未动（留用户定夺）：依赖 major 升级（riverpod 3/flutter_markdown 停更/file_picker
  -5 majors）、大文件拆分（settings_screen 3000+ 行等）、debugPrint→结构化日志体系。

## 2026-11-03：P8 结案——llama-completion fastfail 与 NPU 无关（jinja 模板 unsupported 未捕获异常）；"raw 流独立缺陷"证伪

`llama-completion`（raw）4B 必崩 0xC0000409（1.7B 不崩、chunk/ctx 无关、REQUANT 无关、ASAN 构建同样崩且
无 ASAN 报告）→ 定位过程：Event Log 崩在 ucrtbase（terminate fastfail）；ASAN 版 0.29 s 早崩暴露真实
崩点 = `common_chat_format_example`（启动期的模板示例渲染），Event Log 与生产版同偏移 → **两次"decode
编译时崩"的旧读法全部推翻，崩点始终在 template**。根因链：Spark-X2.6-4B 的聊天模板不在 llama.cpp 内置
matcher 清单 → 非 jinja 路径抛 `"this custom template is not supported, try using --jinja"` → completion
工具两处调用（example + 真实 prompt 的 `common_chat_templates_apply`/`common_chat_format_single`）都无
捕获 → terminate。1.7B（LMF3）模板在内置清单内所以幸存。

- **绕过**：`--jinja` 或 `-no-cnv`（两者均实测 rc=0，且 raw 流下 NPU backend 全程健康——lv512 编译+
  执行成功，此前"raw 流有独立堆破坏缺陷"证伪，当时把 jinja 异常误归因到 decode 编译）。
- **fork 修复（vendored diff #9，两文件）**：`common/chat.cpp` example 渲染包 try/catch（空示例 +
  stderr 日志）；`tools/completion/completion.cpp` 检测 example 渲染失败 → 警告并自动 fallback 到
  jinja（`--jinja` 行为），真实 prompt 不再二次崩。裸参数 raw 4B 实测：警告打出、rc=0。
- **上游 issue 素材**（等用户贴，docs/upstream-issues/）：非 jinja matcher 未覆盖的模板应报错而非
  terminate；example 渲染属装饰性不应致命；两个公开函数（format_example/format_single）缺异常边界。
- ASAN 树（D:\llm\npu\asan，`bld_asan.bat`，LLAMA/GGML_SANITIZE_ADDRESS=ON）留作后续排查工具——
  本案无堆破坏，ASAN 无报告恰好佐证是 terminate 而非越界。

## 2026-11-03：P9 定案——首请求 ~13 s 是 llama/driver 层固有成本；应用层预热请求是最后杠杆

同 server 连发两请求（`ctrl/ck_2req.ps1`，4B chunk128 c2048 `--no-warmup`）：**req1 12.9 s / req2 4.2 s**
——一次性成本 ~8.7 s。分解（slot timing + 对照实验）：
- prompt eval：req1 8.9 s vs req2 3.1 s。**无批拆分**（早前"61/17 两批"是 progress 报点误读；单批）。
  chunk 执行本身 ~3 s/批（5 tokens 也要 3.1 s——span 图全量算，正常）；多出的 ~5.8 s = 首请求固有
  （jinja 渲染 + tokenize + 首次真实数据执行路径），warmup 开关不影响它（warmup-on 的 req1 同为 12.9）。
- eval：req1 4.0 s（lv256 blob 热编译 1.5 s + 首采样路径）vs req2 1.06 s（151 ms/tok = 纯带宽地板）。
- `--no-jinja` 500（Spark 必须走 jinja，srv 有捕获不崩）；raw /v1/completions 单批但首请求同样多付
  （attach 类一次性成本，driver 层）。
- **结论**：server 侧无更多杠杆；`--no-warmup`（P1，已交付 -2.7 s）之后，剩余 ~6 s 固有成本只能靠
  **应用层预热**：网关就绪后立刻发一个 max_tokens=1 的预热请求，把首执行/lv 编译/模板路径全部焐热
  （~5 s），用户首次真实提问即走 req2 路径（~4.2 s）。M2 网关加这一行即拿到；CLI/chat-npu 不需要
  （交互式用户打字时间天然焐热）。

## 2026-11-02（深夜 2）：启动时间分解（4B 生产配置 server）——warmup 只预热 prefill，decode 图在首请求才编译

`ctrl/ck_startup.ps1`（4B chunk128 c2048，warm 缓存）：热启动 **11.7 s** 到 /health ok，分解（llama
相对时间戳 + BUDGET-TRACE t=）：**0.2→3.4 s 权重装载**（2.4 GB mmap/requant）；**3.4→5.2 s prefill 图
编译**（blob 命中，1.6 s）；**5.2→11.5 s = srv warmup eval**（sched_reserve 的 256-token **prefill**
pass 真跑 ~6 s）。关键发现：**warmup 从不触发 decode 图编译**（整个启动只有 1 条 compile-local:prefill）
——生产 server 的第一个真实请求才付 decode lv 图的编译。`--no-warmup`：ready 8.4–8.8 s，首请求 12 s
（lv256，blob 热后）/ 24 s（blob 冷）——省的是等待时间，把编译成本挪到首请求，总量不减。

**首请求 12 s 的真分解**（slot print_timing + trace，基线 warmup-on）：prefill ~5.9 s（**首请求的
prefill 每 chunk ~3 s = 20 t/s，是 warmup 同图 85 t/s 的 1/4——首次带真实数据的执行开销**）+
decode 3.3 s（含 lv256 编译 **仅 1.5 s**，blob 热）+ ~3 s tokenize/模板。客户端墙钟与服务端 total
吻合（无测量假象）。

**后台预编 decode lv256（GGML_OPENVINO_PREBUILD_DECODE）已实现但默认关**：worker 在 prefill 编译后
孵化、与 warmup 重叠、发布带四重守卫（entry 在册/levels 空表/无 legacy/未 kill-switch），free() join
保 cgraph 生命周期。实测：worker 并发编译劣化 **1.5 s → 8 s**（NPUW 编译与前台竞争），ready +1.3 s，
首请求只省 1.5 s——净 ~0.5 s，不值得并发风险。除非插件侧并发编译不再劣化，保持 0。剩余杠杆：
warmup 3×prefill pass ~6 s（能否减批）与首请求 prefill 首 chunk 3 s（attach 开销）。

遥测补强：BUDGET-TRACE 全部行带 t=ms（GetTickCount64 惰性锚定；静态初始化期的
ggml_time_us/GetTickCount64 都不可靠，别再往回改）。

`-b 128`（试图把 warmup 减批）**反效应，勿用**：ready 40.3 s、首请求 20.3 s（调度切成更多批次，
backend pass 从 4 次涨到 12 次）。生产 -b 不动（默认）。

`chunk512`（c512 srv 流）**证伪**：每 chunk 执行 9.3 s vs chunk256 的 1.95 s / chunk128 的 1.51 s
（span 翻倍执行超线性），pp 35.5 t/s 反而低于 chunk256 的 ~88；且 lv512 blob 命中后 IR 仍要 ~20 s。
**chunk256 是 prefill 甜点**（短上下文已交付 +55–59%），别再往上加。

## 2026-11-02（深夜）：srv 流缺陷定案 —— 真规则是 `prefill(chunk256)+decode(KV≥1024 行)` 装不下；bench 对照是假象

上一段（未决）的"srv 流特异驻留"假设**已被 BUDGET-TRACE 证伪并替换**。遥测（env `GGML_OPENVINO_BUDGET_TRACE=1`，
utils.cpp `ov_budget_trace`，fprintf stderr——llama 默认日志回调会把后端 GGML_LOG_* 全吞，必须绕开；
env 名已加进 extra.cpp 白名单）给出的完整时间线：

### 一、定案
- **失败签名**：4B chunk256 + decode KV 行跨度 ≥1024（即 ctx≥1024 的 srv 流 decode）→ 新 decode 图首
  execute `pfnAppendGraphExecute` 失败（`ZE_RESULT_ERROR_UNINITIALIZED`，levels-off 时 `..._OUT_OF_HOST_MEMORY`）。
  kill-switch 后 fallback 编 full-ctx（=同跨度，lv==ctx）**必然同尺寸再爆**——fallback 在此场景天然无效。
- **边界（同机复测，新二进制，干净进程）**：chunk256 + lv512 ✅（c512 cli -st 出 token）；lv1024 ❌（c1024）；
  lv2048 ❌（c2048）。chunk128 + lv2048 ✅（生产，回归出 token）。1.7B chunk256 lv2048 ✅（三图共存，ws 7 GB）。
  `MEMORY_OPTIMIZE=1` 无效；崩溃时 avail 物理 21 GB+、commit 41 GB+——"OUT_OF_HOST_MEMORY" 是驱动内部 per-process
  配额错误，不是系统缺内存。
- **规则**：预算 ≈ prefill 图(chunk) + **最大** decode 图(lv) 联合驻留。chunk128 换 decode 图放大空间（生产配置），
  chunk256 只容 lv≤512。与上游 issue #3（权重 bank 不跨 CompiledModel 去重）同根。

### 二、上一轮"bench 对照"为何是假象（勿再用它当 lv>256 的证据）
decode-pass 级 trace：`llama-bench -p 2500 -n 128` 的 tg 全部 128 步都是 **filled=256 ctx=256 level=256**——
bench 的 decode mask 从不覆盖全部历史，**bench 从没编译/执行过 lv>256 的图**。"bench 同形状 ✅"因此从未对照过
真正的失败形状。bench 的 pp 增益（chunk256 +55–59%）仍然为真（prefill 图与 mask 无关）。
同理被证伪：levels-off"两图也爆"（legacy lv=0 就是 full-ctx 2048 同尺寸，超预算是平凡的）；"srv 多驻留 4 GB"
（失败时刻 cli 与 bench 的 IR 驻留数一致：prefill+一张 decode）。

### 三、代码改动（两树同步，编译绿）
1. **空批 decode 短路**（utils.cpp `ov_graph_compute_static` 头部）：`is_static && !no_kv_cache && !is_prefill &&
   attention_size_raw<=0` → 直接 `GGML_STATUS_SUCCESS`。0 token 无 KV 行无 logits 行可写，编图执行都是白做。
   （上一段的 clamp-to-1 方案撤销——它让空批真编一张 lv256 图，纯属多养一张图；clamp 表达式随之删除，
   注释记录历史。）生产回归：chunk128 c2048 cli -st 长 prompt 出 token、lv2048 命中、无 ZE。
2. **BUDGET-TRACE 遥测保留**（默认关）：compile 现场（tag+lv+lastpass）、decode-pass（filled/ctx/level/hit）、
   BUDGET-FAIL、ws/avail/commit。下次预算类问题直接开它，别再人肉猜。

### 四、新独立缺陷（低优先，非生产流）：llama-completion 静态 decode 编译 fastfail
`llama-completion`（raw，无 -st）4B chunk256：编 decode 图时 **0xC0000409（heap fastfail）**，c2048/c1024 均确定
复现（trace 停在 compile-local 之前）；同形状 cli -st 是 ZE append 失败而非 fastfail → raw 的堆破坏是独立问题。
raw completion 不在生产路径（chat/server/bench 都健康），记录待查，别和预算规则混在一起。

### 五、生产配置（最终）
- 4B srv/chat：**chunk128 全 ctx 不变**；**chunk256 在 ctx≤512 已验证可用**（pp +55%，短对话场景可考虑），
  ctx≥1024 禁止 chunk256（本报告规则）。1.7B：chunk256 任意 ctx。离线批量 prefill（bench 式）：chunk256 随便用。
- `chat-npu.ps1` 头注释同步了该规则。

## 2026-11-02（晚）：4B chunk256 预算封锁证伪（bench 流 pp +55–59%）+ srv 流超预算缺陷（新，未决）

回应 NPUW 权重 bank 线索的实测轮。插件 DLL 字符串扫描证实 `NPUW_WEIGHTS_BANK`（string，"非空名共享权重"）
早已在 compile_config 里（`"shared"`），`NPUW_WEIGHTS_BANK_ALLOC` 存在——但共享并未跨 CompiledModel 去重
（与上游 issue #3 的 import 无 dedup 一致）。随后转向"chunk256 到底装不装得下"的实测：

### 一、证伪："4B 默认 chunk 必须 ≤128（驱动主机内存预算）"过时
三图驱逐修复（上午轮）之后，**llama-bench 流** chunk256 冷缓存全绿（Spark-X2.6-4B，新缓存目录，r≥2）：

| ctx(≈) | pp chunk128 | pp chunk256 | Δ | tg128 |
|---|---:|---:|---:|---:|
| 640 | 84.6 ± 1.6 | **131.5 ± 2.8** | **+55%** | 6.75 / 6.66 |
| 2048 | 41.3（pp1900） | **65.9**（pp1900） | **+59%** | 6.47 / 6.24 |
| 8192 | — | 42.8（pp8064） | — | 6.49 |

decode 不动（带宽地板不变），prefill 大涨——**"chunk256 撞预算"是三图修复前的旧账**（README/状态表沿用的
64/128 论断据此修正）。脚本 `ctrl/bank_chunk256_full2.ps1`。

### 二、新缺陷（未决）：srv 系流（llama-cli -st / llama-server）chunk256 + c2048 必爆
同机同权重同 env，**唯一变量是流量入口**（干净进程状态、僵尸 llama-server 已排除——它 15:07 才出生，
首崩在 14:3x，且杀干净后照崩）：

| 流 | chunk256 c2048 | 备注 |
|---|---|---|
| llama-bench（-p1900/-n128、短 prompt 均试） | ✅ | tg 走 level-2048，prefill+单图驻留 |
| llama-cli -st（levels-on） | ❌ level-256 首 execute UNINIT，fallback 图再爆 | 首个 decode step 即崩 |
| llama-cli -st（levels-off，仅 prefill+legacy 两图！） | ❌ | 两图也爆 → 不是 level 图数量问题 |
| llama-cli -st --no-warmup | ❌ | warmup/jinja-empty 排除 |
| llama-server | ❌ HTTP 500, ze=2 | chunk128 server ✅（16 token 完成） |
| llama-cli -st @ c512 | ✅ | 边界在 ctx（1024 未测） |
| LFM3-1.7B chunk256 c2048 cli | ✅ | 1 GB 权重装得下 → 4B 专属 |
| llama-cli -st chunk128 c2048（新二进制回归） | ✅ Beijing | clamp 修复无回归 |

已证伪的机制假设：n_batch=2048 sched 驻留（`-ub 128` 照崩）、warmup/jinja、level 图数量（levels-off 两图也崩）、
编图顺序。**唯一未证伪的差异**：cli/srv 进程相对 bench 多驻留一块设备侧内存（~数百 MB 级，把本就贴边的
chunk256 prefill 顶出预算）。下一步诊断（别重复我已排除的）：在 `build_static_model`/首次 execute 失败点
加遥测——枚举进程内全部 CompiledModel 及其 host pinned 缓冲字节数，对比 bench 与 cli 同一时刻的驻留清单。
在那之前**生产配置不变**：srv 系流（chat/server）4B 用 chunk128（已验证），chunk256 增益目前只在 bench/离线
长 prompt 流兑现。fallback 失效（首 execute 失败后驱动态污染，"driver is not initialized" 传染后续图）
同属本缺陷，修复驱逐-重试路径也是候选方向。

### 三、engine 侧已改（两树同步，编译绿，回归过）
`utils.cpp` decode 级别查找去掉 `attention_size_raw > 0` 前提：空批次 decode（sched_reserve warmup，raw==0）
此前直落 level-0 全 ctx 图（第三张权重 bank）；现 clamp 到最小 level（256），空批次无 KV 写入、功能等价、
不多占 bank。`decode_attention_level` 对 n_kv<=0 早退 0，故显式 clamp 到 1。生产判据：chunk128 c2048 cli
回归 Beijing 正常。

### 四、测量纪律补
- **跑 NPU 实验前必须 `Get-Process llama*` 清残留**——本轮一个 10 GB 僵尸 llama-server 污染了 15:07–16:2x
  整批判定（levels-off "两图也崩"的结论在僵尸在场时得出，杀干净后复验才可信）。
- server 首请求的 t/s 与"空 answer"都不可作判据（编译停顿 + CoT），按既有纪律：热缓存 + ≥128 token。

## 2026-11-02：视觉性能轮收官后——decode "512 断崖"证伪（非缺陷）+ profiling×blob-cache 崩溃定案

视觉吞吐修复（warm encode 542 ms）已 commit `af30ad4` push。续跑性能轮，测文本热启动/decode t/s，两条结论：

### 一、decode "随上下文断崖"= 正常注意力成本，非 NPU 缺陷（前提证伪，勿再追）
- tgs sweep（Omni-2B，chunk128，`-dev OPENVINO3 -st`，warm cache）：prompt 词数 n 递增，Generation t/s：
  levels-on `14.5 / 14.1 / 8.3 / 7.7 / 5.2`；levels-off（全 ctx 单图）**恒定 8.0-8.3**。native `-dev none`
  **恒定 48-56 t/s**（与长度无关）。
- **误判纠正**：初判"level-512 图 20× 断崖"是错的——verbose 显示 n=470（prompt ~700 token，越过 512 填充）
  选的是 **level-1024 图**（`[1024,256]`），attends 大跨度，自然慢。级别机制本身上轮已 bit-exact 验证
  （1.7B 15 t/s 与 -c 无关、逐位一致）。NPU decode 比 native 慢（短 3.6×、长 ~10×）与随填充变慢，
  **正是上一轮已定案的注意力/状态 I/O 残差**（`状态输入 DMA 全量搬运` + `attention 对静态跨度`；
  stateful 与 lm_head u4 杠杆均已证伪）——不是新缺陷。levels 关反而更慢（8 vs 14 短 ctx），印证多级图有效。
- **别在这上面耗**：真要显著提速需 NPU remote tensor / 状态 I/O 布局重型改造，超出性能主攻的性价比；
  视觉编码（542 ms）才是本轮真实吞吐战果。

### 二、新缺陷（真 bug，值得记录/上报）：`ov::enable_profiling` × 插件 blob 缓存 → NPU 崩溃
- 复现：`GGML_OPENVINO_PROFILING=2`（会 insert `ov::enable_profiling(true)`）+ 复用同一 `CACHE_DIR` 二次运行
  → `ZE_RESULT_ERROR_INVALID_NULL_HANDLE (0x78000005)` @ `zero_wrappers.cpp:208 pfnAppendGraphExecute`，
  `graph_compute` 返回 -1，Prompt/Gen 全 0.0 t/s。首次编译（空缓存）正常出 CSV，命中 blob 再导入即崩。
- 定性：profiling 编出的 blob 不带 profiling 句柄，插件缓存导入后 AppendGraphExecute 拿空句柄——profiling
  配置未纳入插件 blob 缓存键。**规避**：profiling 探针每次用一次性空 `CACHE_DIR`（脚本 `ctrl/npu_proflevel.ps1`
  已改为每 run 新目录）；生产路径 `PROFILING<2` 不触发，无影响。
- 上游候选：`enable_profiling` 应参与 NPU 插件 blob 缓存键（与"bank-aware blob import"同族——缓存键覆盖不全）。

### 工具/测量（本轮新增，ctrl/）
- `npu_start.ps1`（-v 逐相位时间戳）、`npu_tgsweep.ps1`（Levels on/off × 尺寸，报 Generation t/s）、
  `nat_tgsweep.ps1`（native `-dev none` 基线，`-dev CPU` 无效）、`npu_pp2b.ps1`、`npu_proflevel.ps1`
  （256/512 图逐节点 CSV，一次性 cache）、`npu_prof470.ps1`。IR 备份 `ctrl/ir/model_prefill_28645898.*`。
- 教训重申：**跨配置复用同一 CACHE_DIR 会串味**（profiling/非 profiling blob 混用即崩）；探针隔离缓存目录。

## 2026-11-01 深夜：视觉精度两根因连定案，NPU 视觉端到端收官 ✅

**结果**：NPU 视觉端到端描述与 native 一致（"black field + red circle + green band"），文本三问
3/3（最终二进制上复测）。视觉里程碑（milestone 4.x 视觉半）完成；吞吐缺陷次轮已定案修复
（见下方"视觉吞吐基线 → 已定案并修复"：warm encode 12.6 s → 542 ms）。

### 根因①：cacheless 图 input_len=-1 → size_t 回绕 → 多平面位置表读越界
- cacheless 图（mtmd 视觉编码器：显式 softmax，无 FLASH_ATTN_EXT）没有任何代码给
  `compute_params.input_len` 赋值（赋值点只有 KV 路径 ggml-decoder.cpp:950 与 cacheless
  FLASH_ATTN_EXT 扫描 :1102）。作为 size_t 回绕到 2^64-1，多平面 inp_pos 绑定的平面步长
  `p * input_len` 回绕成 `-p`：第 2/3/4 平面从缓冲区**前面**读 p 个元素 → rope 角度按位置错位
  （out[p][s] = h(s-p)）→ 编码器 cos 0.54。
- 证据链：rope-2 输入 CPU dyn vs CPU static 逐位一致（cos=1）→ 发散在 rope 内 → DEBUG_INPUT
  打出绑定 positions 与平铺 index 的差分模式 `out[p][s]=h(s-p)` → VISBIND 打出
  input_len=18446744073709551615。修复：平面长度从张量自身取（`ne[0]/n_planes`，utils.cpp
  静态 prefill 绑定），不依赖 decoder。CPU 静态 node_416 cos 1.00000 / maxabs 0（逐位一致）。

### 根因②：NPUW 配置三元组在 clip 图上静默损坏（NPU-only cos 0.52）
- 修复①后 CPU 静态逐位一致，NPU 仍 0.524。反转点：**同一 IR 在 python 里直接编译到 NPU
  （默认配置）cos 0.995** → 图翻译无罪，缺陷在引擎的编译配置路径。
- python 逐键二分（ir_vis2/model_prefill_13498411.xml，引擎 config 复现 cos 0.557）：
  单键全干净、两两全干净，最小坏三元组 = `NPU_USE_NPUW + NPUW_FOLD + NPUW_FUNCALL_FOR_ALL`
  （去掉 FUNCALL_FOR_ALL 或 FOLD 均恢复 0.995）。
- 为什么视觉图会吃到 NPUW 配置：clip 图 softmax **没有 mask 输入**（双向注意力），
  `is_cacheless_attn` 不置位 → `no_kv_cache=false` → 走完整 NPUW 配置而非 `without_npuw`。
- 修复：`cgraph_is_vision_encoder()`（扫描 `GGML_ROPE_TYPE_VISION` rope）在三个编译点擦除
  `NPUW_FUNCALL_FOR_ALL`（static 路径、naive 路径；擦除而非设 NO——顺带改变 config key 集，
  与 extra_cfg 3→4 一起把旧坏 blob 挡在缓存外）。engine 端 env 反向验证：显式
  FUNCALL_FOR_ALL=YES 复现漂移、NO 修复，因果链闭合。
- **上游备案**：NPUW 的 FOLD×FUNCALL_FOR_ALL 交互 bug（单图 IR、默认 NPUW 选项即复现）值得报
  OpenVINO；NPUW bank-aware blob import（热启动 <5 s 的最后依赖）仍未解决。

### 过程教训（本轮新增）
- **编译配置类缺陷先做"同 IR python 对拍"再怀疑图翻译**：一次对拍直接把搜索空间从 400+ 算子
  砍到 config key 二分。
- python `model.add_outputs()`（中间 checkpoint）在 NPUW 路径会让编译直接崩
  （"invalid unordered_map key" / f16 输出类型不匹配）——判据改用模型自带 result 输出。
- 引擎有两套"static"编译路径（naive_compute 与 ov_graph_compute_static），还有
  `without_npuw` 过滤：改编译配置前先确认目标图实际走哪条（vision 图走
  ov_graph_compute_static 的 full-config 分支，第一轮修错了点）。

### 下一轮候选（按优先级，2026-11-02 更新）
1. **性能主攻继续**：视觉吞吐已修复（542 ms）；回 4B decode / prefill 剩余杠杆
   （HANDOFF 性能轮清单）；LLM 图启动/导入时间也在此列（与上游 bank-aware import 同族）。
2. 上游：四条 NPUW/插件缺陷 = 汇总 `docs/upstream-npuw-report.md` + **逐条可直接粘贴的
   `docs/upstream-issues/01..04-*.md`**（①FOLD×FUNCALL 精度损坏；②NPUW 缓存不覆盖
   baked-Constants 图；③blob import 不感知 weights bank——热启动 <5 s 的拦路虎；
   ④enable_profiling×blob 缓存崩溃）。本机无 gh CLI——在 GitHub 网页逐条粘贴提交（等用户）。
3. 音频 top-1 级 f16 分歧（非阻塞，复利行为同类）。

### 视觉吞吐基线 → **已定案并修复**（2026-11-02，性能轮收官）
上一轮记录的 **5061 ms 是冷态假象**（单次冷跑把每进程 clip 重编译算进了编码时间）。
本轮分解（448×448 → 3136 patch 图，python 直测 IR 与 engine 行级计时双通道）：

| 通道 | 修复前 | 修复后 |
|---|---|---|
| clip 图 NPU **纯推理**（python，warm） | 147–191 ms | 同（本来就不慢） |
| clip 图**每进程编译**（engine 行级） | **~12.2 s**（每次都重编译） | ~0.4 s（blob 缓存命中） |
| `mtmd batch encoding`（warm，engine） | 12.6 s | **542 ms**（blob 已进 FS 缓存稳态）/ **896 ms**（blob 刚写回、FS 冷）|
| 冷启动首跑（一次性） | 16.9 s | 16.5 s（编译一次，之后全命中）|
| native ggml CPU / OV-CPU 动态（参照） | 435 ms / 956 ms | 不变 |

**根因**：NPU 编译配置只设了 `NPUW_CACHE_DIR`（NPUW 自己的 funcall/子图分解缓存），没设
`ov::cache_dir`（插件 blob 缓存）。视觉编码器权重烤成 `ov::Constants`，NPUW 缓存对它**永不命中**
（每进程全量 NPUW 重编译 ~12 s）；而 LLM 图走 shared weights bank 路线，NPUW 缓存正常命中
（~2.3 s），所以此前只有视觉暴露此缺陷。python 实证矩阵：NPUW-only 每次 12–13 s；加 CACHE_DIR
后同一 IR 命中 0.41–0.74 s；视觉 IR 跨进程逐位稳定（md5 相同，可安全命中）。
**修复**：`ggml-openvino-extra.cpp` NPU 分支在 `NPUW_CACHE_DIR` 旁补插
`compile_config.insert(ov::cache_dir(cache_dir))`（without_npuw 路径剥 CACHE_MODE 但保留
CACHE_DIR，非 NPUW 路线接受该键）。验收：最终二进制 warm encode 亚秒级、描述正确、文本 3/3、
音频 EXITCODE=0。工具：ctrl/vis-npu-cdir.ps1（PERFW 行级计时）、vis_time.py（IR 直测）、
vis_cfg.py（配置键二分）、vis-regress.ps1（全新缓存冷/热回归守卫）；缓存 cache_cdir。
**回归守卫（2026-11-02 最终二进制，全新 cache_regress 两次连跑）**：冷 16.5 s / warm 896 ms、
描述逐字正确。warm 值依赖 FS 缓存：blob 刚落盘再读 ≈900 ms，反复命中稳态 542 ms——对外口径
用"亚秒级（0.5–0.9 s）"，别只报 542。
**上游可报**：NPUW_CACHE_DIR 对权重烤成 Constants 的图永不命中——要么文档化，要么让 NPUW
缓存层也覆盖 baked-Constants 图（与 bank-aware blob import 是同一家族问题）。

---

> **✅ 已收尾（2026-10-31）：** 下方记录的 decode K 分支缺陷**已定案并修复**（commit `63179ef`，
> rope.cpp 显式 Concat tile + 注册门扩到 NPU），三问验收 3/3 首次全对。终章见
> [defect1-rootcause.md](defect1-rootcause.md)。本文其余内容保留为过程记录；首次验收闸门已过，
> 本地 commit 已随 v0.0.1 发布。

## 核心状态
- 根因已定案：NPU scatter 丢 index-0 写入 → docs/defect1-rootcause.md（但注意下面的修正）
- 修复尝试 #1（set_rows.cpp 静态 prefill 的 pad+shift+slice，工作树未提交）：**未生效**
  - 证据：nowarmf dump 逐 pass 差分与修复前逐位一致（row0 仍是 decode 预热的 65.49 常量）
  - 副作用：row43 从 0.9947 变为 0.0169（49.66 范数）——原因未明
  - 首要疑点：`context.is_prefill()` 在翻译期可能没有按预期置位（检查 NodeContext::is_prefill
    与 decoder 的 virtual is_prefill 在 prefill/decode 两图各自的返回值；用 GGML_LOG_ERROR 在
    translate_set_rows 入口打印 is_static/is_prefill/idx_name 三个值即可定案，改完必须同步
    E:→D: 两个树：src/ggml-openvino → D:\llm\npu\src\llama\ggml\src\ggml-openvino）
  - row0 的 65.49 常量 = 上下文初始化 decode 预热（decode_1）写入的哑 token K；
    --no-warmup 关不掉它（在 llama_context 构造里）
- 验收闸门未过（0/3），本地 7 commit 未推
- 工具：npu-probe.ps1 / WangCaiNpuReset 计划任务 / D: 构建树 bld_mtmd.bat

## 下一步精确顺序
1. 在 translate_set_rows 加三值日志，确认两图的 is_static/is_prefill 实际值
2. 若 flag 不对：改 decoder 的 is_prefill 传递（GgmlOvDecoder per-phase 已有 ptr_prefill）
3. 生效判据：nowarmf 复测 row0 cos(npu,cpu) ≈ 0.99 且 row43 恢复 0.99
4. 然后：三问验收（accept.ps1）→ 全对 → push 全部本地 commit
5. 别忘了 user 的 GPU server 占 20GB 的事：大 ctx 实验前先问

## 更新（pad/slice 修复尝试后的关键新事实）
1. is_static/is_prefill 探针证明 flag 正确：prefill 图 static=1 prefill=1，decode 图 prefill=0。
2. pad+shift+slice 修复**确实进入了执行图并生效**——但结果错误：row0 仍是 65.49 常量，
   且 row43 从正确(0.9947)变为错误(0.0169/49.66)。即 scatter+pad 路径本身能写，
   但与状态回写/refill 机制的交互有问题（疑似 Slice 输出作为 set_output_tensor/状态更新的
   形状或别名问题）。已回退到原始 scatter，构建绿色。
3. row0 的 65.49 值与 prompt 无关 + 上下文初始化 decode 预热（decode_1，--no-warmup 关不掉，
   在 llama_context::sched_reserve 里）用哑 token（可能是零/未初始化 embedding）写 row 0。
   真实 prefill 的 row-0 写入从未覆盖它。
4. 下一步候选（按序）：
   a. 给 ScatterUpdate 换 v12 ScatterND 或检查 indices 的 dtype/形状（Squeeze 后 [N] i64）
      ——先做一个 TBO 式最小 SET_ROWS 复现：TBO `-o SET_ROWS -p '.*ne=\[512.*'` 之类，
      用 0 索引复现"跳 0"，拿到 Intel 插件级证据；
   b. 若确认插件 bug：引擎侧修法改为"静态 prefill 的写用 Copy/Concat 重构"而不是 scatter
      （写范围连续且编译期已知 chunk 起点=indices[0]，可用 indices[0] 作 Gather 推导偏移）；
   c. 或在 llama.cpp 侧给 KV cache 的 cell id 加 1 偏移（rows 1-based），代价是全链路检查。
5. 当前 DLL = 原始 scatter（回归到本会话开始前的行为），构建绿色。

## 2026-11-01 续：缺陷收窄到 SSM_CONV 状态路径（scatter/conv 算子均排除）
- 裸 ScatterUpdate（含索引 0、含 SET_ROWS 精确形状/轴）：NPU 正常 → 插件不跳 0
- ScatterND 替换 prefill 写入：row0 依旧 → 与写入算子无关
- 裸 GroupConvolution python 对拍：max diff 0.003（f16 噪声级）→ conv 算子干净
- **引擎转储 cache_r 逐 pass 对比：第一个 pass（零状态）cos 就只有 0.4546，
  NPU 侧 nz 少 66（整段写零）** → 缺陷在 SSM_CONV 的状态视图/切片装配
- 同时确认：cell 0 由 ctx 初始化 decode 预热（BOS）独占写入是正常 llama.cpp 行为
  （两设备索引一致 [1..39]，prefill 不写 cell 0），CPU 的 cell-0 值是对的、
  NPU 的同一 pass 算出 65.49 错误值——与 conv 状态首 pass 发散同源
- 下一步：python 复刻 SSM_CONV 的状态视图装配（state 缓冲视图偏移 + 输入 concat
  的 NPUW 降级行为），或直接读 build_lfm_shortconv 的 view/concat 结构

## 2026-11-01 晚：decode 图 K 分支算子级定位 + IR 对比工具
- decode_5 同 pass：V row43 完美（0.9998 四头全对），K row43 h0/h2 逐位精确、
  h1/h3 摧毁（范数 17→33 / 13.8→34），周期 256 元素 → k_norm/RoPE 链的视图错误
  （V 证明 hidden/W_v/scatter 全对；prefill 同 token K 正确排除权重/量化）
- IR 已转储：E:\DTXY\WangCai\model_{decode,prefill}_3726599.xml
  对比脚本：D:\llm\npu\ctrl\trace_ir.py / trace_back.py（ElementTree，<layer>/<edge>）
- k_norm 结构两图一致（RMS 经 MatMul+Squeeze 降级）；差异待查 <port> 形状属性
  （decode 的 [4,128] reshape 视图 vs prefill 的 [n_seq,4,128]）与 RoPE 的
  VariadicSplit 常量
- 修复验证判据：nowarmf 式转储 row0 与 row43 的 cos(npu,cpu)≈0.99 → accept.ps1
  三问验收 → 全对 push 全部本地 commit（当前 13 个）

## 2026-11-01 深夜：IR 形状对比（最锐利线索）
- decode Kcur 链：MatMul(W_k) → Unsqueeze → Divide(RMS, MatMul+Squeeze 降级, 每头
  128 元素分组) → Reshape [1,1,4,128] → Multiply(×k_norm weight) → RoPE(VariadicSplit)
  ——prefill 同构，形状 [1,256,4,128]
- 损坏模式：同 pass 内 V 完美、K 的 h0/h2 逐位精确、h1/h3 摧毁（256 元素周期）
  → 嫌疑 = NPUW 对 1-token 形状 [1,1,4,128] 的 4 头广播（k_norm weight 与 RoPE
  cos/sin 的 broadcast tile）降级错误；prefill 的 [1,256,4,128] tile 正确
- 修复候选：把 decode 图的 k_norm/RoPE 形状改成与 prefill 同构（[1,1,4,128] →
  [1,4,128]→unsqueeze 回来），或绕过广播（k_norm weight 用 Concat 复制 4 份、
  cos/sin 同理）——在 translate 端做，避开 NPUW 的 broadcast tile bug
- 验证：ndtest 式转储 row0/row43 cos≈0.99 → accept.ps1 三问 → push

## 2026-11-01 深夜 II：广播 tile 修复无效 → elementwise-on-GEMV 理论
- AlignEltwiseOperandRanks 扩展（低秩 operand unsqueeze+4 头 tile，k_norm weight 与
  RoPE cos/sin 都覆盖）：row0/row43 完全不变 → 隐式广播排除
- 现有铁证组合：V 分支（matmul→直连 scatter，无 elementwise）完美；
  K 分支（matmul→norm/RoPE elementwise→scatter）h0/h2 逐位对、h1/h3 坏
  → **NPUW 的 DQ/GQ2i（N=1 GEMV）路径上 elementwise 算子的子块处理可疑**
- 下一轮：① GGML_OPENVINO_DEBUG_INPUT 已不可用（值太多），改为把 decode 图的
  K-cur（scatter 的 data operand）硬编码为额外图输出做一次 debug 构建
  （CPU 端 DEBUG_NODE 可行，NPU 端须静态加输出而非 Result 追加）；
  ② 或试 NPUW_DQ_FULL=NO / 其他 DQ 子开关针对 GQ2i；
  ③ 或把 decode 图 K 分支的 elementwise 全部换成 Concat/Copy 显式实现
- 判据不变：row0/row43 cos≈0.99 → accept.ps1 三问 → push（本地 14 commit）

## 2026-11-01 深夜 III：DQ 也排除 + RMS 分组成为头号嫌疑
- NPUW_DQ=NO：row0/row43 逐位不变 → DQ/GQ2i 排除；且错误值对图结构
  （ScatterUpdate/ScatterND/pad/broadcast-tile/DQ）全部不变、对输入 prompt 有响应
  （nowarm2 换 prompt 后 row0 变化 cos 0.15）→ 是"计算错误"不是"残留"
- NPU 与 CPU 唯一未排除的差异：K 独有的 RMS 链。rms_norm.cpp 的 ReduceMean 走 -1 轴
  （512 全池化），而 ggml 参考是每头 128 分组——需确认 llama.cpp lfm2.cpp 在
  build_norm 前是否 reshape（若 reshape 存在于 ggml 图而 OV 端丢失/错位，
  且 CPU-static 与 NPU 同错则 CPU 参照本身也偏离 native——需与 native CPU 对比 row0）
- 下一轮第一动作：① 读 lfm2.cpp k_norm 前的 reshape；② native CPU（-dev none）
  转储 row0/K(BOS) 与 CPU-static 对比 → 若 CPU-static 本身就错，缺陷在图翻译的
  RMS 分组，修复点 = rms_norm.cpp 的轴处理

## 2026-11-01 深夜 IV：待办第一项
- RMS 池化验证未完成：native CPU（-dev none）不经 OV 后端、GGML_OPENVINO_DUMP_BIN
  无效 → 需要 native 侧的 K 转储挂钩（或在 python 里用 GGUF 权重直接算 BOS 的
  每 head RMS K 参照）来回答"CPU-static 的 k_norm 是否真的 512 池化"
- 已排除清单（勿重测）：scatter 三种实现、NPUW FOLD/FUNCALL/DQ、广播 tile、
  conv 算子、权重量化、hidden（V 证明）、驱动/内存预算

## 2026-11-01 深夜 V：512 池化假说在 IR 层面死亡；同秩广播是唯一未排除项
- IR 复核（model_decode_3726599.xml）：k_norm 的 ReduceMean_73975 是 [1,1,4,128]→[1,1,4,1]，
  **每头 128 分组，图翻译本身正确**——"RMS 512 池化"假说不用再做 native 参照验证，省一轮
- 但发现此前"广播 tile 无效"结论的漏洞：AlignEltwiseOperandRanks 旧版只处理**秩不同**的广播，
  K 链上三个**同秩**广播从未被覆盖：
  ① RMS scale [1,1,4,128]×[1,1,4,1]（Multiply_73981）② RoPE cos/sin [1,1,4,64]×[1,1,1,64]
  ③ rotate-half [1,1,4,128]×[1,1,1,128]（Multiply_73993）
  且 k_norm weight 是 Constant，旧版顶部 guard 直接 return false——commit e904f84 声称覆盖
  weight 是不准确的，实际从未 tile 过 Constant 操作数
- 修复（align_eltwise_ranks.cpp 重写）：decode 形状门（out 秩≥2、head 轴=4、head 前全是 1）内，
  每个操作数 unsqueeze 到输出秩 + 显式 tile 全部 size-1 轴；Constant 直接材料化成全形
  Constant（f32、≤64k 元素），其余 Concat 倍增。prefill [1,256,...] 与动态图不进门
- 构建绿。验证：cache_tile（NPU）/ cache_tilecpu（CPU-static），compare-k-heads.ps1
  row0/row43 每头 cos≈0.99 判据

## 2026-11-01 深夜 VI：tile 真正进图后的新状态
- 修复注册门（translate_session.cpp：is_gpu() → gpu/npu/FORCE_STATIC）后 pass 首次真正生效：
  新 decode IR（model_decode_36452578.xml）k_norm weight 已材料化 [1,1,4,128]、
  Multiply 两操作数同形——343 个 Concat（旧 90）
- 中途修了一个倍增 bug：eps Add 上 Concat 倍增 1→2→8（应为 4）导致 shape inference 崩；
  改为成倍 + Slice 补尾
- 常量 tile 版（bld_tile5）：NPU decode 全 NaN（K/V/logits），文本退化为 ">>"
- 非常量 tile 版（bld_tile6，Constant 操作数跳过）：NPU decode 仍全 NaN（K l10/l12 NaN，
  文本退化）→ NaN 不是常量材料化引起，而是激活侧 Concat tile（RMS scale ×128 /
  cos/sin ×4 / softmax max / mask ×4 之一或组合）
- 并行验证中：① python 最小复现（隐式广播 vs Concat tile，[1,1,4,128] 各模式，NPU vs CPU）
  ② 转储取证（gwcpu vs tile-cpu CPU 中立性；nowarmf 基线 h0/h2/h1/h3 签名复核；tile-npu NaN 范围）
- 注意：analyze-tensors.ps1 原有 PS7 语法已修复（line 18 return if）

## 2026-11-01 深夜 VII：根因修复 —— decode 图 RoPE 的 cos/sin 头轴广播（已验证）
- 决定性证据链（graph-output 调试构建，ggml_dup+build_forward_expand 制造图输出）：
  ① decode_1 的 K pre-norm/post-norm 在 NPU 上完全正确（cos 0.997+，范数逐位一致）
  ② 缓存 K 行 0 只有偶数 128 块正确，奇数块是跨构建逐位相同的确定性垃圾
  ③ NPU post-rope vs pre-rope（位置 0，数学上恒等）：h0/h2 cos=1.0、h1/h3 cos 0.38/0.49
  → 缺陷 = 静态 decode 图 rope 的 cos/sin [1,1,1,128] 头轴广播在 NPUW 降级下坏掉
- 修复（rope.cpp）：静态 decode 图把 cos_full/sin_full 沿头轴显式 Concat tile 到
  [1,1,4,X]，绕开隐式广播。位置 0 恢复恒等；缓存 row0 四头 cos 0.997+ 范数逐位一致
- 验收：三问 48 token 全对（Q2 明确 "Beijing"、Q3 明确 "Paris"、Q1 推理正确）——首次通过
- 今日教训（务必记住）：
  a. AlignEltwiseOperandRanks 曾被 is_gpu() 门住——NPU 上所有"tile 无效"实验都是死代码，
     一次无效实验浪费了多轮重建。改 pass 注册门前先确认它真的在跑（改 IR 后 hash 会变）
  b. "解码行全坏/h0h2 精确" 等旧结论是 pass 错位比较的产物——转储比对前先按字节对齐 pass
  c. ggml_set_output 不足以制造图输出（遍历不可达），要 ggml_dup + ggml_build_forward_expand(gf,)
  d. LFM3-1.7B 走 lfm3.cpp 不是 lfm2.cpp（打补丁前先确认模型到 builder 的映射）
- 修复 commit：translate_session.cpp（注册门 gpu→gpu/npu/FORCE_STATIC）+ rope.cpp（tile）
  + align_eltwise_ranks.cpp（同秩 tile 扩展，norm 门 + 跳过常量；已验证中性）

## 2026-10-31 深夜 VIII：剩余目标推进（1.2 ✅ / 4.x 新阻塞点）
- 里程碑 1.2 复测通过并入库 status.md：p220 续写 64 token CPU-static vs NPU **逐字节一致**
  （修复前同判据通过、修复中断、现已恢复）；zh 指令生成 72 token 连贯无坍塌；
  自由生成 top-1 与 f32 参照第 5 步起分歧 = f16 噪声复利（cos 0.5–0.9，无平台期）
- Omni 音频（milestone 4.x）重测推进两步：
  ① 417 个 "failed to process weight tensor" 归零（7c1d32f 回归修复确认生效）
  ② -c 512 下不再 DEVICE_LOST（默认 ctx 会撞内存预算；本次元凶 vmmemWSL 20GB）
  ③ 修了一个真 bug：ggml-decoder.cpp 的 IM2COL 动态维断言假设 OW==IW，对 stride-2
     下采样卷积（Whisper 式音频编码器）必误报——改为按卷积公式 (I+2p-d(k-1)-1)/s+1
     断言，批量维保持恒等（提交待做）
  ④ 当前阻塞点（下一个战场）：音频编码器注意力 Add(scores [1,8,38,69], mask [1,1,38,38])
     宽度不匹配——mask 是方的（38 帧查询）但 K 侧 69 列。两个假设：clip.cpp 的
     mel pad/分块策略给了 69 的 K 序列而 mask 仍按帧数建方阵；或 engine 的 clip mask
     构建假设方阵。下一步：dump clip 图的 K/V 与 mask 的 ggml 形状（GGML_OPENVINO_DUMP_IR
     已确认可用），对照 mtmd audio 分块逻辑（n_chunks=1/3、31 帧差值来源）
- 设备健康协议有效：DEVICE_LOST 后 WangCaiNpuReset 复位 + 探针（probe 缓存被清理后
  会冷编译，150s 超时会误报 SLOW——给 probe 换个常驻缓存目录或加大超时）

## 2026-10-31 深夜 IX：Omni 音频又进一步（CPU 全通，NPU 差一层）
- 本轮修复（全部已提交或待提交）：
  ① IM2COL 动态维断言 → 卷积公式（ccdf715）
  ② utils.cpp：clip 图 mask（名字 attn_mask*，2-D [n_kv,n_q]）在 static_decode 与 dynamic
     两条绑定路径都改为**原样直绑** {1,1,n_q,n_kv}——此前被 LLM chunk 布局重成形
  ③ ggml-decoder.cpp get_graph_input_shape：attn_mask* 名字的 2-D mask 参数形状同样直绑，
     绕开 get_mask_ctx_size() 的 KV 环宽度
- 结果：**CPU 设备下 Omni 音频端到端跑通**（audio 编码 + 生成，EXITCODE=0，无异常）
- NPU 设备下仍失败，同一 Add：scores [1,8,38,69] vs mask 参数 [1,1,38,38]。
  已证伪：不是 get_graph_input_shape（插桩显示它收到 [69,38] 且我的分支会返回 {1,1,38,69}）；
  不是 trim_mask_to_kv（38<=69 直接原样返回）；不是陈旧 blob（NPUW_CACHE_DIR 每次都清）
- 关键疑点：报错的 friendly_name 是 **Add_47152**，而 audio 图 IR 里的 Add 是 65xxx 编号族
  ——失败的可能不是同一张图！mmproj 里还有 vision 塔（dots3note-v，流式窗口设计同源，
  K 同样带 31 帧上下文）。下一步：① 打印 NPU 下实际编译的 clip 子图清单与各自
  参数形状（GGML_OPENVINO_DUMP_CGRAPH 或 NPUW 的形状日志）；② 确认 vision 图是否
  也用 attn_mask 命名 + 是否被 [38,38] 的某处覆盖；③ 或在 set_input 前打印
  bound tensor 的 shape 定位是编译期形状还是绑定形状不一致
- 顺便：mtmd-audio-c512.ps1 里 DEVICE 一度被改成 NPU，调试 CPU 路径时注意

## 2026-10-31 深夜 X：NPU clip-mask 的最后谜团（插桩数据齐全，待下一轮）
- 插桩结论（NPU 运行、DEBUG_INPUT=1）：
  ① get_graph_input_shape 收到 attn_mask ne=[69,38,1,1] is_inp_mask=1 —— 我的分支应返回 {1,1,38,69}
  ② 但编译期报错仍是 Parameter attn_mask f32[1,1,38,38] —— 形状被第四处来源覆盖
  ③ **三个直绑分支（static_decode/prefill/dynamic）的日志一次都没打印** —— 运行期 mask 绑定
     根本不经过这三个函数！剩下唯一候选：convert_ggml_input_to_ov 的 ggml_tensor->extra
     快路径（buffer 分配时挂的预建 ov::Tensor）——extra 的 shape 来自 tensor->ne 反转，
     理论上应是 [1,1,38,69]……除非挂 extra 时的 ne 是 [38,38]（挂的时机早于 mask 构建？）
- 下一轮第一动作：在 convert_ggml_input_to_ov 的 extra 快路径命中时打印 shape+name（NPU 跑一次）；
  若命中，追查该 extra 是谁在何时以什么 ne 创建的（buffer set_tensor / alloc 顺序）
- 注意：Add_47152 编号族与 audio IR（65xxx）不同——先确认失败图就是 audio 编码器
  （state_in_k_* 打印紧邻失败点，倾向是），但 mmproj 里 vision 塔同源设计，勿排除
- CPU 路径已全通：mtmd-audio-c512.ps1 里 DEVICE 临时改 CPU 即可复现成功

## 2026-10-31 深夜 XI：NPU 音频编码器跑通；推进到 LLM×音频 token 层
- 第四条绑定路径谜底揭晓（最终插桩）：get_graph_input_shape 的 mask 分支返回 {1,1,38,69} 正确，
  但函数末尾有个 LLM 专用特例——**SOFTMAX 的 mask 输入被强制方阵化 [1,1,seq_active,seq_active]**，
  lfm3a 音频注意力恰走 SOFTMAX → {1,1,38,69} 被盖成 {1,1,38,38}。修复 = attn_mask* 名字跳过方阵化
- 连锁修复 2：CACHE_MODE——clip 图因不支持的算子从 NPUW 回退到非 NPUW 路径，该路径拒绝
  为 NPUW 缓存加的 CACHE_MODE 选项；without_npuw() 现在连 CACHE_MODE 一起剥
- **结果：NPU 上音频编码器编码成功（chunk 1/3 done）**，推进到 LLM 图消费音频 token：
  新错误 = q_layernorm/rope 形状不一致（Q [1,38,16,128] vs rope cos Concat [1,256,1,128]，
  256 = LLM prefill chunk 的位置表 vs 38 个音频 token 的 ubatch）——LLM rope 的 sin/cos
  表长度与音频 ubatch 的 token 数不匹配，rope.cpp 的 sin_cos 共享缓存 key（op_params）
  可能不含位置数，或 prefill 静态 256 图被 audio ubatch 复用。这是下一轮第一战场
- 本轮提交：softmax 方阵化门 + CACHE_MODE 剥离 + 插桩清理

## 2026-10-31 深夜 XII：LLM×音频 rope 形状——缩到 decoder 相位判定
- 完整输入清单已拿到（DEBUG_INPUT 插桩，mtmd-audio15/19）：
  音频 embedding 图的全部输入 = model.embed_tokens [2048,38]（音频 embedding，cb 命名，
  非 inp_embd！）、inp_pos [38]、mask [256,38]、KV idx [38] —— 图内部在 38 处自洽
  （embed_tokens [2048,38] → norm → rope 应得 cos [38]）
- 但 rope cos 实为 [1,256,1,128]：**该图的 gis 打印 prefill=0** —— 38 token 的批次被
  decoder 判成 decode 相位！于是 is_inp_pos 静态分支走 len=1/m_prefill_chunk_size 的
  decode 逻辑，rope/位置/mask 的形状假设全部错位。候选根因：
  ① get_is_prefill(cgraph, inp_pos) 对 embd 批次的判定（mtmd 音频 batch 是否设置
     inp_pos 使 ne[0]>1 可靠？）② HANDOFF 已警告的 ptr/ptr_prefill decoder 别名
     （首 pass 相位污染后续图）③ llama.cpp 对 embd batch 的 inp_pos 构建
- 曾试并回退的修法（勿重试）：inp_embd/model.embed_tokens pad 到 256（reshape 常量
  [38] 烤死，不匹配）；positions 自然长度（文本 shortconv reshape [256] 烤死，回归）
- 正确方向推测：修 ②（decoder 相位别名）或 ①——音频批次必须被判成 prefill 且
  inp_pos 的参数形状跟随真实 38（对齐 mask [256,38] 的 38 行）
- 下一步第一动作：在 get_is_prefill / decoder 构造处打印音频图的 is_prefill 判定依据
  （inp_pos->ne[0]、调用来源），确认 ①/② 哪个成立

## 2026-10-31 深夜 XIII：LLM×音频 rope 定案——shortconv 状态机按 chunk 固化，修法在 llama.cpp 侧
- 完整证据链（gis 全量插桩）：
  音频 embedding 图输入全部在 38 处自洽：model.embed_tokens [2048,38]（mtmd 音频 embedding 的
  cb 命名，非 inp_embd）、inp_pos [38]、mask [256,38]、KV idx [38]
  但 LLM shortconv 的状态装配（cache_r [12288]=6×2048 状态视图、Slice [1,1,2,2048]、
  Reshape [1,1,256,2048]）**全部按 256 chunk 几何烘焙**——文本 ubatch 恰好被 llama.cpp
  pad 到 256 所以自洽，音频 ubatch（38）天然不匹配
- 已试并回退（勿重试）：① embd pad 到 256（llama.cpp 图内 reshape 常量 [38] 烤死不匹配）
  ② positions 自然长度（shortconv 状态装配 [256] 烤死，文本回归 Reshape_1291 [1,1,2,2048]→[256]）
- **结论：引擎侧无法单方面适配，音频 ubatch 必须 pad 到 chunk 宽——修法在 llama.cpp 侧**
  （D: 树 mtmd.cpp / llama-batch）：音频 embedding 批次喂给 llama_decode 前 pad 到
  llama_n_ubatch(ctx)=256：零 embedding + 位置顺延 + 只在真实 token 上置 output 标志 +
  padded 行的 attention 由 causal mask 自然遮蔽（作为 key 会被后续 chunk 的滑窗读到，
  需确认 zero-embedding 的 K/V 是否会污染——若污染需在 mask 里显式遮蔽 padded 行）
- 验证路径：pad 后 NPU 跑 mtmd-audio-c512.ps1 → 三 chunk 全编码 → 生成文本 → 与 CPU
  （DEVICE=CPU 同脚本已端到端通过）对比

## 2026-10-31 深夜 XIV：修复落地——引擎侧 raw-embd pad + 动态维传播，NPU 音频端到端跑通
- **先修正上一节的一个定案错误**：llama.cpp 并没有 pad 文本 ubatch。cgraph dump 证实文本图的
  ggml 节点按自然宽度（40-token prompt 的图就是 40 宽）；256 宽来自**引擎的 bind 时 pad**
  （get_ov_input_tensor_static_prefill 把 inp_tokens/inp_pos 补到 chunk 并以 last_value+1 填充，
  chunk_valid_len 参数让 shortconv 状态装配只消费有效行）。因此上一节"llama.cpp 侧 pad 音频"
  的方案是错的：llama.cpp 侧 pad 会让 chunk_valid_len=256、padded 零行的 conv 状态被永久写进
  cache_r/cache_s（污染后续所有 chunk），KV cell 消耗也会错位。**修法在引擎侧，对齐文本机制。**
- 三处改动（全部在 ggml-openvino，llama.cpp 零改动）：
  ① `ggml-decoder.h`：新增 `is_raw_embd`——input 标志的 F32 NONE 叶子直接喂 RMS_NORM（mtmd
  音频/图像 embedding 的入口形态，与 token 路径的 GET_ROWS 形态区分）。
  ② `ggml-decoder.cpp get_graph_input_shape`：raw-embd 分支声明 `{1,1,chunk,2048}` 静态形状；
  `utils.cpp get_ov_input_tensor_static_prefill`：bind 时把 embedding 数据零填充到 chunk 宽
  （零行 RMS 范数=0，激活有限；K/V 散射到 last_value+1 的 cell，mask 的 -INF 列保证不可读）。
  ③ `ggml-decoder.cpp compute_node_dynamic_dims`：raw-embd 叶子标动态维 1（token 轴）——这是
  最关键的一处：没有它，CONT/Reshape 链会把捕获期的 n_tokens=38 烤进 Reshape 常量
  （Reshape_165021: Slice[1,1,256,2048]→[1,1,38,2048] 直接 shape-inference 报错），文本路径
  之所以没事是因为 inp_tokens 走 GET_ROWS 天然获得动态维。
- 结果：
  - **CPU 静态路径音频端到端通过**（EXIT=0，回答 "A high-pitched, pure"，f32 动态参照
    "A high-pitched electronic tone."——语义一致）
  - **NPU 音频端到端通过**（EXIT=0，编码 3 chunk → LLM 消费 → 生成 "instrument." 之类的
    音频描述）。与 f32 参照有 top-1 级分歧，与文本自由生成已记录的 f16 复利行为同类
    （status.md 1.2 的注）；对照实验：Omni-2B 纯文本 2+2 NPU=CPU="4"、98-token 长文本
    prefill NPU=CPU="Paris"，说明 LLM 图本身无恙；音频编码器输出统计 NPU≈CPU（fp16 噪声级）。
  - 文本回归：accept-smoke 3/3（LFM3-1.7B CPU 静态）。
- 排查过程留档：先用 reshape-bake/view-bake 临时插桩定位烤死常量的来源（cont.cpp 的
  dst_shape 全烘焙路径），插桩已全部拆除。mtmd-audio-c512.ps1 里还有一行 DEBUG_INPUT='1'
  需在最终验收时移除。

## 2026-11-01：缺陷 2（NPU 解码性能）第一轮解剖——三项根因定案
- 测量方法：GGML_OPENVINO_PROFILING=1（每步 Graph inference / OV raw infer 分解）+ =2（逐节点
  CSV，注意 CSV 写入进程 CWD，-n N 时只覆盖前 N+1 个文件，取最后一个；且逐节点耗时总和可能
  超过 wall time——DPU/DMA 并行记账）
- **时间都花在哪（-c 512，70 ms/步，12.5 t/s）**：bind 开销仅 0.3 ms，77 ms 几乎全在
  `infer_request->infer()` 内部。逐节点：Parameter（状态输入）31.8 ms（单节点 DMA 20 ms +
  Shave 9.8 ms，~11.5 MB KV 状态 → **0.4 GB/s，host→device 每步全量搬运**）、Multiply 25.5 ms、
  MatMul 22.5 ms（其中 **lm_head 一项 10.9 ms**）。
- **ctx 线性项实测**：c=512→70.6 ms、1024→115.7、2048→293.7（超线性，二次项 ~5.6e-5 ms/token²）。
  c=2048 逐节点：Add 112 ms + 一批 ~48 ms 节点（ScaledDotProductAttention / Transpose
  cache_k_l2 / Multiply / MatMul）——全部是注意力路径对**静态全 ctx 跨度**的操作。
- **根因 ①**：compute_llm_params 里 `if (is_static) attention_size = ctx_per_seq` 把静态 decode 图的
  注意力跨度烤死为全 ctx——即使只填了 40 个 cell，每步也处理 2048。FA 路径的 flat-KV reshape
  本来就吃 attention_size 输入（动态路径运行时切片、30 t/s 的原因）。
- **修复尝试与证伪**：把 attention_size 参数化（bind 真实 n_kv=PAD(填充,256)）→ NPU 插件编译期
  直接拒绝："to_shape was called on a dynamic shape"——**NPU 静态图不容忍任何动态中间形状**，
  运行时切片在单张 NPU 图里不可行。代码保留为 GGML_OPENVINO_TRIM_DECODE_ATTENTION（默认 0，
  仅 CPU/GPU 静态实验用），extra_cfg 位已隔离 blob 缓存。注意 flash_attn_ext.cpp 的
  num_heads_kv 提取已改为容忍动态形状（对静态路径无害）。
- **根因 ②**：NPU 上没有 remote tensor（"remote tensor is not used for NPU yet"，extra.cpp 注释；
  create_tensor_extra 的 remote 分支 `GGML_ASSERT(ggml_openvino_is_gpu())`）→ KV 状态每步
  host↔device 往返，~30 ms/步 @c512，随 ctx 线性放大。GPU 路径的 USMTensor 零拷贝方案在
  NPU 上不可用。
- **根因 ③**：NPUW 编译开关无效（NPUW_DQ:NO / FOLD:NO / FUNCALL_FOR_ALL:NO 全部持平或更慢）
  ——瓶颈不在折叠/量化策略。
- **NPU 兼容的修复路线（未实施）**：离散多跨度 decode 图组——每个 PAD(n_kv,256) 级别一张全静态
  图（256/512/…/ctx），按填充级别切换请求；权重经 NPUW_WEIGHTS_BANK=shared 共享，冷编译
  ctx/256 张图（NPUW_CACHE_DIR 持久化后一次性成本）。预期把 decode 恢复到与填充级别相关的
  ~50 ms 基线，并消掉高 ctx 的超线性项。状态 I/O 项（根因②）另需 NPU remote tensor 或
  stateful 化，独立工作量。
- 当轮结论：12.5 t/s @c512 已接近 OpenVINO GenAI 在 NPU 3720 上 1-2B 模型的公开水平；要显著
  超越需要上面两条重型改造，本聚焦轮先落地测量基建（PROFILING=2 已接入静态路径）与根因记录。

## 2026-11-01：缺陷 2 第二轮——离散多跨度 decode 图组落地（17× @c8192）+ accept-smoke Q3 flake 定案
### 多级 decode 图（已实施、已验证）
- 方案：`decode_attention_level(n_kv, ctx)`——按 PAD(n_kv,256) 的离散级别（256/512/…/ctx）
  每级一张全静态 decode 图，llama.cpp 每步按当前 n_kv 选级；KV cache 参数与绑定按级别裁视图
  （level_shape[2]=level），每步状态 I/O 与该级别成正比。`ComputeParams::attention_size_raw`
  在烤死前捕获 mask->ne[0]，供命中判定用。
- 实现（ggml-openvino）：utils.cpp 三编译分支（dual=prefill+decode@ctx / decode-only=私编某级，
  编前**驱逐**其他级——NPU 设备预算只容 prefill+一张 decode 图，第二张常驻在首次 execute 即
  ZE_RESULT_ERROR_UNINITIALIZED（缺陷-7 签名） / prefill-only）；convert_ggml_input_to_ov 里
  KV 零填充（fill>0 且 fill<span 时把 [fill,span) 段清零，杜绝上一序列残留跨级别泄漏）；
  ggml-decoder.cpp is_kvcache 输入形状按级别裁剪；GGML_OPENVINO_DISABLE_DECODE_LEVELS=1 逃生门
  回退全 ctx 单图。escape 门全部登记进 ggml-openvino-extra.cpp allowlist。
- 实测（LFM3-1.7B Q4_K_M，NPU 3720）：**decode 15.0-15.1 t/s 与 ctx 无关**——c=8192 从 0.9 t/s
  →15（**17×**），c=2048 从 3.3→15（4.5×）；600-token 任务跨 256/512/1024 三级切换全程无错；
  7K prompt 在 4096 级正常；token 流在不同 ctx 下逐字节一致；level 图 vs ctx 图 48 步 logits
  逐位一致（diff-lines: 0）。
- 教训（过程事故）：D: 工作树的未提交多级修改曾被意外还原到早晨版（/md5 与 E: 提交一致/），
  从 /tmp/mlnew 备份恢复后重建验证通过。**多轮实验期间必须保持 /tmp 双备份**（mlnew=当前，
  mlbak=已提交基线）。
### accept-smoke Q3 flake 定案（测试基建 bug，非引擎回归）
- 现象：Q3（"1+1"）在多级代码上 2/3、NO_KV_ZEROIZE 下 3/3，看似 zeroing 相关。
- 真因（两层）：① 判定 `$text -match '2'` 匹配**整个日志**，性能行
  `[ Prompt: 23.7 t/s | Generation: 29.0 t/s ]` 的 t/s 数字随机含 '2'，假通过/假失败随机器
  负载漂移——之前的 "zeroing 相关性" 完全是这行数字噪声，小样本巧合；② n=48 对 LFM3 的思维
  链太短：note-4 文本（"or simply '4'" 幻觉）动/静态路径**逐字节一致**（非引擎回归），n=96
  时两路径都到 "Thus 1+1 = 2"。
- 修复：accept-smoke.ps1 改为只匹配答案区段（回显 prompt 与 `[ Prompt:` 性能行之间），默认
  -n 96。修复后 3 轮 3/3 全过、完全确定。
- zeroing 结论：保留（level 切换时清 [fill,span) 是跨级别正确性保障；A/B logits 逐位一致，
  无数值代价）；GGML_OPENVINO_NO_KV_ZEROIZE 保留为调试逃生门。

## 2026-11-01：缺陷 2 第三轮先导探针——NPU stateful（VariableState）路线证伪
- 探针（tools/npu-probes/，OpenVINO 2026.4.1 Python API，LFM3 同机）：
  - `npu-stateful-probe.py`：read_value/assign 最小图。**NPU 支持 VariableState**——query_state()
    正常、状态跨 infer() 在设备上累积（out2=2 证明；初始值张量被忽略、按 0 初始化）。
    注意 OV Python 构造坑：Model([results], [sinks], [params], name) 的 sinks 在参数**之前**，
    且 sink 必须是 Assign 节点本身（Result 不算 Sink）。
  - `npu-state-vs-param-bench.py`：8.4 MB f16 KV 量级状态，每步耗时对比：
    **参数绑定 6.1-6.3 ms/步（≈1.4 GB/s） vs 设备驻留 state 43-45 ms/步**——stateful 慢 7 倍。
  - 状态大小扫描（2/8/32 MB）：11.4 / 43 / 205 ms/步，≈**5-6 ms/MB（0.18 GB/s）**，
    成本随大小线性——每次 infer() 都走慢速状态检查点路径，不是固定开销。
- **结论**：stateful 化（设备驻留 KV）在当前驱动/插件上是性能反模式，路线证伪；多级 decode 图的
  参数绑定 + 级别裁剪就是当前 OpenVINO NPU 上的最优架构。defect-2 剩余分量里，state I/O 已被
  级别裁剪大幅缩小，下一个独立杠杆是 lm_head（11 ms，[2048]×[128000] 单发 GEMV）。
- 过程注意：**平铺 [1, N] 大形状的 elementwise 图会让 NPUW 编译爆炸**（0.5 MB 平铺 add 图编译
  数分钟、CPU 占满）——探针一律保持 4D 结构。

## 2026-11-01：缺陷 2 lm_head 杠杆探察——u4 化证伪，F16 常量即当前快路径
- 判定（IR 解析 + 代码路径）：LFM3 的 lm_head 与 token_embd 共享（GGUF 无 output.weight，
  token_embd 为 Q6_K）。NPU 上被 `ggml_openvino_get_requant_type` 强制 **F16 常量（~524 MB）**
  ——历史原因是 Q8_0_C cluster 布局在 NPUW 上 execute 崩（ZE_RESULT_ERROR_UNINITIALIZED），
  注释以"vocab 每 token 只读一次"接受之。多级 decode 图落地后它成了最大单项：
  **13.7 ms/步（38 GB/s，带宽界附近）**。CPU 静态路径则是 Q8_0_C（i8 262 MB）。
- 实验（新增 `GGML_OPENVINO_REQUANT_EMBD_Q4=1`，token_embd → Q4_0_128，与其余层同款 u4；
  已登记 extra_cfg allowlist）：NPU 实测 **13.0 → 2.5 t/s，慢 5 倍**——NPUW 压缩 MatMul
  （GatherMatMulCompressed）对 [1,2048]×[2048,128000] 高瘦形状不划算；三问验收 3/3 精度无损
  但性能反模式。**结论：u4 lm_head 证伪，F16 常量即当前快路径**；选项保留为默认关（零风险，
  blob 缓存键已隔离）。
- c512（level==ctx）decode 步现状（PROFILING=2，多级 build）：状态输入两 Parameter 合计
  ~33.7 ms（level 256 时 KV≈全 ctx，裁剪无收益）+ attention Multiply 22.4 ms + lm_head 13.7 ms。
  decode 15 t/s 下进一步提速的可行方向只剩：状态 I/O 的布局/搬运优化（非 stateful，已证伪）、
  attention Multiply 的算子降级路径、或 llama.cpp 侧 vocab 裁剪（只算候选 token 的 logits，
  涉及采样器改动，超出本轮）。**decode 攻坚就此收官，转 2.2 热启动。**

## 2026-11-01：里程碑 2.2 第一轮——热启动 23 s → 8.9 s（三项修复）
### 启动时间分解（-lv 5 + GGML_WARM_TRACE 逐段实测，c512、warm blob 缓存）
原 23 s 的构成：**权重 repack ~10 s** + 图转换 ~2.3 s + NPUW 编译/导入 ~2×1 s + 首次推理 ~1.1 s
+ 采样/其它。逐项发现：
- **repack 串行且标量**：`requantize_to_buffers` 的全量物化路径对每张 8.44 MB FFN 权重耗时
  ~0.09 s（94 MB/s），153 张张量串行 ≈ 10 s；token_embd（Q6_K→F16，205 MB）单张 0.75 s，其中
  大头是 1 GB 的一次性 f32 暂存分配。
- **ov::parallel_for 是串行回退**：本机 OpenVINO 构建无 TBB/OpenMP 时它退化为单线程
  （实测 worker threads = 0）——不能指望它并行化任何加载期工作。
### 修复（本轮落地）
1. **requant 全量物化路径按行分块并行**（ggml-quants.cpp）：std::thread 池（24 线程），chunk 边界
   对齐偶数块保持 u4 zp 字节对（对称 i4 无 zp，显式 symmetric 参数绕过元素类型推导——
   字节偏移 view 的 u8 包装会骗过 is_symmetric 判断）；每 chunk 独立 scratch，消掉 1 GB 暂存。
   token_embd 0.75→0.11 s，FFN 单张 0.09→0.01 s，**整体 repack ~10 s → ~1 s**。
   不满足行对齐/块偶数条件时回退原串行路径（Q4_1_64 一律串行）。
2. **make_dirs 的盘符 bug**（model-cache.cpp）：`_mkdir("D:")` 返回 EACCES 使
   GGML_OPENVINO_COMPILED_MODEL_CACHE_DIR 在任何 Windows 盘符路径下**静默失效**。跳过 "X:" 组件。
3. **多级 decode 图接入 COMPILED_MODEL_CACHE_DIR**（utils.cpp build_static_model）：prefill /
   decode@level 各自指纹（phase tag + level 混入 extra_cfg），import 跳过转换+编译。
### 当前状态与剩余
- 热启动实测 **8.9 s**（llama-completion -n 4，warm blob 缓存）。距离 <5 s 目标剩两项：
  ① CM 缓存在 NPU 上 import 失败——**NPUW 导出的 blob 不含权重**（26 MB/图），import 需要提供
  WEIGHTS_PATH 或 MODEL_PTR（指向与导出时相同的权重存储）；三种图各报一次 WARN 后回退编译。
  下一轮把权重缓冲 dump 成文件并注入 NPUW 权重属性（预期再省 ~4.4 s：转换 2.3 + 编译 2.1）。
  ② 首次 prefill 推理 1.1 s（图首次下载到设备）。
- 无回归：NPU 14.5 t/s + 三问 3/3；CPU accept-smoke 3/3。
- 测量基建：GGML_WARM_TRACE=1 打开 repack/加载分段 trace（env 门控，标记 TEMP，2.2 收官时拆除）。

### 2.2 后续探针：NPUW 无权重 blob 的 import 契约（tools 探针 probe_stateful/probe_mp*.py）
- python（numpy 常量，OV 自持内存）编译导出的 blob **内嵌权重**（290 KB 小模型），import 无需任何
  property；带 `WEIGHTS_PATH` 指向同内容 .bin 也 OK，`MODEL_PTR` 传裸地址报
  "Incompatible model argument"（它要的是 ov::Model 实例，不是指针——名字有误导性）。
- 引擎 C++ 导出的 blob **无权重**（26 MB/图）：权重常量直接包装 backend 权重缓冲（避免每图复制
  1.3 GB），NPUW 识别为外部权重 → 导出 weightless blob，import 断言要求 WEIGHTS_PATH 或 MODEL_PTR。
- `WEIGHTS_PATH`/`MODEL_PTR` 字符串确认存在于 openvino_intel_npu_plugin.dll；但 NPUW 期望的文件
  布局/偏移基准无法从二进制推断（python 的成功案例不能外推——它的 blob 本就带权重）。
- **结论**：<5 s 的最后 ~4 s（转换 2.3 + 编译 2.1）需要拿到对应 OpenVINO 提交的 NPUW 源码，确认
  weightless blob 的权重重定位契约（或改用权重内嵌导出 + 每图 1.3 GB 暂存副本的方案）。已列入下一轮。
- 其它备选（记录）：dual 分支的 decode@ctx 图改惰性可省启动 ~1.5 s，但把 1.5 s 卡顿挪到 256-token
  跨级点，且后台预热会与 NPU 设备预算（缺陷-7）冲突，暂不动。

### 2.2 后续：NPUW 权重分离（WSH）契约已从源码完全打开
- NPUW 插件源码已定位并 sparse-clone 到本机：`D:\llm\npu\probe_stateful\ovsrc`
  （openvinotoolkit/openvino master，`src/plugins/intel_npu/src/plugin/npuw/`；注意 master 里 npuw
  已从 `src/npuw` 移到 `src/plugin/npuw`）。
- 关键代码路径：
  - `npuw/compiled_model.cpp:98` `should_use_weightless_flow`：NPUW_FOLD 开（默认）且
    const_to_offset 非空 → 导出 weightless blob；
  - `npuw/compiled_model.cpp:120` `make_import_weights_ctx`：import 时按优先级
    `WEIGHTS_HANDLE_PROVIDER`（ov::FileHandleProvider 回调，可给 mmap 句柄）→
    `WEIGHTS_PATH`（ov::weights_path，mmap 文件）→ `MODEL_PTR`（**ov::hint::model**，
    是 `shared_ptr<const ov::Model>`，不是裸指针——名字有误导）；
  - 权重引用 = blob 里记录的 `(bin_offset, size)` 对，`bin_offset` 由
    `src/core/src/weight_sharing_util.cpp`（ov::weight_sharing WSH pass）在编译预处理时打进
    `WeightlessCacheAttribute`——**指向 WSH 重建的共享权重存储**，不是我们的 backend 缓冲。
- **下一轮实现方案（按优先级）**：
  1. 引擎侧自行走 WSH 等价流程：把三张图共用的 1.3 GB 权重缓冲写一次
     `<cache_cm>/weights.bin`，并给 create_weight_nodes 产出的常量打上对应 bin_offset 的
     WeightlessCacheAttribute（或改从 ov::read_model(xml,bin) 读回），使 NPUW 导出/导入的
     offset 语义对齐——import 即 mmap weights.bin（~0.45 s/图）。
  2. 或者放弃 weightless：让常量在编译期持副本（每图 +1.3 GB 暂存），blob 内嵌权重，
     import 免属性——磁盘 3.9 GB、净省 ~2.6 s。
- 预期账目（即使全部打通）：CM 缓存净省 ≈2.6 s（转换 2.3 + 编译省差），热启动 8.9 → ~6.3 s；
  到 <5 s 还需解决首次设备图下载 1.1 s 与 NPUW blob import 的 ~1 s——需要 NPUW 深处（LLM
  compiled model 的 init schedule）或接受 6 s 量级作为 2.2 的阶段性目标。

### 2.2 后续：CM 缓存 NPU 实测——机制性不可行，保持 opt-in 关闭（本轮终态）
- 打通后发现：prefill 能 OPTIMIZE_SPEED 内嵌权重导出/导入（4.1 GB 缓存目录，import 0.3 s ✓），
  但 **imported 模型的权重 bank 与后续编译的 decode 图不共享**——设备权重重复，执行劣化 10×
  （decode 729 ms/token vs 正常 75 ms），踩缺陷-7 的设备预算。decode 图也不能 CM import：
  shared bank 的 `read_and_add_tensor` 对重复 UID 直接 assert（NPUW import 无去重——GenAI 流程
  每进程只 import 一个模型）。
- 结论：**NPU 上不要设 GGML_OPENVINO_COMPILED_MODEL_CACHE_DIR**（默认未设，无影响）。CM 缓存
  代码保留（CPU/GPU 路径可能受益），<5 s 的剩余 ~4 s 需等 NPUW 支持 bank 感知的 blob import
  （权重句柄 provider / bank 去重），已记录于此。
- 热启动终态：**默认路径 8.9-9.4 s**（repack 并行化贡献 ~14 s）。无回归：NPU 三问 3/3、
  CPU accept-smoke 3/3。

## 2026-11-01：音频"回归"定案——三层因果链闭合（NPU 音频恢复正确输出）
- 现象回顾：NPU/CPU 静态音频在多级 decode 提交后输出坍缩为 "<think>"+EOS/静默退出；NPU 另有
  level 图 UNINITIALIZED 崩溃。逐层 dump 对比（GGML_OPENVINO_DUMP_BIN + 逐层 KV cos）定位：
- **因果①（已修复）音频编码器 requant 精度**：NPU 默认把 Q4_0 重分组到 group-128 对称，对
  mmproj conv 栈（"a."-前缀张量）是纯损失——projected 嵌入对 CPU 静态参照 cos 0.963（范数系统性
  +12%），音频答案在 <think> 后立即 EOS。修复：NPU 默认对 "a."-前缀 Q4_0 走 native（其余 Q4_0
  保持 Q4_0_128——LLM 侧 group-128 是 GatherMatmulCompressed 的性能最优，native 化会让 1.7B
  decode 掉到 8.5 t/s）。修复后编码器嵌入 cos 0.9997（fp16 噪声级）。
- **因果②LLM 权重量化不一致**：CPU 静态（q4_sym128_all → Q4_0 native）与 NPU 默认（Q4_0→128）
  的 LLM 权重不同。逐层 KV cos 显示两条路径的 NPU-vs-CPU 分歧幅度同级（文本 layer12=0.734、
  音频 layer12=0.76），文本答案余量大不受影响、音频答案落在边际敏感区被翻转。NPU 用
  `REQUANT_KQUANT=q4_sym128_all`（与 CPU 参照同量化）后，NPU 音频输出与 CPU 静态/native Q8_0
  参照逐字一致："A high-pitched, pure"。
- **因果③（遗留）Omni-2B + level 图 = 缺陷-7 设备预算**：Omni-2B 的 decode level 图首次
  execute 即 ZE_RESULT_ERROR_UNINITIALIZED（非确定性，与设备碎片化相关；曾有一次全程成功）。
  Omni 上需 `DISABLE_DECODE_LEVELS=1`。1.7B 文本模型不受影响（15 t/s ctx 无关保持）。
- 验证矩阵（本轮终态）：NPU 音频正确输出 ✓（q4_sym128_all + levels off）；CPU 静态音频 ✓；
  1.7B NPU decode 14.0-14.7 t/s @c2048/c8192 ✓；CPU accept-smoke 3/3 ✓。
- 已知待办：①引擎级 fallback——level 图 execute 撞 UNINITIALIZED 时自动降级重编 ctx 图重试
  （消灭 Omni 上的 env 需求）；②mtmd-cli 无 perf footer 且尾部截断的退出路径（三方向都在，
  与本回归无关）；③"top-1 分歧定性"升级为"分岐幅度定性"——文本/音频同量级，答案余量决定
  是否可见，原"f16 复利"结论成立并已量化。

## 2026-11-01：level 图设备预算自动降级重试落地（消灭 Omni 的 env 需求）
- 机制：decode level 图 `infer()` 抛 ZE_RESULT_ERROR_UNINITIALIZED 时（defect-7 族：设备预算装不下
  prefill + level 图），置进程级 `g_decode_levels_disabled` 开关、清空全部 level 缓存/decoder、解锁
  entry mutex 后递归重入一次——重入时 decode_level=0，走 full-ctx decode 图（decode-only 分支编译
  ctx 图并**发布到 ctx-pair 缓存**而非 level 缓存，否则每步重编译）。
- 两个实现坑（已记）：①entry mutex 非递归——重入前必须 `lock.unlock()`（unique_lock），否则
  "resource deadlock would occur"；②decode-only 分支的发布目标按 decode_level==0 分流。
- 实测：Omni-2B NPU 音频**无 env、全新缓存**自动触发降级（level 256 撞预算 → 重试）并输出正确
  完整描述（"A high-pitched, pure"）；1.7B 文本不触发（levels 保持，14.4-14.8 t/s @c2048/c8192），
  CPU accept-smoke 3/3。
- NPU 音频已知可用配置简化为：`REQUANT_KQUANT=q4_sym128_all`（LLM 量化对齐参照；编码器已由
  "a."-豁免自动保护）。mtmd-audio-c512.ps1 已同步更新。

## 2026-11-01：视觉输入首探——native 参照通过，静态翻译有一个明确的 rope 形状烘焙缺陷
- native（-dev none，Q8_0）：**视觉端到端直接可用**——测试图（448² 深底红圆+绿条）输出
  "A flag with a black upper field containing a large solid red circle ... green horizontal band"，
  描述精确。mmproj 含视觉编码器（133 个 v. 张量）+ 音频（313 a.）+ 投影（12 mm.）。
- OpenVINO 静态路径（CPU FORCE_STATIC）在 ViT 内失败：
  `Multiply_153226: [1,784,16,64] × Concat [1,3136,1,64]` broadcast 失败。784=28²（448/16 patch conv
  输出），3136=56²——rope/位置频率 Concat 按 56×56 烘焙而 conv 走 28×28，与音频 reshape-bake 同类
  （cont.cpp dst_shape 全烘焙 / 静态形状捕获错位）。附带一串
  "cannot determine dynamic dim for RESHAPE node 'conv_spatial-N'" 告警——视觉 patch 维未标动态。
- 下一轮方案（按音频 XIV 的成熟打法）：①compute_node_dynamic_dims 给视觉 patch 轴标动态；
  ②定位 3136 烘焙源（rope freqs 的静态捕获），对齐 conv 输出的 patch 数；③NPU 验证。
- mtmd-cli"退出路径"项核销：修复后 NPU 音频输出与 native 参照含停止点逐字一致（EOS 是模型行为），
  perf footer 本就是 mtmd-cli（experimental CLI）不打印的——非缺陷。
- 测试资产：D:\llm\npu\test_image.png（合成图，红圆+绿条）；ctrl/vis_native.ps1、vis_ov.ps1。

### 视觉缺陷精确定位（cgraph dump 证据）
- cgraph（vis_cg/cgraph_ov.txt）全程 784 token（448/16 patch ✓），ROPE 节点 Q[64,16,784]/
  K[64,8,784] 正常。3136 只在 OV 翻译产物里出现：失败 Multiply 的 Concat 输入 [1,3136,1,64]
  = **4×784——视觉 rope 的 4 段式位置表（每 patch 4 行，2D 轴向 rope 的 4 个分段）被当成
  784×4 个 token 直接喂进 Multiply**，而 native 动态翻译会对分段做切片。
- 修复方向：静态 rope lowering 支持 mrope 分段（读 rope src 的分段配置，按段切片 cos/sin 再
  逐段乘回），或视觉图走动态翻译（编码器图非 decode，动态路径本就支持——查它为何被路由进
  静态：编码器图 is_static 判定 + FORCE_STATIC 强制；FORCE_STATIC 下编码器图也可考虑豁免走
  动态，先验证数值再谈性能）。
- 快速验证建议：FORCE_STATIC=0 + 设备 CPU（动态路径）跑视觉——若通过则"豁免编码器图走动态"
  即为最小修复；NPU 上编码器图动态执行是否可行另测（编码器非 decode，设备预算压力小）。

### 视觉探针补充：OpenVINO 动态路径 CPU 通过，NPU 仍卡 NPUW
- CPU 动态路径（FORCE_STATIC=0，native 同款翻译）：**视觉端到端正确**（输出与 native 一致）——
  4 段式 rope 在动态翻译里本就被正确处理，最小修复假设证实。
- NPU（动态路径）在 NPUW 编译期撞同一 broadcast 断言——NPUW 有自己的 shape inference/降级管线，
  对 4 段位置表同样不兼容。NPU 视觉的两条路线：①静态 rope lowering 支持 mrope 分段（与 CPU 静态
  同修）；②NPUW 侧配置/变换规避（NPUW_DQ/FOLD 类开关逐个试）。均列下轮。
- 里程碑 4.x 现状：音频 ✓（NPU/CPU），视觉 native ✓ / OV-CPU 动态 ✓ / 静态与 NPU 待修。

### 视觉 rope 最终证据：positions 叶子 [3136] 与 784 patch 的静态绑定错位
- cgraph：ROPE src[1] = `positions` [3136,1,1,1]，标记 **CPU 后端叶子**——视觉 2D 轴向 rope 的
  4 坐标/patch 位置表（784 patch × 4）。静态绑定路径把它当 3136 个 token 喂进 rope 的
  theta 计算（cos_theta reshape [1,3136,1,64]），与 data [1,784,16,64] 失配。动态路径绑定
  "positions" 的方式不同（native/OV-CPU 动态均正确），说明修复点在静态绑定/下钻：
  按 rope sections（op_params 内）每 token 取 4 坐标展开，与文本 inp_pos 的绑定对齐。
- 状态留档：cgraph dump 证据在 ctrl/cgraph_ov.txt（临时，下轮开工时重新生成即可）。

## 2026-11-01：副靶立项 Spark-X2.6-4B——跨模型验证 + u4 权重宿主视图修复

**目的**：主靶一直是 LFM3 系（混合架构），引擎的算子翻译层是否只对 LFM3 成立需要一副靶回答。
选定讯飞 **Spark-X2.6-4B**（bartowski Q4_K_M GGUF，2.5 GB，标准稠密 Transformer，上游 llama.cpp
已原生支持，vendored abb76ab 直接加载无需改模型代码）。

### 结果矩阵（同机 275HX / OV 2026.4.1）

| 路径 | LFM3-1.7B | Spark-X2.6-4B |
|---|---|---|
| native CPU（`-dev none`，参照） | ✓ | ✓ 151.9/19.9 t/s |
| OV-CPU 动态 | ✓ 96.3/23.1 t/s（裸跑，无 requant env） | ✓ 77.4/8.2 t/s（裸跑） |
| OV-CPU 静态（三问验收） | ✓ 3/3（无 env） | ✓ 3/3 |
| NPU 静态 | ✓ 14.7 t/s（c1024） | ✓ 3/3（2.4 t/s，chunk128+禁 levels） |

**跨模型结论：引擎翻译层不是 LFM3 专用**——另一家族、另一架构、另一模板（含 thinking）的 4B
模型在同一套 ggml-openvino 路径上端到端跑通并通过全部精度验收。

### 修复一：u4 无法包宿主内存（阻塞所有非对称 4-bit 路径）
这份 OV 构建里 `ov::Tensor(u4, shape, host_ptr)` 与 `ov::Constant(u4, shape, raw_ptr)` 都抛
`is_pointer_representable`（u4/i8 通过）——**所有非对称 4-bit 权重路径从未可用**：native
Q4_K/Q4_1（Q4_K_M 最常见格式的 OV-CPU 路径，README 的 OV-CPU 数字当年必然带了 requant env，
accept-smoke.ps1 里的 env 注释即为佐证）和 `REQUANT_KQUANT=q4_asym64*`。三层修复：
1. `process_weight_tensor` 的 `wrap_or_detach`：u4 槽位改为内部分配 + 提取后回写（槽位契约不变）；
2. `make_int4_weights` unsigned 分支：`Constant` 从 ov::Tensor 拷贝构造，不再裸指针共享；
3. `count_bad_f16` 校验只对 f16 元素类型的 scales/zp 做（u4 zp 上 `data<f16>()` 本身就是那条断言
   的抛出点——detach 打通前两关后才暴露）。

### 修复二：native 非对称提取统一精确 f16 零点
修完 1 之后 native Q4_K 首次可用，随即暴露：整数 zp 的 `round(min/scale)` 舍入让 LFM3 静态图
思考退化成 "\n" 死循环（动态路径侥幸正确）。MoE 专家早因同一误差改用精确 f16 零点（bias 形态，
仍可融合 GatherMatmulCompressed）；现在推广到全部 native 非对称提取（Q4_K/Q4_1/Q5_1/Q5_K），
`extract_quantized_weights` / `process_weight_tensor` / `get_extracted_layout` 三处同步。修复后
LFM3 与 Spark 的 OV-CPU 静态三问无 env 全 3/3，`accept-smoke.ps1` 的 requant env 已摘除。

### NPU 4B 预算实测
- 4B（requant 后 ~2.3 GB 权重）默认配置（chunk256 + decode levels）在图编译完成后**执行期**撞
  `ZE_RESULT_ERROR_OUT_OF_HOST_MEMORY`（系统 RAM 空闲 28.8 GB，是驱动侧预算，非系统内存）。
- `GGML_OPENVINO_PREFILL_CHUNK_SIZE=128` + `GGML_OPENVINO_DISABLE_DECODE_LEVELS=1` + c512 可跑：
  prefill 16.8 t/s（chunk 口径失真偏保守）、decode 2.4 t/s。**开 levels 反而更慢**（1.5 t/s）——
  level 图与权重 bank 竞争预算。副靶配置脚本：tools/spark-npu-accept.ps1。
- 4B 是当前驱动/驱动配置下的实际上限候选；2.3 GB 权重 + 单图编译的预算结构见
  npu-internals.md（未再深挖，留给上游 NPUW bank-aware import）。

### 遗留
- NPU 4B decode 2.4 t/s 未优化（lm_head F16 常量在 4B 上更贵——152k×4096 词表；u4 化已被
  里程碑 2.2 轮证伪，但那是 1.7B 的结论，4B 值得复测一次）。
- 视觉 4 坐标 positions 静态绑定修复仍是下轮主任务（本节未动）。

### 补充（同轮）：Qwen3-4B NPU 复测翻案
2026-10-31 记录的 Qwen3-4B NPU"从第一步单 token 塌缩（GGGG…）"在当前引擎上不再复现：副靶配置
（chunk128 + 禁 levels + c512）下输出连贯，三问验收 **3/3**（decode 2.3 t/s）。两个外部模型家族
（Spark-X2.6-4B、Qwen3-4B）全部通过 NPU 精度验收。当时塌缩的根因未单独定案（其间落地了 KV 环
修复、level 自动降级、u4/f16-zp 修复等多个改动），按复测证据翻案。

## 2026-11-01：性能轮——4B NPU decode 2.4 → 4.9 t/s（level 预算三图问题）

**用户核心目标调整：性能优先。** 副靶 4B 的 2.3–2.4 t/s 不可用，本轮全程定位。

### 排查链（每步都有实测证据）
1. `GGML_OPENVINO_PROFILING=1`：每步 436–480 ms **全部在 NPU 图执行内**（主机绑定 <10 ms）。
2. ctx 对照：c256 = 164 ms/步、c512 = 436 ms——成本 ∝ 环/span 超线性。
3. 算子级 profile（`PROFILING=2`）：KV ScatterNDUpdate 每实例 8 ms（写 4 KB 进 1 MB 环）、
   rope 路径 Add 30 ms（16 KB f32）——小算子按 span 缩放的执行/调度开销；LFM3 同设置
   全步 92 ms、Add 仅 3.8 ms（24 层 vs 36 层 + 全局注意力层数差异）。
4. **levels 为何失效**：level-256 图编译成功后**首个 execute 即
   ZE_RESULT_ERROR_UNINITIALIZED**（-lv 5 日志实锤），自动降级后稳态全程跑全 ctx 图。
   根因：**设备预算 = prefill + 一张 decode 图（权重 bank 按 CompiledModel 计），而 prefill
   在新 entry 上还会预编 legacy 全 ctx decode 图 → 三图常驻**。1.7B（3×1 GB 权重 bank）
   装得下三图所以 LFM3 从未暴露；4B（3×2.3 GB）必爆。
5. 编译开关矩阵（FUNCALL/DQ/FOLD overrides）全部无效（2.4→2.6/2.7，DQ=NO 编译失败）——
   结构性问题，不是开关问题。

### 修复（utils.cpp，三处）
- `decode_levels_active` 常量：levels 激活时 prefill **不再预编 legacy 全 ctx decode 图**。
- level 编译分支：连同 legacy decode 图一并驱逐（level==0 时的发布逻辑不变，fallback 重进时按需重编）。
- level==0 的 cache_hit 按相位拆分（prefill 只看 prefill 半区；复用检查改绑实际使用的
  decoder——原实现解引用 null `entry->ptr` 会段错误，已实测踩过并修复）。

### 结果（275HX / NPU 3720，热缓存稳态）
| 模型 | 修复前 | 修复后 | 验收 |
|---|---|---|---|
| Spark-X2.6-4B c512 | 2.4 t/s | **4.9 t/s**（raw infer 436→~150 ms） | 3/3 |
| Qwen3-4B c512 | 2.3 t/s | **4.0 t/s** | 3/3 |
| LFM3-1.7B c1024 | 14–15 t/s | 13.1 t/s（无回归） | 3/3 |

level 基数 256 vs 128 实测持平（4.7 vs 4.5），保持 256（少一次 level 编译）。

### 剩余差距与下一步（按杠杆排序）
4B 理论下限 ≈ 2.3 GB 权重 ÷ 15.7 GB/s（LFM3 实测带宽）≈ 145 ms/步 ≈ 7 t/s；当前 4.9。
1. **标准注意力的算子降级开销**：36 层 × span 的 scatter/rope 小算子群（LFM3 只有 11 层
   注意力 + 短卷积）。方向：把 QK^T/softmax/PV 链折叠进 DPU 大子图（NPUW FOLD 对标准
   GQA 的模式覆盖），或 llama.cpp 侧换 flash-attn 式 KV 写路径。
2. host ~50 ms/步（150 参数逐个 set_input_tensor）——静态参数预绑定。
3. 4B 权重字节：token_embd F16（~795 MB）+ output Q8_0_C（~400 MB）占一半；EMBD_Q4 在
   1.7B 上证伪过，4B 上权重占比更大，值得复测。
   **复测结论（2026-11-02，证伪）**：Spark c512 chunk128+levels、n=128、每臂双跑取热跑——
   u4 **on：decode 1.7 t/s、prefill 14.8**；**off：decode 5.1、prefill 19.0**（~3× 慢，
   tied embedding 连 prefill 的 GatherMatmul 一起拖累）。NPUW 压缩 MatMul 反模式与模型规模
   无关，F16 常量维持默认。**顺带修复**：`REQUANT_EMBD_Q4` 改变图内权重常量却漏入 extra_cfg
   缓存键（A/B 会串味），已混入（utils.cpp）；`DISABLE_ELTWISE_RANK_ALIGN` 漏入 CM 盘缓存
   `cache_settings[]`，一并补上（model-cache.cpp）。A/B 脚本 `ctrl/spark_ab_u4.ps1`。

### 性能轮补记（同日）：稳态真实数字与算子开销定案

PERFTRACE 插桩（WARMTRACE 门控，decode 步 bind/outbind/infer 分解）+ 长生成消歧：
- **稳态分解（Spark level-256）**：infer 141 ms ≈ 权重带宽下限 145 ms（2.3 GB ÷ 15.7 GB/s），
  bind 3 ms、outbind ~0——**设备已贴带宽地板，主机侧无肉**。
- **headline 失真修正**：`Generation t/s` 含每次进程的 level 图编译停顿与 gen 相位固定开销，
  n=64 时 4.2–4.7，n=128 摊薄后 Spark **5.9 t/s**（逐 token 时间戳实测 145 ms = 6.9 t/s）；
  Qwen3-4B n=128 稳态 **4.5 t/s**（修复前 2.3）。测 4B 必须热缓存 + ≥128 token。
- 算子级 profile（level 图 360 实例）：MatMul ≈ 带宽下限；Add/Multiply/Scatter/Parameter/
  Concat 合计 ~258 实例 × ~0.6 ms 调度开销——但它们与 MatMul 重叠流水，净空 <25 ms/步。
  "把注意力链折叠进 DPU 大子图"的期望收益被实测压缩到 ~10–15%（非此前估计的 2×）。
- KV zeroize（NO_KV_ZEROIZE 探针）：~0.3 t/s，保留（正确性必需）。
- 编译开关（FUNCALL/DQ/FOLD overrides）已证无效；EMBD_Q4 复测（4B 权重字节占 1/3）仍是
  唯一未试的权重侧杠杆。
- **结论：4B 稠密 Q4_K_M 在 NPU 3720 上的 decode 上限 ≈ 7 t/s（带宽决定），已达成 ~85%。**
  再往上只剩上游依赖（NPUW bank-aware blob import、更高带宽的驱动/硬件）。

### prefill chunk 扫描（4B 首 token 延迟）
chunk 64/128/32 实测（Spark-4B c512，13 token prompt，冷启动含编译）：prefill 20.0 / 17.1 /
15.5 t/s，端到端 51 / 58 / ~60 s。chunk64 短 prompt 最优；32 以下每 chunk 固定开销反噬。
EMBD_Q4（权重侧唯一未试杠杆）经复查对 decode 无效——decode 只读 output.weight（Q8_0_C），
token_embd 每步只读一行；且 lm_head u4 化在 1.7B 已证伪（同一下降路径），不复测。

### 4B prefill 正确口径补测（pp512，回应"prefill 为啥差那么多"）
llama-bench -p 512 -n 0：native 166.6 / OV-CPU 95.1 / **NPU(chunk128) 89.4 t/s** = native 的
54%，与 OV-CPU 持平。此前 15-20 t/s 是 13 token 短 prompt + chunk64/128 的 pad 失真（13 token
付 64-128 列）。与 1.7B 的 69% 相比的 15 个点差值 = 预算把 chunk 压到 128/64 的 pad 浪费 +
每 chunk 固定开销；回到 chunk256 需要上游 NPUW bank 去重。测量纪律：短 prompt 看首 token
延迟（秒），长 prompt 看 t/s。

## 2026-11-01：视觉静态翻译跑通——多平面 positions 双计修复（残留精度缺陷另立）

**根因（VISROPE 插桩 + IR 对照实锤）**：视觉编码器是无 KV 的 cacheless 图，`utils.cpp` 里
`prefill_chunk_size = inp_pos->ne[0]` 取了 **3136**——但 llama.cpp 视觉 rope 的 positions 本身
已把 4 个平面打包进 ne[0]（4×784）；decoder 定参时再乘 n_planes → **[1,1,1,12544]** 参数，
make_sin_cos 的多平面 reshape 按每平面 3136 个"token"切 → [1,3136,1,64] 的 cos/sin 表对
[1,784,16,64] 的数据——即此前记录的 Multiply 形状验证失败。音频编码器未爆是因为其 positions
是单平面（除数为 1）。translate_session 的共享 sin_cos（无 mode 参数）已被注释是死路径；
rope.cpp 的 op_case 映射（VISION→3）与绑定侧的多平面处理本身都是对的。

**修复**：cacheless 图取 chunk 时按 ROPE 的 op 分辨多平面并除以平面数（vision → 784）。

**结果**：LFM3-Omni-2B + mmproj 视觉编码器 + LLM 静态翻译端到端跑通（CPU FORCE_STATIC），
此前直接死于形状验证。对照 native：描述方向对（识别出红色图形）但整体描述错误
（native："一面旗帜，上半部分纯黑"；static："三个红色的椭圆形"）——**残留精度缺陷**，
模式与音频轮的编码器精度回归相似（内容要素对、结构错）。下轮：先隔离是视觉编码器还是
LLM 侧图像 token 的 4 平面位置处理（音频路径已验证过 LLM 静态 + 单平面，图像 token 的
mrope 位置是新领域），再对照 patch embeddings 级别找差异。VISROPE/WARMTRACE 插桩暂留
（门控环境变量，精度缺陷关闭后统一拆除）。

## 2026-11-05：P14e 转默认 + P15/P16 结案 + 严格 A/B 定案（4B decode 达标 +78%）

### A/B 判决（本轮最重要成果）
同一 cache 目录（KvN2）、同一二进制、同日两套 blob 集（KV_HOST_WRITE ON/OFF），llama-bench 暖 r3：
- **tg128：链式 8.89 ± 0.01 vs 摘链 12.26 ± 0.03 = +38% 纯摘链增益**；链式 8.89 与 P14b 时代 8.96 闭环
- pp512ck256：192.29 vs 191.57（持平——摘链不动 prefill，按设计）
- vs P11 基线：4B tg 6.89 → 12.26 = **+78.0%，decode 轴超额达标**
- **环境漂移带 ~4%**（同代码不同时段 run 互差）已定性——历史跨时段对比必须同 cache A/B
- **KV_HOST_WRITE 转默认 ON**（`0` 显式关）：extra_cfg blob 键随默认翻转，旧缓存失效一次

### P15 结案（MoE-NPU 融合 = no-op，归因修正）
a5c39ca 的 commit message 有两处错误，在此修正：
- **Spark-X2.6-4B 是 dense**——GGUF 无 expert_count（"experts" 字样来自 tokenizer 词表）；217 MatMul =
  QKV 36 + attn_output 36 + attn_gate 36 + FFN 108 + head 1
- 两个 dump 的 IR 里 **0 个 MOECompressed**——pass 无匹配对象；KvI→KvM 的 tg 差异是环境漂移
- `MOE_NPU` 保留为无害 opt-in（NPUW 能编融合图不崩），给真 MoE 模型用

### P16 结案（rope NegMul 消除 = IR 真省 72 节点，时间零差）
NEOX rotate-half 的每节点 Multiply(x2,-1) 移进共享 swapped-sin 表（P14b memo 家族）。
4B 三轴与 pre-P16 全持平（52.51/191.57/12.26）——72 个 NegMul 已被上游吸收（常量折叠或并行调度）。
代码保留（bit-neutral，3/3 答案实证；图更净）。1.7B（NORMAL mode）双向回归绿。

### 4B prefill 的物理画像（本轮两次 PROFILING 的定案）
- **ck128 chunk（2.46s）**：MatMul 59% + Add 24%（180 个，launch 界 ~3ms/个）+ Multiply 6% + Transpose 6% + ScatterND 1.8%
- **ck256 chunk（1.33s）**：MatMul 55% + Add 27%（token 翻倍 Add 时间不动 = 纯 launch）——residual 72 个占 Add 一半（数学不可消）
- **217 MatMul 分解**：QKV 36 + O 36 + attn_gate 36 + FFN 108 + head 1（attn_gate 是 Spark 架构特性）
- 1898 个 shape 节点（Reshape/Convert/Unsqueeze/Squeeze）不在 CSV top family = 已被 NPUW 吸收
- **结论**：translator 级杠杆已榨干；突破需要 NPUW 调度粒度（subgraph 约束/tile 策略）级改动

### 环境教训（本轮新增两条）
- **D 盘满 → blob 写坏毒化**：写一半崩掉的 blob set 复用即 ZE_RESULT_ERROR_INVALID_NULL_HANDLE（0x78000005），
  症状像"设备坏了"，实为缓存损坏——换 ArmTag 重编即愈。跑长任务前确认 ≥20 GB
- **改 translate_session.h（类布局）必须全量重编**：ninja 增量漏编含旧布局的 TU → ODR 违例 →
  0xC0000005 @ ggml-openvino.dll+0x49251（每个带 rope 的图必崩）——二分两轮才定位。
  规则：`rm -rf build/ggml/src/ggml-openvino/CMakeFiles/ggml-openvino.dir` 后再 bld.bat
- **`D:\llm\npu\bin` 是陈旧镜像**（手动拷贝，会落后）：p14_eval 用 `src\llama\build\bin` 是对的；
  任何手跑前先 `cp build/bin/* bin/` 刷新

### P17：编译旋钮扫描收档（DQ 家族 = decode 专属，prefill 无解）
正确方法学（llama-bench vs llama-bench，`-r 1` 同日直连）两格：
- `NPU_COMPILER_DYNAMIC_QUANTIZATION=NO`：pp2048 52.27 / pp512 192.29（持平）/ **tg 8.86（-29%）**；
  3 题答案仍正确（f16 激活数值上没问题）——但 decode 的动态量化收益是真金白银，证伪
- `NPUW_DQ_FULL=YES`：pp2048 52.67（持平）/ **tg 8.73（-29%）**，同签名，证伪
- **方法学教训**：初判"44.3 t/s = prefill 4×"是拿无 PROFILING 的 run 对 PROFILING=2 的 run——
  4B prefill 图上 profiling 开销 ~4×；粗筛必须 bench 对 bench，否则白跑一轮

4B prefill 缺口（+22.7%/+41.6% vs +50% 目标）的当前定案：translator 级杠杆全部测完
（P15 MoE 无对象 / P16 NegMul 被吸收 / P14e 只管 decode / 索引链共享在 decode 侧），
NPUW 编译旋钮面（FOLD/DQ/DQ_FULL/FUNCALL/WEIGHTS_BANK）也无 prefill 增益——
剩余差距 = DPU MatMul 计算域（54%）+ residual Add launch 界（27%，数学不可消）+ chunk 固定成本。
**下一步需要 NPUW 内部调度改动（subgraph 粒度 / tile 策略），不是 translator 工作。**

### P18：自动 prefill 升档 + 默认翻转失效修复（2026-11-05 晚）
**P18 auto prefill chunk promotion**（utils.cpp，未 pin 流零改动）：env 把 chunk 钉在 128（4B 生产档）时，
token 数 129–512 的 prefill 自动升 chunk256 图（该区间 chunk128 需 2–4 个整块，chunk256 只需 1–2）。
- **bench 实锤**：pp200（升档区正中）184.81 t/s = chunk256 单块 1.08s；非升图 chunk128 模型值 ~127 t/s
  （2 块 1.58s）→ **+46%**，与 README 时代 +55-59% 的区间结论一致
- >512 保持 128（大图顶爆 decode 预算共存）；≤128 不换图；env 未设置 = 256 缺省不变；decode 图不受影响
- **验证插曲（两条教训）**：① 第一轮"假阴性"（43.6 t/s 不升档）是 `D:\llm\npu\bin` 陈旧 DLL（04:28 早于
  P18 构建 06:34）——刷新镜像后 bench 才实锤；llama-cli 那个 1793 字符长 prompt 实际 >512 token，
  本来就该留在 128 区（设计行为，不是 bug）。② **两树同步是手工的**：bld.bat 只 build D: 树，
  E: 的改动必须先 cp 过去（本轮 extra.cpp 修复差点被漏掉——DLL mtime 不动才发现）
- **重大发现：6077ff8 的默认翻转是死的**。`ggml_openvino_getenv_int()` 对未设置变量返回缺省 0，
  门控里 `getenv_int(...) == 0` 把"未设置"当成显式 `=0` → 装出来的"默认 ON"实际是默认 OFF。
  tg128 探针（env 不设，新 DLL）实测 **8.87 t/s = 链式值**（该是 12.26）当场抓包。
  修复：改用 `getenv_str` 判 nullptr 区分"未设置"与"显式 0"。**教训：任何 default 翻转，
  必须用"env 完全不设"的探针验一遍，A/B 的 ON 臂是显式 =1，验不出翻转失效。**
  （受影响范围：6077ff8 起所有"默认开"路径；打包 zip 里的引擎同样是 OFF 的，需要重打包）

### P19：chunk 尺寸轴收档——设备 scratch 崖实测（2026-11-05 深夜）
pp512 轴（191.6，目标 203.4，差 6%）的最后候选：加大 chunk 摊薄 launch-bound Add 族
（同 Add 数 × 2 token）。launch-bound 算术估 ck512 可到 206-240 t/s，探针两格：
- **ck512**：图编译成功（blob 7.2GB，translator 侧无障碍），**infer warmup 即败**
  （`ggml_backend_sched_graph_compute_async failed -1`）
- **ck384**：同签名失败（blob 7.1GB 编译成功）→ **崖在 256-384 之间**
- 结论：chunk256 就是 4B prefill 图的设备 scratch 物理上限（256 可跑，384/512 编译过但设备
  实例化/执行超预算）。chunk 维度对 pp 轴的贡献已到头；pp2048ck128 与 pp512ck256 的剩余缺口
  维持 NPUW 内部调度域定案。**4B prefill translator 级杠杆至此全部实测关闭**：
  P15（MoE 无对象）/ P16（rope 被吸收）/ P17（DQ 族 decode 专属）/ P19（chunk 崖 256）。

### P20：NPUW_FOLD=YES A/B 收档——4B 上 FOLD=NO 定案复实锤（2026-11-05 深夜）
FOLD=NO 是 1.7B 时代翻的默认，4B prefill 从未对比过；FOLD 若把 launch 界 Add 族并入邻接算子，
恰在 pp 缺口（+22%/+6%）射程内。探针（GGML_OPENVINO_NPU_COMPILE_OVERRIDES=NPUW_FOLD=YES，
ck256，pp512+tg128 同 invocation）：
- **pp512 136.89（对 191.6 = -28.6%）/ tg128 7.75（对 12.11 = -37%）**——两轴同向崩，与 P17 DQ 族同签名
- blob 集仅 76MB（FOLD=NO 同格 ~19GB）：YES 少做图工作（"36.4s vs 383s"时代的成因），
  合并出的算子在 4B 的稠密大 MatMul 图上落点更差
- 结论：**FOLD=NO 对 4B 同样成立**，编译旋钮面最后一格关闭。4B prefill 的 translator 可达域
  全部实测完毕：P15（MoE 无对象）/ P16（rope 吸收）/ P17（DQ 族）/ P19（chunk 崖 256）/ P20（FOLD 反噬）

### 缺陷：P14e 默认 ON = NPU 全线垃圾文本（2026-11-06，打包验收现场抓获）
真机验收（ASR&TTS 合入后的便携包）报「Omni 复读机」，绕开 App 用 llama-cli 做变量矩阵：
CPU 干净 / NPU 全配置复读（逐字节一致=确定性图错）/ **显式 `KV_HOST_WRITE=0` 即愈且不掉速**；
1.7B、Spark-4B 同中招——**爆炸半径=NPU 上的一切**。元凶即上方 P14e「转默认 ON」
（Nov 5 12:30 DLL，源码含超出 patches/0001 的未版本化改动；VIEW 警告不在补丁内）。
6077ff8 教训（翻转要探针验生效）只防了「翻不动」，没防「翻本身坏」：**A/B 全绿在 t/s 上，
垃圾 token 同样计 t/s——默认翻转从此必须过文本质量闸**。已止血：bundled_manifests envTemplate
钉 `{kvHostWrite=0}`、deep preset 的 1 改 0（其「9.1 t/s」降级为存疑数字待复测）。
全文：docs/defect-npu-p14e-kvhostwrite.md（复现命令+行动项在彼处，含 src/llama 未入 git
致无法 bisect 的立案）。
