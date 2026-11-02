/// `plugin.json` / `prompt.md` 的**唯一**校验实现。
///
/// 铁律（§4.15）：boot 加载、设置页保存、`tool/plugins.dart validate` **必须调同一份代码** ——
/// 对齐 DSH "the same `applyEntryPatches` serves boot and `--dump-config`, so a dump can never drift
/// from what boots"。任何一处自己再写一遍校验，都算平台缺陷。
library;

import 'dart:convert';

import 'deprecations.dart';
import 'flow.dart';
import 'manifest.dart';
import 'slot.dart' show isValidSlotId;

enum IssueSeverity { error, warning }

/// 校验问题码（闭集：面板与 CLI 按它出文案，`message` 只是兜底）。
enum ValidationIssueCode {
  tooLarge,
  notJson,
  missingField,
  badType,
  badFormat,
  unsupportedVersion,
  unknownPermission,
  unknownStepOp,
  unknownCapability,
  duplicateParam,
  paramOutOfRange,
  defaultValueRejected,
  missingImpliedPermission,
  flowRequired,
  flowEmpty,
  unknownPhase,
  deprecation,
  unknownField,
  /// `ask_params` 那一步实际一个问题都不会问（键写错 / 什么都没写）—— 静默降级，必须当场拦。
  askParamsWrongKey,
  askParamsEmpty,
  /// `ask_params` 的 `names` 里引用了没在 `(root).params` 定义过的参数。
  unknownParamName,
  /// `ask_params` 要问 `boolean` / `text` 参数 —— 原语问不出来（只用配置值），静默跳过。
  askParamNotAskable,
  /// 声明式插件声明了参数，但流程里没有任何地方用到它（面板上摆了个改了没反应的开关）。
  unusedParam,
  /// `prompt.md` 里引用了没有任何一步提供的占位符（会原样留在提示词里送给模型）。
  unknownPlaceholder,
  /// 步骤 `params` 里有该原语根本不读的键（拼错 / 记错），会被静默忽略。
  unknownOpParam,
}

final class ValidationIssue {
  const ValidationIssue({
    required this.path,
    required this.code,
    required this.message,
    this.hint,
    this.severity = IssueSeverity.error,
  });

  /// 指向 JSON 里的位置，例如 `params[2].min`。
  final String path;
  final ValidationIssueCode code;
  final String message;
  final String? hint;
  final IssueSeverity severity;

  bool get isError => severity == IssueSeverity.error;

  @override
  String toString() => '${isError ? '错误' : '提醒'} $path: $message${hint == null ? '' : '（$hint）'}';
}

/// 一次校验的聚合结果（对齐 cordis `ValidationError` 聚合 issues 的做法：一次报全，不是遇到第一个就停）。
final class ValidationReport {
  const ValidationReport(this.id, this.issues);
  const ValidationReport.ok(this.id) : issues = const [];

  final String id;
  final List<ValidationIssue> issues;

  bool get ok => issues.every((i) => !i.isError);
  List<ValidationIssue> get errors => issues.where((i) => i.isError).toList(growable: false);
  List<ValidationIssue> get warnings => issues.where((i) => !i.isError).toList(growable: false);

  /// 给面板/CLI 的多行文本。
  String format() {
    if (issues.isEmpty) return '插件 $id 校验通过';
    final b = StringBuffer()..writeln('插件 $id：${errors.length} 个错误，${warnings.length} 个提醒');
    for (final i in issues) {
      b.writeln('  ${i.isError ? '✗' : '!'} [${i.code.name}] ${i.toString()}');
    }
    return b.toString().trimRight();
  }

  ValidationReport merge(ValidationReport other) => ValidationReport(id, [...issues, ...other.issues]);
}

