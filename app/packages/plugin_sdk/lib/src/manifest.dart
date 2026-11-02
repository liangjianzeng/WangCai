/// 声明面契约（L1）：`plugin.json` 的形状与默认值。
///
/// 设计来源：Cordis `Plugin.Base{name, Config, inject, provide, intercept}` +
/// DSH `package.json` 的 `dsh` 块（`bundle.patch` / `profile.bundles` / `client`）+ `engines`。
/// **L1 是用户可编辑面**：一经发布字段只加不改（弃用走 `deprecations.dart`）。
library;

import 'flow.dart';

/// 当前支持的声明格式版本。加载时若 `manifestVersion` 大于它 → 拒绝加载并提示升级 app。
const int kSupportedManifestVersion = 1;

/// `plugin.json` 允许的最大字节数（平台预算，§4.16）。
const int kMaxManifestBytes = 64 * 1024;

/// `prompt.md` 允许的最大字节数。
const int kMaxPromptBytes = 32 * 1024;

/// 插件来源（决定优先级；照本仓 Skills 的 rank 100/200 文化）。
enum PluginSource {
  /// 编译进 APK 的内置插件（rank 100）。
  builtin,

  /// 用户目录里的声明式插件（rank 200，**同名遮蔽内置**）。
  user,
}

/// 信任分级（§4.14）。级别决定能拿到什么样的 `PluginCtx`。
enum PluginTrust {
  /// 平台自带：全能力 + 可声明槽 + 可覆盖能力。
  trusted,

  /// 用户手写 `plugin.json` + `prompt.md`：**只能使用 flow 动词白名单**，不接触任意 Dart。
  declarative,

  /// 第三方 Dart 源码（远期）：子 Isolate + 白名单动词 + JSON 往返。
  extension,
}

/// 权限（`plugin.json` 的 `permissions`）。**未声明即拒**（强制时点在 P7，契约现在就定死）。
enum PluginPermission {
  camera, // 取景拍照
  photoLibrary, // 相册选图
  network, // 任何联网（含 API 模型调用、Edge TTS）
  pluginStorage, // 自己的分域 KV（默认即给，仍显式列出以便审计）
  speechSynthesis, // 朗读
  llmChat, // 一次性文本补全
  llmVision, // 带图一次性补全
  speechRecognition, // ASR
  webSearch, // 联网搜索
  fileExport, // 导出文件到共享目录
}

PluginPermission? permissionFromWire(String s) {
  for (final p in PluginPermission.values) {
    if (p.wireName == s) return p;
  }
  return null;
}

extension PluginPermissionWire on PluginPermission {
  String get wireName => switch (this) {
        PluginPermission.camera => 'camera',
        PluginPermission.photoLibrary => 'photo_library',
        PluginPermission.network => 'network',
        PluginPermission.pluginStorage => 'storage:plugin',
        PluginPermission.speechSynthesis => 'tts',
        PluginPermission.llmChat => 'llm:chat',
        PluginPermission.llmVision => 'llm:vision',
        PluginPermission.speechRecognition => 'asr',
        PluginPermission.webSearch => 'web_search',
        PluginPermission.fileExport => 'file_export',
      };
}

/// 参数类型（设置页据此自动渲染控件；对应 DSH 的 "schema-derived auto-generated page"）。
enum PluginParamType { number, boolean, text, choice }

/// 一个可编辑参数。[askAtStart] = 运行前向用户确认（听写的"间隔几秒"就是它）。
final class PluginParam {
  const PluginParam({
    required this.name,
    required this.label,
    required this.type,
    this.defaultValue,
    this.min,
    this.max,
    this.step,
    this.options = const [],
    this.description,
    this.askAtStart = false,
    this.volatile = false,
  });

  final String name;
  final String label;
  final PluginParamType type;
  final Object? defaultValue;
  final double? min;
  final double? max;
  final double? step;
  final List<String> options;
  final String? description;
  final bool askAtStart;

