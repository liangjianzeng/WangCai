/// 方案档（Profile）—— DSH `profile = bundles[] + patch` 的轻量版。
///
/// 一句话：**「上课模式 / 自习模式 / 什么都不开」= 一个档**。档里装的是
/// 「开哪几个插件 + 每个插件的参数 + 用哪个人格 / 哪个模型」，用户一键切换。
///
/// 两条硬规矩（都写进了测试）：
/// 1. **compose == preview**：面板预览和 runtime 真正加载走**同一个纯函数**，
///    所以"预览说会开三个、实际开了两个"这种漂移在结构上不可能发生
///    （对齐 DSH"so a dump can never drift from what boots"）。
/// 2. **fail-safe**：档文件坏了 / 档名不存在 → 退回"没选档"并留警告，
///    **绝不因为档读不动就把用户的插件全关掉**（那等于用户功能凭空消失）。
library;

import 'dart:convert';

/// 档的来源（宿主负责读盘；内核不碰 `dart:io`）。返回 `档名 → JSON 原文`。
typedef ProfileSource = Map<String, String> Function();

/// 一个方案档。
final class PluginProfile {
  const PluginProfile({
    required this.name,
    this.enabled = const {},
    this.disabled = const {},
    this.config = const {},
    this.personaId,
    this.modelId,
    this.apiModelId,
    this.note,
    this.broken = const [],
  });

  final String name;

  /// 白名单：**非空**时档内只允许这些插件被启用（"上课模式只留听写三件"）。
  final Set<String> enabled;

  /// 黑名单：档内明确关掉谁（与白名单可并存，先白后黑）。
  final Set<String> disabled;

  /// `插件 id → 参数覆盖`（写在档位层，用户显式改过的值仍然更大）。
  final Map<String, Map<String, Object?>> config;

  /// 切档要顺带带上的人格 / 驱动模型（宿主拿去落设置）。
  ///
  /// **null = 档不表态，宿主一律不碰**：档没写人格却把用户人格清空，等于偷偷改设置。
  /// 本地模型与 API 模型是两个独立设置项，混成一个字段会出现"切到 API 档结果本地默认模型被改掉"的串台。
  final String? personaId;
  final String? modelId;
  final String? apiModelId;
  final String? note;

  /// 解析时丢掉的非法字段说明（面板原样显示，别让用户猜）。
  final List<String> broken;

  bool get declaresSet => enabled.isNotEmpty;

  // 不留 `declaresEnvironment`：环境三项各字段自己判 null（"不表态就是 null"是契约），
  // 聚合谓词零调用者，而且将来加第 4 个环境项时改的人不会想到这里 —— 典型的会分叉的第二份说法。

  static String? _nullableString(Object? v) {
    if (v == null) return null;
    final t = '$v'.trim();
    return t.isEmpty ? null : t;
  }

  factory PluginProfile.fromJson(String name, Map<String, Object?> json, {List<String> broken = const []}) {
    final problems = <String>[...broken];
    Set<String> strings(Object? v, String field) {
      if (v == null) return const {};
      if (v is! List) {
        problems.add('$field 不是数组，已忽略');
        return const {};
      }
      return {for (final e in v) '$e'}.where((e) => e.isNotEmpty).toSet();
    }

    final cfg = <String, Map<String, Object?>>{};
    final rawCfg = json['config'];
    if (rawCfg is Map) {
      rawCfg.forEach((k, v) {
        if (v is Map) {
          cfg['$k'] = {for (final e in v.entries) '${e.key}': e.value};
        } else {
          problems.add('config.$k 不是对象，已忽略');
        }
      });
    } else if (rawCfg != null) {
      problems.add('config 不是对象，已忽略');
    }

    return PluginProfile(
      name: name,
      enabled: strings(json['enabled'], 'enabled'),
      disabled: strings(json['disabled'], 'disabled'),
      config: cfg,
      personaId: _nullableString(json['personaId']),
      modelId: _nullableString(json['modelId']),
      apiModelId: _nullableString(json['apiModelId']),
      note: json['note'] == null ? null : '${json['note']}',
      broken: problems,
    );
  }

  Map<String, Object?> toJson() => {
        'enabled': enabled.toList(),
        'disabled': disabled.toList(),
        if (config.isNotEmpty) 'config': {for (final e in config.entries) e.key: e.value},
        if (personaId != null) 'personaId': personaId,
        if (modelId != null) 'modelId': modelId,
        if (apiModelId != null) 'apiModelId': apiModelId,
        if (note != null) 'note': note,
      };
}

/// [ProfileStore.compose] 的结果：runtime 与面板共用的唯一真相。
final class ProfileComposition {
  const ProfileComposition({
    this.profile,
    required this.enabled,
    required this.config,
    this.restrictedByProfile = false,
    this.personaId,
    this.modelId,
    this.apiModelId,
    this.warnings = const [],
  });