final RegExp _idPattern = RegExp(r'^[a-z][a-z0-9-]{2,63}$');
final RegExp _capabilityIdPattern = RegExp(r'^[a-z][a-z0-9-]*(\.[a-z][a-z0-9-]*)+$');
final RegExp _paramNamePattern = RegExp(r'^[a-z][a-zA-Z0-9]{0,40}$');
final RegExp _enginesPattern = RegExp(r'^(>=|>)?(\d+)\.(\d+)\.(\d+)$');

const Set<String> _knownTopLevelFields = {
  'manifestVersion', 'id', 'name', 'description', 'whenToUse', 'icon', 'source', 'trust', 'rank',
  'enabledByDefault', 'inject', 'permissions', 'requiresSdk', 'engines', 'params', 'config',
  'profiles', 'flow', 'promptFile', 'overridable', 'ownsSlots',
};

/// 校验原始 JSON 文本（含体积预算与 JSON 合法性）。
ValidationReport validateManifestText(String raw, {Set<String> knownCapabilityIds = const {}}) {
  if (utf8.encode(raw).length > kMaxManifestBytes) {
    return ValidationReport('?', [
      ValidationIssue(
        path: '(file)',
        code: ValidationIssueCode.tooLarge,
        message: 'plugin.json 超过 ${kMaxManifestBytes ~/ 1024}KB',
        hint: '把长文本移到 prompt.md，参数只留必要的',
      ),
    ]);
  }
  Object? decoded;
  try {
    decoded = jsonDecode(raw);
  } catch (e) {
    return ValidationReport('?', [
      ValidationIssue(path: '(file)', code: ValidationIssueCode.notJson, message: '不是合法 JSON：$e', hint: '检查逗号与引号'),
    ]);
  }
  if (decoded is! Map) {
    return const ValidationReport('?', [
      ValidationIssue(path: '(root)', code: ValidationIssueCode.badType, message: '最外层必须是对象'),
    ]);
  }
  return validateManifest(
    Map<String, dynamic>.from(decoded),
    knownCapabilityIds: knownCapabilityIds,
  );
}

