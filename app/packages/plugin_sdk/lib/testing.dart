/// 契约测试夹具与**一致性套件（conformance）**。
///
/// 用途有两个，都不可省：
/// 1. `test/` 里离线跑（`dart test`，不依赖 Flutter / 真机 / 网络）；
/// 2. 插件作者写完插件后 `await runConformance(() => MyPlugin())` 一行拿到六组体检结果，
///    结果同时被插件面板「体检」按钮渲染 —— **套件是唯一裁判，插件自己说了不算**。
///
/// 注意：本文件里的"内核级"断言（fiber 状态迁移、epoch 自动重载）在 P1 内核落地后补全；
/// P0 阶段先钉住**插件作者规约**（apply 无 IO、dispose 干净、失败不 throw、错误可解释、槽规矩、select 纯）。
library;

import 'dart:async';
import 'dart:convert';

import 'package:plugin_sdk/plugin_sdk.dart';

// ————————————————————————————————— Fakes —————————————————————————————————

/// 一次能力调用的记录（用于"apply 期间零调用"与顺序断言）。
final class CapabilityCall {
  CapabilityCall(this.capabilityId, this.method, this.tick, {this.args = const {}});
  final String capabilityId;
  final String method;
  final int tick;
  final Map<String, Object?> args;

  @override
  String toString() => '$capabilityId.$method@#$tick';
}

/// 可编排的能力基类：可用性可切换、调用被记录、可注入失败。
class FakeCapability implements Capability {
  FakeCapability(this._key, {bool available = true, this.unavailableReason}) : _available = available;

  final ServiceKey _key;
  bool _available;
  String? unavailableReason;

  /// 由 [FakeCapabilityHarness] 注入，用于记录调用发生在哪个阶段。
  void Function(CapabilityCall)? recorder;
  int Function() _tick = () => 0;
  set tickSource(int Function() t) => _tick = t;

  @override
  ServiceKey get key => _key;

  @override
  bool get available => _available;
  set available(bool v) => _available = v;

  void _record(String method, [Map<String, Object?> args = const {}]) =>
      recorder?.call(CapabilityCall(_key.id, method, _tick(), args: args));

  /// 让子类复用记录。
  void record(String method, [Map<String, Object?> args = const {}]) => _record(method, args);

  @override
  Future<void> warmUp() async => _record('warmUp');

  @override
  Future<Outcome<void>> probe() async {
    _record('probe');
    if (!_available) {
      return Err<void>.of(PluginFailureKind.missingCapability, unavailableReason ?? '${_key.id} 不可用',
          hint: '检查设置页对应开关');
    }
    return const Ok<void>(null);
  }
}

/// 一次性文本补全的假实现：可编程返回内容 / 失败 / 抛异常（用来验证插件是否会漏 `throw`）。
final class FakeLlmComplete extends FakeCapability implements LlmComplete {
  FakeLlmComplete({this.response = '{}', this.failWith, this.throwOnCall = false})
      : super(ServiceKeys.llmComplete, available: true);

  String response;
  PluginFailure? failWith;

  /// true 时**故意抛异常**：合规的插件必须用 `Outcome.guard` 包住，否则 conformance 会红。
  bool throwOnCall;

  /// 最近一次收到的提示词（断言抽词 prompt 是否被污染成聊天历史）。
  String? lastSystemPrompt;
  String? lastUserText;

  @override
  Future<Outcome<String>> complete({
    required String systemPrompt,
    required String userText,
    int? maxTokens,
    double temperature = 0,
    PluginCancelToken? cancelToken,
  }) async {
    record('complete', {'maxTokens': maxTokens, 'temperature': temperature, 'system': systemPrompt, 'user': userText});
    lastSystemPrompt = systemPrompt;
    lastUserText = userText;
    if (throwOnCall) throw StateError('fake llm exploded');
    if (failWith != null) return Err<String>(failWith!);
    return Ok<String>(response);
  }
}

/// 带图补全（抽词路径）。
final class FakeLlmVision extends FakeCapability implements LlmVision {
  FakeLlmVision({this.response = '{"words":[]}', this.availableOverride, this.failWith})
      : super(ServiceKeys.llmVision, available: true, unavailableReason: '本机没有可用的视觉模型');

