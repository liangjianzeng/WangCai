/// 唤醒对话会话（T2.2/T2.4）：免提对话的场景句柄（M2 模拟态 = 按钮触发，
/// KWS 语音常驻唤醒在 M3 接进同一门面）。
///
/// 流程（母方案 §4.2/§6）：
/// 1. `start`：插浮条 → [VoiceService.beginCapture]（wake 场景，超时按设置项
///    voiceWakeNoInputSec/voiceWakeMaxInputSec）→ partial 增量上浮条（假流式）；
/// 2. 收尾（说话停顿超时/手动结束/最长输入超时统一走 [VoiceService.finalTexts]）：
///    - D2 `autoSend=true`：定稿上屏 → **3s 缓冲**倒计时自动发送，期间可点
///      「取消」（回输入框）或「重说」（丢稿直接再开一轮，麦自动重开）；
///    - `autoSend=false`：定稿直接进输入框，用户手动发。
/// 3. **空稿二段式（T2.3）**：首空稿浮条提示「没听清，请再说一次」并自动重开
///    一次麦；再空稿才提示「未识别到内容」收尾。用户主动结束（stop）不再重试。
///    拍板（M3 终验补齐）：提示为浮条视觉态而非 TTS 语音——语音播报会触发
///    半双工停麦，与「重开麦」互斥；提示音/浮条即时可见已是硬反馈。
library;

import 'dart:async';

import 'package:flutter/material.dart';

import 'voice_service.dart';

class WakeSession {
  WakeSession({
    required this.onDeliver,
    this.onEnded,
    required this.autoSend,
    required this.noInputSec,
    required this.maxInputSec,
    this.autoSendBuffer = const Duration(seconds: 3),
  });

  /// 定稿出口：[text] 进输入框；[send]=true 时紧接着发送（D2 自动）。
  final Future<void> Function(String text, bool send) onDeliver;

  /// 会话彻底收尾（含空稿/取消/重说路径）——宿主同步入口图标态。
  final VoidCallback? onEnded;

  /// D2：定稿后缓冲倒计时自动发送（默认 3s；测试注入毫秒级驱动）。
  final bool autoSend;
  final int noInputSec;
  final int maxInputSec;
  final Duration autoSendBuffer;

  final ValueNotifier<String> partial = ValueNotifier('');
  final ValueNotifier<String> finalized = ValueNotifier('');
  final ValueNotifier<int> autoSendCountdown = ValueNotifier(0);

  OverlayEntry? _overlay;
  StreamSubscription<String>? _partialSub;
  StreamSubscription<String>? _finalSub;
  Timer? _sendTimer;
  bool _settling = false; // 收尾去重（超时/手动/ disposed 竞态）
  int _emptyRetries = 0; // T2.3 空稿二段式：自动重试一次
  bool _userEnded = false; // 用户主动结束的空稿不再自动重试
  int _epoch = 0; // 重开麦代次：stop/abort/retry 推进，使在途重试失效
  bool _reopening = false; // 重开麦在途（active 短暂真空期防并发会话）

  bool get active =>
      _overlay != null || _partialSub != null || _reopening;

  /// 启动会话。返回 false = 被拒（会话互斥/引擎失败；权限与模型 gate 由
  /// 调用方先完成——它们需要 BuildContext 弹窗）。
  /// [context] 传 null = 不挂浮条（纯状态机，单测用）。
  Future<bool> start(BuildContext? context) async {
    if (active) return false;
    _settling = false;
    _userEnded = false;
    _emptyRetries = 0;
    _epoch++;
    partial.value = '';
    finalized.value = '';
    autoSendCountdown.value = 0;
    if (context != null) {
      _overlay = OverlayEntry(builder: (_) => _WakeOverlay(session: this));
      Overlay.of(context, rootOverlay: true).insert(_overlay!);
    }
    final ok = await VoiceService.instance.beginCapture(
      scene: VoiceScene.wake,
      idleTimeout: Duration(seconds: noInputSec),
      maxUtterance: Duration(seconds: maxInputSec),
    );
    if (!ok) {
      _removeOverlay();
      return false;
    }
    _partialSub =
        VoiceService.instance.partialText.listen((t) => partial.value = t);
    _finalSub = VoiceService.instance.finalTexts.listen(_onFinal);
    return true;
  }

