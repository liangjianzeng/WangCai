/// 配置四层合并 + 带 revision 的存储（照 DSH settings 的 `defaults → base → user` + 会话内临时）。
///
/// 两条从 DSH 抄来的纪律：
/// - **易变值不算变更**（`equalExceptVolatile`）：把"上次用的间隔"算成配置改动会诱发无谓重载；
/// - **revision fencing**：设置页保存必须带它读到的 revision，撞车就报冲突而不是默默覆盖
///   （DSH 的 `SETTINGS_CONFLICT`；本仓 `InferenceSettings` 是单一大 blob，更需要它）。
library;

import 'package:plugin_sdk/plugin_sdk.dart';

/// 配置来源层（数值越大越优先）。
enum ConfigLayer { defaults, profile, user, session }

final class ResolvedConfig {
  const ResolvedConfig({required this.values, required this.layers});
  final Map<String, Object?> values;
  final Map<String, ConfigLayer> layers;

  Object? operator [](String key) => values[key];
  ConfigLayer? layerOf(String key) => layers[key];
}

/// 只读合并视图（fiber 每次 apply 拿一份快照；改配置 = 新快照 = epoch 变化 = 重载）。
class ConfigStack {
  ConfigStack({
    required this.manifest,
    Map<String, Object?> profile = const {},
    Map<String, Object?> user = const {},
    Map<String, Object?> session = const {},
  }) : _profile = Map.unmodifiable(profile),
       _user = Map.unmodifiable(user),
       _session = Map.unmodifiable(session);

  final PluginManifest manifest;
  final Map<String, Object?> _profile;
  final Map<String, Object?> _user;
  final Map<String, Object?> _session;

  Object? _defaultOf(String name) {
    for (final p in manifest.params) {
      if (p.name == name) return p.defaultValue;
    }
    return manifest.config[name];
  }

  bool _isVolatile(String name) => manifest.params.any((p) => p.name == name && p.volatile);

  /// 取值：session → user → profile → manifest.config → params 默认。
  ///
  /// 注意判定的是**存在性**而不是相等：`user` 里显式写了 `false` 就是覆盖，
  /// 不能因为"和默认值一样"就当没覆盖（DSH 同款坑）。
  Object? value(String name) {
    if (_session.containsKey(name)) return _session[name];
    if (_user.containsKey(name)) return _user[name];
    if (_profile.containsKey(name)) return _profile[name];
    if (manifest.config.containsKey(name)) return manifest.config[name];
    return _defaultOf(name);
  }

  ConfigLayer layerOf(String name) {
    if (_session.containsKey(name)) return ConfigLayer.session;
    if (_user.containsKey(name)) return ConfigLayer.user;
    if (_profile.containsKey(name)) return ConfigLayer.profile;
    return ConfigLayer.defaults;
  }

  /// 全部参数的生效值（面板显示"当前值 + 来自哪层 + 重置"）。
  ResolvedConfig resolveAll() {
    final names = <String>{
      for (final p in manifest.params) p.name,
      ...manifest.config.keys,
      ..._profile.keys,
      ..._user.keys,
      ..._session.keys,
    };
    return ResolvedConfig(
      values: {for (final n in names) n: value(n)},
      layers: {for (final n in names) n: layerOf(n)},
    );
  }

  /// 除易变值外是否与另一份相同（决定是否真的需要重载插件）。
  bool sameExceptVolatile(ConfigStack other) {
    final names = <String>{
      for (final p in manifest.params) p.name,
      ...manifest.config.keys,
    };
    for (final n in names) {
      if (_isVolatile(n)) continue;
      if (value(n) != other.value(n)) return false;
    }
    return true;
  }

  Map<String, Object?> get sessionOverrides => _session;