  String response;

  /// 非 null 时用它覆盖可用性（模拟"没加载视觉模型"）。
  bool? availableOverride;

  /// 非 null 时直接回这条失败（模拟"服务端拒绝/网络不通"）。
  PluginFailure? failWith;

  List<String>? lastImagePaths;

  @override
  bool get available => availableOverride ?? super.available;

  @override
  Future<Outcome<String>> completeWithImage({
    required String systemPrompt,
    required String userText,
    required List<String> imagePaths,
    int? maxTokens,
    double temperature = 0,
    PluginCancelToken? cancelToken,
  }) async {
    // systemPrompt/userText 也记下来：测试要能验"用户的附加要求真的进了提示词"。
    record('completeWithImage', {
      'images': imagePaths.length,
      'maxTokens': maxTokens,
      'system': systemPrompt,
      'user': userText,
    });
    lastImagePaths = imagePaths;
    if (failWith != null) return Err<String>(failWith!);
    return Ok<String>(response);
  }
}

/// 朗读能力假实现：可配置每个词耗时、是否跳过、是否失败。
final class FakeSpeak extends FakeCapability implements Speak {
  FakeSpeak({this.perItem = Duration.zero, this.failAt = const {}, this.gapCap = Duration.zero})
      : super(ServiceKeys.speak, available: true);

  final Duration perItem;

  /// 下标 → 失败原因（模拟"个别词合成失败"）。
  final Map<int, String> failAt;
  /// >0 时把每次间隔的真实等待压到该值（只影响测试耗时，不影响 [SpeakRequest] 记录）。
  final Duration gapCap;

  final List<SpeakRequest> requests = [];
  bool stopped = false;
  SpeakRequest? lastRequest;

  @override
  Stream<SpeakProgress> speak(SpeakRequest request, PluginCancelToken cancelToken) async* {
    requests.add(request);
    lastRequest = request;
    record('speak', {'items': request.items.length, 'gap': request.gap.inMilliseconds, 'voice': request.voice});
    for (var i = 0; i < request.items.length; i++) {
      if (cancelToken.isCancelled) return;
      yield SpeakProgress(index: i, text: request.items[i], phase: SpeakPhase.synthesizing);
      if (perItem > Duration.zero) {
        if (!await cancelToken.delay(perItem)) return;
      }
      if (cancelToken.isCancelled) return;
      final err = failAt[i];
      if (err != null) {
        yield SpeakProgress(index: i, text: request.items[i], phase: SpeakPhase.skipped, error: err);
        continue;
      }
      yield SpeakProgress(index: i, text: request.items[i], phase: SpeakPhase.playing);
      if (request.gap > Duration.zero) {
        yield SpeakProgress(index: i, text: request.items[i], phase: SpeakPhase.gap);
        // gapCap：测试里把真实等待压扁（否则 6 个词 × 5 秒 = 半分钟假等），
        // 但**请求里的 gap 原样保留**，断言照样能验"间隔有没有正确传给能力"。
        final wait = gapCap > Duration.zero && request.gap > gapCap ? gapCap : request.gap;
        if (!await cancelToken.delay(wait)) return;
      }
    }
  }

  @override
  Future<void> stop() async {
    stopped = true;
    record('stop');
  }

  @override
  Future<bool> prewarm(List<String> texts, String voice) async {
    record('prewarm', {'count': texts.length});
    return true;
  }
}

/// 取图假实现。
final class FakeCapture extends FakeCapability implements Capture {
  FakeCapture({this.images = const ['/tmp/fake-1.jpg'], this.failCameraWith}) : super(ServiceKeys.capture, available: true);
  List<String> images;
  PluginFailure? failWith;

  /// **只在走相机时**失败（用来验"相机权限被拒 → 自动改走相册"这类兜底路径；
  /// 用 [failWith] 会把相册那一趟也一起打挂，测不出兜底有没有真的发生）。
  PluginFailure? failCameraWith;

