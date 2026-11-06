import 'dart:async';
import 'dart:math' as math;

import 'package:flutter/material.dart';

import '../voice/voice_model_manager.dart' show VoiceModelManager, VoiceModels, VoiceDownloadCancelled;
import '../voice/voice_service.dart';

/// 按住说话会话：长按语音按钮期间的浮层 UI（引擎生命周期已收编 VoiceService，
/// T1.8 消费方收口——会话只是门面上的一个场景句柄）。
///
/// 交互（微信式）：
/// - `start`：先插浮层（「准备中」），[VoiceService.beginCapture] 就绪后切换实时回显；
/// - 上滑超过阈值 → cancelMode（浮层提示「松开取消」）；
/// - `end`：松手时取终稿（cancelMode 或空文本返回空串）。
///
/// 生命周期坑（真机实测，语义原样保留）：首次 start 要加载 ~160MB 模型（数秒），
/// 期间用户可能已松手——调用方必须在 start 前把会话登记到持有方，松手时若引擎
/// 未就绪则置 [cancelRequested]，由 start 完成侧负责收尾，避免会话孤儿化
/// （浮层滞留 + 麦克风常开）。
class HoldToTalkSession {
  HoldToTalkSession({VoiceService? service})
      : _service = service ?? VoiceService.instance;

  final VoiceService _service;

  /// 实时转写文本（已断句定稿 + 当前 partial）。
  final ValueNotifier<String> partial = ValueNotifier('');

  /// 上滑取消状态（浮层据此切换提示样式）。
  final ValueNotifier<bool> cancelMode = ValueNotifier(false);

  /// 引擎是否已就绪（浮层据此从「准备中」切到实时回显）。
  final ValueNotifier<bool> ready = ValueNotifier(false);

  /// 引擎加载完成前用户已松手：start 侧收尾时按取消处理。
  bool cancelRequested = false;

  OverlayEntry? _overlay;
  StreamSubscription<String>? _sub;
  bool _engineStarted = false;

  /// 引擎是否已开始录音（end 语义分叉的依据）。
  bool get isStarted => _engineStarted;

  /// 上滑取消的位移阈值（逻辑像素，相对长按起点）。
  static const double cancelSlop = 70;

  /// 启动会话：插浮层 → 门面开麦 → 切实时回显。
  /// 返回 false = 启动失败（浮层已自行撤除；被拒原因见 VoiceService 日志：
  /// 会话互斥 / 播报期关麦 / 引擎起不来）。
  Future<bool> start(BuildContext context) async {
    // 先取 OverlayState（context 跨 async gap 使用会告警）
    final overlay = Overlay.of(context, rootOverlay: true);
    _overlay = OverlayEntry(builder: (_) => _HoldOverlay(session: this));
    overlay.insert(_overlay!);
    final ok = await _service.beginCapture(scene: VoiceScene.holdToTalk);
    if (cancelRequested) {
      // 加载期间用户已松手：门面侧按取消收尾（归还麦克风），会话报废。
      await _service.cancelCapture();
      _removeOverlay();
      return false;
    }
    if (!ok) {
      _removeOverlay();
      return false;
    }
    _engineStarted = true;
    _sub = _service.partialText.listen((t) {
      partial.value = t;
    });
    ready.value = true;
    return true;
  }

  /// 结束会话：[cancelled] 为 true 时丢弃结果。返回终稿文本（可能为空串）。
  /// 引擎尚未就绪时调用 = 请求中止，由 start 侧负责收尾。
  Future<String> end({bool cancelled = false}) async {
    if (!_engineStarted) {
      cancelRequested = true;
      _removeOverlay();
      return '';
    }
    _removeOverlay();
    await _sub?.cancel();
    _sub = null;
    final text = await _service.endCapture(cancelled: cancelled);
    _engineStarted = false;
    return text.trim();
  }

  void _removeOverlay() {
    _overlay?.remove();
    _overlay = null;
  }
}

/// 测试钩子：直接构建回显浮层（绕过引擎加载，供 widget 测试验证键盘场景）。
@visibleForTesting
Widget buildHoldTalkOverlayForTest(HoldToTalkSession session) =>
    _HoldOverlay(session: session);

class _HoldOverlay extends StatelessWidget {
  const _HoldOverlay({required this.session});

  final HoldToTalkSession session;

