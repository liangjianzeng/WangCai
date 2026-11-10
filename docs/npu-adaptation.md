# NPU 世代自适应：Core Ultra 一/二/三代怎么被对待

回答的问题：**"这台机器不是那台开发机（275HX + NPU 3720），引擎还开得起来吗？"**
全仓调优值——4B ctx512/chunk128、`GGML_OPENVINO_DISABLE_DECODE_LEVELS=1`、
admission「4B@ctx>512 → OUT_OF_HOST_MEMORY」、`-dev` 回退 `OPENVINO2`、冷编 600s——
都出自**一台**机器（[status.md](status.md)）。本文说明换机时这些值如何被裁决。

**总原则（2026-11-05 定案）：保守起步 + 实测上探。** 未实测过的世代只用一代已验证
的保守先验，绝不预填乐观数字（无实测不赌）；该机跑成功过的档位由绑定表记住后自动
放开，执行期失败自动收回。

> **2026-11-06 口径修订（全局 ctx 拍板，读本文前先换脑）**：「preset.ctx 当上限先验 +
> 4B@ctx>512 拦」已退役——用户裁决「4096 是最基本的，否则狗毛都干不了」。ctx 只有
> 一个口子：设置页滑杆（`InferenceSettings.contextSize`，默认 4096，每刻度 512 至 16K，
> `snapContextSize` 夹紧）；preset 不再携带 ctx。「保守起步+实测上探」只剩两半：
> 越档实测豁免、执行期 OOM 的 `demoteCtx` 回退；clamp 唯一来源 = 世代档案
> `ctxOverrides` 数据位（当前空表 = 原样放行）。16K 深上下文臂（`NPUW_FOLD=YES`）
> 由网关在 ctx>4096 时自动挂载（KV_HOST_WRITE 仍钉 0，见 defect-npu-p14e-kvhostwrite.md）。
> ~~「4096 对一切模型放行是硬红线」~~——此句已被两次实测推翻，勿再引用：
> **2026-11-07** admission 收紧（4B 线 ctx≤512 确定可用、>512 先验拦，4096 首请求
> UNINITIALIZED/塌方实锤）；**2026-11-09** 兜底准入（用户拍板「问题模型先兜底定制
> ctx，确保先能用」）：ctx 门槛类规则声明 `fallbackCtx`（4B 线=512）后触发不再
> 拒载——网关把请求 ctx 收敛到 max(兜底档, 该机实测档) 继续加载，ℹ️ 留痕；
> 无实测安全档的模型（Qwen3.5-4B/MiniCPM5-2B）维持硬拒载。机制见
> `bundled_manifests.dart` 头注释与 `engine_manifest.dart::evaluateAdmission`。

---

## 1. 世代识别：型号码为锚，识别不了就 unknown

`llama-server --list-devices` 的 NPU 行（`...=NPU - <名称> (<MiB>...)`）由
`openvino_probe.dart::parseNpuListDevices` 解析成 `NpuDeviceInfo`：
`devArg`（`OPENVINO{n}` 枚举下标）、`deviceName`、`npuCode`、`totalMib/freeMib`。
按 exe 进程级缓存，**只缓存成功**（失败下轮重探，驱动热修后自愈）。

世代表决在 `npu_profiles.dart::npuGenerationFor`，纯函数：

| npuCode | 世代 | 对应硬件 |
|---|---|---|
| 3700–3799 | `ultra1` | Meteor Lake / Arrow Lake-HX（开发机 = 3720） |
| 3800–3899 | `ultra2` | Lunar Lake / Arrow Lake-H（3820） |
| 4000–4999 | `ultra3` | Panther Lake（枚举形态未实机核证） |
| 缺号/越界 | `unknown` | → 按一代保守基线兜底（= 今天的行为） |

**名称兜底必须走带 `\b` 的正则**（`NPU\s*(\d{3,4})\b`），禁止 `contains` 松匹配——
`(NPU 37200)` 的子串 `3720` 会被 contains 误判成一世代，而错误世代比 unknown 危险
（unknown 只是保守，错世代可能放行未验证档位）。单测
`test/engine/npu_probe_test.dart` 锁死这条防误吃。

## 2. 保守先验：NpuProfile 是数据位，不是猜测位

`profileFor(generation)` 返回 `NpuProfile{ctxOverrides, minDriverVersion, driverNote}`。
当前 const 表里**没有任何预填的 ctx 数字**：gen1 的实测值就是 manifest preset 本身
（覆盖表为空 = 让位 preset）；gen2/gen3 同样空表——**它们的先验 = 一代先验**。
唯一非空字段是 gen3 的 `driverNote`（新硬件对新驱动敏感，纯排障提示）。