/// 校验已解析的 manifest。[knownCapabilityIds] 为空时跳过"能力是否存在"检查（离线自检场景）。
ValidationReport validateManifest(
  Map<String, dynamic> raw, {
  Set<String> knownCapabilityIds = const {},
  bool checkPrompt = true,
  // 只为测试与迁移工具留的口子（默认用 `kL1Deprecations` 这份唯一真相）。
  // 没这个口子时，登记表是空的 → "弃用只提醒不判坏"这条承诺**整条通道一次都没被执行过**。
  List<DeprecatedField>? deprecations,
}) {
  final issues = <ValidationIssue>[];
  void err(String path, ValidationIssueCode code, String message, [String? hint]) =>
      issues.add(ValidationIssue(path: path, code: code, message: message, hint: hint));
  void warn(String path, ValidationIssueCode code, String message, [String? hint]) => issues.add(ValidationIssue(
        path: path,
        code: code,
        message: message,
        hint: hint,
        severity: IssueSeverity.warning,
      ));

  final id = raw['id'];
  final pluginId = id is String ? id : '?';

  // —— 前向兼容：未知字段只提醒（契约只加不改，旧版 app 遇到新字段要能带着警告继续跑）——
  for (final k in raw.keys) {
    if (!_knownTopLevelFields.contains(k)) {
      warn('(root).$k', ValidationIssueCode.unknownField, '本版本不认识字段 "$k"，将忽略它',
          '升级 app 后才会生效；不是写错了就不用管');
    }
  }

  // —— 必填与格式 ——
  if (id is! String || id.isEmpty) {
    err('(root).id', ValidationIssueCode.missingField, '缺少 id');
  } else if (!_idPattern.hasMatch(id)) {
    err('(root).id', ValidationIssueCode.badFormat, 'id "$id" 不合法',
        '用小写字母开头，2–64 位，只允许小写字母/数字/连字符，例如 english-dictation');
  }
  final name = raw['name'];
  if (name is! String || name.trim().isEmpty) {
    err('(root).name', ValidationIssueCode.missingField, '缺少 name（列表里显示的名字）', '例如「英语听写」');
  }
  final desc = raw['description'];
  if (desc is! String || desc.trim().isEmpty) {
    warn('(root).description', ValidationIssueCode.missingField, '没有 description，面板会很难解释这个插件是干什么的');
  }

  final mv = raw['manifestVersion'];
  if (mv != null && mv is! num) {
    err('(root).manifestVersion', ValidationIssueCode.badType, 'manifestVersion 必须是整数');
  } else if (mv is num && mv.toInt() > kSupportedManifestVersion) {
    err('(root).manifestVersion', ValidationIssueCode.unsupportedVersion,
        '这份 plugin.json 要求声明格式 v${mv.toInt()}，本机 app 只支持到 v$kSupportedManifestVersion',
        '升级 app，或把 manifestVersion 改回 $kSupportedManifestVersion');
  }

  final engines = raw['engines'];
  if (engines is Map && engines['app'] is String) {
    final e = engines['app'] as String;
    if (!_enginesPattern.hasMatch(e.trim())) {
      warn('(root).engines.app', ValidationIssueCode.badFormat, 'engines.app "$e" 无法解析', '写成 ">=0.3.4" 这种形式');
    }
  }

  // —— inject：能力依赖 ——
  final inject = raw['inject'];
  if (inject != null && inject is! List) {
    err('(root).inject', ValidationIssueCode.badType, 'inject 必须是字符串数组');
  } else if (inject is List) {
    for (var i = 0; i < inject.length; i++) {
      final c = inject[i];
      if (c is! String) {
        err('inject[$i]', ValidationIssueCode.badType, 'inject[$i] 不是字符串');
        continue;
      }
      if (!_capabilityIdPattern.hasMatch(c)) {
        err('inject[$i]', ValidationIssueCode.badFormat, '能力 id "$c" 不合法', '形如 app.speak / llm.vision');
      } else if (knownCapabilityIds.isNotEmpty && !knownCapabilityIds.contains(c)) {
        err('inject[$i]', ValidationIssueCode.unknownCapability, '本机没有提供能力 "$c"，该插件永远不会启动',
            '确认拼写，或在「插件」面板里查看本机能力清单');
      }
    }
  }

  // —— permissions ——
  final permissions = raw['permissions'];
  final declaredPermissions = <String>{};
  if (permissions != null && permissions is! List) {
    err('(root).permissions', ValidationIssueCode.badType, 'permissions 必须是字符串数组');
  } else if (permissions is List) {
    for (var i = 0; i < permissions.length; i++) {
      final p = permissions[i];
      if (p is! String) {
        err('permissions[$i]', ValidationIssueCode.badType, 'permissions[$i] 不是字符串');
        continue;
      }
      if (permissionFromWire(p) == null) {
        err('permissions[$i]', ValidationIssueCode.unknownPermission, '未知权限 "$p"',
            '可用值：${PluginPermission.values.map((e) => e.wireName).join(', ')}');
      } else {
        declaredPermissions.add(p);
      }
    }
  }

  // —— params ——
  final params = raw['params'];
  final paramMap = <String, PluginParam>{};
  if (params != null && params is! List) {
    err('(root).params', ValidationIssueCode.badType, 'params 必须是数组');
  } else if (params is List) {
    for (var i = 0; i < params.length; i++) {
      final path = 'params[$i]';
      if (params[i] is! Map<Object?, Object?>) {
        err(path, ValidationIssueCode.badType, '第 $i 个参数必须是对象');
        continue;
      }
      final j = Map<String, dynamic>.from(params[i] as Map<Object?, Object?>);
      final n = j['name'];
      if (n is! String || !_paramNamePattern.hasMatch(n)) {
        err('$path.name', ValidationIssueCode.badFormat, '参数名 "$n" 不合法', '用 lowerCamelCase 字母数字');
        continue;
      }
      if (paramMap.containsKey(n)) {
        err('$path.name', ValidationIssueCode.duplicateParam, '参数名 "$n" 重复');
        continue;
      }
      PluginParam p;
      try {
        p = PluginParam.fromJson(j);
      } catch (e) {
        err(path, ValidationIssueCode.badType, '参数 "$n" 解析失败：$e');
        continue;
      }
      paramMap[n] = p;
      if (p.type == PluginParamType.choice && p.options.isEmpty) {
        err('$path.options', ValidationIssueCode.missingField, 'choice 参数 "$n" 必须有候选项');
      }
      if (p.type == PluginParamType.number && p.min != null && p.max != null && p.min! > p.max!) {
        err('$path.min', ValidationIssueCode.paramOutOfRange, '参数 "$n" 的 min 大于 max');
      }
      if (j.containsKey('default') && !p.acceptsValue(j['default'])) {
        err('$path.default', ValidationIssueCode.defaultValueRejected,
            '参数 "$n" 的默认值 ${j['default']} 不合法（类型或区间不符）');
      }
      if (p.type == PluginParamType.number && j['default'] is num && p.min != null && p.max != null) {
        final d = (j['default'] as num).toDouble();
        if (d < p.min! || d > p.max!) {
          err('$path.default', ValidationIssueCode.paramOutOfRange, '参数 "$n" 默认值 $d 超出 [${p.min}, ${p.max}]');
        }
      }
    }
  }

  // —— config：只能覆盖已声明的参数 ——
  final config = raw['config'];
  if (config != null && config is! Map) {
    err('(root).config', ValidationIssueCode.badType, 'config 必须是对象');
  } else if (config is Map) {
    config.forEach((k, v) {
      final key = k.toString();
      final p = paramMap[key];
      if (p == null) {
        warn('config.$key', ValidationIssueCode.unknownField, 'config 里的 "$key" 没有对应参数，将被忽略',
            '要么在 params 里声明它，要么删掉');
      } else if (!p.acceptsValue(v)) {
        err('config.$key', ValidationIssueCode.paramOutOfRange, 'config 里 "$key" 的值 $v 不合契约',
            '类型要匹配 ${p.type.name}${p.type == PluginParamType.choice ? '，且必须在候选项里' : ''}');
      }
    });
  }

  // —— flow ——
  final trust = (raw['trust'] as String?) ?? PluginTrust.declarative.name;
  final flow = raw['flow'];
  if (trust == PluginTrust.declarative.name && flow == null) {
    err('(root).flow', ValidationIssueCode.flowRequired, '声明式插件必须提供 flow（它的全部能力面就是这些步骤）',
        '不知道怎么写？用 tool/plugin_scaffold.dart --template flow 生成骨架');
  }
  if (flow != null) {
    if (flow is! Map) {
      err('(root).flow', ValidationIssueCode.badType, 'flow 必须是对象');
    } else {
      final fm = Map<String, dynamic>.from(flow);
      final steps = fm['steps'];
      if (steps is! List || steps.isEmpty) {
        err('(root).flow.steps', ValidationIssueCode.flowEmpty, 'flow.steps 不能为空');
      } else {
        final phaseIds = ((fm['phases'] as List?) ?? const [])
            .whereType<Map<Object?, Object?>>()
            .map((e) => e['id'].toString())
            .toSet();
        final stepIds = <String>{};
        // `ask_params` 要问的东西来自两处：步骤的 `params.names`，或参数自己标了 `askAtStart`。
        // 提前算好，下面逐步判"这一步到底会不会真的问出点什么"。
        final declaredParamList = raw['params'] is List ? raw['params'] as List : const <Object?>[];
        final declaredParamNames = {
          for (final e in declaredParamList)
            if (e is Map && e['name'] is String) e['name'] as String
        };
        final declaredParamTypes = <String, String>{
          for (final e in declaredParamList)
            if (e is Map && e['name'] is String && e['type'] is String)
              e['name'] as String: e['type'] as String,
        };
        // 只问得出 number 与 choice：`boolean` 弹"是/否"、`text` 要输长文本，原语对这两种是 `break`
        // （用配置值），所以**标了问 / 列了问都不过是摆个空步骤**。
        bool askable(String name) {
          final t = declaredParamTypes[name];
          return t != null && t != PluginParamType.boolean.name && t != PluginParamType.text.name;
        }

        final askAtStartNames = [
          for (final e in declaredParamList)
            if (e is Map && e['askAtStart'] == true && e['name'] is String) e['name'] as String
        ];
        for (var k = 0; k < declaredParamList.length; k++) {
          final e = declaredParamList[k];
          if (e is! Map || e['askAtStart'] != true || e['name'] is! String) continue;
          final n = e['name'] as String;
          if (askable(n) || !declaredParamTypes.containsKey(n)) continue;
          warn('(root).params[$k]', ValidationIssueCode.askParamNotAskable,
              '"$n" 标了 askAtStart，但它是 ${e['type']} 参数 —— 开场问不出来（原语只用配置值），标了等于没标',
              'askAtStart 只对 number 与 choice 有效；要用户改就去设置页改');
        }
        // 判"这一步到底会不会问出点什么"只数**问得出来的**那些。
        final askAtStartAskable = askAtStartNames.where(askable).toList();
        // `askAtStart` 只有流程里真有个 `ask_params` 步骤才会被问到（引擎只在原语里回落到它）。
        if (askAtStartAskable.isNotEmpty &&
            !steps.any((e) => e is Map && '${e['op']}' == FlowStepOp.askParams.wireName)) {
          warn(
            '(root).flow.steps',
            ValidationIssueCode.askParamsEmpty,
            '${askAtStartAskable.length} 个参数标了 askAtStart，但流程里没有 ask_params 步骤 —— 一个都不会问',
            '在想问的位置（一般在 review 之后、朗读之前）插一步 {"op": "ask_params"}',
          );
        }
        final usedParamNames = <String>{};
        for (var i = 0; i < steps.length; i++) {
          final path = 'flow.steps[$i]';
          if (steps[i] is! Map<Object?, Object?>) {
            err(path, ValidationIssueCode.badType, '第 $i 步必须是对象');
            continue;
          }
          final sj = Map<String, dynamic>.from(steps[i] as Map<Object?, Object?>);
          final sid = sj['id'];
          if (sid is! String || sid.isEmpty) {
            err('$path.id', ValidationIssueCode.missingField, '第 $i 步缺少 id');
          } else if (!stepIds.add(sid)) {
            err('$path.id', ValidationIssueCode.duplicateParam, '步骤 id "$sid" 重复');
          }
          final opName = sj['op'];
          if (opName is! String) {
            err('$path.op', ValidationIssueCode.missingField, '第 $i 步缺少 op');
            continue;
          }
          final op = flowStepOpFromWire(opName);
          if (op == null) {
            err('$path.op', ValidationIssueCode.unknownStepOp, '未知步骤 "$opName"',
                '可用：${FlowStepOp.values.map((e) => e.wireName).join(', ')}');
            continue;
          }
          // 隐式被读到的参数 —— 与 `flow_runner` 的隐式 config 读取**一一对应**，
          // 改那边必须同时改这里，否则"写得对的声明式插件"会被误报（那条有测试钉着）：
          //   `speak_sequence` → `voice`、`gapParam ?? 'gapSeconds'`（flow_runner.dart 的 speak 步）
          //   `llm_extract`    → `readChinese`（extract 步的 withNote 兜底）
          //   `ask_params`     → `names` 里那几个（在下面的分支里加）
          switch (op) {
            case FlowStepOp.speakSequence:
              usedParamNames.add('voice');
              final sp = sj['params'];
              usedParamNames.add(sp is Map && sp['gapParam'] is String ? sp['gapParam'] as String : 'gapSeconds');
            case FlowStepOp.llmExtract:
              usedParamNames.add('readChinese');
            default:
              break;
          }
          final phase = sj['phase'];
          if (phase is String && phaseIds.isNotEmpty && !phaseIds.contains(phase)) {
            warn('$path.phase', ValidationIssueCode.unknownPhase, '步骤 "$sid" 引用了未声明的阶段 "$phase"');
          }
          if (op == FlowStepOp.askParams) {
            // **静默降级的一类病**：`ask_params` 只读 `params.names`。作者写成 `params.params`
            // （或压根没写），运行时一个问题都不问，`{{config.gapSeconds}}` 退回默认值 ——
            // 听写就变成不停顿的连珠炮，而插件"跑成功了"。这种 bug 用户只会说"念太快"，
            // 永远查不到声明里，所以必须在 validate 就拦住，并且话要说中后果。
            final stepParams = sj['params'] is Map ? Map<Object?, Object?>.from(sj['params'] as Map) : null;
            final given = stepParams?[('names')];
            final askedList = given is List ? given.whereType<String>().toList() : const <String>[];
            // （"被问 = 被使用"在下面逐个名字判定：问不出来的那种不算用过。）
            final typoKey = stepParams == null
                ? null
                : stepParams.keys.cast<Object?>().firstWhere(
                      (k) => k == 'params' || k == 'name' || k == 'param' || k == 'questions',
                      orElse: () => null,
                    );
            if (askedList.isEmpty && typoKey != null) {
              err('$path.params', ValidationIssueCode.askParamsWrongKey,
                  '第 $i 步 ask_params 用错了键 "$typoKey"：这一步只认 params.names —— 写错的后果是**一个问题都不问**，'
                  '间隔之类直接拿默认值（听写会变连珠炮）',
                  '改成 "params": {"names": ["gapSeconds"]}');
            } else if (askedList.isEmpty && askAtStartAskable.isEmpty) {
              warn('$path.params', ValidationIssueCode.askParamsEmpty,
                  '第 $i 步 ask_params 什么都不会问：没写 params.names，也没有任何参数标 askAtStart',
                  '要问就写 "params": {"names": [...]}；不问就把这一步删掉，别留空步骤让人以为会问');
            }
            var askableCount = 0;
            for (final n in askedList) {
              final t = declaredParamTypes[n];
              if (declaredParamTypes.containsKey(n) && !askable(n)) {
                // 原语对 boolean/text 是 `break`（弹窗问"是/否"体验太差，交给设置页）——
                // 作者把它写进 names，就是**摆一个什么都不问的提问步骤**。
                warn('$path.params.names', ValidationIssueCode.askParamNotAskable,
                    '第 $i 步 ask_params 要问 "$n"，但它是 $t 参数 —— 这一步问不出来（原语只用配置值），静默跳过',
                    '要用户改就去设置页改；ask_params 只问得出 number 与 choice');
                continue;
              }
              askableCount += 1;
              // **被问 = 被使用**：问到的值会进 `{{count}}` 这类占位符（见 flow_runner 的三层替换）。
              usedParamNames.add(n);
              if (!declaredParamNames.contains(n)) {
                err('$path.params.names', ValidationIssueCode.unknownParamName,
                    '要问的参数 "$n" 没在 (root).params 里定义', '在 params 里补上它，或从 names 里去掉');
              }
            }
            if (askedList.isNotEmpty && askableCount == 0) {
              warn('$path.params', ValidationIssueCode.askParamsEmpty,
                  '第 $i 步 ask_params 列了 ${askedList.length} 个参数，却一个都问不出来（全是 boolean/text）',
                  '把这一步删掉，或只留 number/choice 参数');
            }
          }
          final knownKeys = op.knownParamKeys;
          final stepParamMap = sj['params'];
          if (knownKeys != null && stepParamMap is Map) {
            for (final k in stepParamMap.keys.whereType<String>()) {
              if (knownKeys.contains(k)) continue;
              warn('$path.params.$k', ValidationIssueCode.unknownOpParam,
                  '"$opName" 不读参数 "$k" —— 写了等于没写：运行时静默忽略，作者却以为它生效了',
                  '这个原语只读：${knownKeys.join(', ')}；要的效果换这些键名来表达');
            }
          }
          final usesImages = steps.any((e) =>
                  e is Map && '${e['op']}' == 'capture') ||
              sj['params'] is Map && (sj['params'] as Map)['useImages'] == true;
          for (final need in op.impliedPermissionsIn(hasImages: usesImages)) {
            if (!declaredPermissions.contains(need)) {
              err('$path.op', ValidationIssueCode.missingImpliedPermission,
                  '第 $i 步 "$opName" 需要权限 "$need"，但 permissions 里没声明',
                  '在 permissions 里加上 "$need"');
            }
          }
        }
        if (trust == PluginTrust.declarative.name) {
          // **声明式插件没有 Dart 代码**，参数被用到的唯一途径就是步骤里的 `{{config.x}}`
          // 或 `ask_params` 的 `names`。声明了却没人引用 = 面板上摆一个"改了什么都没发生"的开关，
          // 用户会以为它有效 —— 比压根没有这个开关更糟。代码级插件不查（它在 Dart 里读 config，看不见）。
          void collectConfigRefs(Object? node) {
            if (node is String) {
              for (final m in RegExp(r'\{\{\s*config\.([A-Za-z0-9_]+)').allMatches(node)) {
                usedParamNames.add(m.group(1)!);
              }
            } else if (node is Map) {
              for (final v in node.values) {
                collectConfigRefs(v);
              }
            } else if (node is List) {
              for (final v in node) {
                collectConfigRefs(v);
              }
            }
          }

          for (final st in steps) {
            collectConfigRefs(st);
          }
          for (var i = 0; i < declaredParamList.length; i++) {
            final e = declaredParamList[i];
            if (e is! Map) continue;
            final name = e['name'];
            if (name is! String || usedParamNames.contains(name)) continue;
            // `volatile`（"记下上次用的间隔"那类）豁免：面板的参数编辑器本来就**不显示**它
            // （`plugins_screen` 里 `where((p) => !p.volatile)`），所以它不是"摆着没人用的开关"。
            if (e['volatile'] == true) continue;
            warn('(root).params[$i]', ValidationIssueCode.unusedParam,
                '参数 "$name" 声明了但流程里没人用它（既没有 {{config.$name}}，也不在 ask_params 的 names 里）',
                '要么在步骤里引用它，要么删掉 —— 面板上摆个改了没反应的开关，比没有更糟');
          }
        }
      }
    }
  }

  // —— L1 弃用字段 ——
  for (final i in deprecationIssues(raw, table: deprecations)) {
    issues.add(i);
  }

  // —— 槽 id 只在插件自己声明子槽时校验（放在这里保证只有一份实现）——
  final ownedSlots = raw['ownsSlots'];
  if (ownedSlots is List) {
    for (var i = 0; i < ownedSlots.length; i++) {
      final s = ownedSlots[i];
      if (s is String && !isValidSlotId(s)) {
        err('ownsSlots[$i]', ValidationIssueCode.badFormat, '槽 id "$s" 不合法', '形如 dictation.wordAction');
      }
    }
  }

  return ValidationReport(pluginId, issues);
}