  @override
  Future<Outcome<List<String>>> pickImages({required int maxCount, required bool preferCamera}) async {
    record('pickImages', {'maxCount': maxCount, 'camera': preferCamera});
    if (failWith != null) return Err<List<String>>(failWith!);
    if (preferCamera && failCameraWith != null) return Err<List<String>>(failCameraWith!);
    if (!available) {
      return Err<List<String>>.of(PluginFailureKind.missingCapability, unavailableReason ?? '相机不可用',
          hint: '在系统设置里允许本应用使用相机');
    }
    return Ok<List<String>>(images.take(maxCount).toList());
  }
}

/// 分域存储假实现（内存版）。
final class FakeStore extends FakeCapability implements Store {
  FakeStore({Map<String, String>? seed})
      : _data = Map<String, String>.of(seed ?? const {}),
        super(ServiceKeys.store, available: true);

  final Map<String, String> _data;
  Map<String, String> get data => Map.unmodifiable(_data);

  @override
  Future<Outcome<String?>> read(String key) async {
    record('read', {'key': key});
    return Ok<String?>(_data[key]);
  }

  @override
  Future<Outcome<void>> write(String key, String value) async {
    record('write', {'key': key, 'len': value.length});
    _data[key] = value;
    return const Ok<void>(null);
  }

  @override
  Future<Outcome<void>> remove(String key) async {
    record('remove', {'key': key});
    _data.remove(key);
    return const Ok<void>(null);
  }

  @override
  Future<Outcome<List<String>>> keys() async {
    record('keys');
    return Ok<List<String>>(_data.keys.toList()..sort());
  }
}

/// 语音识别假实现（跟读评测类插件与"能力齐不齐"的门控测试要用）。
final class FakeTranscribe extends FakeCapability implements Transcribe {
  FakeTranscribe({this.text = '你好', this.availableOverride}) : super(ServiceKeys.transcribe, available: true);
  String text;
  bool? availableOverride;
  String? lastAudioPath;

  @override
  bool get available => availableOverride ?? super.available;

  @override
  Future<Outcome<String>> transcribe(String audioPath, {PluginCancelToken? cancelToken}) async {
    record('transcribe', {'path': audioPath});
    lastAudioPath = audioPath;
    if (!available) {
      return Err<String>.of(PluginFailureKind.missingCapability, unavailableReason ?? '识别模型还没下载',
          hint: '去「设置 → 语音」下载识别模型');
    }
    if (cancelToken?.isCancelled ?? false) {
      return Err<String>.of(PluginFailureKind.cancelled, '已取消');
    }
    return Ok<String>(text);
  }
}

/// 询问假实现：按队列依次返回预设答案。
final class FakeInteract extends FakeCapability implements Interact {
  FakeInteract({List<double>? numbers, List<String>? choices})
      : _numbers = [...?numbers],
        _choices = [...?choices],
        super(ServiceKeys.interact, available: true);

  final List<double?> _numbers;
  final List<String?> _choices;
  String? lastQuestion;

  @override
  Future<Outcome<double?>> askNumber({required String question, required double defaultValue, required double min, required double max}) async {
    record('askNumber', {'q': question, 'min': min, 'max': max, 'default': defaultValue});
    lastQuestion = question;
    final v = _numbers.isEmpty ? defaultValue : _numbers.removeAt(0);
    if (v != null && (v < min || v > max)) {
      return Err<double?>.of(PluginFailureKind.badContent, '输入超出范围', hint: '请输入 ${min.toStringAsFixed(0)}–${max.toStringAsFixed(0)} 之间的数');
    }
    return Ok<double?>(v);
  }

  @override
  Future<Outcome<String?>> askChoice({required String question, required List<String> options, String? defaultValue}) async {
    record('askChoice', {'q': question, 'options': options.length});
    lastQuestion = question;
    final v = _choices.isEmpty ? defaultValue : _choices.removeAt(0);
    return Ok<String?>(v);
  }
}

/// 能力挂具：按 id 装配 fake 能力，统一记录调用。
final class FakeCapabilityHarness {
  FakeCapabilityHarness();

  final Map<String, Capability> byId = {};
  final List<CapabilityCall> calls = [];
  int _tick = 0;

  int get tick => _tick;
  void tickForward([int n = 1]) => _tick += n;