拿到真二/三代机器实测后的导入路径就是往表里填行：
`ctxOverrides: {'<preset名>': <实测稳态ctx>}`，如有世代专属 admission 例外，
给规则标 `appliesGenerations`（`engine_manifest.dart`，缺省 = 全世代适用）。
`profileOverrideForTest` 提供整表注入，clamp 链接线由
`test/platform/npu_generation_adapt_test.dart`「档案数据位」用例锁定。

## 3. clamp 链与实测闭环（谁有权抬高上限）

ctx 上限的裁决在 `local_server_inference.dart::_ctxCeilingFor`，优先级固定：

```
measured（BindingsStore.maxStableCtx，该机此模型跑成功过的最大档）
  >  世代档案 ctxOverrides（当前全空表）
  >  manifest preset.ctx（出厂先验 = 一代实测）
```

**重要口径（2026-11-06 复查，勿高估今天的自动化程度）**：preset 命中的模型上，
clamp 先把请求 ctx 压到 ≤ prior，`recordRun` 因此只会记下 ≤ prior 的值 ——
`measured > prior` **今天到不了**：`_ctxCeilingFor` 的上抬分支、admission 的实测
豁免、`demoteCtx` 的收回分支对 preset 档都是「管子在、水未通」（单测的 seed
验证的是管路本身）。实测真正活化的入口：① manifest preset 上调（出厂重新实测
后放宽先验）；② 世代档案 `ctxOverrides` 填行；③ 无 preset 命中的模型
（prior=null 不 clamp，用户显式 ctx 可入场，跑成后落袋）。`demoteCtx` 在 preset
档目前只清绑定行、不改 clamp 行为，完整意义随 ①② 兑现。这是「保守起步」的
自然结果：宁可保守到机械化，也不在无实测的机器上放行未验证档位。

- **上探**：每次成功推理 `recordRun` 单调回写 `maxStableCtx`（bindings_store.dart），
  下次加载同模型直接放行到该档。admission 的 ctx 门槛规则被实测**豁免**
  （`AdmissionRule.triggers` 的 `measuredCtx`：只有 ctx 门槛类规则让位，
  纯参数量规则——如 OOM 与参数量的硬关系——永不让位）。
- **回退**：加载失败且驱动报 `OUT_OF_HOST_MEMORY` → `demoteCtx(failedCtx)` 收回
  被证伪的上抬（失败值 ≥ 实测值才收；**失败不证伪更低档**）。
- **驱动版本只查一次**（2026-11-06 复查）：CIM 全枚举数秒级开销，会话级记忆
  + engines.json 已带 driver 直接沿用；查而未得不缓存，下次成功加载重试。
- **MiB 只是诊断**：`totalMib/freeMib` 进 UI 与 engines.json，但**绝不参与预算**
  ——NPU 的 OUT_OF_HOST_MEMORY 是驱动 per-process 预算而非系统内存
  （[HANDOFF.md](HANDOFF.md) 2026-11-02 深夜定案），拿它当依据会得出系统性错误结论。

## 4. 探测失败与驱动：不再隐形

- **devArg 探测**优先于 manifest 硬编码（`OPENVINO3` 是开发机枚举，无 dGPU 机型
  常见 `OPENVINO2`）；探测失败回退 `OPENVINO2` 时**写引擎日志留痕**
  （`_ownLogLine`，日志弹层可见），不再静默带病起 server。
- **驱动版本** best-effort：`EngineStore.npuDriverVersion`（仿 nvidia-smi 先例）
  跑 `Get-CimInstance Win32_PnPSignedDriver` 匹配 `AI Boost|(R) NPU`，失败静默 null，
  不阻塞加载。成功加载后随 `lastNpuInfo` 摘要（devArg/名称/码/世代/驱动）持久化进
  engines.json（可选字段不 bump 版本）。
- **引擎管理卡**（engine_manager_section）显示「型号 · 世代 · -dev 档位」，gen3 附
  驱动升级提示——换机排障第一眼就能看出识别成了什么世代、走了哪条兜底。

## 5. 验证（可证伪入口）

```bash
# 世代链全量（全绿）：探测解析/世代表决/clamp/实测上探/失败回退/档案注入
flutter test test/engine/npu_probe_test.dart test/engine/npu_profiles_test.dart \
  test/platform/npu_generation_adapt_test.dart
# 回归锚：3720 行为逐位同 v0.0.5 ——「回归锚」用例锁 -dev OPENVINO3 / -c 512 / chunk128
```

真机核对（本机 3720）：引擎卡显示 `Intel(R) AI Boost (NPU 3720) · 一代 · -dev OPENVINO3`；
加载 Qwen3-4B 的「启动命令」弹层含 `-dev OPENVINO3 -c 512`，env 含
`GGML_OPENVINO_PREFILL_CHUNK_SIZE=128`——与 v0.0.5 逐位一致是本特性的红线，
由上述回归锚用例代守。二/三代无实机（2026-11-05 用户确认），验收口径 =
模拟枚举文本的单测全绿；上真机后按 §2 导入实测行。