/// `prompt.md` 的轻量校验：只拦"明显写坏了"，不做内容判断（内容是用户的自由）。
ValidationReport validatePrompt(
  String text, {
  required String pluginId,
  Set<String>? providedPlaceholders,
}) {
  final issues = <ValidationIssue>[];
  if (utf8.encode(text).length > kMaxPromptBytes) {
    issues.add(ValidationIssue(
      path: 'prompt.md',
      code: ValidationIssueCode.tooLarge,
      message: 'prompt.md 超过 ${kMaxPromptBytes ~/ 1024}KB，会挤掉模型上下文',
      hint: '把示例精简到 2–3 个，规则用短句',
    ));
  }
  // 占位符必须有人提供。**运行时替换不上是不报错的** —— `{{grade}}` 会原样留在提示词里送给模型，
  // 抽取质量悄悄变差（模型照抄 `{{grade}}`、或自己编一个），作者只看得见"结果有点怪"。
  // 判据与 `flow_runner._renderPrompt` 一一对应：只有 `{{userInstruction}}`、**该 `llm_extract`
  // 步骤自己的 `params`**、以及**走到它之前** `ask_params` 问出来的值会进提示词。
  if (providedPlaceholders != null) {
    final missing = <String>{};
    for (final m in RegExp(r'\{\{\s*([A-Za-z0-9_]+)\s*\}\}').allMatches(text)) {
      final name = m.group(1)!;
      if (providedPlaceholders.contains(name) || name == 'userInstruction') continue;
      missing.add(name);
    }
    if (missing.isNotEmpty) {
      issues.add(ValidationIssue(
        path: 'prompt.md',
        code: ValidationIssueCode.unknownPlaceholder,
        message: '提示词里的占位符没人提供：${missing.join('、')} —— 它会原样留在提示词里送给模型，'
            '抽取质量悄悄变差，而且全程没有任何报错',
        hint: '在 llm_extract 步骤的 params 里给它值，或让 ask_params 在它**之前**问出来；'
            '现在给得出的是：${(providedPlaceholders.toList()..sort()).join('、')}',
        severity: IssueSeverity.warning,
      ));
    }
  }
  if (text.trim().isEmpty) {
    issues.add(ValidationIssue(
      path: 'prompt.md',
      code: ValidationIssueCode.missingField,
      message: 'prompt.md 是空的，抽取没有指令可依',
      hint: '至少写清：输出格式、顺序保真、拿不准就不给（禁止编造）',
      severity: IssueSeverity.warning,
    ));
  }
  return ValidationReport(pluginId, issues);
}


