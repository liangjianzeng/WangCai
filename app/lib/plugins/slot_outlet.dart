/// 宿主侧的槽渲染器（P2）—— 宿主的输入区从此**零 if-else**：只有几个 `SlotOutlet` 洞。
///
/// 三条纪律（都是 §4.3 冻结件，不是这里新造的）：
/// - **渲染什么由 `registry.entries()` 决定**：遮蔽 / 让位 / chain 选中，全在内核算完，这里不重复排序；
/// - **条目渲染出错 → 该条目让位（abdicate）**，绝不把整条输入区带崩；
/// - **不缓存第二份真相**：每次 build 现场读注册表；变更靠 `subscribe`（微任务合并）触发重建。
library;

import 'package:flutter/material.dart';
import 'package:plugin_kernel/plugin_kernel.dart';

/// 把 [SlotRegistry] 送进 widget 树（app 根包一层即可）。
///
/// 用 `InheritedWidget` 而不是 Provider：这个文件要保持**纯 Flutter**，
/// 这样槽渲染语义能用最朴素的 `widget_test` 验证，不用起整套 ProviderScope。
class SlotRegistryScope extends InheritedWidget {
  const SlotRegistryScope({required this.registry, required super.child, super.key});

  final SlotRegistry registry;

  static SlotRegistry of(BuildContext context) {
    final w = context.dependOnInheritedWidgetOfExactType<SlotRegistryScope>();
    assert(w != null, 'widget 树里少了 SlotRegistryScope —— 在 app 根包一层');
    return w!.registry;
  }

  @override
  bool updateShouldNotify(SlotRegistryScope oldWidget) => oldWidget.registry != registry;
}

/// 插件动作入口（chip 点击 / slash 命令 / 智能体工具**三合一走同一条** `service.run`）。
///
/// 为什么是抽象接口 + InheritedWidget：插件贡献的 Widget 不该（也没法）拿到 Provider 容器，
/// 更不该 import 宿主；它只在被点的时候向下层要一个"帮我跑我自己"的口子。
abstract interface class PluginDispatcher {
  /// 跑一个插件（`entry` 说清是谁唤起的，插件里可分支）。
  Future<Outcome<PluginRunResult>> run(String pluginId, PluginInput input);

  /// 读插件自己的 KV（活动条这类"现场显示"用；前缀由平台加）。
  Future<String?> readPluginValue(String pluginId, String key);
}

class PluginDispatcherScope extends InheritedWidget {
  const PluginDispatcherScope({required this.dispatcher, required super.child, super.key});

  final PluginDispatcher? dispatcher;

  /// 找不到返回 null（平台没起来时插件图标该安静地什么都不做，而不是抛异常）。
  static PluginDispatcher? of(BuildContext context) =>
      context.dependOnInheritedWidgetOfExactType<PluginDispatcherScope>()?.dispatcher;

  @override
  bool updateShouldNotify(PluginDispatcherScope oldWidget) => oldWidget.dispatcher != dispatcher;
}

/// 订阅一个槽并在变化时重建（布局完全交给调用方，所以插件能拿到任意容器）。
class SlotBuilder extends StatefulWidget {
  const SlotBuilder({
    required this.slotId,
    required this.builder,
    this.ownerData,
    this.registry,
    super.key,
  });

  final String slotId;
  final Widget Function(BuildContext context, List<SlotEntry> entries) builder;

  /// chain 槽的 `select` 输入；其它槽用不到。
  final Map<String, Object?>? ownerData;

  /// 显式注入（测试用）；为 null 时从 [SlotRegistryScope] 取。
  final SlotRegistry? registry;

  @override
  State<SlotBuilder> createState() => _SlotBuilderState();
}

class _SlotBuilderState extends State<SlotBuilder> {
  Disposable? _off;
  SlotRegistry? _bound;

  @override
  void initState() {
    super.initState();
    _bind();
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    _bind(); // Scope 里的 registry 换了（理论上只发生一次）也要重订阅
  }

  void _bind() {
    final reg = widget.registry ?? _maybeRegistry();
    if (identical(_bound, reg) && _off != null) return;
    _off?.call();
    _bound = reg;
    if (reg == null) return;
    _off = reg.subscribe((slotId) {
      if (slotId != widget.slotId || !mounted) return;
      setState(() {}); // 注册表本身微任务合并过，这里不会被刷爆
    });
  }

  SlotRegistry? _maybeRegistry() {
    SlotRegistry? found;
    context.visitAncestorElements((e) {
      final w = e.widget;
      if (w is SlotRegistryScope) {
        found = w.registry;
        return false;
      }
      return true;
    });
    return found;
  }

  @override
  void dispose() {
    _off?.call();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final reg = widget.registry ?? _bound ?? SlotRegistryScope.of(context);
    final entries = reg.entries(widget.slotId, ownerData: widget.ownerData);
    return widget.builder(context, entries);
  }
}