  /// 去掉会话层的副本（只留 默认 / 方案档 / 用户 这三层可持久的）。
  ///
  /// 判"用户改了没有"必须用它：会话里临时试过一个值之后，合并值会一直压着，
  /// 拿合并值判就得出"没变化" —— 用户明明保存成功，却被回一句「没有变化」。
  ConfigStack get persistedOnly =>
      ConfigStack(manifest: manifest, profile: _profile, user: _user, session: const {});
}

/// 可变配置存储（每插件一份 user/profile + 全局 revision）。
class ConfigStore {
  final Map<String, Map<String, Object?>> _user = {};
  final Map<String, Map<String, Object?>> _profile = {};
  // 会话层归这里，不归 ctx 自己揣着：以前 `PluginCtx.setSessionOverride` 写进的是
  // 每个 ctx 的私人笔记本，内核与面板用 `stackFor` 看配置时永远看不见 ——
  // 面板指着「插件默认」，实际念给用户听的却是那个临时值（显示与实际不一致）。
  final Map<String, Map<String, Object?>> _session = {};
  final Map<String, int> _revisions = {};
  String? _activeProfile;

  String? get activeProfile => _activeProfile;
  int revisionOf(String pluginId) => _revisions[pluginId] ?? 0;

  Map<String, Object?> userOf(String pluginId) => Map.unmodifiable(_user[pluginId] ?? const {});
  /// 当前生效档给这个插件的参数（与 [userOf] 对称；没选档就是空）。
  /// 写入按 `档名|插件 id` 分键，读也必须按同一个键 —— 早先这里直接读 `_profile[pluginId]`，
  /// 于是"面板看档位层"永远是空的，档改没改参数都看不出来。
  Map<String, Object?> profileOf(String pluginId) => _activeProfile == null
      ? const {}
      : _profileValues(_activeProfile!, pluginId);

  void setActiveProfile(String? profile) => _activeProfile = profile;

  /// 档位层**整体替换**（不是累加）：切档 / 档文件被作者改过之后，
  /// 档里已经删掉的键必须真的消失，否则旧参数会阴魂不散。
  void replaceProfile(String profile, String pluginId, Map<String, Object?> values) {
    _profile['$profile|$pluginId'] = Map.of(values);
  }

  // 这里**不留** `seedProfile()`（累加式写档）：档位层的写入口只许有 `replaceProfile` 一个 ——
  // "整体替换"才是切档/档文件被作者改过后的正确语义，留个累加口就是给旧参数留后路。

  Map<String, Object?> _profileValues(String profile, String pluginId) =>
      Map.unmodifiable(_profile['$profile|$pluginId'] ?? const {});

  /// 会话内临时值（**不落盘**，重启就没）。谁写的、读也按同一个插件 id —— 与 [userOf] 对称。
  Map<String, Object?> sessionOf(String pluginId) => Map.unmodifiable(_session[pluginId] ?? const {});

  /// 写一条会话内临时值；`null` = 撤掉这条，回到用户层/方案档/声明默认。
  void setSessionOverride(String pluginId, String name, Object? value) {
    final next = Map<String, Object?>.of(_session[pluginId] ?? const <String, Object?>{});
    if (value == null) {
      next.remove(name);
    } else {
      next[name] = value;
    }
    if (next.isEmpty) {
      _session.remove(pluginId);
    } else {
      _session[pluginId] = next;
    }
  }

  /// 清掉某插件的全部会话临时值（面板「恢复默认」连着它一起清）。
  void clearSessionOverrides(String pluginId) => _session.remove(pluginId);

  ConfigStack stackFor(PluginManifest manifest, {Map<String, Object?>? session}) => ConfigStack(
        manifest: manifest,
        profile: _activeProfile == null ? const {} : _profileValues(_activeProfile!, manifest.id),
        user: userOf(manifest.id),
        session: session ?? sessionOf(manifest.id),
      );

