// 路由两档（2026-11-07 用户拍板重设计）：纯决策函数，无 IO —— 输入候选实例
// + 绑定表快照，输出应选引擎。护栏「同一时刻至多一个 loaded 引擎」由调用方
// （LocalServerInference）承担，这里只做选路。
//
// 立场（2026-11-02 拍板）：不写死参数量阈值。设备适配约束全部来自数据 ——
// admission 规则（manifest）与绑定表实测；策略代码只见 status/blocked，
// 不见「4B/3.5B」这类魔数。
//
// 2026-11-07 重设计（用户拍板，取代 v0.0.4「NPU 主打 GPU 外挂自动改道」）：
//   本项目是 NPU 优先和核心的项目。NPU = 本体，GPU/iGPU/CPU 一律是**旁路
//   能力的扩展**——只有用户在设置里显式选择「GPU 外挂」档（或钉选具体引擎）
//   才会走。废除「自动」档：它「NPU 不可用就自动改道 GPU」的语义正是
//   「一加载就滑进独显」的根源。NPU 跑不了 → 明确报错 + 告诉用户外挂在哪，
//   绝不静默换道。
import 'bindings_store.dart';

enum RoutingTier {
  /// NPU 核心（默认）：本项目本体。只走 NPU；NPU 不可满足 → 拒绝加载并给
  /// 出原因与手工外挂的指引，绝不自动改道 GPU/远端。
  npuFirst,

  /// GPU 外挂（旁路，显式选择）：用户在设置里手工选了它才生效。按绑定表
  /// 实测 t/s 选最快（CUDA > Vulkan 启发兜底），远端兜底也在本档内。
  gpuSidecar,
}

/// 兼容映射：'auto'（旧默认档）并入 NPU 核心（它的改道语义已废）；
/// 'speed' 旧名 → GPU 外挂（语义延续，用户显式选择）。
RoutingTier routingTierFromName(String? name) => switch (name) {
      'speed' || 'speedFirst' || 'gpu' || 'gpuSidecar' => RoutingTier.gpuSidecar,
      _ => RoutingTier.npuFirst, // 'npu'/'npuFirst'/'auto' 与一切未知值
    };

/// 候选引擎实例（由 EngineRegistry 快照生成，policy 不摸 registry）。
class EngineCandidate {
  const EngineCandidate({
    required this.instanceId,
    required this.kind,
    required this.devices,
    this.enabled = true,
    this.installed = true,
  });

  final String instanceId;
  final String kind; // 'llamaServer' | 'remote'
  final List<String> devices; // manifest.capabilities.devices
  final bool enabled;

  /// 二进制/配置可用：llamaServer = 可执行文件存在；remote = 端点+key 已配置。
  final bool installed;

  bool get isRemote => kind == 'remote';
  bool get isNpu => devices.any((d) => d.toUpperCase().contains('NPU'));

  /// 外挂档内无绑定实测时的稳定偏好（llama.cpp 官方性能序：独显 > 核显）。
  int get deviceRank {
    final up = devices.map((d) => d.toUpperCase()).join(',');
    if (up.contains('CUDA')) return 0;
    if (up.contains('VULKAN')) return 1;
    if (up.contains('NPU')) return 2;
    if (up.contains('CPU')) return 3;
    return 4;
  }
}

class RoutingDecision {
  const RoutingDecision(
      {this.instanceId, required this.reason, this.suggestion, this.needInstall});
  const RoutingDecision.none(this.reason, [this.suggestion])
      : instanceId = null,
        needInstall = null;

  final String? instanceId;
  final String reason;

  /// 给用户的建议（NPU 不可用/外挂档被拦时非空，§4.1 语义）。
  final String? suggestion;

  /// 按需下载信号（仅 GPU 外挂档）：档内无可选引擎但有「已启用未安装」的
  /// cuda/vulkan 实例时 = 建议安装的 variant（'cuda'|'vulkan'）。UI 层据此
  /// 弹「下载引擎」（EngineStore.install 进度）→ 装完重试加载。
  final String? needInstall;
}

/// 外挂档缺失引擎的下载建议：已启用未安装的 llamacpp 变体，
/// CUDA（快道）优先于 Vulkan（通解）；无候选 = null。
String? suggestInstallVariant(List<EngineCandidate> candidates) {
  final missing =
      candidates.where((c) => !c.isRemote && c.enabled && !c.installed);
  if (missing.any((c) => c.instanceId.contains('cuda'))) return 'cuda';
  if (missing.any((c) => c.instanceId.contains('vulkan'))) return 'vulkan';
  return null;
}

/// 选路输入。[blocked]：engineId → admission/探测拒绝文案（调用方算好传入；
/// policy 不重新解释 manifest）。[bindings]：该模型在绑定表里的全部行。
class RoutingRequest {
  const RoutingRequest({
    required this.tier,
    required this.candidates,
    this.bindings = const [],
    this.blocked = const {},
  });