  /// 易变值：记下"上次用的间隔"这类，**不算配置变更**（`equalExceptVolatile` 忽略它）。
  ///
  /// 为什么要这个：把易变值算成变更会诱发无谓的插件重载与"配置已改动"提示。
  final bool volatile;

  Map<String, dynamic> toJson() => {
        'name': name,
        'label': label,
        'type': type.name,
        if (defaultValue != null) 'default': defaultValue,
        if (min != null) 'min': min,
        if (max != null) 'max': max,
        if (step != null) 'step': step,
        if (options.isNotEmpty) 'options': options,
        if (description != null) 'description': description,
        if (askAtStart) 'askAtStart': true,
        if (volatile) 'volatile': true,
      };

  static PluginParam fromJson(Map<String, dynamic> j) => PluginParam(
        name: j['name'] as String,
        label: (j['label'] as String?) ?? (j['name'] as String),
        type: PluginParamType.values.firstWhere(
          (t) => t.name == j['type'],
          orElse: () => PluginParamType.text,
        ),
        defaultValue: j['default'],
        min: (j['min'] as num?)?.toDouble(),
        max: (j['max'] as num?)?.toDouble(),
        step: (j['step'] as num?)?.toDouble(),
        options: (j['options'] as List?)?.map((e) => e.toString()).toList() ?? const [],
        description: j['description'] as String?,
        askAtStart: j['askAtStart'] as bool? ?? false,
        volatile: j['volatile'] as bool? ?? false,
      );

  /// 值是否落在契约区间内（校验器与运行时共用这一份判定）。
  bool acceptsValue(Object? v) => switch (type) {
        PluginParamType.number => v is num && (min == null || v >= min!) && (max == null || v <= max!),
        PluginParamType.boolean => v is bool,
        PluginParamType.text => v is String && v.length <= 4000,
        PluginParamType.choice => v is String && options.contains(v),
      };
}

/// 插件声明。不可变；配置改动通过 [copyWithConfig] 产生新的，便于 diff 与"改了什么"审计。
final class PluginManifest {
  const PluginManifest({
    required this.id,
    required this.name,
    required this.description,
    this.manifestVersion = kSupportedManifestVersion,
    this.whenToUse = '',
    this.icon,
    this.source = PluginSource.user,
    this.trust = PluginTrust.declarative,
    this.rank,
    this.enabledByDefault = false,
    this.inject = const [],
    this.permissions = const [],
    this.requiresSdk = 'v1',
    this.enginesApp = '',
    this.params = const [],
    this.config = const {},
    this.profiles = const [],
    this.flow,
    this.promptFile = 'prompt.md',
    this.overridable = false,
  });

  /// 稳定 id：`[a-z][a-z0-9-]{2,63}`；一旦发布不可改（是配置与存储的键）。
  final String id;
  final String name;
  final String description;
  final int manifestVersion;

  /// 给模型看的一句话（注入 `<available_plugins>` 目录，照 Skills 的 whenToUse 文化）。
  final String whenToUse;
  final String? icon;
  final PluginSource source;
  final PluginTrust trust;

  /// 同名覆盖优先级；未给按 source 推（builtin 100 / user 200）。
  final int? rank;
  final bool enabledByDefault;

  /// 依赖的能力 id 列表（照抄 Cordis `inject`："it only loads while all are available"）。
  final List<String> inject;
  final List<PluginPermission> permissions;

  /// 需要的能力契约版本（L3 协商）。
  final String requiresSdk;

  /// 形如 ">=0.3.4"；不满足 → 不加载并在面板指名不满足的那一条。
  final String enginesApp;
  final List<PluginParam> params;
  final Map<String, dynamic> config;

  /// 归属的方案档（空 = 所有档都可用）。
  final List<String> profiles;

  /// 声明式流程（`trust == declarative` 必填，§4.8）。
  final FlowMeta? flow;
  final String promptFile;

  /// 是否允许被同 id 的高 rank 插件遮蔽（内置插件默认允许用户覆盖）。
  final bool overridable;

