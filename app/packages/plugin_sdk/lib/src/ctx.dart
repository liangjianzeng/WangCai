/// 插件运行时看到的唯一世界（L3）：只经 [PluginCtx] 取能力，**绝不 import 宿主实现**。
///
/// 设计来源：Cordis `Context`（本仓不用 `Proxy`/`noSuchMethod`，改显式 `require<T>()`，
/// 因为 Dart 没有可靠的 Proxy 故事且字符串服务名丢静态安全）+ DSH `defineTool` 的
/// `execute(args, exec)`（"async work must observe or forward `exec.signal`"）。
library;

import 'dart:async';

import 'capability.dart';
import 'hook.dart';
import 'manifest.dart';
import 'outcome.dart';
import 'slot.dart';

/// 能力访问面。
abstract interface class CapabilityAccess {
  /// 同步门控查询（面板/chip 灰不灰读它）。未知 id 视为不可用。
  bool isAvailable(String capabilityId);

  String? unavailableReason(String capabilityId);

  /// 取实现。失败分支是闭集：`missingCapability`（未注册或 `available == false`）、
  /// `permissionDenied`（没声明对应权限）、`incompatibleContract`（契约版本不匹配）。
  ///
  /// **绝不返回 null 假装成功**：拿不到就用 [Outcome.fold] 处理。
  Outcome<T> require<T extends Capability>(ServiceKey<T> key);

  /// 插件贡献新能力实现（`trusted` 才有；其余信任级返回 `permissionDenied`）。
  Outcome<Disposable> provide<T extends Capability>(ServiceKey<T> key, T impl, {int priority = 0});
}

/// 槽访问面。
abstract interface class SlotAccess {
  /// 拥有槽（声明）。`trusted` 才可对 `app.*` 之外的命名空间声明；只能声明自己命名空间。
  Outcome<void> declare(SlotDef def);

  /// 填槽。未声明的槽会排队等声明（不报错、不丢）。
  ///
  /// [SlotContribution.payload] 是 `Object?`：app 侧塞 widget，测试里塞哨兵值（Dart 协变，
  /// 作者仍可写 `SlotContribution<MyCard>(...)`）。
  Outcome<Disposable> register(SlotContribution<Object?> contribution);

  /// 读账本（诊断/自测用；渲染走 app 侧 `SlotOutlet`）。
  List<SlotEntry> entries(String slotId, {String? key, Map<String, Object?>? ownerData});

  Disposable subscribe(void Function(String slotId) onChange);
}

/// 日志面。**每条都会带 traceId**，接进现成「推理日志」页。
abstract interface class PluginLog {
  void debug(String message);
  void info(String message);
  void warn(String message);

  /// 失败专用：message 面向用户，cause 只进日志。
  void fail(String message, {Object? cause, PluginFailureKind? code});
}

/// 插件的整个世界。内核实现它；测试用 `plugin_sdk/testing.dart` 的 `FakePluginCtx`。
abstract interface class PluginCtx {
  PluginManifest get manifest;

  /// 一次插件会话的追踪号，贯穿抽词/合成/播放/失败（§4.16 可观测性）。
  String get traceId;

  CapabilityAccess get capabilities;
  SlotAccess get slots;
  PluginLog get log;

  /// 注册资源回收。**必须**用它拿订阅/定时器，否则 conformance「回收」组会红。
  Disposable effect(Disposable disposer);

  /// 合并后的配置读取（默认 → 方案档 → 会话内临时，§4.5）。
  Object? configValue(String name);
  double numberConfig(String name, double fallback);
  bool boolConfig(String name, bool fallback);
  String stringConfig(String name, String fallback);

  /// 会话内临时覆盖（本次听写把间隔调成 8s，**不落盘**）。
  void setSessionOverride(String name, Object? value);

  bool hasPermission(PluginPermission permission);

  /// 本次会话的取消令牌。所有插件侧异步都必须观察它。
  PluginCancelToken get cancelToken;

  /// 会话 id（`root` 作用域的槽用 `'root'`）。
  String get sessionId;
}