  T register<T extends Capability>(T cap) {
    byId[cap.key.id] = cap;
    if (cap is FakeCapability) {
      cap.recorder = calls.add;
      cap.tickSource = () => _tick;
    }
    return cap;
  }

  T requireRegistered<T extends Capability>(ServiceKey<T> key) => byId[key.id] as T;

  /// 某次调用之后的记录（阶段化断言用）。
  List<CapabilityCall> callsSince(int fromTick) => calls.where((c) => c.tick >= fromTick).toList(growable: false);
}

/// [PluginCtx] 的假实现。作者与 conformance 套件共用。
class FakePluginCtx implements PluginCtx {
  FakePluginCtx({
    required this.manifest,
    FakeCapabilityHarness? harness,
    Set<String>? permissions,
    Map<String, Object?>? config,
    this.sessionId = 'test-session',
    SlotRegistry? slotRegistry,
    this.declareHostSlots = true,
  })  : harness = harness ?? FakeCapabilityHarness(),
        declaredPermissions = permissions ?? manifest.permissions.map((p) => p.wireName).toSet(),
        _config = Map<String, Object?>.of(config ?? const {}),
        traceId = 'fake-trace',
        slotsLedger = slotRegistry ?? SlotRegistry() {
    // 夹具要像真宿主：启动即声明全部契约槽（否则插件填 app.input.right 只能进 pending，
    // 测试就会验到和真机不一样的路径）。关掉它可专门测"槽还不存在时的排队"。
    if (declareHostSlots) {
      for (final d in kHostSlotContract) {
        slotsLedger.declare(d);
      }
    }
  }

  @override
  final PluginManifest manifest;
  final FakeCapabilityHarness harness;
  final Set<String> declaredPermissions;
  final Map<String, Object?> _config;
  final Map<String, Object?> sessionOverrides = {};
  final SlotRegistry slotsLedger;

  /// 是否预声明宿主 11 槽（默认 true，模拟宿主启动时的声明动作）。
  final bool declareHostSlots;
  final List<String> logs = [];
  final List<String> failures = [];
  final List<Disposable> effects = [];

  /// true 期间记录任何能力调用 → conformance 用它断言"apply 里没 IO"。
  bool applyPhase = false;
  int applyPhaseViolations = 0;

  @override
  final String traceId;
  @override
  final String sessionId;

  @override
  final PluginCancelToken cancelToken = PluginCancelToken(debugLabel: 'fake-ctx');

  late final CapabilityAccess capabilities = _FakeCapabilityAccess(this);
  late final SlotAccess slots = _FakeSlotAccess(this);

  @override
  Disposable effect(Disposable disposer) {
    effects.add(disposer);
    return () => effects.remove(disposer);
  }

  Future<void> disposeAllEffects() async {
    for (final d in effects.reversed) {
      try {
        await d();
      } catch (_) {
        // 与内核一致：单个 disposer 失败只记日志。
      }
    }
    effects.clear();
  }

  @override
  Object? configValue(String name) => sessionOverrides.containsKey(name) ? sessionOverrides[name] : (_config[name] ?? _paramDefault(name));
  double _paramDefault(String name) => 0;

  @override
  double numberConfig(String name, double fallback) {
    final v = configValue(name);
    return v is num ? v.toDouble() : fallback;
  }

  @override
  bool boolConfig(String name, bool fallback) => configValue(name) is bool ? configValue(name)! as bool : fallback;

  @override
  String stringConfig(String name, String fallback) => configValue(name) is String ? configValue(name)! as String : fallback;

  @override
  void setSessionOverride(String name, Object? value) => sessionOverrides[name] = value;

  @override
  bool hasPermission(PluginPermission permission) => declaredPermissions.contains(permission.wireName);

  @override
  PluginLog get log => _FakeLog(this);
}

final class _FakeLog implements PluginLog {
  _FakeLog(this.ctx);
  final FakePluginCtx ctx;
  @override
  void debug(String m) => ctx.logs.add('D $m');
  @override
  void info(String m) => ctx.logs.add('I $m');
  @override
  void warn(String m) => ctx.logs.add('W $m');
  @override
  void fail(String message, {Object? cause, PluginFailureKind? code}) {
    ctx.logs.add('F $message');
    ctx.failures.add(message);
  }
}

