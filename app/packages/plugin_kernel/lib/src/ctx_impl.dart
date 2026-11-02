/// 内核给插件的 [PluginCtx] 实现 —— 插件的整个世界都从这里发，**越界必须被当场拒**。
///
/// 三条边界（都是 conformance 与内核测试的靶子）：
/// - **未声明即拒**：没在 `plugin.json` 的 `permissions` 里声明就取能力 → `permissionDenied`；
/// - **命名空间**：插件只能在自己的 `<id>.*` 下声明槽；填槽可以填宿主与别人的（那是生态）；
/// - **信任分级**：只有 `trusted` 能贡献能力实现（`provide`）。
library;

import 'package:plugin_sdk/plugin_sdk.dart';

import 'capability_registry.dart';
import 'config_layers.dart';
import 'fiber.dart';
import 'trace.dart';

class KernelPluginCtx implements PluginCtx {
  KernelPluginCtx({
    required this.fiber,
    required this.manifest,
    required CapabilityRegistry capabilities,
    required SlotRegistry slots,
    required ConfigStack config,
    required TraceSink trace,
    required this.traceId,
    this.sessionStore,
    this.sessionId = 'root',
  })  : _caps = capabilities,
        _slots = slots,
        _config = config,
        _trace = trace {
    _capAccess = _CapabilityAccess(this);
    _slotAccess = _SlotAccess(this);
    _log = _Log(this);
  }

  final PluginFiber fiber;
  @override
  final PluginManifest manifest;
  final CapabilityRegistry _caps;
  final SlotRegistry _slots;
  final ConfigStack _config;
  final TraceSink _trace;
  @override
  final String traceId;
  @override
  final String sessionId;

  final Map<String, Object?> _session = {};
  late final _CapabilityAccess _capAccess;
  late final _SlotAccess _slotAccess;
  late final _Log _log;
  int _effectSeq = 0;

  @override
  CapabilityAccess get capabilities => _capAccess;
  @override
  SlotAccess get slots => _slotAccess;
  @override
  PluginLog get log => _log;

  @override
  PluginCancelToken get cancelToken => fiber.cancelToken;

  @override
  Disposable effect(Disposable disposer) {
    _effectSeq += 1;
    return fiber.addEffect(EffectNode('effect#$_effectSeq', dispose: disposer));
  }

  @override
  Object? configValue(String name) =>
      _session.containsKey(name) ? _session[name] : _config.value(name);

  @override
  double numberConfig(String name, double fallback) {
    final v = configValue(name);
    if (v is num) return v.toDouble();
    if (v is String) return double.tryParse(v) ?? fallback;
    return fallback;
  }

  @override
  bool boolConfig(String name, bool fallback) {
    final v = configValue(name);
    if (v is bool) return v;
    if (v is String) return v == 'true' || v == '1';
    return fallback;
  }

  @override
  String stringConfig(String name, String fallback) {
    final v = configValue(name);
    return v is String ? v : (v == null ? fallback : '$v');
  }

  /// 会话层的**真源在 [ConfigStore]**（面板与内核都从那儿读）；这里只留一份镜像，
  /// 让本 ctx 立刻读得到自己刚写的值，不必等 fiber 重建。
  /// 以前只有这份私人笔记本：面板指着「插件默认」，实际用的却是这里的临时值。
  final ConfigStore? sessionStore;

  @override
  void setSessionOverride(String name, Object? value) {
    // 会话内临时值：**不落盘**（"这次先把间隔调成 8 秒"不该改走用户的默认设置）。
    _session[name] = value;
    sessionStore?.setSessionOverride(manifest.id, name, value);
  }

  @override
  bool hasPermission(PluginPermission permission) =>
      manifest.permissions.any((p) => p.wireName == permission.wireName);
}

final class _CapabilityAccess implements CapabilityAccess {
  _CapabilityAccess(this.ctx);
  final KernelPluginCtx ctx;
  final Map<String, Disposable> _provided = {};

  @override
  bool isAvailable(String capabilityId) => ctx._caps.isAvailable(capabilityId);

  @override
  String? unavailableReason(String capabilityId) => ctx._caps.unavailableReason(capabilityId);

  @override
  Outcome<T> require<T extends Capability>(ServiceKey<T> key) {
    final need = impliedPermissionFor(key.id);
    if (need != null && !ctx.hasPermission(need)) {
      return Outcome.err<T>(
        code: PluginFailureKind.permissionDenied,
        message: '「${ctx.manifest.name}」想要用 ${key.id}，但没声明 ${need.wireName} 权限',
        hint: '在 plugin.json 的 permissions 里加上 "${need.wireName}"',
        pluginId: ctx.manifest.id,
      );
    }
    final r = ctx._caps.resolve<T>(key, consumerPluginId: ctx.manifest.id);
    if (r.isErr) return r;
    final impl = r.valueOrNull!;
    // 存储按插件隔离：前缀由**平台**加，不靠作者自觉（作者忘了前缀就会读到别人的数据）。
    if (key.id == ServiceKeys.store.id && impl is Store) {
      final scoped = _NamespacedStore(impl, ctx.manifest.id);
      // 显式 cast：`is T` 之后编译器仍不肯把具体类提升成类型变量 T（交集类型），
      // 判定已经做过，这里只是告诉它事实。
      if (scoped is T) return Ok<T>(scoped as T);
    }
    return Ok<T>(impl);
  }

