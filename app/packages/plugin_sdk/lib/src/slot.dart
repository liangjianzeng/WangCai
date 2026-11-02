/// 槽契约（L4）：宿主（或任何插件）**声明**槽，其他人**填**槽。
///
/// 设计来源：`dsh-client-ui-slots`（`SlotKind = 'single'|'list'|'keyed'|'chain'`、
/// `SlotScope = 'root'|'session-maybe'|'session'`、`register(...): () => void`、
/// "entries sharing one cell coexist at distinct priorities… the cell's **lowest live entry renders**；
/// 同格同 priority 的第二次注册 **throws naming the occupant**"）+ `reportEntryError(..., {abdicate:true})`。
///
/// 本文件**只建模账本（ledger）**，不含任何 Flutter 类型：`payload` 是泛型，app 侧塞 widget，
/// 契约测试塞哨兵值。这样契约能脱离 Flutter 跑（`dart test`），也是 §4.16"SDK 不泄漏 Flutter 类型"的落法。
library;

import 'dart:async';

import 'hook.dart';
import 'outcome.dart';

/// 槽的基数语义（逐字对齐 DSH）。
enum SlotKind {
  /// 单占用；同格多次注册按 `priority` 遮蔽，同 priority 冲突**报错**。
  single,

  /// 有序列表；`order` 升序（小者靠前，默认 0），同 `id` 视为同格。
  list,

  /// 按键派发（如消息节点、按工具名派发的工具卡）。同 key 再注册 = **替换**。
  keyed,

  /// 选择器路由的接管链；`select` 必须是**纯函数**。
  chain,
}

/// 槽的数据作用域（决定能拿到什么 owner props）。
enum SlotScope { root, sessionMaybe, session }

/// 槽声明（由 owner 提供）。
final class SlotDef {
  const SlotDef({
    required this.id,
    required this.kind,
    required this.scope,
    required this.ownerPluginId,
    required this.description,
    this.maxEntries,
  });

  /// 命名规范：`<owner>.<区域>.<位置>[.<细分>]`，段全小写 `a-z0-9`。
  final String id;
  final SlotKind kind;
  final SlotScope scope;

  /// owner 的插件 id；宿主内置槽用 `app`。
  final String ownerPluginId;

  /// 填这个槽要保证什么（渲染预算/可否返回空/崩溃让位）——**评审必读**。
  final String description;

  /// 可选：最多几个条目（例如播控条只允许 1 个）。
  final int? maxEntries;

  // 「槽 id 的第一段是归属者」这条判据由内核与 conformance 各自实现，这里不留 `namespace` 读取口：
  // 它零调用者，留着就是同一件事的第二份写法（哪天判据改了，改的人看不到这里）。
}

/// 一次贡献（填槽）。
final class SlotContribution<P> {
  const SlotContribution({
    required this.slotId,
    required this.pluginId,
    required this.id,
    required this.label,
    required this.payload,
    this.key,
    this.order = 0,
    this.priority = 0,
    this.select,
  });

  final String slotId;
  final String pluginId;

  /// 条目 id：list 槽是"格子"键，single/chain 是条目名。**同插件内唯一**。
  final String id;

  /// keyed 槽的派发键（如工具名）。非 keyed 槽必须为 null。
  final String? key;

  /// 人类可读名（诊断树/面板）。
  final String label;

  final int order;
  final int priority;

  /// 渲染载荷：app 侧是 widget 工厂，测试里是哨兵值。
  final P payload;

  /// 仅 chain 槽：从 owner props 选出匹配数据；返回 null 表示不接管。
  ///
  /// **必须纯**：只依赖入参，不读外部可变状态、无副作用（DSH："the decline decision lives here,
  /// never in a mounted component probing its own props"）。
  final Object? Function(Map<String, Object?> ownerData)? select;
}

/// 账本里的一条已生效贡献。
final class SlotEntry {
  SlotEntry({required this.contribution, required this.registeredAt});

  final SlotContribution<Object?> contribution;
  final int registeredAt;

  /// 条目自身渲染抛错后被"让位"（DSH abdicate）；内核渲染下一个存活者。
  bool abdicated = false;

