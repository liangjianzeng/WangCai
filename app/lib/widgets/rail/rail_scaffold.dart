import 'package:flutter/material.dart';

/// 左栏 harness（2026-10-24 UI 改造，设计稿见会话存档）：
///
/// - [AppRail]：56dp 能力图标栏（Logo + 主图标组 + 底部组）。插件可经
///   `app.rail` 槽位贡献图标（SlotOutlet 由宿主塞进 children）。
/// - [RailPanelController]：面板开合状态（当前页 key），会话/计划等
///   HomeScreen 逻辑直接调 open/close/toggle。
/// - [RailPanelHost]：rail + 主区 + 滑入面板容器（背 tap 关闭）。
///   面板只盖主区（含 AppBar），rail 恒可见——与设计稿一致。
///
/// 面板页由宿主以 `Map<String, RailPageSpec>` 注册；页内容自带滚动与
/// 状态监听（Consumer），host 不感知业务。

/// 左栏单条目数据（图标 + 语义 + 面板 key）。
class RailItem {
  /// 面板 key（与 RailPanelHost.pages 的 key 对应）；纯动作条目（如新建会话）
  /// 传 null = 永不高亮。
  final String? panelKey;
  final IconData icon;
  final String tooltip;
  final VoidCallback onTap;

  /// true = 图标右上角挂绿点（会话执行中 / 有活跃计划等状态徽标）。
  final bool badge;

  const RailItem({
    required this.icon,
    required this.tooltip,
    required this.onTap,
    this.panelKey,
    this.badge = false,
  });
}

/// 面板页注册项：标题 + 页构造器。
class RailPageSpec {
  final String title;
  final WidgetBuilder build;
  const RailPageSpec({required this.title, required this.build});
}

/// 把 controller 递给栏内按钮（RailIconButton 订阅它做选中态高亮）。
class RailPanelScope extends InheritedWidget {
  final RailPanelController controller;

  const RailPanelScope({
    super.key,
    required this.controller,
    required super.child,
  });

  static RailPanelScope? maybeOf(BuildContext context) =>
      context.dependOnInheritedWidgetOfExactType<RailPanelScope>();

  @override
  bool updateShouldNotify(RailPanelScope oldWidget) =>
      !identical(oldWidget.controller, controller);
}

class RailPanelController extends ChangeNotifier {
  String? _activeKey;

  /// 当前打开的面板 key；null = 全关。
  String? get activeKey => _activeKey;

  void open(String key) {
    if (_activeKey == key) return;
    _activeKey = key;
    notifyListeners();
  }

  void close() {
    if (_activeKey == null) return;
    _activeKey = null;
    notifyListeners();
  }

  /// 已开同页 = 关（再点同图标收起），否则开。
  void toggle(String key) => _activeKey == key ? close() : open(key);
}

/// 左栏本体：Logo + children（主图标组，含插件槽位）+ spacer + bottomChildren。
///
/// 点 Logo = 完全收起侧边栏（2026-10-25 用户需求，收/恢复状态由宿主持有）：
/// 宿主隐藏整条 rail 后在顶栏左上角放恢复 Logo，主区自动吃满横向宽度。
class AppRail extends StatelessWidget {
  final VoidCallback? onLogoTap;
  final String? logoTooltip;
  final List<Widget> children;
  final List<Widget> bottomChildren;

  const AppRail({
    super.key,
    this.onLogoTap,
    this.logoTooltip,
    required this.children,
    this.bottomChildren = const [],
  });

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    // 设计稿形态：左栏是明确的“容器”——着色底 + 右缘描边，图标紧凑成组。
    return Material(
      color: scheme.surfaceContainerHighest.withValues(alpha: 0.55),
      child: Container(
        width: 48,
        decoration: BoxDecoration(
          border: Border(
            right: BorderSide(color: scheme.outlineVariant, width: 1),
          ),
        ),
        child: SafeArea(
          right: false,
          child: Column(
            children: [
              const SizedBox(height: 6),
              _RailLogo(onTap: onLogoTap, tooltip: logoTooltip),
              const _RailDivider(),
              // 条目间 2px 呼吸缝：紧凑但不粘连（设计稿 gap:2）。
              for (var i = 0; i < children.length; i++) ...[
                if (i > 0) const SizedBox(height: 2),
                children[i],
              ],
              const Spacer(),
              for (var i = 0; i < bottomChildren.length; i++) ...[
                if (i > 0) const SizedBox(height: 2),
                bottomChildren[i],
              ],
              const SizedBox(height: 6),
            ],
          ),
        ),
      ),
    );
  }
}