  /// 「先试试这组值」：只进会话层，**不落盘**。
  ///
  /// 判据与 [patchUser] 一模一样 —— 临时值同样会真的去念给用户听，
  /// 越界一样得拒；"只是试试"不是放松校验的理由（试试 900 秒间隔照样是 15 秒一个词）。
  Outcome<void> trial({required PluginManifest manifest, required Map<String, Object?> patch}) {
    for (final e in patch.entries) {
      final reject = _undeclaredKey(manifest, e.key);
      if (reject != null) return _toVoid(reject, manifest.id);
      final bad = _badValue(manifest, e.key, e.value);
      if (bad != null) return _toVoid(bad, manifest.id);
    }
    for (final e in patch.entries) {
      setSessionOverride(manifest.id, e.key, e.value);
    }
    return const Ok<void>(null);
  }

  Outcome<void> _toVoid(Outcome<ConfigStack> r, String pluginId) {
    final f = r.failureOrNull!;
    return Outcome.err<void>(
      code: f.code,
      message: f.message,
      hint: f.hint,
      pluginId: pluginId,
      step: f.step,
    );
  }

  /// 保存用户改动。**必须**带 `expectedRevision`（设置页读到的那个）；不一致 = 冲突，不覆盖。
  ///
  /// 校验由调用方先跑（`validateManifest`），这里只做 fencing 与类型兜底。
  Outcome<ConfigStack> patchUser({
    required PluginManifest manifest,
    required Map<String, Object?> patch,
    int? expectedRevision,
  }) {
    final current = revisionOf(manifest.id);
    if (expectedRevision != null && expectedRevision != current) {
      return Outcome.err<ConfigStack>(
        code: PluginFailureKind.configInvalid,
        message: '这份设置在你编辑期间被别人改过了',
        hint: '刷新看最新值再改，别覆盖掉别人的改动',
        pluginId: manifest.id,
        step: 'revision',
      );
    }
    for (final entry in patch.entries) {
      final reject = _undeclaredKey(manifest, entry.key);
      if (reject != null) return reject;
      final bad = _badValue(manifest, entry.key, entry.value);
      if (bad != null) return bad;
    }
    _user.putIfAbsent(manifest.id, () => {}).addAll(patch);
    _revisions[manifest.id] = current + 1;
    return Ok<ConfigStack>(stackFor(manifest));
  }

  /// 「这个键到底存不存在」的唯一判据（`patchUser` 与 `patchPath` 共用）。
  ///
  /// 未声明的键一律拒：否则一个 typo 会在 config 里留下**永远读不到的死值** ——
  /// 面板照旧只显示声明过的参数，用户改了没反应，也永远看不见自己写进去的那一行。
  Outcome<ConfigStack>? _undeclaredKey(PluginManifest manifest, String key) {
    final known = {for (final p in manifest.params) p.name};
    if (known.contains(key) || manifest.config.containsKey(key)) return null;
    return Outcome.err<ConfigStack>(
      code: PluginFailureKind.configInvalid,
      message: '参数 "$key" 没在 plugin.json 里声明',
      hint: '先在 params 里声明它，或删掉这一项',
      pluginId: manifest.id,
      step: key,
    );
  }