  String get id => contribution.id;
  String get pluginId => contribution.pluginId;
  int get priority => contribution.priority;
  int get order => contribution.order;
  String get slotId => contribution.slotId;
  String get label => contribution.label;
  String? get key => contribution.key;
  Object? get payload => contribution.payload;
}

/// 槽账本（不含 UI）。所有变更返回 disposer，且会**在微任务里合并**发一次变更通知
/// （DSH `subscribe(key)` 的 microtask-batched 语义）。
class SlotRegistry {
  final Map<String, SlotDef> _defs = {};
  final Map<String, List<SlotEntry>> _entries = {};
  final Map<String, List<SlotContribution<Object?>>> _pending = {};
  final Map<String, int> _versions = {};
  final List<void Function(String slotId)> _listeners = [];
  final Map<String, int> _seq = {};
  bool _notifyScheduled = false;
  final Set<String> _dirty = <String>{};

  /// 已声明的槽。
  // 不留 `declaredSlots()`：槽清单只有一个问法 `snapshot()`（面板与门控都读它）。
  // 留两份读法 = 第二真源，将来一边过滤一边没过滤就会分叉。
  bool isDeclared(String slotId) => _defs.containsKey(slotId);

  /// 声明槽（owner 调用）。重复声明同 id → `duplicateDeclaration`（防止两个 owner 抢同一个位置）。
  Outcome<void> declare(SlotDef def) {
    final idError = _validateSlotId(def.id);
    if (idError != null) {
      return Err<void>(PluginFailure(
        code: PluginFailureKind.configInvalid,
        message: idError,
        hint: '槽 id 用 `<owner>.<区域>.<位置>`，段为小写字母/数字',
        pluginId: def.ownerPluginId,
      ));
    }
    final existing = _defs[def.id];
    if (existing != null) {
      if (existing.ownerPluginId != def.ownerPluginId) {
        return Err<void>.of(
          PluginFailureKind.configInvalid,
          '槽 ${def.id} 已由 ${existing.ownerPluginId} 声明，${def.ownerPluginId} 不能重复声明',
          hint: '换命名空间，或让原 owner 提供子槽',
          pluginId: def.ownerPluginId,
        );
      }
      return Err<void>.of(PluginFailureKind.configInvalid, '槽 ${def.id} 已声明过',
          hint: '同名槽由首个声明者拥有');
    }
    _defs[def.id] = def;
    _entries.putIfAbsent(def.id, () => <SlotEntry>[]);
    // declare-then-fill：把等这个槽的注册放进来。
    final waiting = _pending.remove(def.id);
    if (waiting != null) {
      for (final c in waiting) {
        _insert(def, c);
      }
    }
    _bump(def.id);
    return const Ok<void>(null);
  }

  /// 填槽。未声明的槽**不报错**：进 pending 队列，等 owner 声明时自动生效
  /// （DSH `ctx.slots.inject(key, cb)`：插件加载顺序自由）。
  Outcome<Disposable> register(SlotContribution<Object?> c) {
    if (c.id.isEmpty) {
      return Err<Disposable>.of(PluginFailureKind.configInvalid, '条目 id 不能为空',
          hint: '给条目一个稳定 id，便于"为什么没显示"的定位', pluginId: c.pluginId);
    }
    final def0 = _defs[c.slotId];
    if (def0 == null) {
      _pending.putIfAbsent(c.slotId, () => <SlotContribution<Object?>>[]).add(c);
      return Ok<Disposable>(() {
        final list = _pending[c.slotId];
        if (list != null) {
          list.removeWhere((e) => e == c);
          if (list.isEmpty) _pending.remove(c.slotId);
        }
      });
    }
    final err = _insert(def0, c);
    if (err != null) return Err<Disposable>(err);
    final registered = _entries[c.slotId]!.lastWhere((e) => e.contribution == c);
    return Ok<Disposable>(() {
      final list = _entries[c.slotId];
      if (list == null) return;
      list.removeWhere((e) => e == registered); // 按条目对象摘除（贡献对象可能被 keyed 替换过，不能按 payload 比）
      _bump(c.slotId);
    });
  }

