/// 分层工具注册表 —— 参照 DSH `register()` + `restrict()` + ScopedLayers 思想。
///
/// 层级：全局内置 → 按模型 → 用户启用（近层遮蔽远层）。
/// - 全局层：内置工具，默认全模型可见；
/// - 模型层：某模型可见性的 allow/deny；
/// - 用户层：用户设置的 allow/deny（最近层，遮蔽模型层）。
/// 各层过滤取交集：先按模型层过滤全局，再按用户层过滤。
library;

import 'tool_definition.dart';

/// 一层可见性限制（参照 DSH `ToolRestriction`）。
class _Restriction {
  final Set<String>? allow; // 非空时只保留这些工具
  final Set<String>? deny;  // 非空时移除这些工具

  const _Restriction({this.allow, this.deny});
}

/// 分层工具注册表。
class ToolRegistry {
  final Map<String, ToolDefinition> _global = {};
  final Map<String, _Restriction> _modelRestrictions = {};
  _Restriction? _userRestriction;

  /// 动态注册一个工具（重复注册同名工具抛异常，参照 DSH named entries）。
  void register(ToolDefinition tool) {
    if (_global.containsKey(tool.name)) {
      throw ArgumentError('tool "${tool.name}" is already registered');
    }
    _global[tool.name] = tool;
  }

  /// 注销一个工具；不存在时静默忽略（幂等）。
  void unregister(String name) {
    _global.remove(name);
  }

  /// 设置某模型的可见性限制。
  /// [allow] 非空时只保留这些工具；[deny] 非空时移除这些工具。
  /// 传 null 恢复该模型为无限制（跟随全局）。
  void restrictModel(String modelId, {Set<String>? allow, Set<String>? deny}) {
    if (allow == null && deny == null) {
      _modelRestrictions.remove(modelId);
      return;
    }
    _modelRestrictions[modelId] = _Restriction(allow: allow, deny: deny);
  }

  /// 设置用户层可见性限制（最近层）。
  void restrictUser({Set<String>? allow, Set<String>? deny}) {
    if (allow == null && deny == null) {
      _userRestriction = null;
      return;
    }
    _userRestriction = _Restriction(allow: allow, deny: deny);
  }

  /// 某模型可见的工具集（按 全局 → 模型 → 用户 过滤）。
  List<ToolDefinition> visibleFor(String modelId) {
    final names = _global.keys.toList();
    return _applyRestriction(_applyRestriction(names, _modelRestrictions[modelId]),
            _userRestriction)
        .map((name) => _global[name]!)
        .toList();
  }

  /// 按名字查找工具。
  /// [modelId] 提供时同时校验该模型可见性 —— 模型不可见的工具返回 null，
  /// 让 agent 循环对"模型调用了不可见工具"给出"未知工具"错误（参照 DSH UNKNOWN_TOOL）。
  ToolDefinition? lookup(String name, {String? modelId}) {
    final tool = _global[name];
    if (tool == null) return null;
    if (modelId != null && !visibleFor(modelId).contains(tool)) return null;
    return tool;
  }

  /// 全局注册的所有工具（不含分层过滤，供诊断/默认呈现）。
  List<ToolDefinition> get all => _global.values.toList();

  /// 应用一层限制：allow（只保留，空集 = 全部不可见）→ deny（移除）。
  List<String> _applyRestriction(List<String> names, _Restriction? restriction) {
    if (restriction == null) return names;
    var result = names;
    final allow = restriction.allow;
    if (allow != null) {
      result = result.where(allow.contains).toList();
    }
    final deny = restriction.deny;
    if (deny != null && deny.isNotEmpty) {
      result = result.where((n) => !deny.contains(n)).toList();
    }
    return result;
  }
}