final class _FakeCapabilityAccess implements CapabilityAccess {
  _FakeCapabilityAccess(this.ctx);
  final FakePluginCtx ctx;
  final Map<String, Capability> provided = {};

  Capability? _lookup(ServiceKey key) => provided[key.id] ?? ctx.harness.byId[key.id];

  @override
  bool isAvailable(String capabilityId) => _lookup(ServiceKey(capabilityId))?.available ?? false;

  @override
  String? unavailableReason(String capabilityId) {
    final c = _lookup(ServiceKey(capabilityId));
    if (c == null) return '本机没有提供能力 $capabilityId';
    return c.available ? null : (c.unavailableReason ?? '$capabilityId 当前不可用');
  }

  @override
  Outcome<T> require<T extends Capability>(ServiceKey<T> key) {
    if (ctx.applyPhase) {
      ctx.applyPhaseViolations++;
    }
    ctx.harness.tickForward();
    final need = _permissionFor(key.id);
    if (need != null && !ctx.hasPermission(need)) {
      return Err<T>.of(PluginFailureKind.permissionDenied, '插件未声明 ${need.wireName} 权限',
          hint: '在 plugin.json 的 permissions 里加上 "${need.wireName}"', pluginId: ctx.manifest.id);
    }
    final c = _lookup(key);
    if (c == null) {
      return Err<T>.of(PluginFailureKind.missingCapability, '本机没有提供能力 ${key.id}',
          hint: '在插件面板查看本机能力清单，或安装提供该能力的插件', pluginId: ctx.manifest.id);
    }
    if (!c.available) {
      return Err<T>.of(PluginFailureKind.missingCapability, c.unavailableReason ?? '${key.id} 当前不可用',
          hint: '见「设置」页对应开关', pluginId: ctx.manifest.id);
    }
    if (c.key.contractVersion != key.contractVersion) {
      return Err<T>.of(PluginFailureKind.incompatibleContract,
          '能力 ${key.id} 的契约是 ${c.key.contractVersion}，本插件要 ${key.contractVersion}',
          hint: '升级插件或 app', pluginId: ctx.manifest.id);
    }
    return Ok<T>(c as T);
  }

  @override
  Outcome<Disposable> provide<T extends Capability>(ServiceKey<T> key, T impl, {int priority = 0}) {
    if (ctx.manifest.trust != PluginTrust.trusted) {
      return Err<Disposable>.of(PluginFailureKind.permissionDenied,
          '只有 trusted 插件能贡献能力实现（当前是 ${ctx.manifest.trust.name}）',
          hint: '声明式插件请改用现有能力', pluginId: ctx.manifest.id);
    }
    final prev = provided[key.id];
    provided[key.id] = impl;
    return Ok<Disposable>(() {
      if (prev == null) {
        provided.remove(key.id);
      } else {
        provided[key.id] = prev;
      }
    });
  }

  PluginPermission? _permissionFor(String capabilityId) => impliedPermissionFor(capabilityId);
}

final class _FakeSlotAccess implements SlotAccess {
  _FakeSlotAccess(this.ctx);
  final FakePluginCtx ctx;

  @override
  Outcome<void> declare(SlotDef def) {
    if (def.ownerPluginId != ctx.manifest.id && def.ownerPluginId != 'app') {
      return Err<void>.of(PluginFailureKind.permissionDenied, '只能在自己命名空间 ${ctx.manifest.id}.* 下声明槽',
          hint: '把槽 id 改成 "${ctx.manifest.id}.${def.id.split('.').skip(1).join('.')}"', pluginId: ctx.manifest.id);
    }
    return ctx.slotsLedger.declare(def);
  }

  @override
  Outcome<Disposable> register(SlotContribution<Object?> c) {
    // 注意：填槽**不算 IO**（apply 的本义就是注册贡献物）；只有能力调用/网络/磁盘算。
    return ctx.slotsLedger.register(c);
  }

  @override
  List<SlotEntry> entries(String slotId, {String? key, Map<String, Object?>? ownerData}) =>
      ctx.slotsLedger.entries(slotId, key: key, ownerData: ownerData);