  final RoutingTier tier;
  final List<EngineCandidate> candidates;
  final List<Binding> bindings;
  final Map<String, String> blocked;
}

/// 两档决策（2026-11-07 用户拍板）：
/// - npuFirst（核心）：NPU 未被 blocked 且绑定非 broken 就用；否则**拒绝**
///   （none + 原因 + 外挂指引）。绝不自动改道 GPU/远端——那是用户的手工决定。
/// - gpuSidecar（外挂）：用户显式选择的旁路档——绑定表 t/s 降序，无实测引擎
///   按设备启发（CUDA>Vulkan>CPU）先跑出第一次实测；档内全不可用 → 远端兜底
///   /按需下载信号（GPU 系的降级链留在档内，不越界回 NPU）。
RoutingDecision chooseEngine(RoutingRequest req) {
  final local = req.candidates
      .where((c) => !c.isRemote && c.enabled && c.installed)
      .toList();
  final remote = req.candidates
      .where((c) => c.isRemote && c.enabled && c.installed)
      .firstOrNull;

  bool usableByBinding(EngineCandidate c) {
    final b = req.bindings.where((b) => b.engineId == c.instanceId).firstOrNull;
    return b == null || b.status != BindingStatus.broken;
  }

  RoutingDecision? bySpeed() {
    final bound = <({EngineCandidate c, double? tps})>[];
    for (final c in local) {
      if (req.blocked.containsKey(c.instanceId)) continue;
      if (!usableByBinding(c)) continue;
      final tps =
          req.bindings.where((b) => b.engineId == c.instanceId).firstOrNull?.lastDecodeTps;
      bound.add((c: c, tps: tps));
    }
    if (bound.isEmpty) return null;
    bound.sort((a, b) {
      // 无实测（未知）先于有实测：新装引擎必须先跑出第一次实测，否则
      // 「有实测的慢引擎永久压制新装快引擎」死锁（2026-11-03 实案：NPU
      // 5 t/s 的历史实测压死新装 CUDA）。无实测之间按设备启发；都有实测
      // 按 t/s 降序。
      if (a.tps == null && b.tps != null) return -1;
      if (a.tps != null && b.tps == null) return 1;
      if (a.tps != null && b.tps != null) return b.tps!.compareTo(a.tps!);
      return a.c.deviceRank.compareTo(b.c.deviceRank);
    });
    return RoutingDecision(
      instanceId: bound.first.c.instanceId,
      reason: bound.first.tps != null
          ? 'GPU 外挂：实测 ${bound.first.tps!.toStringAsFixed(1)} t/s'
          : 'GPU 外挂：无实测，设备启发 ${bound.first.c.devices}',
    );
  }

  final npus = local.where((c) => c.isNpu).toList();

  if (req.tier == RoutingTier.npuFirst) {
    for (final c in npus) {
      if (req.blocked.containsKey(c.instanceId)) continue;
      if (!usableByBinding(c)) continue;
      return RoutingDecision(instanceId: c.instanceId, reason: 'NPU 核心档');
    }
    // NPU 不可满足 → 拒绝（核心档绝不偷跑 GPU/远端）。reason = 原因原文
    // （admission 拒绝文案原文透传，含缺陷单指引），suggestion = 可操作指引。
    final blockNote = npus
        .map((c) => req.blocked[c.instanceId])
        .whereType<String>()
        .firstOrNull;
    const guide = '可在 设置→引擎管理 显式选择「GPU 外挂」档或钉选旁路引擎';
    return RoutingDecision.none(
      blockNote ??
          (npus.isEmpty ? 'NPU 引擎不可用（未安装或未启用）' : 'NPU 引擎绑定不可用'),
      npus.isEmpty
          ? 'NPU 引擎未就绪；如需 GPU：$guide'
          : guide,
    );
  }

  // GPU 外挂档（用户显式选择）。
  final speed = bySpeed();
  if (speed != null) return speed;
  // 档内全被拦/全 broken：给 admission 建议（若调用方传了）。
  final blockNote = req.blocked.values.where((v) => v.isNotEmpty).join('；');
  if (remote != null) {
    return RoutingDecision(
      instanceId: remote.instanceId,
      reason: 'GPU 外挂档内不可用，走远端兜底',
      suggestion: blockNote.isEmpty ? null : blockNote,
    );
  }
  // 本地全空/全被拦且无远端：若存在已启用未装的 cuda/vulkan 实例，
  // 给出按需下载信号（Phase 3c 闭环的起点，UI 弹层消费）。
  final needInstall = suggestInstallVariant(req.candidates);
  if (blockNote.isEmpty && needInstall != null) {
    return RoutingDecision(
      reason: 'GPU 外挂不可用（$needInstall 未安装）',
      suggestion: '可下载官方 llama.cpp $needInstall 引擎',
      needInstall: needInstall,
    );
  }
  return RoutingDecision.none('GPU 外挂不可用',
      blockNote.isEmpty ? '请在 设置→引擎管理 安装/启用一个旁路引擎' : blockNote);
}