/// 通用槽洞：按 kind 渲染条目负载。
///
/// 负载约定：`Widget` 直接渲染；`String` 渲染成 `Text`；其它类型 = 作者违约，
/// **当场让位并记日志**（而不是抛异常把宿主带走）。
class SlotOutlet extends StatelessWidget {
  const SlotOutlet({
    required this.slotId,
    this.axis = Axis.horizontal,
    this.spacing = 8,
    this.ownerData,
    this.maxVisible,
    this.emptyWidget,
    this.registry,
    super.key,
  });

  final String slotId;
  final Axis axis;
  final double spacing;
  final Map<String, Object?>? ownerData;

  /// 防御性上限：某槽被塞爆时截断（正常应受 `SlotDef.maxEntries` 约束）。
  final int? maxVisible;
  final Widget? emptyWidget;
  final SlotRegistry? registry;

  @override
  Widget build(BuildContext context) {
    return SlotBuilder(
      slotId: slotId,
      ownerData: ownerData,
      registry: registry,
      builder: (context, entries) {
        final shown = maxVisible == null ? entries : entries.take(maxVisible!).toList();
        if (shown.isEmpty) return emptyWidget ?? const SizedBox.shrink();
        final children = <Widget>[];
        for (var i = 0; i < shown.length; i++) {
          if (i > 0) {
            children.add(axis == Axis.horizontal
                ? SizedBox(width: spacing)
                : SizedBox(height: spacing));
          }
          children.add(_SlotEntryView(entry: shown[i], registry: registry ?? SlotRegistryScope.of(context)));
        }
        return axis == Axis.horizontal
            ? Row(mainAxisSize: MainAxisSize.min, children: children)
            : Column(mainAxisSize: MainAxisSize.min, children: children);
      },
    );
  }
}

class _SlotEntryView extends StatelessWidget {
  const _SlotEntryView({required this.entry, required this.registry});

  final SlotEntry entry;
  final SlotRegistry registry;

  @override
  Widget build(BuildContext context) {
    final payload = entry.payload;
    if (payload is Widget) return payload;
    if (payload is String) return Text(payload, overflow: TextOverflow.ellipsis);
    // 负载类型不对是**作者违约**：这一条让位，别把整条输入区带走。
    registry.reportEntryError(entry.slotId, entry.id, pluginId: entry.pluginId);
    return const SizedBox.shrink();
  }
}

/// 插件接管发送时的回调（`select` 返回它，宿主 await 它）。
///
/// 返回 `true` = 我处理了，宿主**不要**再走普通发送；返回 `false` = 我看了一眼但不接，
/// 宿主照常发送（所以插件"不接"必须显式 return false，绝不能靠返回 null 蒙混）。
typedef ComposerTakeover = Future<bool> Function(String text, List<String> imagePaths);

/// chain 槽（发送链接管）的解析结果。
final class SlotTakeover {
  const SlotTakeover({required this.entry, required this.value});
  final SlotEntry entry;

  /// `select(ownerData)` 返回的非 null 值（纯函数，再算一次是安全的）。
  final Object? value;
}

/// 问一遍 chain 槽「这段输入你接不接」，第一个给出非 null 者当选。
///
/// **`select` 必须是纯函数**（冻结件）：这里会为当选者再调一次取回它的接管数据。
SlotTakeover? resolveTakeover(SlotRegistry registry, String slotId, Map<String, Object?> ownerData) {
  final winner = registry.entries(slotId, ownerData: ownerData);
  if (winner.isEmpty) return null;
  final e = winner.first;
  final select = e.contribution.select;
  if (select == null) {
    registry.reportEntryError(slotId, e.id, pluginId: e.pluginId);
    return null;
  }
  try {
    final v = select(ownerData);
    if (v == null) return null;
    return SlotTakeover(entry: e, value: v);
  } catch (_) {
    // 违反纯度约定的 select：让它让位，宿主照常发送，不能让插件把发送键卡死。
    registry.reportEntryError(slotId, e.id, pluginId: e.pluginId);
    return null;
  }
}

/// 把一次插件失败显示成**"一句人话 + 下一步做什么"**。
///
/// 为什么宿主给这个函数：平台的失败契约是 `message`（人话）+ `hint`（下一步）+ `cause`（技术原文）。
/// 以前两个内置插件的 SnackBar 只贴 `f.message`，等于**把 hint 丢了** ——
/// 2026-10-24 真机上"一直报没能从图里提取内容"就是这么变成一句没用的红条的：
/// 宿主分好类的下一步（去开视觉 / 去加载模型 / 检查 API）全在 hint 里，界面上一个字都没露。
/// 插件一律走这里，别再各自 `f.message`。
String describePluginFailure(PluginFailure failure) {
  final hint = failure.hint;
  if (hint == null || hint.trim().isEmpty) return failure.message;
  return '${failure.message}\n$hint';
}