  /// 「这个值配不配得上这个参数」的唯一判据（两个写入口共用）。
  ///
  /// 为什么在**写入时**挡：`ctx.numberConfig('gapSeconds', 5)` 是**照直读**的，运行时没人再夹逼 ——
  /// 面板输入框里手打一个 `900`，听写就变成 15 秒一个词，用户只会觉得"这插件有毛病"。
  /// `ask_params` 那条问出来的值由 flow 复查（因为问出来的是能力实现的返回值），
  /// 而配置值属于**写入口**，与"未声明的键"是同一类问题：进了 config 就再也抓不到。
  /// 报错而不是悄悄夹逼：悄悄夹逼就是"我明明填了 900，你怎么给我 30"那种说不清的降级。
  Outcome<ConfigStack>? _badValue(PluginManifest manifest, String key, Object? value) {
    if (value == null) return null; // 删除 = 回到上一层，不判
    final param = manifest.params.where((p) => p.name == key).firstOrNull;
    if (param == null) return null; // 只在 manifest.config 里的键：结构由插件自己定，不判
    switch (param.type) {
      case PluginParamType.number:
        final n = value is num
            ? value.toDouble()
            : (value is String ? double.tryParse(value.trim()) : null);
        if (n == null) {
          return _bad(manifest, key, '「${param.label}」是数字参数，收到的 "$value" 不是数字');
        }
        if (param.min != null && n < param.min!) {
          return _bad(manifest, key, '「${param.label}」不能小于 ${param.min!.toStringAsFixed(0)}，你填了 ${n.toStringAsFixed(0)}');
        }
        if (param.max != null && n > param.max!) {
          return _bad(manifest, key, '「${param.label}」不能大于 ${param.max!.toStringAsFixed(0)}，你填了 ${n.toStringAsFixed(0)}');
        }
        return null;
      case PluginParamType.choice:
        if (param.options.isNotEmpty && value is String && !param.options.contains(value)) {
          return _bad(manifest, key,
              '「${param.label}」只能从 ${param.options.join(' / ')} 里选，你填了 "$value"');
        }
        return null;
      case PluginParamType.boolean:
        if (value is! bool && !(value is String && (value == 'true' || value == 'false'))) {
          return _bad(manifest, key, '「${param.label}」是开关，只能填 true 或 false，你填了 "$value"');
        }
        return null;
      case PluginParamType.text:
        return null;
    }
  }

  Outcome<ConfigStack> _bad(PluginManifest manifest, String key, String message) => Outcome.err<ConfigStack>(
        code: PluginFailureKind.configInvalid,
        message: message,
        hint: '改回范围内的值再保存；范围写在 plugin.json 的 params 里（${manifest.id}）',
        pluginId: manifest.id,
        step: key,
      );

  /// 路径式改写（给"隐藏密钥明文"这类操作留的口子：只动一个路径，不整包覆盖）。
  Outcome<ConfigStack> patchPath({
    required PluginManifest manifest,
    required List<String> path,
    required Object? value,
    int? expectedRevision,
  }) {
    if (path.isEmpty) {
      return Outcome.err<ConfigStack>(
        code: PluginFailureKind.configInvalid,
        message: '路径不能为空',
        hint: '至少给一个参数名',
        pluginId: manifest.id,
      );
    }
    // 首段就是参数名，判据与 `patchUser` 同一条 —— 两个口子必须一样严，
    // 否则"绕开检查"只要有第二个入口就必然发生（这条口子以前就能写死值）。
    final reject = _undeclaredKey(manifest, path.first);
    if (reject != null) return reject;
    if (path.length == 1) {
      final bad = _badValue(manifest, path.first, value);
      if (bad != null) return bad;
    }
    final current = revisionOf(manifest.id);
    if (expectedRevision != null && expectedRevision != current) {
      return Outcome.err<ConfigStack>(
        code: PluginFailureKind.configInvalid,
        message: '这份设置在你编辑期间被别人改过了',
        hint: '刷新看最新值再改',
        pluginId: manifest.id,
        step: 'revision',
      );
    }
    final root = _user.putIfAbsent(manifest.id, () => {});
    Map<String, Object?> cursor = root;
    for (var i = 0; i < path.length - 1; i++) {
      final next = cursor[path[i]];
      if (next is! Map) {
        cursor[path[i]] = <String, Object?>{};
      }
      cursor = cursor[path[i]]! as Map<String, Object?>;
    }
    if (value == null) {
      cursor.remove(path.last);
    } else {
      cursor[path.last] = value;
    }
    _revisions[manifest.id] = current + 1;
    return Ok<ConfigStack>(stackFor(manifest));
  }

  /// 恢复默认（用户层清空，profile 与默认值保留）。
  void resetUser(String pluginId) {
    _user.remove(pluginId);
    _revisions[pluginId] = revisionOf(pluginId) + 1;
  }
}