  PluginFailure? _insert(SlotDef def, SlotContribution<Object?> c) {
    final list = _entries.putIfAbsent(def.id, () => <SlotEntry>[]);
    // — kind 相关的形状校验 —
    if (def.kind == SlotKind.keyed) {
      if (c.key == null || c.key!.isEmpty) {
        return PluginFailure(
          code: PluginFailureKind.configInvalid,
          message: '槽 ${def.id} 是 keyed 槽，注册必须带 key',
          hint: '拼错的 key 永不渲染（对齐 DSH tool.call.toolview），请核对拼写',
          pluginId: c.pluginId,
        );
      }
      list.removeWhere((e) => e.contribution.key == c.key); // 同 key = 替换（DSH："replaces its view"）
    } else if (def.kind == SlotKind.chain) {
      if (c.select == null) {
        return PluginFailure(
          code: PluginFailureKind.configInvalid,
          message: '槽 ${def.id} 是 chain 槽，注册必须提供 select',
          hint: 'select 必须是纯函数：同输入必同输出、不读外部状态、无副作用',
          pluginId: c.pluginId,
        );
      }
    } else if (c.key != null) {
      return PluginFailure(
        code: PluginFailureKind.configInvalid,
        message: '槽 ${def.id} 是 ${def.kind.name} 槽，不接受 key',
        hint: 'key 只用于 keyed 槽',
        pluginId: c.pluginId,
      );
    }
    // — 同格与 priority（DSH：lowest live entry renders；同 priority 冲突报错并指名占用者）—
    final sameCell = def.kind == SlotKind.list
        ? list.where((e) => e.id == c.id)
        : list.where((e) => def.kind != SlotKind.keyed);
    for (final e in sameCell) {
      if (e.priority == c.priority && !(def.kind == SlotKind.single && e.abdicated)) {
        return PluginFailure(
          code: PluginFailureKind.configInvalid,
          message: '槽 ${def.id} 的格子 "${c.id}" 已被 ${e.pluginId} 以 priority ${c.priority} 占用',
          hint: '用更高的 order 排到后面，或用更低（更小）的 priority 遮蔽它',
          pluginId: c.pluginId,
        );
      }
    }
    if (def.maxEntries != null && list.length >= def.maxEntries!) {
      return PluginFailure(
        code: PluginFailureKind.configInvalid,
        message: '槽 ${def.id} 最多 ${def.maxEntries} 个条目，已满',
        hint: '先卸载不需要的插件',
        pluginId: c.pluginId,
      );
    }
    list.add(SlotEntry(
      contribution: c,
      registeredAt: _seq.update(def.id, (v) => v + 1, ifAbsent: () => 0),
    ));
    _bump(def.id);
    return null;
  }

  /// 渲染查询：返回该槽当前应渲染的条目（已按 kind 做遮蔽/让位/筛选）。
  ///
  /// [ownerData] 只在 chain 槽用于跑 `select`（纯函数）。
  List<SlotEntry> entries(String slotId, {String? key, Map<String, Object?>? ownerData}) {
    final def = _defs[slotId];
    if (def == null) return const [];
    final list = List<SlotEntry>.of(_entries[slotId] ?? const []);
    if (key != null) list.removeWhere((e) => e.contribution.key != key);

    switch (def.kind) {
      case SlotKind.single:
        final alive = list.where((e) => !e.abdicated).toList()
          ..sort((a, b) {
            final p = a.priority.compareTo(b.priority);
            return p != 0 ? p : a.registeredAt.compareTo(b.registeredAt);
          });
        return alive.isEmpty ? const [] : [alive.first];
      case SlotKind.chain:
        final alive = list.where((e) => !e.abdicated).toList()
          ..sort((a, b) {
            final p = a.priority.compareTo(b.priority);
            return p != 0 ? p : a.registeredAt.compareTo(b.registeredAt);
          });
        for (final e in alive) {
          final matched = e.contribution.select!.call(ownerData ?? const {});
          if (matched != null) return [e]; // 第一个非 null 者当选
        }
        return const [];
      case SlotKind.list:
      case SlotKind.keyed:
        final alive = list.where((e) => !e.abdicated).toList()
          ..sort((a, b) {
            final o = a.order.compareTo(b.order);
            return o != 0 ? o : a.registeredAt.compareTo(b.registeredAt);
          });
        return alive;
    }
  }