  int get effectiveRank => rank ?? (source == PluginSource.builtin ? 100 : 200);

  Map<String, dynamic> toJson() => {
        'manifestVersion': manifestVersion,
        'id': id,
        'name': name,
        'description': description,
        if (whenToUse.isNotEmpty) 'whenToUse': whenToUse,
        if (icon != null) 'icon': icon,
        'source': source.name,
        'trust': trust.name,
        if (rank != null) 'rank': rank,
        'enabledByDefault': enabledByDefault,
        if (inject.isNotEmpty) 'inject': inject,
        if (permissions.isNotEmpty) 'permissions': permissions.map((p) => p.wireName).toList(),
        'requiresSdk': requiresSdk,
        if (enginesApp.isNotEmpty) 'engines': {'app': enginesApp},
        if (params.isNotEmpty) 'params': params.map((p) => p.toJson()).toList(),
        if (config.isNotEmpty) 'config': config,
        if (profiles.isNotEmpty) 'profiles': profiles,
        if (flow != null) 'flow': flow!.toJson(),
        'promptFile': promptFile,
        if (overridable) 'overridable': true,
      };

  static PluginManifest fromJson(Map<String, dynamic> j) {
    final src = PluginSource.values.firstWhere((s) => s.name == j['source'], orElse: () => PluginSource.user);
    final trust = PluginTrust.values.firstWhere((t) => t.name == j['trust'], orElse: () => PluginTrust.declarative);
    return PluginManifest(
      manifestVersion: (j['manifestVersion'] as num?)?.toInt() ?? kSupportedManifestVersion,
      id: j['id'] as String,
      name: (j['name'] as String?) ?? (j['id'] as String),
      description: (j['description'] as String?) ?? '',
      whenToUse: (j['whenToUse'] as String?) ?? '',
      icon: j['icon'] as String?,
      source: src,
      trust: trust,
      rank: (j['rank'] as num?)?.toInt(),
      enabledByDefault: j['enabledByDefault'] as bool? ?? false,
      inject: (j['inject'] as List?)?.map((e) => e.toString()).toList() ?? const [],
      permissions: ((j['permissions'] as List?) ?? const [])
          .map((e) => permissionFromWire(e.toString()))
          .whereType<PluginPermission>()
          .toList(),
      requiresSdk: (j['requiresSdk'] as String?) ?? 'v1',
      enginesApp: ((j['engines'] as Map?)?['app'] as String?) ?? '',
      params: ((j['params'] as List?) ?? const [])
          .map((e) => PluginParam.fromJson(Map<String, dynamic>.from(e as Map)))
          .toList(),
      config: Map<String, dynamic>.from((j['config'] as Map?) ?? const {}),
      profiles: (j['profiles'] as List?)?.map((e) => e.toString()).toList() ?? const [],
      flow: j['flow'] == null ? null : FlowMeta.fromJson(Map<String, dynamic>.from(j['flow'] as Map)),
      promptFile: (j['promptFile'] as String?) ?? 'prompt.md',
      overridable: j['overridable'] as bool? ?? false,
    );
  }

  PluginManifest copyWithConfig(Map<String, dynamic> newConfig) => PluginManifest(
        manifestVersion: manifestVersion,
        id: id,
        name: name,
        description: description,
        whenToUse: whenToUse,
        icon: icon,
        source: source,
        trust: trust,
        rank: rank,
        enabledByDefault: enabledByDefault,
        inject: inject,
        permissions: permissions,
        requiresSdk: requiresSdk,
        enginesApp: enginesApp,
        params: params,
        config: newConfig,
        profiles: profiles,
        flow: flow,
        promptFile: promptFile,
        overridable: overridable,
      );

  /// 取参数默认值：`config` 覆盖 `params[].default`（L1 层的"默认值层"；再往上的方案档/会话内层由内核合）。
  Object? effectiveParamValue(PluginParam p) => config.containsKey(p.name) ? config[p.name] : p.defaultValue;
}
