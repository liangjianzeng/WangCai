/// 能力注册表：任何人（含插件）都能注册，消费者只认 [ServiceKey]。
///
/// 语义与槽**同一套心智**（避免平台里出现两套优先级）：
/// - **priority 越小越优先**；同 id 同 priority 冲突 → 报错并指名占用者；
/// - 被遮蔽的实现**不销毁**（照 Cordis `Context.isolate` 的换实现思路）：遮蔽者卸载后自动回退；
/// - 每次某 id 的实现集变化 → 该 id 的 `revision` +1，依赖它的 fiber 靠 epoch 自动重载。
library;

import 'package:plugin_sdk/plugin_sdk.dart';

final class CapabilityEntry {
  CapabilityEntry({
    required this.key,
    required this.impl,
    required this.ownerPluginId,
    required this.priority,
    required this.seq,
    required this.revision,
  });

  final ServiceKey key;
  final Capability impl;
  final String ownerPluginId;
  final int priority;
  final int seq;
  final int revision;

  /// 面板诊断："这个实现是谁给的、有没有被遮蔽、为什么不可用"。
  bool get available => impl.available;
  String? get unavailableReason => impl.unavailableReason;
}

final class CapabilityRegistry {
  final Map<String, List<CapabilityEntry>> _byId = {};
  final Map<String, int> _revisions = {};
  int _seq = 0;
  final List<void Function(String capabilityId)> _listeners = [];

  /// 注册实现。返回 disposer（卸载插件时回收，被遮蔽者自动浮回）。
  ///
  /// 失败分支：`configInvalid`（同 id 同 priority 已被占用，指名占用者）。
  Outcome<Disposable> register(
    Capability impl, {
    required String ownerPluginId,
    int priority = 0,
  }) {
    final id = impl.key.id;
    final list = _byId.putIfAbsent(id, () => <CapabilityEntry>[]);
    for (final e in list.where((e) => e.priority == priority && e.key.contractVersion == impl.key.contractVersion)) {
      return Outcome.err<Disposable>(
        code: PluginFailureKind.configInvalid,
        message: '能力 ${impl.key} 已被 ${e.ownerPluginId} 以 priority $priority 提供',
        hint: '想盖住它就用更小的 priority（例如 ${priority - 1}）；它不会消失，你卸载后自动回退',
        pluginId: ownerPluginId,
      );
    }
    final entry = CapabilityEntry(
      key: impl.key,
      impl: impl,
      ownerPluginId: ownerPluginId,
      priority: priority,
      seq: _seq++,
      revision: _bump(id),
    );
    list.add(entry);
    return Ok<Disposable>(() {
      final l = _byId[id];
      if (l == null) return;
      if (l.remove(entry)) _bump(id);
    });
  }

  /// 解析实现：先按 (id, contractVersion) 精确匹配，取 priority 最小者；
  /// 全部不可用时返回**第一个不可用原因**（面板要能解释"为什么灰着"）。
  Outcome<T> resolve<T extends Capability>(ServiceKey<T> key, {String? consumerPluginId}) {
    final list = _byId[key.id];
    if (list == null || list.isEmpty) {
      return Outcome.err<T>(
        code: PluginFailureKind.missingCapability,
        message: '这台机器没有提供能力 ${key.id}',
        hint: '在「插件」面板查看本机能力清单，或安装提供它的插件',
        pluginId: consumerPluginId,
      );
    }
    final sorted = _sorted(list);
    final exact = sorted.where((e) => e.key.contractVersion == key.contractVersion).toList();
    if (exact.isEmpty) {
      final have = sorted.map((e) => e.key.contractVersion).toSet().join(', ');
      return Outcome.err<T>(
        code: PluginFailureKind.incompatibleContract,
        message: '能力 ${key.id} 只有 $have，本插件要 ${key.contractVersion}',
        hint: '升级 app 或该插件',
        pluginId: consumerPluginId,
      );
    }
    final alive = exact.where((e) => e.impl.available).toList();
    if (alive.isEmpty) {
      final first = exact.first;
      return Outcome.err<T>(
        code: PluginFailureKind.missingCapability,
        message: first.impl.unavailableReason ?? '${key.id} 当前不可用',
        hint: '见「设置」页对应开关',
        pluginId: consumerPluginId,
      );
    }
    return Ok<T>(alive.first.impl as T);
  }

  /// 门控查询（面板灰不灰、fiber 能不能加载）。
  bool isAvailable(String id) {
    final list = _byId[id];
    if (list == null || list.isEmpty) return false;
    return _sorted(list).any((e) => e.impl.available);
  }

  String? unavailableReason(String id) {
    final list = _byId[id];
    if (list == null || list.isEmpty) return '这台机器没有提供能力 $id';
    final sorted = _sorted(list);
    for (final e in sorted) {
      if (e.impl.available) return null;
    }
    return sorted.first.impl.unavailableReason ?? '$id 当前不可用';
  }

  /// 某能力当前的实现集版本（fiber 的 epoch 由它算出来）。
  int revisionOf(String id) => _revisions[id] ?? 0;

  /// 全部实现（含被遮蔽的）—— 面板"能力"页数据源。
  List<CapabilityEntry> list([String? id]) {
    if (id != null) return List.unmodifiable(_sorted(_byId[id] ?? const []));
    return [for (final l in _byId.values) ..._sorted(l)];
  }

  // 这里**不留** `knownIds()`：本机有哪些能力只有一个真源 ——
  // 面板读 [list]，门控与校验读宿主给的 `hostCapabilityIds`。另开一份迟早分叉。

  Disposable subscribe(void Function(String capabilityId) onChange) {
    _listeners.add(onChange);
    return () => _listeners.remove(onChange);
  }

  /// 试一下（面板"测试"按钮）：可 IO，比 [isAvailable] 深。
  Future<Outcome<void>> probe(String id) async {
    final list = _byId[id];
    if (list == null || list.isEmpty) {
      return Outcome.err<void>(
        code: PluginFailureKind.missingCapability,
        message: '这台机器没有提供能力 $id',
        hint: '查看本机能力清单',
      );
    }
    for (final e in _sorted(list)) {
      if (e.impl.available) return e.impl.probe();
    }
    return Outcome.err<void>(
      code: PluginFailureKind.missingCapability,
      message: _sorted(list).first.impl.unavailableReason ?? '$id 当前不可用',
      hint: '见「设置」页对应开关',
    );
  }

  /// 空闲预热（内核在启动后低优先级调用，不在 build 路径）。
  Future<void> warmUpAll() async {
    for (final e in list()) {
      if (!e.impl.available) continue;
      try {
        await e.impl.warmUp();
      } catch (_) {
        // 预热失败只影响性能，不影响可用性：吞掉。
      }
    }
  }

  void clear() {
    _byId.clear();
    _revisions.clear();
    _seq = 0;
  }

  List<CapabilityEntry> _sorted(List<CapabilityEntry> list) {
    final out = List<CapabilityEntry>.of(list)
      ..sort((a, b) {
        final p = a.priority.compareTo(b.priority);
        if (p != 0) return p; // 小的在前 = 更优先
        return b.seq.compareTo(a.seq); // 同优先级：后注册的先（但同优先级本来就被拦了）
      });
    return out;
  }

  int _bump(String id) {
    final v = (_revisions[id] ?? 0) + 1;
    _revisions[id] = v;
    for (final l in List<void Function(String)>.of(_listeners)) {
      try {
        l(id);
      } catch (_) {
        // 监听器失败被吞。
      }
    }
    return v;
  }
}