  @override
  Disposable subscribe(void Function(String) onChange) => ctx.slotsLedger.subscribe(onChange);
}

// ———————————————————————————— conformance 套件 ————————————————————————————

/// 一条体检结果。
final class ConformanceCheck {
  const ConformanceCheck({required this.group, required this.name, required this.passed, this.detail});

  /// 六组之一（与 §4.16 表对齐）。
  final String group;
  final String name;
  final bool passed;

  /// 失败时的具体说明（面板直接显示）。
  final String? detail;

  @override
  String toString() => '${passed ? '✓' : '✗'} [$group] $name${detail == null ? '' : ' — $detail'}';
}

/// 跑一致性套件。返回全部检查（**不抛异常**：任何检查内部异常折算成该条失败）。
Future<List<ConformanceCheck>> runConformance(
  AppPlugin Function() factory, {
  FakeCapabilityHarness? harness,
  Set<String>? permissions,
  Map<String, Object?>? config,
  PluginInput? input,
}) async {
  final out = <ConformanceCheck>[];
  ConformanceCheck raw(String group, String name, bool ok, [String? detail]) =>
      ConformanceCheck(group: group, name: name, passed: ok, detail: detail);

  // —— 契约组 ——
  final manifest = factory().manifest;
  final report = validateManifest(
    manifest.toJson(),
    knownCapabilityIds: {
      'llm.complete', 'llm.vision', 'app.speak', 'app.capture', 'app.store', 'app.interact',
      'asr.transcribe', 'net.search',
    },
  );
  out.add(raw('契约', 'plugin.json 自校验通过', report.ok, report.errors.map((e) => e.toString()).join('; ')));
  out.add(raw('契约', 'id 合法且稳定', _idPatternOk(manifest.id), manifest.id));
  out.add(raw('契约', 'description 非空（面板能解释它是干什么的）', manifest.description.trim().isNotEmpty));
  out.add(raw('契约', '声明了 inject（不靠隐式依赖）', manifest.inject.isNotEmpty));
  out.add(raw('契约', '失败信息规范（message≤120 且必要码带 hint）', _failureSpecOk(manifest)));

  // —— 生命周期组 ——
  final h = harness ?? FakeCapabilityHarness();
  final missing = _missingInjects(manifest, h);
  final ctxMissing = FakePluginCtx(manifest: manifest, harness: h, permissions: permissions, config: config);
  ctxMissing.applyPhase = true;
  final applyMissing = manifest.trust == PluginTrust.declarative ? const Ok<Disposable?>(null) : factory().apply(ctxMissing);
  await Future<void>.delayed(Duration.zero);
  out.add(raw('生命周期', '能力不齐时 apply 不产生副作用', ctxMissing.applyPhaseViolations == 0,
      'apply 期间发生 ${ctxMissing.applyPhaseViolations} 次能力调用'));
  out.add(raw('生命周期', '能力不齐时 apply 明确失败（不假装成功）',
      missing.isEmpty || applyMissing.isErr, '缺：${missing.join(', ')} 但 apply 返回 ${applyMissing.runtimeType}'));

  final ctx = FakePluginCtx(manifest: manifest, harness: h, permissions: permissions, config: config);
  ctx.applyPhase = true; // apply 阶段的定义：注册贡献物之外不许有任何能力调用
  final applyResult = await factory().apply(ctx);
  out.add(raw('生命周期', '能力齐备时 apply 成功', applyResult.isOk,
      applyResult.failureOrNull?.message ?? ''));
  out.add(raw('生命周期', 'apply 期间零 IO / 零能力调用', ctx.applyPhaseViolations == 0,
      '${ctx.applyPhaseViolations} 次违规调用'));
  ctx.applyPhase = false;

  // —— 回收组 ——
  await ctx.disposeAllEffects();
  final leftover = [
    ...ctx.slotsLedger.snapshot().where((e) => e['registrant'] == manifest.id),
    ...ctx.slotsLedger.pendingContributions().where((c) => c.pluginId == manifest.id).map((c) => {'slot': c.slotId, 'id': c.id}),
  ];
  out.add(raw('回收', 'dispose 后该插件贡献物全清', leftover.isEmpty,
      leftover.map((e) => '${e['slot']}#${e['id']}').join(', ')));

  // —— 状态与错误组 ——
  final runCtx = FakePluginCtx(manifest: manifest, harness: h, permissions: permissions, config: config);
  var runThrew = false;
  String? runThrowDetail;
  try {
    await factory().run(runCtx, input ?? PluginInput(entry: PluginEntryKind.composerAction));
  } catch (e) {
    runThrew = true;
    runThrowDetail = '${e.runtimeType}: $e';
  }
  out.add(raw('状态与错误', 'run 不 throw，失败一律走 Outcome', !runThrew, runThrowDetail));
  out.add(raw('状态与错误', '取消令牌在 run 结束时未被永久取消（可复用）', !runCtx.cancelToken.isCancelled));

  // —— 槽组 ——
  final badSlots = ctx.slotsLedger
      .snapshot()
      .where((e) => e['registrant'] == manifest.id && e['active'] == false)
      .toList();
  out.add(raw('槽', '没有已让位（崩溃）的条目', badSlots.isEmpty, badSlots.map((e) => e['slot']).join(', ')));
  out.add(raw('槽', '注册的槽都有合法 id 命名空间', _slotNamespaceOk(manifest, ctx.slotsLedger),
      '插件只能在 ${manifest.id}.* 或宿主 app.* 下填槽'));

  // —— 预算组 ——
  final jsonBytes = utf8Length(manifest.toJson());
  out.add(raw('预算', 'plugin.json ≤ ${kMaxManifestBytes ~/ 1024}KB', jsonBytes <= kMaxManifestBytes, '$jsonBytes B'));
  out.add(raw('预算', '参数数量 ≤ 12（设置页可用性与启动开销）', manifest.params.length <= 12,
      '${manifest.params.length} 个参数'));

  return out;
}