/// `prompt.md` 里**真会被替换掉**的占位符集合（与 `flow_runner._renderPrompt` 的三层来源一一对应）。
///
/// 三层：`{{userInstruction}}` ＋ 该 `llm_extract` 步骤自己的 `params`（`promptFile`/`system` 不算）
/// ＋ **走到它之前** `ask_params` 问出来的值（问不出来的 `boolean`/`text` 不算 —— 原语对它们是 `break`）。
///
/// 顺序是语义的一部分：把 `ask_params` 排在 `llm_extract` **后面**，问出来的值就进不了提示词，
/// 而运行时一声不吭 —— 所以这里按"该步之前"算，validate 才能把这种排布抓出来。
Set<String> providedPromptPlaceholders(PluginManifest manifest) {
  final out = <String>{'userInstruction'};
  final flow = manifest.flow;
  if (flow == null) return out;
  final byName = {for (final p in manifest.params) p.name: p};
  for (var i = 0; i < flow.steps.length; i++) {
    final step = flow.steps[i];
    if (step.op != FlowStepOp.llmExtract) continue;
    for (var k = 0; k < i; k++) {
      final prev = flow.steps[k];
      if (prev.op != FlowStepOp.askParams) continue;
      final given = prev.params['names'];
      final asked = given is List
          ? given.whereType<String>().toList()
          : manifest.params.where((x) => x.askAtStart).map((x) => x.name).toList();
      for (final n in asked) {
        final p = byName[n];
        if (p == null) continue;
        if (p.type == PluginParamType.boolean || p.type == PluginParamType.text) continue;
        out.add(n);
      }
    }
    for (final k in step.params.keys) {
      if (k == 'promptFile' || k == 'system') continue;
      out.add(k);
    }
  }
  return out;
}
