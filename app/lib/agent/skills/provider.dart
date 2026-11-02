/// SkillProvider（Phase 5）—— 端侧 skill 扫描/注册。
///
/// 两级 rank：内置（rank 100）+ 用户（rank 200）。
/// 模型面：首次 step 注入 `<available_skills>`（name + description + whenToUse），
/// 触发时（invocation 或模型判断）注入完整 body。
library;

import 'dart:io';

import 'package:path_provider/path_provider.dart';

import 'skill.dart';

String _join(String a, String b) {
  final sep = (a.endsWith('/') || a.endsWith('\\')) ? '' : '/';
  return '$a$sep$b';
}

String _basename(String path) {
  var s = path;
  while (s.endsWith('/') || s.endsWith('\\')) {
    s = s.substring(0, s.length - 1);
  }
  final idxSlash = s.lastIndexOf('/');
  final idxBack = s.lastIndexOf('\\');
  final idx = idxSlash > idxBack ? idxSlash : idxBack;
  return idx == -1 ? s : s.substring(idx + 1);
}

/// SkillProvider（端侧简化版）。
final class SkillProvider {
  final List<Skill> _skills;

  /// 目录冻结文本（P1-D prompt-cache）：非空时 [availableSkillsText] 恒
  /// 返回该文本（按会话冻结），技能集变化延迟到会话切换才进目录——
  /// 系统提示逐字节稳定，API prompt cache / 本地 KV 前缀不因增删技能破掉。
  /// load_skill 注册表仍用实时技能集，新增技能照常可拉取。
  String? frozenDirectoryText;

  SkillProvider({List<Skill>? skills})
      : _skills = _dedupeByRank(
            (skills ?? loadBuiltinSkills()).sortedByRank());

  /// 所有 skill（按 rank 降序，rank 大的优先）。
  List<Skill> get skills => _skills;
  int get count => _skills.length;

  /// 按名称查找 skill（不存在返回 null）。
  Skill? byName(String name) {
    for (final s in _skills) {
      if (s.name == name) return s;
    }
    return null;
  }

  /// 检查某 skill 是否存在。
  bool has(String name) => byName(name) != null;

  /// 注册用户 skill（rank 200；同名覆盖内置）。
  void registerUser(Skill skill) {
    _skills.removeWhere((s) => s.name == skill.name);
    _skills.add(skill.withRank(kRankUser));
  }

  /// 删除用户 skill（按名称）。
  bool remove(String name) {
    final idx = _skills.indexWhere((s) => s.name == name && s.rank == kRankUser);
    if (idx == -1) return false;
    _skills.removeAt(idx);
    return true;
  }

  /// 生成 `<available_skills>` 注入文本（首次 step，模型可见）。
  ///
  /// 格式（DSH Part 12.3）：
  /// ```
  /// <available_skills>
  /// name: web-research
  /// description: ...
  /// whenToUse: ...
  /// invocation: tool: web_search
  ///
  /// name: code-review
  /// ...
  /// </available_skills>
  /// ```
  /// [loadSkillAvailable] = load_skill 工具是否已注册。未注册时**不得**在
  /// 提示里教唆模型调用 load_skill——否则本地档模型被指向一个不存在的工具，
  /// 只会产出无效调用（2026-09-30 真机修正；2026-10-01 起两档都注册）。
  /// [saveSkillAvailable] = save_skill 工具是否已注册（模型自主沉淀技能）。
  String availableSkillsText(
      {bool loadSkillAvailable = false, bool saveSkillAvailable = false}) {
    final frozen = frozenDirectoryText;
    if (frozen != null && frozen.isNotEmpty) return frozen;
    if (_skills.isEmpty) return '';
    final sb = StringBuffer();
    sb.writeln('<available_skills>');
    for (final s in _skills) {
      sb.writeln(s.injectionText().trim());
      sb.writeln();
    }
    sb.writeln('</available_skills>');
    // 目录 → 加载/沉淀链路说明（正文此前无任何获取途径）。
    if (loadSkillAvailable) {
      sb.writeln('任务匹配某技能的 whenToUse 时，先调用 load_skill 工具'
          '（name=技能名）获取完整指引，再按指引执行。');
    }
    if (saveSkillAvailable) {
      sb.writeln('用户要求"记住这套做法/存成技能"，或你发现某类任务的处理'
          '方式日后还会重复用到时，调用 save_skill 把它固化为长期技能。');
    }
    return sb.toString();
  }

  /// 生成完整 skill body 注入文本（触发时，模型可见）。
  ///
  /// 格式：
  /// ```
  /// <skill name="web-research">
  /// ...body...
  /// </skill>
  /// ```
  String skillText(String name) {
    final s = byName(name);
    if (s == null) return '';
    return '<skill name="${s.name}">\n${s.body}\n</skill>';
  }
}

extension ListSkills on List<Skill> {
  List<Skill> sortedByRank() {
    final copy = List.of(this);
    copy.sort((a, b) => b.rank.compareTo(a.rank));
    return copy;
  }
}