class _RailLogo extends StatelessWidget {
  final VoidCallback? onTap;
  final String? tooltip;

  const _RailLogo({this.onTap, this.tooltip});

  @override
  Widget build(BuildContext context) {
    // 设计稿 logo：紫→蓝对角渐变（纯色太闷）。
    final logo = Material(
      color: Colors.transparent,
      borderRadius: BorderRadius.circular(10),
      child: Ink(
        decoration: const BoxDecoration(
          borderRadius: BorderRadius.all(Radius.circular(10)),
          gradient: LinearGradient(
            begin: Alignment.topLeft,
            end: Alignment.bottomRight,
            colors: [Color(0xFF7C5CFC), Color(0xFF5B8DEF)],
          ),
        ),
        child: InkWell(
          borderRadius: const BorderRadius.all(Radius.circular(10)),
          onTap: onTap,
          child: const SizedBox(
            width: 30,
            height: 30,
            child: Icon(Icons.auto_awesome, size: 16, color: Colors.white),
          ),
        ),
      ),
    );
    if (tooltip == null) return logo;
    return Tooltip(message: tooltip, child: logo);
  }
}

class _RailDivider extends StatelessWidget {
  const _RailDivider();

  @override
  Widget build(BuildContext context) {
    return Container(
      width: 22,
      height: 1,
      margin: const EdgeInsets.symmetric(vertical: 4),
      color: Theme.of(context).colorScheme.outlineVariant,
    );
  }
}

/// 栏内统一样式的图标按钮：40×40 触点、22px 图标；选中 = 主色胶囊底。
/// active 态由 [RailPanelScope] 里的 controller 推导（panelKey 匹配），
/// 并订阅 controller 变化自我重建。
class RailIconButton extends StatefulWidget {
  final RailItem item;

  const RailIconButton({super.key, required this.item});

  @override
  State<RailIconButton> createState() => _RailIconButtonState();
}

class _RailIconButtonState extends State<RailIconButton> {
  RailPanelController? _subscribed;

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    final c = RailPanelScope.maybeOf(context)?.controller;
    if (!identical(c, _subscribed)) {
      _subscribed?.removeListener(_onControllerChanged);
      _subscribed = c;
      c?.addListener(_onControllerChanged);
    }
  }

  @override
  void dispose() {
    _subscribed?.removeListener(_onControllerChanged);
    super.dispose();
  }

  void _onControllerChanged() {
    if (mounted) setState(() {});
  }

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final active = widget.item.panelKey != null &&
        _subscribed?.activeKey == widget.item.panelKey;
    Widget btn = InkWell(
      borderRadius: BorderRadius.circular(10),
      onTap: widget.item.onTap,
      child: Container(
        width: 34,
        height: 34,
        decoration: BoxDecoration(
          color: active ? scheme.primaryContainer : Colors.transparent,
          borderRadius: BorderRadius.circular(10),
        ),
        child: Icon(
          widget.item.icon,
          size: 18,
          color: active ? scheme.onPrimaryContainer : scheme.onSurfaceVariant,
        ),
      ),
    );
    if (widget.item.badge) {
      btn = Badge(
        largeSize: 8,
        padding: const EdgeInsets.all(2.5),
        backgroundColor: Colors.green,
        child: btn,
      );
    }
    return Tooltip(message: widget.item.tooltip, child: btn);
  }
}

/// 主区容器：child（AppBar + 内容）在上，背 tap 幕布与面板滑入层在上。
/// 面板宽度 = min(320, 主区宽 - 8)；盖住 AppBar（与设计稿一致），rail 恒可见。
class RailPanelHost extends StatefulWidget {
  final RailPanelController controller;
  final Map<String, RailPageSpec> pages;
  final Widget rail;
  final Widget child;