  /// 手动结束（浮条「结束」按钮 / 页面销毁 / 入口按钮再点）。
  Future<void> stop({bool cancelled = false}) async {
    // 重试重开麦在途/刚完成（提示态 -2）：用户喊停 = 立即撤，丢弃不重试。
    if (cancelled || autoSendCountdown.value == -2) {
      if (_settling) return;
      _settling = true;
      _epoch++;
      await VoiceService.instance.endCapture(cancelled: true);
      _teardown(removeOverlay: true, keepSubs: false);
      return;
    }
    // 正常结束：不设 _settling——定稿经 finalTexts 事件统一收尾（含空稿
    // 分支；endCapture 的 engine-null 守卫天然防二次事件）。用户主动结束
    // 的空稿不再自动重试（[stop] 语义优先于二段式）。
    _userEnded = true;
    await VoiceService.instance.endCapture();
  }

  /// 收尾统一入口（VoiceService.finalTexts 事件）。
  void _onFinal(String text) {
    if (_settling) return;
    _settling = true;
    _teardown(removeOverlay: false, keepSubs: false);
    partial.value = '';
    finalized.value = text;
    if (text.isEmpty) {
      // 空稿二段式（T2.3）：首空稿自动重开一次麦；再空稿「未识别到内容」
      // 收尾。用户主动结束（stop）不再重试。
      if (!_userEnded && _emptyRetries == 0) {
        _emptyRetries++;
        // 重开窗口交棒 _reopenMic（旧订阅已撤，不会有第二个 final 进来；
        // _settling 复位让 stop/abort 的「重试期喊停」分支可达）。
        _settling = false;
        unawaited(_reopenMic(hint: true));
        return;
      }
      autoSendCountdown.value = -1; // -1 = 「未识别到内容」提示态
      Timer(autoSendBuffer, _removeOverlay);
      return;
    }
    if (autoSend) {
      // D2 默认：3s 缓冲倒计时自动发，期间可取消/重说。倒计时按整秒跳动
      // （缓冲注入毫秒级仅测试用，节拍随缓冲自适应）。
      autoSendCountdown.value = autoSendBuffer.inSeconds;
      final tick = autoSendBuffer < const Duration(seconds: 1)
          ? autoSendBuffer
          : const Duration(seconds: 1);
      _sendTimer = Timer.periodic(tick, (t) {
        final elapsed = tick * t.tick;
        if (elapsed >= autoSendBuffer) {
          t.cancel();
          _sendTimer = null;
          final text0 = finalized.value;
          _removeOverlay();
          unawaited(onDeliver(text0, true));
        } else {
          autoSendCountdown.value =
              (autoSendBuffer - elapsed).inSeconds;
        }
      });
    } else {
      // 手动确认：文本直接进输入框（不发送），浮条撤除。
      _removeOverlay();
      unawaited(onDeliver(text, false));
    }
  }

  /// 重开一次麦（空稿自动重试 / 「重说」共用）。保持浮条；`hint=true` 进
  /// 「没听清」提示态（-2），partial 到达回到聆听态。stop/abort/retry 推进
  /// [ _epoch] 使在途重开失效（失败即收尾，绝不暗中复活会话）。
  Future<void> _reopenMic({bool hint = false}) async {
    final ep = ++_epoch;
    _reopening = true;
    partial.value = '';
    autoSendCountdown.value = hint ? -2 : 0; // -2 = 「没听清」重试提示态
    final ok = await VoiceService.instance.beginCapture(
      scene: VoiceScene.wake,
      idleTimeout: Duration(seconds: noInputSec),
      maxUtterance: Duration(seconds: maxInputSec),
    );
    _reopening = false;
    if (ep != _epoch) {
      // 等待期间被结束/销毁：把刚开的麦还回去，浮条交由结束方撤。
      if (ok) unawaited(VoiceService.instance.cancelCapture());
      return;
    }
    if (!ok) {
      autoSendCountdown.value = -1;
      Timer(autoSendBuffer, _removeOverlay);
      return;
    }
    _userEnded = false;
    _settling = false; // 「重说」路径从缓冲态进来时也复位（新的一轮）
    _partialSub = VoiceService.instance.partialText.listen((t) {
      if (t.isNotEmpty && autoSendCountdown.value == -2) {
        autoSendCountdown.value = 0;
      }
      partial.value = t;
    });
    _finalSub = VoiceService.instance.finalTexts.listen(_onFinal);
  }

  /// 倒计时期间点「取消」：定稿回输入框不发送。
  void cancelAutoSend() {
    _sendTimer?.cancel();
    _sendTimer = null;
    final text = finalized.value;
    autoSendCountdown.value = 0;
    _removeOverlay();
    if (text.isNotEmpty) unawaited(onDeliver(text, false));
  }