final RegExp _idOk = RegExp(r'^[a-z][a-z0-9-]{2,63}$');
bool _idPatternOk(String id) => _idOk.hasMatch(id);

List<String> _missingInjects(PluginManifest m, FakeCapabilityHarness h) =>
    m.inject.where((id) => !(h.byId[id]?.available ?? false)).toList();

bool _failureSpecOk(PluginManifest m) {
  // 规约：需要 hint 的失败码若被用到必须有 hint —— 这里用"构造一个必须带 hint 的失败"来钉住契约本身。
  try {
    PluginFailure(code: PluginFailureKind.missingCapability, message: 'x', hint: 'y');
    return true;
  } catch (_) {
    return false;
  }
}

bool _slotNamespaceOk(PluginManifest m, SlotRegistry reg) {
  final slots = <String>[
    ...reg.snapshot().where((s) => s['registrant'] == m.id).map((s) => s['slot'] as String),
    ...reg.pendingContributions().where((c) => c.pluginId == m.id).map((c) => c.slotId),
  ];
  for (final slot in slots) {
    final owner = slot.split('.').first;
    if (owner != m.id && owner != 'app') return false;
  }
  return true;
}

/// manifest 序列化成 JSON 的字节数（预算组用；与磁盘上的 plugin.json 同尺度）。
int utf8Length(Map<String, dynamic> j) => utf8.encode(jsonEncode(j)).length;

// ———————————————————————— 能力实现的一致性套件（第二实现必须过同一套）————————————————————————

final RegExp _capabilityIdOk = RegExp(r'^[a-z][a-z0-9-]*(\.[a-z][a-z0-9-]*)+$');

