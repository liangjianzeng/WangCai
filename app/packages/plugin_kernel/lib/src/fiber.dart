/// 插件 fiber：一个插件实例的生命周期（照 Cordis `FiberState` / `inertia` / epoch 自动重载）。
///
/// 三条从 Cordis 抄来的硬规矩，都在这里落地并可测：
/// 1. **单飞**（`inertia`）：同一 fiber 同时只允许一个状态迁移，并发 `ensure()` 等同一个结果 ——
///    否则用户狂点开关会出现两个 fiber 同时 apply，贡献物注册两遍；
/// 2. **epoch 自动重载**：依赖的能力实现被替换（`revision` 变）→ 依赖者的 epoch 变 → 下次 `ensure()`
///    先卸再装。"依赖被替换"不该要求用户重启 app；
/// 3. **disposer 逆序执行**，且**单个失败只记日志不阻断其余**（否则一个坏 disposer 会把后面的资源全 leak 掉）。
library;

import 'dart:async';

import 'package:plugin_sdk/plugin_sdk.dart';

/// 生命周期状态（六态，逐字对齐 Cordis：`PENDING/LOADING/ACTIVE/FAILED/DISPOSED/UNLOADING`）。
enum FiberState { pending, loading, active, failed, disposed, unloading }

/// effect 诊断树节点（面板「effect 树」页数据源，照 DSH `EffectMeta{label,children}`）。
final class EffectNode {
  EffectNode(this.label, {this.children = const [], this.dispose});

  final String label;
  final List<EffectNode> children;
  final Disposable? dispose;

  Map<String, Object?> toMap() => {
        'label': label,
        'children': children.map((e) => e.toMap()).toList(),
      };
}

typedef FiberCtxFactory = PluginCtx Function(PluginFiber fiber);

/// 依赖指纹来源：由编排层给出（通常是 `inject 的 id + 各能力 revision` 拼串）。
typedef EpochSource = String Function(PluginFiber fiber);

class PluginFiber {
  PluginFiber({
    required this.plugin,
    required this.ctxFactory,
    required this.epochOf,
    this.onStateChange,
  });

  final AppPlugin plugin;
  final FiberCtxFactory ctxFactory;
  final EpochSource epochOf;
  final void Function(PluginFiber fiber, FiberState state)? onStateChange;

  String get id => plugin.manifest.id;

  FiberState _state = FiberState.pending;
  FiberState get state => _state;

  /// 状态迁移轨迹（面板"这个插件今天到底发生了什么"，也是测试的主要抓手）。
  final List<FiberState> transitions = [];

  PluginFailure? _lastFailure;
  PluginFailure? get lastFailure => _lastFailure;

  /// 单飞锁（Cordis `inertia`）。
  Completer<void>? _inertia;

  String _epoch = '';
  String get epoch => _epoch;

  PluginCancelToken? _cancelToken;
  PluginCancelToken get cancelToken => _cancelToken ??= PluginCancelToken(debugLabel: 'fiber:$id');

  final List<EffectNode> _effects = [];
  List<EffectNode> get effectTree => List.unmodifiable(_effects);

  PluginCtx? _ctx;
  PluginCtx? get ctx => _ctx;

  /// 编排层登记 effect（插件经 `ctx.effect` 走到这里）。
  Disposable addEffect(EffectNode node) {
    _effects.add(node);
    return () => _effects.remove(node);
  }

  bool get isActive => _state == FiberState.active;

  /// 加载（幂等；依赖变了自动重载；并发调用共享同一次迁移）。
  Future<Outcome<void>> ensure() async {
    // ① 单飞：已经在迁移中就等它，绝不并行。
    while (_inertia != null) {
      await _inertia!.future;
    }
    if (_state == FiberState.active) {
      final next = epochOf(this);
      if (next == _epoch) return const Ok<void>(null);
      await _unload(reason: '依赖已替换，自动重载'); // epoch 变 → 先卸
    } else if (_state == FiberState.unloading) {
      await _unload(reason: '补完卸载');
    } else if (_state == FiberState.disposed) {
      _state = FiberState.pending;
      _record();
    }

    final completer = Completer<void>();
    _inertia = completer;
    _set(FiberState.loading);
    try {
      final ctx = ctxFactory(this);
      _ctx = ctx;
      final r = plugin.apply(ctx); // apply 契约上必须同步且无 IO
      // apply 明确失败 = 这个 fiber 停在 failed，绝不允许"半激活"（贡献物注册了一半还对外可用）。
      if (r.isErr) {
        _lastFailure = r.failureOrNull?.scoped(pluginId: id);
        await _disposeEffects();
        _ctx = null;
        _set(FiberState.failed);
        return Err<void>(_lastFailure!);
      }
      _lastFailure = null;
      _epoch = epochOf(this);
      _set(FiberState.active);
      return const Ok<void>(null);
    } catch (e, st) {
      _lastFailure = PluginFailure(
        code: PluginFailureKind.runtimeError,
        message: '插件启动时出了点问题',
        hint: '停用再启用试试；仍不行看诊断树',
        pluginId: id,
        cause: '$e\n$st',
      );
      await _disposeEffects();
      _set(FiberState.failed);
      return Err<void>(_lastFailure!);
    } finally {
      _inertia = null;
      completer.complete();
    }
  }

  /// 失败后重试（面板"重试"按钮）。
  Future<Outcome<void>> retry() async {
    if (_state != FiberState.failed) return ensure();
    _state = FiberState.pending;
    _record();
    return ensure();
  }

  /// 卸载（禁用插件 / 切方案档 / 依赖替换）。**幂等**。
  Future<void> unload({String reason = '已停用'}) async {
    while (_inertia != null) {
      await _inertia!.future;
    }
    if (_state == FiberState.disposed) return;
    final completer = Completer<void>();
    _inertia = completer;
    try {
      await _unload(reason: reason);
    } finally {
      _inertia = null;
      completer.complete();
    }
  }

  Future<void> _unload({required String reason}) async {
    if (_state == FiberState.disposed) return;
    _set(FiberState.unloading);
    cancelToken.cancel(reason);
    await _disposeEffects();
    _ctx = null;
    _epoch = '';
    _set(FiberState.disposed);
  }

  Future<void> _disposeEffects() async {
    // 逆序：后注册的先回收（后注册者往往依赖先注册者建立的东西）。
    for (final node in _effects.reversed.toList()) {
      final d = node.dispose;
      if (d == null) continue;
      try {
        await d();
      } catch (e) {
        // 单个 disposer 失败只记日志：绝不能因为它跳过剩下的回收。
        _disposeFailures.add('${node.label}: $e');
      }
    }
    _effects.clear();
  }

  /// 回收失败清单（面板红点 + 测试抓手）。
  final List<String> _disposeFailures = [];
  List<String> get disposeFailures => List.unmodifiable(_disposeFailures);

  void _set(FiberState s) {
    if (_state == s) return;
    _state = s;
    _record();
  }

  void _record() {
    transitions.add(_state);
    onStateChange?.call(this, _state);
  }

  @override
  String toString() => 'Fiber($id, ${_state.name})';
}