  /// 生效的档名（null = 没选档）。
  final String? profile;

  /// 最终启用集。
  final Set<String> enabled;

  /// `插件 id → 档位层参数`。
  final Map<String, Map<String, Object?>> config;

  /// 档是否声明了白名单（面板要说"这几件是档帮你关的"，不是用户关的）。
  final bool restrictedByProfile;

  final String? personaId;
  final String? modelId;
  final String? apiModelId;
  final List<String> warnings;

  /// 没选档 / 没有 ProfileStore 时的样子：一切照持久化开关。
  const ProfileComposition.passthrough(Set<String> persisted)
      : profile = null,
        enabled = persisted,
        config = const {},
        restrictedByProfile = false,
        personaId = null,
        modelId = null,
        apiModelId = null,
        warnings = const [];

  // 不留 `isActiveEnabled(id)`：启用集只有一个问法 —— `ProfileStore.compose()`。
  // 这个口只看档里的白名单，绕过档位层的 disabled 与持久开关，谁用它谁就在造第二真源。
}

/// 方案档账本。
///
/// 读盘失败 / JSON 坏掉 → 该档视作不存在并留警告（fail-safe），**不影响别的档、也不清空开关**。
/// 档名的硬规矩（面板「新建方案档」与任何写档入口**共用这一份判据**）。
///
/// 返回 null = 可以用；否则是人话原因（面板直接当错误提示显示，不再另编一套话术）。
/// 判的是"能不能当文件名 + 扫不扫得到"，不是审美。
String? profileNameProblem(String raw) {
  final name = raw.trim();
  if (name.isEmpty) return '档名不能空着 —— 叫什么决定你在设置里点哪张卡片';
  if (name.length > 40) return '档名太长了（${name.length} 字），起个短一点的，卡片放不下';
  if (name.startsWith('.')) return '档名不能用点开头：那是隐藏文件，档目录扫不到它';
  if (name.toLowerCase().endsWith('.json')) return '档名不用带 .json，系统自己加';
  final bad = RegExp(r'[/\\:*?"<>|]').allMatches(name).map((m) => m[0]!).toSet();
  if (bad.isNotEmpty) return '档名里有不能用来做文件名的字符：${bad.join(' ')}';
  return null;
}

/// 建档的**规范形状**（面板建档用；作者手写也照这个来）。
///
/// 只在这里定格式：面板、CLI、测试都从这里出，避免"面板写出来的档内核读不懂"这种两头各写一遍的病。
/// 键与 [PluginProfile.fromJson] 严格对齐；`null` 的字段整条不写（档没表态 = 宿主一律不碰）。
Map<String, Object?> profileDraftJson({
  required Set<String> enabled,
  Set<String> disabled = const {},
  Map<String, Map<String, Object?>> config = const {},
  String? personaId,
  String? modelId,
  String? apiModelId,
  String? note,
}) {
  String? trimmed(String? v) {
    if (v == null) return null;
    final t = v.trim();
    return t.isEmpty ? null : t;
  }

  final n = trimmed(note);
  return {
    // 排序写出来：同一次选择永远生成同样的文本，作者拿 diff 或手改都友好。
    'enabled': enabled.toList()..sort(),
    if (disabled.isNotEmpty) 'disabled': disabled.toList()..sort(),
    if (config.isNotEmpty) 'config': config,
    if (trimmed(personaId) case final v?) 'personaId': v,
    if (trimmed(modelId) case final v?) 'modelId': v,
    if (trimmed(apiModelId) case final v?) 'apiModelId': v,
    if (n != null) 'note': n,
  };
}

final class ProfileStore {
  ProfileStore({ProfileSource? source}) : _source = source;

  final ProfileSource? _source;

  /// 每次现读（文件可能刚被作者改过），但一次 compose 内只用同一份快照。
  Map<String, PluginProfile> _snapshot() {
    final src = _source;
    if (src == null) return const {};
    Map<String, String> raw;
    try {
      raw = src();
    } catch (_) {
      return const {};
    }
    final out = <String, PluginProfile>{};
    raw.forEach((name, text) {
      try {
        final parsed = _decode(text);
        if (parsed == null) {
          out[name] = PluginProfile(name: name, broken: const ['JSON 读不懂，这个档本轮不生效']);
        } else {
          out[name] = PluginProfile.fromJson(name, parsed);
        }
      } catch (_) {
        out[name] = PluginProfile(name: name, broken: const ['JSON 读不懂，这个档本轮不生效']);
      }
    });
    return out;
  }

  static Map<String, Object?>? _decode(String text) {
    // `dart:convert` 是纯 Dart，架构门 A2 只禁 `dart:io`/`dart:ffi`：内核照样能离线跑测试。
    try {
      final v = jsonDecode(text);
      return v is Map ? {for (final e in v.entries) '${e.key}': e.value} : null;
    } catch (_) {
      return null;
    }
  }

