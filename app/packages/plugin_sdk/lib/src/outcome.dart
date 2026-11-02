/// 平台统一的"结果 = 值或失败"返回（L3 契约）。
///
/// 设计来源：DSH `RemoteResult<T> = {ok:true,value} | {ok:false,error}` —— 失败**折进返回值**而不是抛异常。
/// 本仓为什么照抄：插件是用户可编辑的东西，`throw` 会把失败变成"红条 + 堆栈"，而平台要求
/// **每一种失败都能被一句话解释并给出路**（同 `lib/tts/edge_tts_service.dart` 的 `TtsFailureKind` 文化）。
///
/// 规约（由 conformance 套件与 `forbid_throw` 静态扫描共同强制）：
/// - 插件对外的公开方法**不得 `throw`**，一律返回 `Outcome`；
/// - `Err.message` 必须是给用户看的一句人话（非空、≤120 字、不含堆栈/枚举名）；
/// - 需要"出路"的失败码必须带 `hint`（面板直接渲染成可点的建议）。
library;

import 'dart:async';

/// 失败码闭集。**新增码要同时补：面板文案、conformance 断言、`_requiresHint`**。
enum PluginFailureKind {
  /// 声明的 `inject` 能力缺失或 `available == false`。
  missingCapability,

  /// 未在 `plugin.json` 声明该权限就取用能力（§4.14）。
  permissionDenied,

  /// `plugin.json` / 参数不合契约：插件不启动，聚合 issues。
  configInvalid,

  /// 能力在，但本次调用失败（网络、模型、IO…）。
  runtimeError,

  /// 被用户或宿主取消（携带 `PluginCancelToken` 的取消原因）。
  cancelled,

  /// 能力可用但当前条件不满足（例如"正在生成中，输入区已锁"）。
  busy,

  /// 契约版本协商失败（`requiresSdk` / `engines.app` 不满足）。
  incompatibleContract,

  /// 超时（区别于 `runtimeError`：面板提示"稍后重试"而不是"检查配置"）。
  timeout,

  /// 上游明确拒绝（如 Edge TTS 403 一类），需要"升级/换实现"的出路。
  denied,

  /// 内容不合规（抽词为空/被截断/JSON 非法…），通常带"改用别的模型"出路。
  badContent,
}

/// 哪些失败码**必须**带 `hint`（缺 hint 时构造期断言直接炸，防止"静默失败"回潮）。
const Set<PluginFailureKind> _requiresHint = {
  PluginFailureKind.missingCapability,
  PluginFailureKind.permissionDenied,
  PluginFailureKind.configInvalid,
  PluginFailureKind.incompatibleContract,
  PluginFailureKind.denied,
  PluginFailureKind.badContent,
};

/// 六类"必须给出路"的失败码，**兜底出路**。
///
/// 为什么要有这张表：构造期那条"必须带 hint"的规矩是 `assert`，**release 包里 assert 会被剥掉**。
/// 于是作者（或我们自己的某条新代码）漏了 hint，debug 看得见、线上就是光秃秃一句"失败了" ——
/// 这类"debug 绿、release 摆烂"的洞只能靠兜底堵，不能靠人自觉。
const Map<PluginFailureKind, String> kFallbackHints = {
  PluginFailureKind.missingCapability: '去「设置 → 插件」看本机能力清单：缺的可能是模型，也可能是某个开关',
  PluginFailureKind.permissionDenied: '在插件目录的 plugin.json 的 permissions 里补上这项，再回插件页重新扫描',
  PluginFailureKind.configInvalid: '照提示改插件目录里的 plugin.json，然后重新扫描',
  PluginFailureKind.incompatibleContract: '这个插件和当前 app 版本不配套：升级 app 或换配套版本的插件',
  PluginFailureKind.denied: '到系统设置里允许该权限，或换一个不需要它的做法',
  PluginFailureKind.badContent: '这一步的输入空了或不对：调整参数、换个说法，或重拍一张更清楚的',
};

/// 一个可解释的失败。
final class PluginFailure {
  PluginFailure({
    required this.code,
    required this.message,
    String? hint,
    this.pluginId,
    this.cause,
    this.step,
  }) : assert(
          message.trim().isNotEmpty && message.length <= 120,
          'PluginFailure.message 必须是给用户看的一句话（1–120 字），实际：${message.length} 字',
        ),
        assert(
          !_requiresHint.contains(code) || (hint != null && hint.trim().isNotEmpty),
          '失败码 $code 必须给出 hint（出路），否则用户只能看到"失败了"',
        ),
        // 断言在上面先跑（debug 照样炸，不许偷懒写没出路的失败）；
        // 这里管的是 release 把 assert 剥掉之后，面板上仍然得有一句话可指。
        hint = ensureHint(code, hint);

  /// 该给出路却没人给时按失败码兜一句（见 [kFallbackHints]：这是 release 模式唯一的防线）。
  static String? ensureHint(PluginFailureKind code, String? hint) {
    final given = (hint != null && hint.trim().isNotEmpty) ? hint.trim() : null;
    if (!_requiresHint.contains(code)) return given;
    return given ?? kFallbackHints[code] ?? '打开「设置 → 插件」看这条插件的说明，或点重新扫描';
  }