  @override
  Outcome<Disposable> provide<T extends Capability>(ServiceKey<T> key, T impl, {int priority = 0}) {
    if (ctx.manifest.trust != PluginTrust.trusted) {
      return Outcome.err<Disposable>(
        code: PluginFailureKind.permissionDenied,
        message: '${ctx.manifest.trust.name} 级插件不能替换能力实现',
        hint: '需要替换实现（例如换离线朗读）请由平台自带插件提供',
        pluginId: ctx.manifest.id,
      );
    }
    if (key.id == impl.key.id && key.contractVersion != impl.key.contractVersion) {
      return Outcome.err<Disposable>(
        code: PluginFailureKind.incompatibleContract,
        message: '注册的能力契约版本 ${impl.key.contractVersion} 与键 ${key.contractVersion} 不一致',
        hint: '让 ServiceKey 与实现的 key 对齐',
        pluginId: ctx.manifest.id,
      );
    }
    final off = ctx._caps.register(impl, ownerPluginId: ctx.manifest.id, priority: priority);
    if (off.isErr) return Err<Disposable>(off.failureOrNull!);
    final d = off.valueOrNull!;
    _provided[key.id] = d;
    ctx.log.info('贡献能力 ${impl.key}（priority $priority）');
    final Disposable unprovide = () {
      d();
      _provided.remove(key.id);
    };
    // 同上：插件卸载后还留一份"能用"的能力实现，`resolve` 就会把调用交给一个已经死掉的插件。
    ctx.effect(unprovide);
    return Ok<Disposable>(unprovide);
  }
}

final class _SlotAccess implements SlotAccess {
  _SlotAccess(this.ctx);
  final KernelPluginCtx ctx;

  @override
  Outcome<void> declare(SlotDef def) {
    if (def.ownerPluginId != ctx.manifest.id) {
      return Outcome.err<void>(
        code: PluginFailureKind.permissionDenied,
        message: '只能在自己命名空间下声明槽（${ctx.manifest.id}.*）',
        hint: '把槽 id 改成 "${ctx.manifest.id}.${def.id.split('.').skip(1).join('.')}"',
        pluginId: ctx.manifest.id,
      );
    }
    if (!def.id.startsWith('${ctx.manifest.id}.')) {
      return Outcome.err<void>(
        code: PluginFailureKind.configInvalid,
        message: '槽 id "${def.id}" 的命名空间与 owner ${def.ownerPluginId} 不一致',
        hint: '槽 id 必须以 "<owner>." 开头',
        pluginId: ctx.manifest.id,
      );
    }
    return ctx._slots.declare(def);
  }

  @override
  Outcome<Disposable> register(SlotContribution<Object?> contribution) {
    if (contribution.pluginId != ctx.manifest.id) {
      return Outcome.err<Disposable>(
        code: PluginFailureKind.permissionDenied,
        message: '不能冒充别的插件填槽（${contribution.pluginId}）',
        hint: 'pluginId 必须是自己',
        pluginId: ctx.manifest.id,
      );
    }
    final r = ctx._slots.register(contribution);
    if (r.isOk) {
      // 作者纪律第 3 条（"贡献物必须挂进 effect"）**不能靠自觉**：忘了挂，重载一次槽里就留一个幽灵
      // ——界面上多出一个点了没反应的 chip，全程没人报错。内核直接兜住；
      // 作者自己再 `ctx.effect(...)` 也安全（注销是 removeWhere，重复调用是空操作）。
      ctx.effect(r.valueOrNull!);
    }
    return r;
  }

  @override
  List<SlotEntry> entries(String slotId, {String? key, Map<String, Object?>? ownerData}) =>
      ctx._slots.entries(slotId, key: key, ownerData: ownerData);

  @override
  Disposable subscribe(void Function(String) onChange) => ctx._slots.subscribe(onChange);
}

final class _Log implements PluginLog {
  _Log(this.ctx);
  final KernelPluginCtx ctx;

  void _emit(TraceLevel level, String message, {Object? cause}) => ctx._trace.emit(TraceRecord(
        traceId: ctx.traceId,
        pluginId: ctx.manifest.id,
        level: level,
        message: message,
        cause: cause,
      ));

  @override
  void debug(String m) => _emit(TraceLevel.debug, m);
  @override
  void info(String m) => _emit(TraceLevel.info, m);
  @override
  void warn(String m) => _emit(TraceLevel.warn, m);
  @override
  void fail(String message, {Object? cause, PluginFailureKind? code}) => _emit(TraceLevel.fail, message, cause: cause);
}

/// 按插件加命名空间的存储包装（`plugin:<id>:<key>`）。
///
/// 为什么包在平台层：让作者自己拼前缀，迟早有人忘 —— 一个忘拼前缀的插件
/// 就能读到另一个插件的数据。隔离必须由平台强制。
final class _NamespacedStore implements Store {
  _NamespacedStore(this._inner, this._pluginId);
  final Store _inner;
  final String _pluginId;

  String _k(String key) => 'plugin:$_pluginId:$key';

  @override
  ServiceKey get key => _inner.key;
  @override
  bool get available => _inner.available;
  @override
  String? get unavailableReason => _inner.unavailableReason;
  @override
  Future<void> warmUp() => _inner.warmUp();
  @override
  Future<Outcome<void>> probe() => _inner.probe();

  @override
  Future<Outcome<String?>> read(String key) => _inner.read(_k(key));
  @override
  Future<Outcome<void>> write(String key, String value) => _inner.write(_k(key), value);
  @override
  Future<Outcome<void>> remove(String key) => _inner.remove(_k(key));
  @override
  Future<Outcome<List<String>>> keys() async {
    final prefix = 'plugin:$_pluginId:';
    final r = await _inner.keys();
    if (r.isErr) return Err<List<String>>(r.failureOrNull!);
    return Ok<List<String>>([for (final k in r.valueOrNull!) if (k.startsWith(prefix)) k.substring(prefix.length)]);
  }
}
