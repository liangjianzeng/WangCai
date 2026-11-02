/// 加载器：把"来源"（内置注册表 + 用户目录里的 `plugin.json`）解析成可运行的插件描述符。
///
/// 四条从 DSH 抄来的纪律：
/// - **坏文件不许拖垮整棵树**：某个 `plugin.json` 写坏了只拒它自己并给出问题清单，其余照常加载；
///   全崩时**沿用上一次好的树**（用户改崩一个插件不该让 app 少一排功能）；
/// - **compose == preview**：boot 与面板预览共用 [parseDeclaration] 这一个纯函数，永不漂移；
/// - **rank 遮蔽**：用户目录同名插件（rank 200）遮蔽内置（rank 100）；内置可 `overridable: false` 挡住；
/// - **门控 ≠ 拒绝**：能力不齐是 `gated`（面板可见、说清缺什么），配置非法才是 `rejected`。
library;

import 'dart:convert';

import 'package:plugin_sdk/plugin_sdk.dart';

import 'capability_registry.dart';

/// 一个来源交出的一条记录（内置给 [manifest]，用户目录给 [json]/[prompt]）。
typedef SourceEntry = ({
  String location,
  String? json,
  String? prompt,
  PluginManifest? manifest,
  AppPlugin Function()? factory,
});

/// 插件来源（内置注册表 / 用户目录各实现一个）。**读文件由宿主做**，内核保持纯 Dart 可离线测。
abstract interface class PluginSourceReader {
  PluginSource get source;
  List<SourceEntry> read();
}

/// 内置插件来源（= DSH `host-plugin-inventory` 的角色）。
class BuiltinSourceReader implements PluginSourceReader {
  BuiltinSourceReader([Map<String, ({PluginManifest manifest, AppPlugin Function() factory})>? entries])
      : _entries = Map.of(entries ?? const {});

  final Map<String, ({PluginManifest manifest, AppPlugin Function() factory})> _entries;

  void register(PluginManifest manifest, AppPlugin Function() factory) => _entries[manifest.id] = (manifest: manifest, factory: factory);
  void unregister(String id) => _entries.remove(id);
  bool contains(String id) => _entries.containsKey(id);

  @override
  PluginSource get source => PluginSource.builtin;

  @override
  List<SourceEntry> read() => [
        for (final e in _entries.entries)
          (location: 'builtin:${e.key}', json: null, prompt: null, manifest: e.value.manifest, factory: e.value.factory),
      ];
}

/// 用户目录来源：宿主把"目录里有什么文件"喂进来（内核不碰 `dart:io`，因此可离线测）。
class DeclarationDirSourceReader implements PluginSourceReader {
  DeclarationDirSourceReader(this._provider);

  /// 目录快照提供者：目录名 → `plugin.json` 文本 + 可选 `prompt.md`。
  final Map<String, ({String json, String? prompt})> Function() _provider;

  @override
  PluginSource get source => PluginSource.user;

  @override
  List<SourceEntry> read() {
    final dir = _provider();
    return [
      for (final e in dir.entries)
        (location: '${e.key}/plugin.json', json: e.value.json, prompt: e.value.prompt, manifest: null, factory: null),
    ];
  }
}

/// 一个插件的声明（可能带问题清单）。
final class PluginDescriptor {
  PluginDescriptor({
    required this.manifest,
    required this.location,
    required this.source,
    this.factory,
    this.issues = const [],
    this.rawJson,
    this.promptText,
  });

  final PluginManifest manifest;

  /// 来源位置（内置 = `builtin:<id>`，用户 = `<目录>/plugin.json`）；面板"从哪来的"直接显示。
  final String location;
  final PluginSource source;

  /// 实现体工厂。声明式插件由 flow runner 提供（P5）。
  final AppPlugin Function()? factory;

  /// 原文：面板详情页现场显示，不缓存第二份真相。
  final String? rawJson;
  final String? promptText;

  final List<ValidationIssue> issues;

  bool get isDeclarative => manifest.trust == PluginTrust.declarative;
  bool get hasImplementation => factory != null;

  /// 给声明式插件补一个实现体（flow runner 上线后由 loader 注入）。
  PluginDescriptor withFactory(AppPlugin Function() factory) => PluginDescriptor(
        manifest: manifest,
        location: location,
        source: source,
        factory: factory,
        issues: issues,
        rawJson: rawJson,
        promptText: promptText,
      );
}

/// 加载终态（闭集）。
enum PluginLoadStatus { active, gated, rejected, disabled }