  @override
  Widget build(BuildContext context) {
    // 键盘打开时回显浮层必须抬到键盘上方：root overlay 不随 Scaffold 的
    // resizeToAvoidBottomInset 缩放，固定 margin 的底部卡片会被键盘整个
    // 盖住。依赖 MediaQuery.viewInsets（键盘弹起/收起自动重建本浮层）。
    final keyboard = MediaQuery.viewInsetsOf(context).bottom;
    return Positioned.fill(
      // 浮层只做展示：手指仍按在语音按钮上，事件路由不能被打断
      child: IgnorePointer(
        child: Material(
          type: MaterialType.transparency,
          child: Column(
            mainAxisAlignment: MainAxisAlignment.end,
            children: [
              Container(
                key: const ValueKey('hold-overlay-card'),
                margin: EdgeInsets.fromLTRB(32, 32, 32, 32 + keyboard),
                padding:
                    const EdgeInsets.symmetric(horizontal: 20, vertical: 16),
                constraints: const BoxConstraints(maxWidth: 360),
                decoration: BoxDecoration(
                  color: Colors.black87,
                  borderRadius: BorderRadius.circular(20),
                ),
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    // 就绪前不显示声浪（声浪 = 真正在监听的信号），改为
                    // 加载指示 +「引擎加载中，请稍后…」；就绪后切回声浪 +
                    // 松开手势提示。上滑取消提示优先级最高。
                    ValueListenableBuilder<bool>(
                      valueListenable: session.ready,
                      builder: (_, isReady, __) =>
                          ValueListenableBuilder<bool>(
                        valueListenable: session.cancelMode,
                        builder: (_, cancelling, ___) {
                          final loading = !isReady && !cancelling;
                          final color = cancelling
                              ? Colors.redAccent
                              : Colors.white;
                          return Row(
                            mainAxisAlignment: MainAxisAlignment.center,
                            children: [
                              if (loading) ...[
                                const SizedBox(
                                  width: 16,
                                  height: 16,
                                  child: CircularProgressIndicator(
                                      strokeWidth: 2, color: Colors.white70),
                                ),
                                const SizedBox(width: 10),
                                Expanded(
                                  child: Text('引擎加载中，请稍后…',
                                      textAlign: TextAlign.center,
                                      style: TextStyle(
                                          color: Colors.white70,
                                          fontWeight: FontWeight.w600)),
                                ),
                              ] else ...[
                                _ListeningIndicator(red: cancelling),
                                const SizedBox(width: 10),
                                Text(cancelling ? '松开取消' : '松开发送',
                                    style: TextStyle(
                                        color: color,
                                        fontWeight: FontWeight.w600)),
                              ],
                            ],
                          );
                        },
                      ),
                    ),
                    const SizedBox(height: 10),
                    ValueListenableBuilder<bool>(
                      valueListenable: session.ready,
                      builder: (_, isReady, __) =>
                          ValueListenableBuilder<String>(
                        valueListenable: session.partial,
                        builder: (_, text, ___) => ConstrainedBox(
                          constraints: const BoxConstraints(minHeight: 48),
                          child: Align(
                            alignment: Alignment.topLeft,
                            child: Text(
                              !isReady
                                  ? '首次使用需加载识别模型，稍等片刻…'
                                  : (text.isEmpty ? '请说话…' : text),
                              style: const TextStyle(
                                  color: Colors.white,
                                  fontSize: 15,
                                  height: 1.4),
                            ),
                          ),
                        ),
                      ),
                    ),
                  ],
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

/// 聆听动态效果：麦克风图标 + 一排声浪条持续波动（提示正在监听语音）。
/// 说话中蓝色声浪，上滑取消时整体变红。
class _ListeningIndicator extends StatefulWidget {
  const _ListeningIndicator({required this.red});

  /// 取消态（上滑超过阈值）：声浪变红。
  final bool red;

  @override
  State<_ListeningIndicator> createState() => _ListeningIndicatorState();
}

class _ListeningIndicatorState extends State<_ListeningIndicator>
    with SingleTickerProviderStateMixin {
  /// 单控制器驱动声浪相位，帧间无随机抖动。
  late final AnimationController _ctrl =
      AnimationController(vsync: this, duration: const Duration(milliseconds: 720))
        ..repeat();

  static const int _bars = 5;

  @override
  void dispose() {
    _ctrl.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return AnimatedBuilder(
      animation: _ctrl,
      builder: (_, __) {
        final color =
            widget.red ? Colors.redAccent : Colors.lightBlueAccent;
        return Row(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.end,
          children: [
            Icon(Icons.mic, color: color, size: 24),
            const SizedBox(width: 6),
            for (var i = 0; i < _bars; i++)
              Container(
                width: 4,
                margin: const EdgeInsets.symmetric(horizontal: 1),
                // 正弦相位级联 → 声浪像水流一样从左到右波动
                height: 10 +
                    10 * ((math.sin(_ctrl.value * math.pi * 2 * 2 +
                                i * 1.3) + 1) / 2),
                decoration: BoxDecoration(
                  color: color.withValues(alpha: 0.85),
                  borderRadius: BorderRadius.circular(2),
                ),
              ),
          ],
        );
      },
    );
  }
}

/// 模型下载引导：模型未就绪时弹窗展示断点续传下载进度，完成返回 true。
class AsrModelGate {
  AsrModelGate._();

  /// 确保模型就绪（T2.2 起支持任意注册表条目——唤醒对话下 sensevoice+vad）。
  /// 已就绪直接返回 true；否则弹下载对话框：完成 → true；用户取消/失败未
  /// 重试 → false（调用方回落）。
  static Future<bool> ensureModelReady(
    BuildContext context, {
    String id = VoiceModels.streaming,
    String title = '启用端侧语音识别',
    String intro = '首次使用需下载中文识别模型（约 160MB，一次即可）：',
  }) async {
    if (await VoiceModelManager.isReady(id)) return true;
    if (!context.mounted) return false;
    final ok = await showDialog<bool>(
      context: context,
      barrierDismissible: false,
      builder: (_) => _AsrDownloadDialog(id: id, title: title, intro: intro),
    );
    return ok == true;
  }
}

class _AsrDownloadDialog extends StatefulWidget {
  const _AsrDownloadDialog({
    required this.id,
    required this.title,
    required this.intro,
  });

  final String id;
  final String title;
  final String intro;

  @override
  State<_AsrDownloadDialog> createState() => _AsrDownloadDialogState();
}

class _AsrDownloadDialogState extends State<_AsrDownloadDialog> {
  final ValueNotifier<double> _progress = ValueNotifier(0);
  String _status = '准备下载…';
  String? _error;
  bool _cancelled = false;

  @override
  void initState() {
    super.initState();
    _start();
  }

  Future<void> _start() async {
    setState(() {
      _error = null;
      _status = '准备下载…';
    });
    try {
      await VoiceModelManager.download(widget.id,
        onProgress: (p, file) {
          _progress.value = p;
          if (mounted) {
            setState(() => _status = '正在下载 $file（${(p * 100).toStringAsFixed(1)}%，'
                '中断可续传）');
          }
        },
        isCancelled: () => _cancelled,
      );
      if (!mounted) return;
      Navigator.of(context).pop(true);
    } on VoiceDownloadCancelled {
      if (mounted) Navigator.of(context).pop(false);
    } catch (e) {
      debugPrint('[DSH][asr] download failed: $e');
      if (mounted) {
        setState(() => _error = '下载失败：$e\n已下载的部分会保留，重试将从断点继续。');
      }
    }
  }

  Future<void> _cancel() async {
    _cancelled = true;
    await VoiceModelManager.cancelDownloads();
  }

  @override
  void dispose() {
    if (!_cancelled) unawaited(VoiceModelManager.cancelDownloads());
    _progress.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return AlertDialog(
      title: Text(widget.title),
      content: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(widget.intro),
          const SizedBox(height: 8),
          const Text('· 下载到应用私有目录，不打包也无需重复下载\n'
              '· 中断（断网/杀 App）后自动断点续传'),
          const SizedBox(height: 14),
          ValueListenableBuilder<double>(
            valueListenable: _progress,
            builder: (_, p, __) => Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                LinearProgressIndicator(value: p <= 0 ? null : p),
                const SizedBox(height: 6),
                Text(_status,
                    style: theme.textTheme.bodySmall
                        ?.copyWith(color: theme.colorScheme.onSurfaceVariant)),
              ],
            ),
          ),
          if (_error != null)
            Padding(
              padding: const EdgeInsets.only(top: 8),
              child: Text(_error!,
                  style: const TextStyle(color: Colors.red, fontSize: 12)),
            ),
        ],
      ),
      actions: [
        TextButton(
          onPressed: () async {
            await _cancel();
            if (context.mounted) Navigator.of(context).pop(false);
          },
          child: const Text('取消'),
        ),
        if (_error != null)
          FilledButton(
            onPressed: _start,
            child: const Text('重试'),
          ),
      ],
    );
  }
}