  final PluginFailureKind code;

  /// 给用户看的一句话。**不得**包含堆栈、Dart 枚举名或英文内部码。
  final String message;

  /// 出路（"去设置 → 模型 加载视觉模型"），面板渲染成按钮。
  final String? hint;

  /// 出错插件（面板定位用）。
  final String? pluginId;

  /// 出错的流程步骤 id（flow / 相位机定位用）。
  final String? step;

  /// 原始异常，仅供日志与诊断树，**永不进 UI**。
  final Object? cause;

  PluginFailure copyWith({String? message, String? hint, String? pluginId, String? step}) => PluginFailure(
        code: code,
        message: message ?? this.message,
        hint: hint ?? this.hint,
        pluginId: pluginId ?? this.pluginId,
        step: step ?? this.step,
        cause: cause,
      );

  /// 带插件与步骤上下文（内核在边界处统一补，插件内不必关心）。
  PluginFailure scoped({String? pluginId, String? step}) => copyWith(
        pluginId: pluginId ?? this.pluginId,
        step: step ?? this.step,
      );

  @override
  String toString() => 'PluginFailure(${code.name}, $message'
      '${pluginId == null ? '' : ', plugin=$pluginId'}'
      '${step == null ? '' : ', step=$step'})';
}

/// 值或失败。用 `sealed class` 以便 UI/内核 `switch` 穷举（漏分支编译期报错）。
sealed class Outcome<T> {
  const Outcome();

  bool get isOk => this is Ok<T>;
  bool get isErr => this is Err<T>;

  /// 便捷读法：失败时为 null。**不要用这个吞掉失败**，只用于"可选值"场景。
  T? get valueOrNull => switch (this) {
        Ok<T>(:final value) => value,
        Err<T>() => null,
      };

  PluginFailure? get failureOrNull => switch (this) {
        Ok<T>() => null,
        Err<T>(:final failure) => failure,
      };

  /// 穷举取值：失败时按 [onError] 折算成默认值（**强制你处理失败分支**）。
  R fold<R>(R Function(T value) onOk, R Function(PluginFailure failure) onError) => switch (this) {
        Ok<T>(:final value) => onOk(value),
        Err<T>(:final failure) => onError(failure),
      };

  Outcome<R> map<R>(R Function(T value) transform) => switch (this) {
        Ok<T>(:final value) => Ok<R>(transform(value)),
        Err<T>(:final failure) => Err<R>(failure),
      };

  /// 串行组合：任一步失败即短路返回该失败（保留第一个失败，绝不"半途而废当成功"）。
  Outcome<R> andThen<R>(Outcome<R> Function(T value) next) => switch (this) {
        Ok<T>(:final value) => next(value),
        Err<T>(:final failure) => Err<R>(failure),
      };

  /// 异步串行组合（插件里最高频的形态：拿到能力 → 调它 → 再折算结果）。
  Future<Outcome<R>> andThenAsync<R>(FutureOr<Outcome<R>> Function(T value) next) async => switch (this) {
        Ok<T>(:final value) => await next(value),
        Err<T>(:final failure) => Err<R>(failure),
      };

  /// 构造失败的简写（内核与注册表里高频，避免每处手写 [PluginFailure]）。
  static Err<T> err<T>({
    required PluginFailureKind code,
    required String message,
    String? hint,
    String? pluginId,
    String? step,
    Object? cause,
  }) =>
      Err<T>(PluginFailure(code: code, message: message, hint: hint, pluginId: pluginId, step: step, cause: cause));

  /// 把 `throw` 风格的旧代码（本仓既有服务大量是抛异常的）包成 `Outcome`。
  /// [mapError] 负责把原生异常翻译成人话；不翻译时兜底成 `runtimeError`。
  static Future<Outcome<T>> guard<T>(
    Future<T> Function() body, {
    PluginFailure Function(Object error, StackTrace st)? mapError,
  }) async {
    try {
      return Ok<T>(await body());
    } catch (e, st) {
      if (mapError != null) return Err<T>(mapError(e, st));
      return Err<T>(PluginFailure(
        code: PluginFailureKind.runtimeError,
        message: '操作没有完成：$e',
        cause: e,
      ));
    }
  }

  static Outcome<T> guardSync<T>(
    T Function() body, {
    PluginFailure Function(Object error)? mapError,
  }) {
    try {
      return Ok<T>(body());
    } catch (e) {
      if (mapError != null) return Err<T>(mapError(e));
      return Err<T>(PluginFailure(code: PluginFailureKind.runtimeError, message: '操作没有完成：$e', cause: e));
    }
  }
}

final class Ok<T> extends Outcome<T> {
  const Ok(this.value);
  final T value;

  @override
  String toString() => 'Ok($value)';
}

final class Err<T> extends Outcome<T> {
  const Err(this.failure);
  Err.of(PluginFailureKind code, String message, {String? hint, String? pluginId, String? step, Object? cause})
      : failure = PluginFailure(code: code, message: message, hint: hint, pluginId: pluginId, step: step, cause: cause);
  final PluginFailure failure;

  @override
  String toString() => 'Err($failure)';
}