  /// 倒计时期间点「重说」：丢稿直接再开一轮（麦自动重开，浮条留在聆听态）。
  Future<void> retry() {
    _sendTimer?.cancel();
    _sendTimer = null;
    finalized.value = '';
    _emptyRetries = 0; // 手动重开 = 新的一轮，二段式重新计数
    return _reopenMic();
  }

  /// 页面销毁兜底：停识别、撤浮条（不交稿）。
  Future<void> abort() async {
    _sendTimer?.cancel();
    _sendTimer = null;
    _epoch++; // 使在途重开失效
    if (!_settling) {
      _settling = true;
      try {
        await VoiceService.instance.endCapture(cancelled: true);
      } catch (_) {}
    }
    _teardown(removeOverlay: true);
  }

  void _teardown({required bool removeOverlay, bool keepSubs = true}) {
    _partialSub?.cancel();
    _partialSub = null;
    if (!keepSubs) {
      _finalSub?.cancel();
      _finalSub = null;
    }
    if (removeOverlay) _removeOverlay();
  }

  void _removeOverlay() {
    _overlay?.remove();
    _overlay = null;
    onEnded?.call(); // 无浮条（纯状态机测试）也通知宿主收尾
  }
}

/// 唤醒对话浮动转写条（气泡上方浮层）：聆听态显示增量 partial；定稿态显示
/// 文本 + D2 倒计时（取消/重说）。
class _WakeOverlay extends StatelessWidget {
  const _WakeOverlay({required this.session});

  final WakeSession session;

  @override
  Widget build(BuildContext context) {
    final keyboard = MediaQuery.viewInsetsOf(context).bottom;
    return Positioned.fill(
      child: Column(
        mainAxisAlignment: MainAxisAlignment.end,
        children: [
          Container(
            margin: EdgeInsets.fromLTRB(24, 24, 24, 24 + keyboard),
            padding:
                const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
            constraints: const BoxConstraints(maxWidth: 420),
            decoration: BoxDecoration(
              color: Colors.black87,
              borderRadius: BorderRadius.circular(16),
            ),
            child: ValueListenableBuilder<int>(
              valueListenable: session.autoSendCountdown,
              builder: (_, countdown, __) {
                if (countdown == -2) {
                  // 空稿二段式：没听清，已自动重开麦等待再说话。
                  return const Row(children: [
                    Icon(Icons.mic_off, color: Colors.white70, size: 20),
                    SizedBox(width: 8),
                    Expanded(
                      child: Text('没听清，请再说一次',
                          style: TextStyle(
                              color: Colors.white70, fontSize: 14)),
                    ),
                  ]);
                }
                if (countdown == -1) {
                  return const Text('未识别到内容',
                      style: TextStyle(color: Colors.white70, fontSize: 14));
                }
                if (countdown > 0) {
                  // D2 缓冲期：定稿 + 倒计时 + 取消/重说。
                  return Column(
                    mainAxisSize: MainAxisSize.min,
                    crossAxisAlignment: CrossAxisAlignment.stretch,
                    children: [
                      Text(session.finalized.value,
                          style: const TextStyle(
                              color: Colors.white, fontSize: 15, height: 1.4)),
                      const SizedBox(height: 8),
                      Row(children: [
                        Text('$countdown 秒后自动发送',
                            style: const TextStyle(
                                color: Colors.white70, fontSize: 12)),
                        const Spacer(),
                        TextButton(
                          onPressed: session.cancelAutoSend,
                          child: const Text('取消',
                              style: TextStyle(color: Colors.white)),
                        ),
                        TextButton(
                          onPressed: () => session.retry(),
                          child: const Text('重说',
                              style: TextStyle(color: Colors.lightBlueAccent)),
                        ),
                      ]),
                    ],
                  );
                }
                // 聆听态：增量 partial。
                return ValueListenableBuilder<String>(
                  valueListenable: session.partial,
                  builder: (_, text, ___) => Row(
                    children: [
                      const Icon(Icons.mic, color: Colors.lightBlueAccent,
                          size: 20),
                      const SizedBox(width: 8),
                      Expanded(
                        child: Text(
                          text.isEmpty ? '请说话…（说完停顿即可）' : text,
                          style: const TextStyle(
                              color: Colors.white, fontSize: 15, height: 1.4),
                        ),
                      ),
                      TextButton(
                        onPressed: () => session.stop(),
                        child: const Text('结束',
                            style: TextStyle(color: Colors.white)),
                      ),
                    ],
                  ),
                );
              },
            ),
          ),
        ],
      ),
    );
  }
}