/// 同名去重（列表已按 rank 降序：保留第一个 = 最高 rank）。
List<Skill> _dedupeByRank(List<Skill> skills) {
  final seen = <String>{};
  final out = <Skill>[];
  for (final s in skills) {
    if (seen.add(s.name)) out.add(s);
  }
  return out;
}

/// 扫描用户 skill 目录（`ApplicationSupport/skills/<name>/SKILL.md`，rank 200）。
///
/// 目录不存在或单个 skill 文件损坏均不影响其余；失败返回空列表。
Future<List<Skill>> loadUserSkills({String? skillsDirOverride}) async {
  try {
    final dirPath = skillsDirOverride ??
        _join((await getApplicationSupportDirectory()).path, 'skills');
    final dir = Directory(dirPath);
    if (!dir.existsSync()) return const [];
    final out = <Skill>[];
    for (final entity in dir.listSync()) {
      if (entity is! Directory) continue;
      final file = File(_join(entity.path, 'SKILL.md'));
      if (!file.existsSync()) continue;
      try {
        final content = file.readAsStringSync();
        final name = _basename(entity.path);
        out.add(Skill.parse(content, name: name).withRank(kRankUser));
      } catch (_) {
        // 坏文件跳过。
      }
    }
    return out;
  } catch (_) {
    return const [];
  }
}

// ---------------------------------------------------------------
// 用户技能落盘（设置页技能管理 UI 用）：直接写标准 SKILL.md，
// 与 loadUserSkills 扫描链路共用同一目录，无需额外存储。
// ---------------------------------------------------------------

/// 用户技能根目录路径（`ApplicationSupport/skills`）。
Future<String> userSkillsDirPath() async =>
    _join((await getApplicationSupportDirectory()).path, 'skills');

/// 技能名 → 安全目录名：压缩空白为 `-`，剔除路径/非法字符。
/// 剔除后为空（如纯符号名）返回 null，由调用方报错。
String? sanitizeSkillDirName(String raw) {
  var s = raw.trim();
  s = s.replaceAll(RegExp(r'\s+'), '-');
  s = s.replaceAll(RegExp(r'[\\/:*?"<>|.]'), '');
  while (s.startsWith('-')) {
    s = s.substring(1);
  }
  while (s.endsWith('-')) {
    s = s.substring(0, s.length - 1);
  }
  return s.isEmpty ? null : s;
}

/// 生成 SKILL.md 文本。格式与 [Skill.parse] 兼容：
/// meta 行（description/whenToUse/invocation）在前，`---` 之后是正文。
String buildSkillMarkdown({
  required String description,
  required String whenToUse,
  String? invocation,
  required String body,
}) {
  final sb = StringBuffer();
  sb.writeln('description: $description');
  sb.writeln('whenToUse: $whenToUse');
  if (invocation != null && invocation.trim().isNotEmpty) {
    sb.writeln('invocation: ${invocation.trim()}');
  }
  sb.writeln('---');
  sb.write(body.trim());
  return sb.toString();
}

/// 写入/更新用户技能（目录名 = [name]）。
///
/// [previousName] 非空且不同于 [name] 时视为改名：先把旧目录整个搬过来
/// （保留用户手放的其它文件），再重写 SKILL.md。
/// 返回技能的实际目录名（经 sanitize，可能与传入不同）。
Future<String> writeUserSkill({
  required String name,
  required String description,
  required String whenToUse,
  String? invocation,
  required String body,
  String? previousName,
  String? skillsDirOverride,
}) async {
  final dirName = sanitizeSkillDirName(name);
  if (dirName == null) {
    throw ArgumentError('技能名无效（剔除非法字符后为空）');
  }
  final root = skillsDirOverride ??
      _join((await getApplicationSupportDirectory()).path, 'skills');
  final skillDir = Directory(_join(root, dirName));
  skillDir.createSync(recursive: true);
  if (previousName != null) {
    final prevDirName = sanitizeSkillDirName(previousName);
    if (prevDirName != null && prevDirName != dirName) {
      final prevDir = Directory(_join(root, prevDirName));
      if (prevDir.existsSync()) {
        // 目录已存在时先删（改名目标同名覆盖）。
        if (skillDir.existsSync()) {
          skillDir.deleteSync(recursive: true);
        }
        prevDir.renameSync(skillDir.path);
      }
    }
  }
  final markdown = buildSkillMarkdown(
    description: description.trim(),
    whenToUse: whenToUse.trim(),
    invocation: invocation,
    body: body,
  );
  await File(_join(skillDir.path, 'SKILL.md')).writeAsString(markdown);
  return dirName;
}

/// 删除用户技能目录（整个目录递归删，含 SKILL.md 与用户附加文件）。
/// 返回是否发生了删除（目录不存在返回 false）。
Future<bool> deleteUserSkill(String name, {String? skillsDirOverride}) async {
  final dirName = sanitizeSkillDirName(name);
  if (dirName == null) return false;
  final root = skillsDirOverride ??
      _join((await getApplicationSupportDirectory()).path, 'skills');
  final dir = Directory(_join(root, dirName));
  if (!dir.existsSync()) return false;
  dir.deleteSync(recursive: true);
  return true;
}