final class LoadedPlugin {
  LoadedPlugin({
    required this.descriptor,
    required this.status,
    this.gatedOn = const [],
    this.gatedHint,
    this.disabledReason,
  });

  final PluginDescriptor descriptor;
  final PluginLoadStatus status;

  /// 缺哪些能力（面板逐条列出并给"去设置"出路）。
  final List<String> gatedOn;

  /// 门控的**人话版本**（面板直接显示这句）：环境类门控（app 版本太旧）没有"缺哪个能力"可列，
  /// 只有一句能照着做的出路。为 null 时面板按 `缺：gatedOn` 渲染。
  final String? gatedHint;
  final String? disabledReason;

  String get id => descriptor.manifest.id;
}

/// 声明解析（**boot 与面板预览共用这一个纯函数** —— compose == preview）。
({PluginDescriptor? descriptor, List<ValidationIssue> issues}) parseDeclaration({
  required String location,
  required PluginSource source,
  String? json,
  String? prompt,
  PluginManifest? manifest,
  AppPlugin Function()? factory,
  Set<String> knownCapabilityIds = const {},
  String appVersion = '0.0.0',
  Set<String> knownProfiles = const {},
}) {
  if (manifest != null) {
    return (
      descriptor: PluginDescriptor(manifest: manifest, location: location, source: source, factory: factory),
      issues: const [],
    );
  }
  if (json == null || json.trim().isEmpty) {
    return (
      descriptor: null,
      issues: const [
        ValidationIssue(path: '(file)', code: ValidationIssueCode.missingField, message: '这个目录里既没有 plugin.json 也不是内置插件'),
      ],
    );
  }
  final report = validateManifestText(json, knownCapabilityIds: knownCapabilityIds);
  if (!report.ok) {
    return (descriptor: null, issues: report.errors);
  }
  final parsed = PluginManifest.fromJson(jsonDecode(json) as Map<String, dynamic>);
  final extra = <ValidationIssue>[];

  // `prompt.md` 也必须在扫描时过校验：**这条只能在装包之后才发现**（作者机器上的 CLI 管不到用户手放的文件），
  // 而它整段进模型上下文 —— 一个 300KB 的 prompt.md 能把整轮对话挤没，用户只会觉得"模型变笨了"。
  // 超预算是 error（这个插件不许跑），写法问题（比如空文件）是 warning（还能跑，进"声明提醒"）。
  // 占位符也在这里判：CLI 管不到用户手放进目录的插件，装包时是最后一道机检。
  final promptReport = prompt == null
      ? null
      : validatePrompt(
          prompt,
          pluginId: parsed.id,
          // 代码级插件不查：它的提示词变量由 Dart 自己填，静态看不见（与 `unusedParam` 同一个豁免理由）。
          providedPlaceholders: parsed.flow == null ? null : providedPromptPlaceholders(parsed),
        );
  if (promptReport != null && !promptReport.ok) {
    return (descriptor: null, issues: promptReport.errors);
  }

  final constraint = _parseConstraint(parsed.enginesApp);
  if (parsed.enginesApp.isNotEmpty) {
    if (constraint == null) {
      extra.add(ValidationIssue(
        path: 'engines.app',
        code: ValidationIssueCode.badFormat,
        message: 'engines.app "${parsed.enginesApp}" 看不懂，本次忽略它',
        hint: '写成 ">=0.3.4" 这种形式',
        severity: IssueSeverity.warning,
      ));
    } else if (!_satisfied(constraint, appVersion)) {
      extra.add(ValidationIssue(
        path: 'engines.app',
        code: ValidationIssueCode.unsupportedVersion,
        message: '这个插件需要 app ${parsed.enginesApp}，本机是 $appVersion',
        hint: '升级 app 后再启用它',
        // **是环境没到位，不是作者写错**：记成 warning（描述符留着），扫描时落成 `gated`，
        // 面板才能说「升级 app 后再启用」而不是把作者的声明判成有问题（reject 的口气是「你写错了」）。
        severity: IssueSeverity.warning,
      ));
    }
  }
  for (final p in parsed.profiles) {
    if (knownProfiles.isNotEmpty && !knownProfiles.contains(p)) {
      extra.add(ValidationIssue(
        path: 'profiles',
        code: ValidationIssueCode.unknownField,
        message: '方案档 "$p" 不存在，这个插件在哪个档里都不会出现',
        hint: '核对「插件方案」里的名字',
        severity: IssueSeverity.warning,
      ));
    }
  }
  return (
    descriptor: PluginDescriptor(
      manifest: parsed,
      location: location,
      source: source,
      factory: factory,
      rawJson: json,
      promptText: prompt,
      issues: [...report.issues, ...extra, ...?promptReport?.issues],
    ),
    issues: [...report.issues, ...extra, ...?promptReport?.issues],
  );
}