  /// 有哪些档（含坏档，面板要列得出来并标坏）。
  List<String> names() => _snapshot().keys.toList()..sort();

  PluginProfile? profile(String name) {
    final p = _snapshot()[name];
    if (p == null || p.broken.isNotEmpty) return null;
    return p;
  }

  /// 坏档（面板显示"这个档读坏了"，而不是让它凭空消失）。
  List<PluginProfile> brokenProfiles() => _snapshot().values.where((p) => p.broken.isNotEmpty).toList();

  /// **唯一的语义所在**：持久化开关 + 档 → 最终启用集与档位层参数。
  ///
  /// 纯函数：同样的输入永远给同样的输出，且不碰任何状态 —— 所以面板拿它做预览、
  /// runtime 拿它决定加载谁，两者不可能各说一套。
  ProfileComposition compose({
    String? active,
    required Set<String> persistedEnabled,
    Set<String> allIds = const {},
  }) {
    if (active == null || active.isEmpty) return ProfileComposition.passthrough(Set.of(persistedEnabled));
    final p = _snapshot()[active];
    if (p == null) {
      return ProfileComposition(
        profile: active,
        enabled: Set.of(persistedEnabled),
        config: const {},
        warnings: ['找不到方案档「$active」，这次先按你原来的开关走'],
      );
    }
    if (p.broken.isNotEmpty) {
      return ProfileComposition(
        profile: active,
        enabled: Set.of(persistedEnabled),
        config: const {},
        warnings: ['方案档「$active」读不动（${p.broken.first}），这次先按你原来的开关走'],
      );
    }

    var ids = p.declaresSet ? Set.of(p.enabled) : Set.of(persistedEnabled);
    if (!allIds.isEmpty) {
      // 档里写了 app 里根本不存在的 id：不算错（插件可能被删），但要能说清。
      final ghost = ids.difference(allIds);
      if (ghost.isNotEmpty && p.declaresSet) {
        ids = ids.difference(ghost);
      }
    }
    ids.removeAll(p.disabled);

    final warnings = <String>[];
    if (p.declaresSet) {
      final ghosts = (p.enabled.difference(allIds)).toList()..sort();
      if (!allIds.isEmpty && ghosts.isNotEmpty) {
        warnings.add('档里有几个插件本机没有：${ghosts.join('、')}');
      }
    }
    if (p.config.keys.any((id) => !allIds.isEmpty && !allIds.contains(id))) {
      warnings.add('档里有参数写给已经不存在的插件');
    }

    return ProfileComposition(
      profile: active,
      enabled: ids,
      config: {for (final e in p.config.entries) e.key: Map.of(e.value)},
      restrictedByProfile: p.declaresSet,
      personaId: p.personaId,
      modelId: p.modelId,
      apiModelId: p.apiModelId,
      warnings: warnings,
    );
  }
}

/// 切档要落到设置里的那些东西（宿主实现；内核只认这个接口，不 import 任何设置实现）。
///
/// 三个 setter 都收 null：null 的含义是**档没表态**，实现方**必须原样不动**。
abstract interface class ProfileSettingsSink {
  String? get personaId;
  String? get defaultModelId;
  String? get activeApiModelId;

  Future<void> usePersona(String? id);
  Future<void> useDefaultModel(String? id);
  Future<void> useApiModel(String? id);
}

/// 把档里的人格 / 模型落到设置，并回报"哪几项没落上"。
///
/// 三条纪律：
/// 1. **档没表态就一个都不碰**（清空用户人格不是"换档"，是偷改设置）；
/// 2. 落完**回读校验**：设置侧可能因为"人格不存在"等原因拒绝，用户必须知道，
///    否则切完档人格没变、下次出问题谁也说不清是谁改的；
/// 3. 只回报，不抛 —— 切档这件事的成败由插件集决定，环境项没落上是"提醒"级。
Future<List<String>> applyProfileSettings(ProfileSettingsSink sink, ProfileComposition c) async {
  if (c.profile == null) return const [];
  final notes = <String>[];

  if (c.personaId != null) {
    await sink.usePersona(c.personaId);
    if (sink.personaId != c.personaId) {
      notes.add('档里要的人格「${c.personaId}」本机没有，人格保持「${sink.personaId ?? '未设置'}」');
    }
  }
  if (c.modelId != null) {
    await sink.useDefaultModel(c.modelId);
    if (sink.defaultModelId != c.modelId) {
      notes.add('档里要的本机模型「${c.modelId}」没切成（可能没下载）');
    }
  }
  if (c.apiModelId != null) {
    await sink.useApiModel(c.apiModelId);
    if (sink.activeApiModelId != c.apiModelId) {
      notes.add('档里要的 API 模型「${c.apiModelId}」没切成（可能没配）');
    }
  }
  return notes;
}