/// **能力实现**（`Capability`）的体检。
///
/// 为什么单独一套：`runConformance` 管的是"插件规不规矩"，但**能力的第二实现**（离线朗读盖掉在线那份、
/// 第三方 `trusted` 插件换掉宿主实现）真正的风险在实现本身 —— 它一旦"不能用却不肯说为什么"，
/// 注册表就会把整份实现选上然后再全场失败；它一旦在 `probe()` 里 throw，就能把面板带崩。
/// 所以任何一份实现（宿主的、示例的、第三方的）上岗前都过**同一套**体检，
/// 而不是"宿主那份特例免检"。任何检查内部异常都折算成该条失败，**本函数永不抛**。
Future<List<ConformanceCheck>> runCapabilityConformance(Capability impl) async {
  ConformanceCheck c(String name, bool ok, [String? detail]) =>
      ConformanceCheck(group: '状态与错误', name: name, passed: ok, detail: detail);
  ConformanceCheck contract(String name, bool ok, [String? detail]) =>
      ConformanceCheck(group: '契约', name: name, passed: ok, detail: detail);

  final out = <ConformanceCheck>[];

  // 契约：能力 id 决定插件 `inject` 能不能写对，写歪了就是"永远解析不到"。
  out.add(contract('能力 id 是点分小写（app.speak 这种）', _capabilityIdOk.hasMatch(impl.key.id), impl.key.id));

  // 可用性：不可用必须说人话原因 —— 面板与注册表回落全靠这句话指路。
  bool available;
  try {
    available = impl.available;
  } catch (e) {
    out.add(c('available 读取不抛', false, '$e'));
    return out;
  }
  out.add(c('available 读取不抛', true));

  String? reason;
  try {
    reason = impl.unavailableReason;
  } catch (e) {
    reason = null;
    out.add(c('unavailableReason 读取不抛', false, '$e'));
  }
  if (!available) {
    out.add(c(
      '不可用时给出人话原因（面板与回落都要靠它）',
      reason != null && reason.trim().isNotEmpty,
      reason == null ? 'available=false 却说不出为什么 —— 用户只能干瞪眼' : null,
    ));
  } else {
    out.add(c(
      '可用时不乱给原因（免得面板两条口径打架）',
      reason == null || reason.trim().isEmpty,
      reason,
    ));
  }

  // probe：面板"试一下"按钮直接调它，抛出来就是把整个面板带崩。
  try {
    final r = await impl.probe();
    if (r case Err(:final failure)) {
      out.add(c('probe 失败时带 message 与出路', failure.message.trim().isNotEmpty && failure.hint != null,
          '${failure.message} / hint=${failure.hint}'));
    } else {
      out.add(c('probe 可用时返回成功', true));
    }
  } catch (e) {
    out.add(c('probe() 永不 throw（异常必须折算成 Outcome）', false, '$e'));
  }

  try {
    await impl.probe(); // 第二次：不许有"第一次好好的、第二次就炸"的隐藏状态
    out.add(c('probe 可重复调用', true));
  } catch (e) {
    out.add(c('probe 可重复调用', false, '$e'));
  }

  // 探测**不该改变**可用性：读一次留给后面比对。
  bool? afterProbe;
  try {
    afterProbe = impl.available;
  } catch (e) {
    afterProbe = null;
  }

  try {
    await impl.warmUp();
    out.add(c('warmUp() 永不 throw（预热失败只该影响性能）', true));
  } catch (e) {
    out.add(c('warmUp() 永不 throw（预热失败只该影响性能）', false, '$e'));
  }

  bool? again;
  try {
    again = impl.available;
  } catch (e) {
    again = null;
  }
  // 「预热完才就绪」是**合法**的：离线 TTS 这类实现在 `warmUp` 里加载模型/音色表，
  // 之前 `available` 就该是 false。以前这里一刀切要求"前后完全一致"，
  // 把最该过体检的第二实现（P7 的离线朗读）判成不合格 —— 误伤比漏判更坏：作者会被自己的体检劝退。
  // 于是只放这一种翻转：探测期间不动，`warmUp` 之后 不可用 → 可用。
  final warmedReady = !available && afterProbe == available && again == true;
  out.add(c(
    '可用性是稳定的（不在 getter 里藏随机或副作用）',
    (again == available && afterProbe == available) || warmedReady,
    warmedReady ? '预热后由不可用转为可用（懒加载，合法）：$available → $again' : '$available → $afterProbe → $again',
  ));

  return out;
}

/// 断言用：把失败的检查拼成一句可读说明（测试里 `expect(fails, isEmpty, reason: describe(fails))`）。
String describeConformanceFailures(Iterable<ConformanceCheck> checks) =>
    checks.where((e) => !e.passed).map((e) => e.toString()).join('\n');
