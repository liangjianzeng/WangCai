/// L1 弃用登记（**唯一真相**：面板黄条、CLI 提醒、迁移工具三处共用）。
///
/// 纪律（§4.10）：契约**只加不改**。确需替换字段时，新键与旧键**双读一个弃用期**，
/// 期间对使用旧键的插件显示黄条"使用了已弃用字段 X，将于 vN 停止支持"。
/// 这里只登记 L1（用户可编辑面）；L3/L4 的破坏变更走 `contractVersion` 双实现共存，不进本表。
library;

import 'validate.dart';

final class DeprecatedField {
  const DeprecatedField({
    required this.path,
    required this.since,
    required this.message,
    this.willRemoveIn,
    this.replacement,
  });

  /// JSON 路径，支持 `a.b` 与 `a[*].b` 两种形式。
  final String path;

  /// 从哪个 app 版本开始弃用。
  final String since;

  /// 计划移除的版本（面板文案用）。
  final String? willRemoveIn;

  /// 替代写法（面板直接渲染成"改成这样"）。
  final String? replacement;

  final String message;
}

/// 当前弃用清单。新增条目的门槛：**该字段确实有替代且旧行为已不推荐**。
const List<DeprecatedField> kL1Deprecations = [
  // 示范条目（未来真实弃用时照此填写）：
  // DeprecatedField(
  //   path: 'ttsVoice',
  //   since: '0.4.0',
  //   willRemoveIn: '0.6.0',
  //   replacement: 'params[].name == "voice"',
  //   message: '顶层 ttsVoice 已弃用，请改为声明一个参数',
  // ),
];

/// 扫描 raw manifest，产出弃用提醒（**warning 级**：弃用期内仍可用，不能因弃用而拒绝加载）。
/// [table] 只为**测试与迁移工具**留的口子：默认用 `kL1Deprecations`（唯一真相）。
/// 以前这张表只能整体替换、而它当前是空的，于是整条弃用通道 —— `a[*].b` 的路径匹配、
/// warning 不判坏、面板黄条、`doctor` 的「声明提醒」—— **一次都没被执行过**。
/// 第一条真实弃用登记落地时，踩的就会是这些没人验过的分支。
List<ValidationIssue> deprecationIssues(Map<String, dynamic> raw, {List<DeprecatedField>? table}) {
  final out = <ValidationIssue>[];
  for (final d in (table ?? kL1Deprecations)) {
    if (_pathPresent(raw, d.path)) {
      out.add(ValidationIssue(
        path: d.path,
        code: ValidationIssueCode.deprecation,
        message: '${d.message}（自 ${d.since} 弃用${d.willRemoveIn == null ? '' : '，计划 ${d.willRemoveIn} 移除'}）',
        hint: d.replacement == null ? null : '替代写法：${d.replacement}',
        severity: IssueSeverity.warning,
      ));
    }
  }
  return out;
}

bool _pathPresent(Map<String, dynamic> raw, String path) {
  final parts = path.split('.');
  Object? cur = raw;
  for (var i = 0; i < parts.length; i++) {
    final p = parts[i];
    final isLast = i == parts.length - 1;
    if (p.endsWith('[*]')) {
      final key = p.substring(0, p.length - 3);
      final list = (cur is Map) ? cur[key] : null;
      if (list is! List) return false;
      if (isLast) return list.isNotEmpty;
      final rest = parts.sublist(i + 1).join('.');
      return list.whereType<Map<Object?, Object?>>().any((e) => _pathPresent(Map<String, dynamic>.from(e), rest));
    }
    if (cur is! Map || !cur.containsKey(p)) return false;
    cur = cur[p];
  }
  return true;
}