  /// 等这个槽声明的注册（诊断与"为什么没显示"必须看得见它）。
  List<SlotContribution<Object?>> pendingContributions([String? slotId]) => [
        for (final e in _pending.entries)
          if (slotId == null || e.key == slotId) ...e.value,
      ];

  /// 条目渲染抛错 → 让位（DSH abdicate）。返回是否确实有一条被让位。
  ///
  /// 必须带 [pluginId]：single/chain 槽里不同插件会用**同名条目**（都叫 `bar`），
  /// 只按 id 找会把别人的也一起让位。
  bool reportEntryError(String slotId, String entryId, {String? pluginId}) {
    final list = _entries[slotId];
    if (list == null) return false;
    var changed = false;
    for (final e in list) {
      if (e.id == entryId && (pluginId == null || e.pluginId == pluginId) && !e.abdicated) {
        e.abdicated = true;
        changed = true;
      }
    }
    if (changed) _bump(slotId);
    return changed;
  }

  // ——— 变更通知（微任务合并）———

  int versionOf(String slotId) => _versions[slotId] ?? 0;

  /// 订阅某槽变更，返回反注册。**同一微任务内多次变更只通知一次**。
  Disposable subscribe(void Function(String slotId) listener) {
    _listeners.add(listener);
    return () => _listeners.remove(listener);
  }

  /// 现场快照（插件诊断页用；照 DSH `snapshot()` → `LiveCompositionNode[]`）。
  List<Map<String, Object?>> snapshot([String? slotId]) {
    final ids = slotId == null ? _defs.keys.toList() : [slotId];
    return [
      for (final id in ids)
        // **读原始账本，不走 `entries()`**：后者是"该渲染谁"（single 槽滤掉让位的、还做接管），
        // 体检要的是"谁登记过什么、现在活不活"。走渲染视图的话，出过错被摘掉的条目会
        // 从面板上直接消失 —— 「我注册的入口被摘了」这条最该有的自解释信息就没了。
        for (final e in _entries[id] ?? const <SlotEntry>[])
          {
            'slot': id,
            'registrant': e.pluginId,
            'id': e.id,
            if (e.contribution.key != null) 'key': e.contribution.key,
            'order': e.order,
            'priority': e.priority,
            'active': !e.abdicated,
          },
    ];
  }

  void _bump(String slotId) {
    _versions[slotId] = (_versions[slotId] ?? 0) + 1;
    _dirty.add(slotId);
    if (_notifyScheduled) return;
    _notifyScheduled = true;
    scheduleMicrotask(() {
      _notifyScheduled = false;
      final dirty = Set<String>.of(_dirty);
      _dirty.clear();
      for (final id in dirty) {
        for (final l in List<void Function(String)>.of(_listeners)) {
          try {
            l(id);
          } catch (_) {
            // 监听器失败被吞：注册表变更不可被观察者否决（对齐 DSH "Listener failures are contained"）。
          }
        }
      }
    });
  }

  // 这里**不留** `clearAll()` / `clearLedgerOnly()`：零调用者，而且是个陷阱 ——
  // 全量清空会把别的插件的条目一起抹掉（切方案档想清的只是自己那一份）。
  // 卸载自己的贡献请保存 `register` 返回的 Disposable（内核也已替你挂进 effect）。
}

/// `plugin` 段只允许小写字母数字与连字符；整体 `<owner>.<区域>.<位置>[.<细分>]`。
final RegExp _slotIdPattern = RegExp(r'^[a-z][a-zA-Z0-9-]*(\.[a-z][a-zA-Z0-9]*){1,3}$');

/// 槽 id 是否合法（公开给校验器与内核复用，保证"只有一份判定"）。
bool isValidSlotId(String id) => _slotIdPattern.hasMatch(id);

String? _validateSlotId(String id) {
  if (!_slotIdPattern.hasMatch(id)) {
    return '槽 id "$id" 不合法';
  }
  return null;
}