/// 触发入口（同一份 `run()` 被多种入口共用，绝不各写一套）。
enum PluginEntryKind { composerAction, composerSheetRow, slashCommand, agentTool, flow, profileSwitch, messageCardAction }

/// 一次调用的输入。
final class PluginInput {
  const PluginInput({
    required this.entry,
    this.text = '',
    this.imagePaths = const [],
    this.args = const {},
    this.sessionId = 'root',
  });

  final PluginEntryKind entry;
  final String text;
  final List<String> imagePaths;
  final Map<String, Object?> args;
  final String sessionId;
}

/// 运行结果。[payloads] 是给 app 侧渲染的不透明载荷（例如词表卡片数据），
/// [data] 是给上层逻辑/flow 步骤消费的结构化数据。
final class PluginRunResult {
  const PluginRunResult({
    this.summary = '',
    this.data = const {},
    this.payloads = const [],
    this.userVisible = true,
  });

  const PluginRunResult.silent()
      : summary = '',
        data = const {},
        payloads = const [],
        userVisible = false;

  final String summary;
  final Map<String, Object?> data;
  final List<Object?> payloads;

  /// false = 纯内部动作（不弹提示）。
  final bool userVisible;
}

/// `apply()` 开头该说的一句实话：**我声明要的能力，本机到底有没有**。
///
/// 为什么值得单独一个函数（而不是让每个作者手写一遍）：
/// * 加载器虽然会按可用性把插件标成"待功能"，但**装完之后**能力可能才消失
///   （离线 TTS 卸载、用户关掉视觉开关）；那时 fiber 会 apply 成功、run 才炸，
///   面板上显示"运行失败"，用户根本不知道缺什么。
/// * 让它 apply 当场失败，面板直接显示"缺：app.speak"，一句话可行动。
/// * conformance 的「生命周期」组会检查这一条：**缺能力时 apply 必须明确失败，不许假装成功**。
///
/// 注意：这里只用 `isAvailable`（查表，不算 IO），不违反"apply 零能力调用"规约。
Outcome<void> ensureDeclaredCapabilities(PluginCtx ctx) {
  final missing = [for (final id in ctx.manifest.inject) if (!ctx.capabilities.isAvailable(id)) id];
  if (missing.isEmpty) return const Ok<void>(null);
  return Err<void>(PluginFailure(
    code: PluginFailureKind.missingCapability,
    message: '还缺：${missing.join('、')}',
    hint: '在「插件」页看它的前置条件；本机能力齐了再点重试',
    pluginId: ctx.manifest.id,
  ));
}

/// 插件实现体。
///
/// 两条硬规约（conformance 机检）：
/// 1. **[apply] 只做注册，禁止 IO / 网络 / 长任务**（fake 能力记录调用时刻，apply 期间必须零调用）；
///    一切耗时都在 [run] 里，且必须响应 `ctx.cancelToken`。
/// 2. **[apply] 返回的 disposer 必须能清干净**：禁用插件后账本为空、无 `Timer`/订阅/在飞任务。
abstract interface class AppPlugin {
  PluginManifest get manifest;

  /// 对齐 Cordis `apply(ctx, config)`：注册贡献物，返回 disposer（可为 null）。
  ///
  /// 失败行为：返回 `Err` → fiber 停在 `failed`，面板显示聚合原因；**不得 throw**。
  Outcome<Disposable?> apply(PluginCtx ctx);

  /// 运行入口（chip / slash / agentTool / flow 共用）。
  Future<Outcome<PluginRunResult>> run(PluginCtx ctx, PluginInput input);
}

/// 便捷：把同步动作包成 disposer。
Disposable toDisposable(FutureOr<void> Function() body) => body;

/// 超时包装（flow 步骤与能力调用共用；到点折算成 `timeout` 失败而不是永久挂起）。
Future<Outcome<T>> withTimeout<T>(
  Future<Outcome<T>> Function() body,
  Duration limit, {
  required String what,
}) async {
  try {
    return await body().timeout(limit);
  } on TimeoutException {
    return Err<T>.of(PluginFailureKind.timeout, '$what 等太久没反应', hint: '稍后重试；网络不稳时可改用离线能力');
  }
}