final class _Constraint {
  const _Constraint(this.inclusive, this.version);
  final bool inclusive;
  final (int, int, int) version;
}

_Constraint? _parseConstraint(String raw) {
  final m = RegExp(r'^(>=|>)?\s*(\d+)\.(\d+)\.(\d+)$').firstMatch(raw.trim());
  if (m == null) return null;
  return _Constraint(m.group(1) != '>', (int.parse(m.group(2)!), int.parse(m.group(3)!), int.parse(m.group(4)!)));
}

(int, int, int)? _parseVersion(String raw) {
  final m = RegExp(r'^(\d+)\.(\d+)\.(\d+)').firstMatch(raw.trim());
  if (m == null) return null;
  return (int.parse(m.group(1)!), int.parse(m.group(2)!), int.parse(m.group(3)!));
}

bool _satisfied(_Constraint c, String appVersion) {
  final v = _parseVersion(appVersion);
  if (v == null) return true; // 读不懂本机版本就不拦（宁可放行也别把用户挡在外面）
  final cmp = (v.$1 - c.version.$1, v.$2 - c.version.$2, v.$3 - c.version.$3);
  final greater = cmp.$1 > 0 || (cmp.$1 == 0 && (cmp.$2 > 0 || (cmp.$2 == 0 && cmp.$3 > 0)));
  final equal = cmp.$1 == 0 && cmp.$2 == 0 && cmp.$3 == 0;
  return c.inclusive ? (greater || equal) : greater;
}

/// 扫描 + 遮蔽 + 门控。
class PluginLoader {
  PluginLoader({
    required this.capabilities,
    required this.builtin,
    this.userSources = const [],
    this.appVersion = '0.0.0',
    Set<String>? knownProfiles,
    this.knownCapabilityIds,
    this.declarativeFactory,
  }) : knownProfiles = knownProfiles ?? const {};

  final CapabilityRegistry capabilities;
  final BuiltinSourceReader builtin;
  final List<PluginSourceReader> userSources;
  final String appVersion;
  /// 已知方案档名（app 侧每次扫描前从 `ProfileStore` 刷新）：用来抓"插件声明了一个不存在的档"。
  /// 可变量：boot 之后新增/删除档文件，下一次 `reload()` 就该跟上。
  Set<String> knownProfiles;

  /// 声明式插件的实现体工厂（P5 = flow runner）。不给就照旧停在 `gated`，**绝不假装能跑**。
  final AppPlugin Function()? Function(PluginDescriptor descriptor)? declarativeFactory;

  /// 一般留空（用契约全集 [kKnownCapabilityIds]）；只有测试才会显式传。
  final Set<String>? knownCapabilityIds;

  final Set<String> _enabledIds = {};
  List<LoadedPlugin> _lastGood = const [];
  // 不留 `lastGood` 公开读取口：面板与 CLI 只问 `usedLastGood` 那一个旗标（有测试钉着它变成人话提醒）。
  // 再开一份「上次好清单」的读法 = 第二真源，将来一边过滤一边没过滤必分叉。

  /// **每个来源上一次读到的好清单**：某个来源（内置注册表 / 用户目录）临时读崩时先沿用它的旧清单，
  /// 而不是让整排功能凭空消失（对齐 DSH 的"坏文件保上次好的树"，粒度做到来源级）。
  final Map<PluginSource, List<PluginDescriptor>> _lastGoodBySource = {};

  /// 启用集（由宿主持久化；内核只认这份集合）。
  void setEnabledIds(Set<String> ids) {
    _enabledIds
      ..clear()
      ..addAll(ids);
  }

