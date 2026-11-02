// 路由三档（设计 §7.3）：纯决策函数，无 IO —— 输入候选实例 + 绑定表快照
// + 回合画像，输出应选引擎。护栏「同一时刻至多一个 loaded 引擎」由调用方
// （LocalServerInference）承担，这里只做选路。
//
// 立场（2026-11-02 拍板）：不写死参数量阈值。设备适配约束全部来自数据 ——
// admission 规则（manifest）与绑定表实测；策略代码只见 status/blocked，
// 不见「4B/3.5B」这类魔数。
import 'bindings_store.dart';

enum RoutingTier {
  /// 速度优先：交互前台一律最快可用（实测 t/s）。
  speedFirst,

  /// NPU 优先：只要 NPU 不被 admission/绑定表否决就归 NPU
  /// （接受 c512/6 t/s —— 后台化使用的正当档位）。
  npuFirst,

  /// 自动（默认）：前台交互→最快；后台队列/拔电→NPU 加权。
  auto,
}

RoutingTier routingTierFromName(String? name) => switch (name) {
      'speed' || 'speedFirst' => RoutingTier.speedFirst,
      'npu' || 'npuFirst' => RoutingTier.npuFirst,
      _ => RoutingTier.auto,
    };

enum TurnProfile {
  /// 前台聊天/智能体回合：响应时间第一。
  interactive,

  /// 摘要/记忆蒸馏等后台队列：省 GPU 给前台。
  background,
}

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

  /// 无绑定实测时的稳定偏好（设计 §7.3「今天=5060Ti CUDA」的无数据启发）。
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
  const RoutingDecision({this.instanceId, required this.reason, this.suggestion});
  const RoutingDecision.none(this.reason, [this.suggestion]) : instanceId = null;

  final String? instanceId;
  final String reason;

  /// 给用户的改道建议（admission 违例/档位不可满足时非空，§4.1 语义）。
  final String? suggestion;
}

/// 选路输入。[blocked]：engineId → admission/探测拒绝文案（调用方算好传入；
/// policy 不重新解释 manifest）。[bindings]：该模型在绑定表里的全部行。
class RoutingRequest {
  const RoutingRequest({
    required this.tier,
    this.profile = TurnProfile.interactive,
    required this.candidates,
    this.bindings = const [],
    this.blocked = const {},
    this.onBattery = false,
  });

  final RoutingTier tier;
  final TurnProfile profile;
  final List<EngineCandidate> candidates;
  final List<Binding> bindings;
  final Map<String, String> blocked;
  final bool onBattery;
}

/// 三档决策（§7.3 规则表）：
/// - speedFirst：绑定表 usable/recommended 按 t/s 降序 → 无实测的已装引擎按
///   设备启发（CUDA>Vulkan>NPU>CPU）→ 远端兜底。
/// - npuFirst：NPU 未被 blocked 且绑定非 broken 就用；否则回落 speed 规则并
///   给出建议文案。
/// - auto：interactive → speed 规则；background 或拔电 → NPU 加权（同上），
///   NPU 不可满足时回落 speed。
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
          ? '速度优先：实测 ${bound.first.tps!.toStringAsFixed(1)} t/s'
          : '无实测：设备启发 ${bound.first.c.devices}',
    );
  }

  final npus = local.where((c) => c.isNpu).toList();

  RoutingDecision? byNpu({required String preferReason}) {
    for (final c in npus) {
      if (req.blocked.containsKey(c.instanceId)) continue;
      if (!usableByBinding(c)) continue;
      return RoutingDecision(instanceId: c.instanceId, reason: preferReason);
    }
    return null;
  }

  final preferNpu = req.tier == RoutingTier.npuFirst ||
      (req.tier == RoutingTier.auto &&
          (req.profile == TurnProfile.background || req.onBattery));

  if (preferNpu) {
    final npu = byNpu(
        preferReason: req.tier == RoutingTier.npuFirst
            ? 'NPU 优先档'
            : (req.onBattery ? '自动档：拔电 NPU 加权' : '自动档：后台队列归 NPU'));
    if (npu != null) return npu;
    final fallback = bySpeed();
    final blockNote = npus
        .map((c) => req.blocked[c.instanceId])
        .whereType<String>()
        .firstOrNull;
    if (fallback != null) {
      return RoutingDecision(
        instanceId: fallback.instanceId,
        reason: '${fallback.reason}（NPU 不可用，改道）',
        suggestion: blockNote ?? 'NPU 无可用绑定（未装/被绑定表标记 broken）',
      );
    }
  } else {
    final speed = bySpeed();
    if (speed != null) return speed;
    // 前台交互但本地全被拦：给 admission 建议（若调用方传了）。
    final blockNote =
        req.blocked.values.where((v) => v.isNotEmpty).join('；');
    if (remote != null) {
      return RoutingDecision(
        instanceId: remote.instanceId,
        reason: '本地引擎不可用，走远端兜底',
        suggestion: blockNote.isEmpty ? null : blockNote,
      );
    }
  }

  if (remote != null) {
    return RoutingDecision(instanceId: remote.instanceId, reason: '远端兜底');
  }
  final blockedNote = req.blocked.values.join('；');
  return RoutingDecision.none('无可用引擎',
      blockedNote.isEmpty ? '请在 设置→推理引擎 安装/启用一个引擎' : blockedNote);
}