  const RailPanelHost({
    super.key,
    required this.controller,
    required this.pages,
    required this.rail,
    required this.child,
  });

  @override
  State<RailPanelHost> createState() => _RailPanelHostState();
}

class _RailPanelHostState extends State<RailPanelHost> {
  /// 关闭后面板不卸载（保留最后一次打开的页），才能做出"滑出"关闭动画。
  String? _lastKey;

  @override
  Widget build(BuildContext context) {
    final controller = widget.controller;
    return RailPanelScope(
      controller: controller,
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          widget.rail,
          Expanded(
            child: AnimatedBuilder(
              animation: controller,
              builder: (context, _) {
                final key = controller.activeKey;
                final open = key != null && widget.pages.containsKey(key);
                if (open) _lastKey = key;
                final spec = _lastKey != null ? widget.pages[_lastKey] : null;
                return Stack(
                  children: [
                    widget.child,
                    // 幕布：开着才可点（IgnorePointer 防穿透）。
                    AnimatedIgnorePointer(
                      ignoring: !open,
                      child: AnimatedOpacity(
                        opacity: open ? 1 : 0,
                        duration: const Duration(milliseconds: 150),
                        child: GestureDetector(
                          onTap: controller.close,
                          child: Container(color: Colors.black38),
                        ),
                      ),
                    ),
                    // 面板常驻挂载：关 = 整体滑出左缘（-1.2 倍自身宽度），
                    // 开/关都有滑入滑出动画；滑出后不可点、不可见。
                    AnimatedSlide(
                      offset: open ? Offset.zero : const Offset(-1.2, 0),
                      duration: const Duration(milliseconds: 200),
                      curve: Curves.easeOutCubic,
                      child: AnimatedIgnorePointer(
                        ignoring: !open,
                        child: Align(
                          alignment: Alignment.centerLeft,
                          child: spec == null
                              ? const SizedBox.shrink()
                              : _buildPanel(context, spec, open: open),
                        ),
                      ),
                    ),
                  ],
                );
              },
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildPanel(BuildContext context, RailPageSpec spec,
      {required bool open}) {
    final scheme = Theme.of(context).colorScheme;
    return LayoutBuilder(builder: (context, constraints) {
      // 设计稿：面板宽 ≈ 88% 主区宽（296/336），右侧留出对话画布一线。
      final width = (constraints.maxWidth * 0.88).clamp(240.0, 300.0);
      return Material(
        color: scheme.surface,
        elevation: 10,
        borderRadius: const BorderRadius.horizontal(right: Radius.circular(18)),
        clipBehavior: Clip.antiAlias,
        child: SizedBox(
          width: width,
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Padding(
                padding: const EdgeInsets.fromLTRB(16, 6, 8, 6),
                child: Row(
                  children: [
                    Expanded(
                      child: Text(spec.title,
                          style: const TextStyle(
                              fontSize: 16, fontWeight: FontWeight.w600)),
                    ),
                    SizedBox(
                      width: 32,
                      height: 32,
                      child: IconButton(
                        visualDensity: VisualDensity.compact,
                        padding: EdgeInsets.zero,
                        icon: const Icon(Icons.close, size: 19),
                        tooltip: '关闭',
                        onPressed: widget.controller.close,
                      ),
                    ),
                  ],
                ),
              ),
              Divider(height: 1, color: scheme.outlineVariant),
              Expanded(child: Builder(builder: spec.build)),
            ],
          ),
        ),
      );
    });
  }
}

/// 幕布的忽略指针动画（关→开瞬间不误触底层）。
class AnimatedIgnorePointer extends StatelessWidget {
  final bool ignoring;
  final Widget child;

  const AnimatedIgnorePointer({
    super.key,
    required this.ignoring,
    required this.child,
  });

  @override
  Widget build(BuildContext context) {
    return IgnorePointer(ignoring: ignoring, child: child);
  }
}