  /// 一次完整扫描。**不抛异常**：单个来源读崩只影响它自己。
  Outcome<LoadResult> scan() {
    final rows = <PluginDescriptor>[];
    final broken = <String, List<ValidationIssue>>{};
    // 校验用**契约全集**（抓拼写错误），门控用**本机实现集**（capability.isAvailable）。
    // 拿"本机装了哪几个"去校验，会把"等离线 TTS 上线"的正常插件当拼错拒掉。
    final known = knownCapabilityIds ?? kKnownCapabilityIds;
    // 只要本轮任何一处沿用了上次结果，就如实告诉调用方（面板要显示"没读到最新清单"的黄条）。
    var usedFallback = false;

    for (final reader in [builtin, ...userSources]) {
      final fromThisSource = <PluginDescriptor>[];
      List<SourceEntry> raw;
      try {
        raw = reader.read();
      } catch (e) {
        final kept = _lastGoodBySource[reader.source];
        broken['${reader.source.name}:<读取>'] = [
          ValidationIssue(
            path: '(source)',
            code: ValidationIssueCode.notJson,
            message: kept == null
                ? '这个插件来源读不了：$e'
                : '这个插件来源读不了：$e（先沿用上一次读到的 ${kept.length} 个插件）',
            hint: '修好它或先把它移走',
          ),
        ];
        if (kept != null) {
          rows.addAll(kept); // 来源级兜底：读崩不等于没有
          usedFallback = true;
        }
        continue;
      }
      for (final r in raw) {
        final parsed = parseDeclaration(
          location: r.location,
          source: reader.source,
          json: r.json,
          prompt: r.prompt,
          manifest: r.manifest,
          factory: r.factory,
          knownCapabilityIds: known,
          appVersion: appVersion,
          knownProfiles: knownProfiles,
        );
        if (parsed.descriptor != null) {
          rows.add(parsed.descriptor!);
          fromThisSource.add(parsed.descriptor!);
        } else {
          broken[r.location] = parsed.issues;
        }
      }
      _lastGoodBySource[reader.source] = List.unmodifiable(fromThisSource);
    }

    // —— 同 id 遮蔽（rank 大者胜；内置 overridable:false 可挡）——
    final byId = <String, PluginDescriptor>{};
    final shadowed = <String, String>{};
    for (final d in rows) {
      final id = d.manifest.id;
      final cur = byId[id];
      if (cur == null) {
        byId[id] = d;
        continue;
      }
      final challenger = d.manifest.effectiveRank >= cur.manifest.effectiveRank ? d : cur;
      final incumbent = identical(challenger, d) ? cur : d;
      if (!incumbent.manifest.overridable && incumbent.source == PluginSource.builtin && challenger.source == PluginSource.user) {
        broken[d.location] = [
          ValidationIssue(
            path: '(root)',
            code: ValidationIssueCode.unknownField,
            message: '内置插件 $id 不允许被覆盖，用户版本被忽略',
            hint: '想定制就换一个新的 id',
            severity: IssueSeverity.warning,
          ),
        ];
        continue;
      }
      byId[id] = challenger;
      shadowed[id] = '${challenger.location} 遮蔽了 ${incumbent.location}';
    }

    // —— 门控 ——
    final loaded = <LoadedPlugin>[];
    for (var d in byId.values) {
      if (d.issues.any((i) => i.isError)) {
        loaded.add(LoadedPlugin(descriptor: d, status: PluginLoadStatus.rejected));
        // 被拒的插件也要进 broken：面板列表与"为什么跑不起来"必须同屏可见。
        broken.putIfAbsent(d.location, () => d.issues.where((i) => i.isError).toList(growable: false));
        continue;
      }
      if (!_enabledIds.contains(d.manifest.id)) {
        loaded.add(LoadedPlugin(
          descriptor: d,
          status: PluginLoadStatus.disabled,
          // 中性措辞：启用集只存"开着的"，**分不出"你关过它"和"它默认没开"**。
          // 说"已被你停用"会让作者以为有人动过设置，白查一轮。
          // 而声明了 `enabledByDefault` 的更要说清：它在 app 里第一次被扫到会自动打开，
          // 只有"开过又被手动关"才会一直停在这儿（判据在宿主的 `plugin.seen` 账本里）。
          disabledReason: d.manifest.enabledByDefault
              ? '没在启用集里；它声明了 enabledByDefault，app 第一次扫到会自动打开（若一直停在这儿，说明被手动关过）'
              : '没在启用集里（新插件默认没开；或在面板里被关过）',
        ));
        continue;
      }
      final envGap = d.issues
          .where((i) => i.path == 'engines.app' && i.code == ValidationIssueCode.unsupportedVersion)
          .firstOrNull;
      if (envGap != null) {
        loaded.add(LoadedPlugin(
          descriptor: d,
          status: PluginLoadStatus.gated,
          gatedOn: const ['engines.app'],
          gatedHint: '${envGap.message}（${envGap.hint ?? '升级 app 后再启用'}）',
        ));
        continue;
      }
      final missing = d.manifest.inject.where((c) => !capabilities.isAvailable(c)).toList();
      if (missing.isNotEmpty) {
        loaded.add(LoadedPlugin(descriptor: d, status: PluginLoadStatus.gated, gatedOn: missing));
        continue;
      }
      if (d.manifest.trust == PluginTrust.extension && d.source == PluginSource.builtin) {
        // `extension` 的含义是"第三方 Dart 源码，跑在进程外"。内置代码本来就跑在我们自己进程里，
        // 挂这个等级只会骗过审计（写着"已隔离"其实没隔离）—— 判配置不符，让它改回 trusted。
        loaded.add(LoadedPlugin(
          descriptor: d,
          status: PluginLoadStatus.rejected,
          gatedOn: const [],
          disabledReason: 'extension 级只用于用户目录里的第三方代码；内置插件请用 trusted',
        ));
        continue;
      }
      if (!d.hasImplementation) {
        // 声明式插件的实现体由 flow runner 注入；引擎没接线就停在 gated —— **绝不"假装能跑"**。
        final made = d.isDeclarative ? declarativeFactory?.call(d) : null;
        if (made == null) {
          if (d.manifest.trust == PluginTrust.extension) {
            // 第三方 Dart 源码级：**进程外隔离还没实现**（§11 预研）。这一级必须停在待功能，
            // 而且不许蹭 `flow.runner` 那句提示 —— 它等的不是 flow 引擎，
            // 是 isolate broker；说错原因会让人去接 flow，然后依然跑不起来还查不出为什么。
            loaded.add(LoadedPlugin(
              descriptor: d,
              status: PluginLoadStatus.gated,
              gatedOn: const ['extension.broker'],
              gatedHint: '第三方 Dart 插件（extension 级）还没实现进程外隔离，现在启用等于让它的代码直接跑在 app 里；'
                  '这个能力做完前请改用 declarative（只写 plugin.json + prompt.md）或内置插件',
            ));
            continue;
          }
          // **等的是什么，要说准**：声明式插件等的是 flow 引擎；
          // 而用户目录里的 dart/trusted 插件等的是"app 能从磁盘加载 Dart 代码"这条路 ——
          // 那是 extension 级预研里的事（§11），今天根本没有。给它挂 flow.runner 的标签，
          // 作者就会去接 flow 引擎，接完依然跑不起来，还查不出为什么。
          if (!d.isDeclarative) {
            loaded.add(LoadedPlugin(
              descriptor: d,
              status: PluginLoadStatus.gated,
              gatedOn: const ['plugin.code.loader'],
              gatedHint: '用户目录里的代码级插件（trusted/dart）需要 app 能加载磁盘上的 Dart 代码，'
                  '这条路还没实现（见 extension 级预研）。现在请把它做成内置插件，'
                  '或改用 declarative（只写 plugin.json + prompt.md）',
            ));
            continue;
          }
          loaded.add(LoadedPlugin(
            descriptor: d,
            status: PluginLoadStatus.gated,
            gatedOn: const ['flow.runner'],
            disabledReason: '声明式插件要等 flow 引擎上线',
          ));
          continue;
        }
        d = d.withFactory(made);
      }
      loaded.add(LoadedPlugin(descriptor: d, status: PluginLoadStatus.active));
    }

    loaded.sort((a, b) {
      final r = b.descriptor.manifest.effectiveRank.compareTo(a.descriptor.manifest.effectiveRank);
      if (r != 0) return r;
      return a.id.compareTo(b.id);
    });

    if (loaded.isEmpty && _lastGood.isNotEmpty) {
      return Ok<LoadResult>(LoadResult(plugins: _lastGood, broken: broken, shadowed: shadowed, usedLastGood: true));
    }
    _lastGood = loaded;
    return Ok<LoadResult>(LoadResult(plugins: loaded, broken: broken, shadowed: shadowed, usedLastGood: usedFallback));
  }
}

final class LoadResult {
  LoadResult({required this.plugins, required this.broken, required this.shadowed, required this.usedLastGood});

  final List<LoadedPlugin> plugins;

  /// 位置 → 问题清单（面板"这些插件没起来，因为…"）。
  final Map<String, List<ValidationIssue>> broken;

  /// id → "谁遮蔽了谁"（覆盖关系必须对用户透明）。
  final Map<String, String> shadowed;

  /// 本次清单没有完全读到最新状态，部分或全部沿用了上一次的结果（面板必须显示黄条）。
  final bool usedLastGood;

  List<LoadedPlugin> byStatus(PluginLoadStatus s) => plugins.where((p) => p.status == s).toList(growable: false);

  LoadedPlugin? byId(String id) {
    for (final p in plugins) {
      if (p.id == id) return p;
    }
    return null;
  }
}
