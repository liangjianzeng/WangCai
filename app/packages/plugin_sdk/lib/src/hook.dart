/// 回收原语与取消令牌（L3 契约）。
///
/// 设计来源：Cordis `Effect`（"Disposers run in **reverse registration order** when the owning fiber
/// unloads"）与 DSH `defineTool` 的 `exec.signal`（"async work must observe or forward `exec.signal`"）。
/// 本仓对应经验：`EdgeTtsService._seq` 代次不变量（`lib/tts/edge_tts_service.dart:326-353`）。
library;

import 'dart:async';

/// 一个资源回收动作。**必须幂等**（可能被调用两次：fiber 卸载 + 显式 dispose）。
///
/// 失败行为：抛异常由内核**吞掉并记日志**，绝不阻断其余 disposer（对齐 Cordis `_unload()` 的
/// per-disposer containment）。因此 disposer 里不要 `try/catch` 后吞异常——让内核统一记账。
typedef Disposable = FutureOr<void> Function();

/// 组合多个 disposer（内核收集用）。逆序执行。
Disposable disposers(List<Disposable> ds) {
  final snapshot = List<Disposable>.of(ds);
  return () async {
    Object? firstError;
    for (final d in snapshot.reversed) {
      try {
        await d();
      } catch (e) {
        firstError ??= e; // 吞掉但保留第一个，供诊断树显示
      }
    }
    if (firstError != null) throw firstError;
  };
}

/// 协作式取消令牌。
///
/// 规约：所有插件侧异步循环必须在**每个 `await` 边界**复查 [isCancelled]（本仓 `_seq` 已验证过的纪律：
/// "每个 await 后重查代次"）。`delay` 这类等待必须用 [delay] 而不是裸 `Future.delayed`，
/// 否则"点停止"要等到整个间隔走完。
final class PluginCancelToken {
  PluginCancelToken({String? debugLabel}) : debugLabel = debugLabel ?? 'token';

  /// 诊断用名字（出现在 effect 诊断树 / trace 日志里）。
  final String debugLabel;

  bool _cancelled = false;
  String? _reason;
  final List<void Function()> _listeners = [];

  bool get isCancelled => _cancelled;
  String? get reason => _reason;

  void throwIfCancelled() {
    if (_cancelled) {
      throw _CancelledSignal(_reason);
    }
  }

  /// 取消并唤醒所有等待者。**幂等**：重复调用只记第一次的原因。
  void cancel([String? reason]) {
    if (_cancelled) return;
    _cancelled = true;
    _reason = reason;
    for (final l in List<void Function()>.of(_listeners)) {
      try {
        l();
      } catch (_) {
        // 监听器失败被吞：取消路径绝不能因为一个观察者而中断。
      }
    }
  }

  /// 注册取消回调，返回反注册函数（内核会把它挂到 fiber 的 effect 上）。
  Disposable onChanged(void Function() listener) {
    _listeners.add(listener);
    if (_cancelled) listener();
    return () => _listeners.remove(listener);
  }

  /// 可取消等待：到点或取消任一发生即返回是否"完整等待到点"。
  Future<bool> delay(Duration d) async {
    if (_cancelled) return false;
    final completer = Completer<bool>();
    final timer = Timer(d, () {
      if (!completer.isCompleted) completer.complete(true);
    });
    final off = onChanged(() {
      timer.cancel();
      if (!completer.isCompleted) completer.complete(false);
    });
    final done = await completer.future;
    await off();
    return done && !_cancelled;
  }

  /// 挂到父令牌上：**父取消 → 本令牌取消**（反向永不成立，见 [child]）。
  Disposable link(PluginCancelToken parent) => parent.onChanged(() => cancel(parent.reason ?? 'parent-cancelled'));

  /// 派生子令牌：**父取消则子取消；子取消绝不波及父**。
  ///
  /// 听写的用法：会话级令牌（切会话/停止生成）是父，一次听写任务是子 ——
  /// 用户按"停止本词"不该把整个会话的生成掐掉。
  PluginCancelToken child([String? label]) {
    final c = PluginCancelToken(debugLabel: '$debugLabel/${label ?? 'child'}');
    onChanged(() => c.cancel('$debugLabel 已取消'));
    return c;
  }
}

/// [PluginCancelToken.throwIfCancelled] 抛出的信号；内核会把它折算成 `Outcome.err(cancelled)`。
final class _CancelledSignal implements Exception {
  const _CancelledSignal([this.reason]);
  final String? reason;
  @override
  String toString() => reason == null ? 'cancelled' : 'cancelled: $reason';
}

/// 是不是"用户取消"信号（类本身不公开，判定走这两个函数）。
bool isCancelSignal(Object? e) => e is _CancelledSignal;

/// 取消原因（给用户看的那句，可能为 null）。
String? cancelReasonOf(Object? e) => e is _CancelledSignal ? e.reason : null;

/// 事件的派发语义（照 DSH 的 `@mode` 文化：每个 hook 必须声明自己是哪种）。
enum HookMode {
  /// 通知，忽略返回值；监听器异常被吞。
  emit,

  /// 责任链：每个监听器包住剩余链路，**不调 `next()` 即否决**。
  waterfall,

  /// 逐个调用直到某个返回非 null（策略询问，例如"这个工具能不能跑"）。
  bail,
}
