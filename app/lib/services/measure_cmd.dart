// ============================================================
// MeasureCmdProbe — 免点击「测量命令口」（仅 debug 构建，性能取证用）
//
// 通道（决策档 §12.17）：宿主机 `adb push` 一个命令文件到外部目录
//   /storage/emulated/0/TongYiLite/measure_cmd.json
// 本挂件挂在 providers 之下，每 2 秒看一眼该文件；读到就执行
// 「加载模型 + 发一条 prompt」，全程不碰屏幕，结果写同目录
//   measure_ack.json
// 该目录 App 本来就在读写（模型清单 / vk_flags.conf），无需新权限。
//
// 判读方式：
//   * ack 里 tCmdSeen / tLoadDone / tSendReturn 三个毫秒时间戳
//     ⇒ load_ms = tLoadDone − tCmdSeen（加载耗时），
//       send_ms = tSendReturn − tLoadDone（发消息到返回的整回合耗时）；
//   * logcat 里一行 ASCII：`adb logcat | grep '\[measure\] ack'`
//     ⇒ `[measure] ack tag=run01 ok=true load_ms=8123 send_ms=15032`；
//   * 命令文件处理完即删（成功/失败都删），重启 App 不会重放旧命令；
//     开跑前先把上一次的 ack 删掉，宿主机只需轮询「ack 出现」。
//
// 静默约定：文件不存在时**一行日志都不打**（2s 一轮会把 logcat 淹掉），
// 真读到命令才打 `[measure] ...`。整条链路包 try/catch，任何异常只打
// `[measure] 失败: $e`，绝不让 App 崩。
//
// release 零行为变化：`kDebugMode` 是编译期常量，为假时不建 Timer、
// 不碰文件系统、build 直接返回空挂件；main.dart 的插入点同样短路。
// ============================================================

import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/foundation.dart' show debugPrint, kDebugMode;
import 'package:flutter/widgets.dart' show BuildContext, SizedBox, Widget;
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../providers/index.dart'
    show
        chatNotifierProvider,
        conversationsProvider,
        currentConversationIdProvider,
        modelManagerProvider;

/// 命令 / 回执目录：与模型清单、vk_flags.conf 同一外部目录（App 已有读写权限）。
const String kMeasureDir = '/storage/emulated/0/TongYiLite';

/// 宿主机写入的命令文件：
/// `{"modelId":"<catalog id>","prompt":"<文本>","tag":"<标识>","timeoutMs":600000}`
const String kMeasureCmdPath = '$kMeasureDir/measure_cmd.json';

/// App 写回的回执文件（字段见 [_writeAck]）。
const String kMeasureAckPath = '$kMeasureDir/measure_ack.json';

/// 轮询间隔：2 秒足够覆盖 adb push 的落地延迟，又不至于空转 IO。
const Duration _kPollInterval = Duration(seconds: 2);

/// 命令未给 timeoutMs 时的整条链路预算（加载 + 发送）。
const int _kDefaultTimeoutMs = 600000;

/// 命令文件连续多少轮「内容不变且解析失败」才判为坏文件（≈10 秒）。
/// adb push 是边写边落地的，半包解析必然失败——先静默等它写完。
const int _kBadJsonStreak = 5;

/// 等待 `ModelManagerNotifier._isBusy` 复位时的重试步长。
const Duration _kBusyRetryInterval = Duration(milliseconds: 200);

int _nowMs() => DateTime.now().millisecondsSinceEpoch;

/// 测量命令轮询挂件（无 UI）。只在 [kDebugMode] 下起表。
class MeasureCmdProbe extends ConsumerStatefulWidget {
  const MeasureCmdProbe({super.key});

  @override
  ConsumerState<MeasureCmdProbe> createState() => _MeasureCmdProbeState();
}

class _MeasureCmdProbeState extends ConsumerState<MeasureCmdProbe> {
  Timer? _timer;

  /// 在途标志：含等待加载的整条链路。轮询命中它直接返回，绝不重入。
  bool _inFlight = false;

  /// 上一轮读到的坏 JSON 原文与连续次数（半包 / 坏文件的判据）。
  String? _lastBadRaw;
  int _badStreak = 0;

  @override
  void initState() {
    super.initState();
    // release（含 profile）与非 Android：不建表——这条路径上没有任何 IO。
    if (!kDebugMode || !Platform.isAndroid) return;
    _timer = Timer.periodic(_kPollInterval, (_) => _poll());
  }

  @override
  void dispose() {
    _timer?.cancel();
    _timer = null;
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => const SizedBox.shrink();

  Future<void> _poll() async {
    if (!mounted || _inFlight) return;
    final raw = await _readCmdRaw();
    if (raw == null) return; // 没有命令：静默，什么都不做

    Map<String, dynamic>? cmd;
    try {
      final decoded = jsonDecode(raw);
      cmd = decoded is Map<String, dynamic> ? decoded : null;
    } catch (_) {
      cmd = null;
    }
    if (cmd == null) {
      // 解析失败：先当「adb push 还在写」静默重试；内容连着多轮不变才判死，
      // 落一条失败 ack 并删除，免得一个坏文件被每 2 秒重放一次。
      if (raw == _lastBadRaw) {
        _badStreak++;
      } else {
        _lastBadRaw = raw;
        _badStreak = 1;
      }
      if (_badStreak < _kBadJsonStreak) return;
      _badStreak = 0;
      _lastBadRaw = null;
      final seen = _nowMs();
      debugPrint('[measure] 失败: 命令文件不是合法 JSON（$kMeasureCmdPath）');
      await _writeAck(
        tag: '',
        ok: false,
        modelId: '',
        promptChars: 0,
        tCmdSeen: seen,
        error: 'bad_json',
      );
      await _deleteCmd();
      return;
    }
    _badStreak = 0;
    _lastBadRaw = null;

    _inFlight = true;
    final tCmdSeen = _nowMs();
    final tag = (cmd['tag'] ?? '').toString();
    final modelId = (cmd['modelId'] ?? '').toString();
    final prompt = (cmd['prompt'] ?? '').toString();
    final timeoutMs = cmd['timeoutMs'] is num
        ? (cmd['timeoutMs'] as num).toInt()
        : int.tryParse('${cmd['timeoutMs']}') ?? _kDefaultTimeoutMs;
    debugPrint('[measure] cmd tag=$tag model=$modelId '
        'promptChars=${prompt.length} timeoutMs=$timeoutMs');
    // 先清掉上一轮回执：宿主机只轮询「ack 出现」即可确认是本条命令的结果。
    await _deleteAck();

    final budget = timeoutMs > 0 ? timeoutMs : _kDefaultTimeoutMs;
    final deadline = tCmdSeen + budget;
    var ok = false;
    String? error;
    int? tLoadDone;
    int? tSendReturn;
    try {
      if (modelId.isEmpty) {
        error = 'missing_model_id';
      } else if (prompt.trim().isEmpty) {
        error = 'missing_prompt';
      } else {
        // 1) 加载模型（同模型已加载时 loadModel 内部直接返回 true）。
        final loaded = await _loadModel(modelId, deadline);
        if (loaded == null) {
          error = 'load_timeout';
        } else if (!loaded) {
          error = 'load_failed';
        } else {
          tLoadDone = _nowMs();
          // 2) 发消息：会话 id / notifier 的取法照抄 home_screen
          //    （_setCurrentConversation + chatNotifierProvider.notifier）。
          //    路由（本地 / API / 智能体）由当前设置决定，与 UI 手动发送一致。
          final conversationId = await _resolveConversationId();
          if (conversationId.isEmpty) {
            error = 'no_conversation';
          } else {
            final remain = deadline - _nowMs();
            if (remain <= 0) {
              error = 'send_timeout';
            } else {
              try {
                await ref
                    .read(chatNotifierProvider.notifier)
                    .sendMessage(conversationId, prompt)
                    .timeout(Duration(milliseconds: remain));
                tSendReturn = _nowMs();
                ok = true;
              } on TimeoutException {
                // 原生回合无法从外部取消，超时的这一轮它会自己跑完；
                // 判读只认 ack：send_ms 记 -1、error=send_timeout。
                error = 'send_timeout';
              }
            }
          }
        }
      }
    } catch (e) {
      // 任何异常都只记账，绝不把 App 带崩。
      error = 'exception: $e';
      debugPrint('[measure] 失败: $e');
    } finally {
      await _writeAck(
        tag: tag,
        ok: ok,
        modelId: modelId,
        promptChars: prompt.length,
        tCmdSeen: tCmdSeen,
        tLoadDone: tLoadDone,
        tSendReturn: tSendReturn,
        error: error,
      );
      // 命令处理完即删：不删的话 2 秒后又会把同一条命令重放一遍。
      await _deleteCmd();
      _inFlight = false;
    }
  }

  /// 读命令原文；文件不存在 / 读不到 / 空内容一律返回 null（静默）。
  Future<String?> _readCmdRaw() async {
    try {
      final file = File(kMeasureCmdPath);
      if (!file.existsSync()) return null;
      final raw = (await file.readAsString()).trim();
      return raw.isEmpty ? null : raw;
    } catch (_) {
      return null;
    }
  }

  /// 加载模型：true=成功，false=loadModel 判失败，null=超时（或挂件已销毁）。
  ///
  /// `loadModel` 在 `_isBusy`（如启动自动加载默认模型正在进行）时直接返回
  /// false —— 那是「别人正在加载」而不是本条命令失败，先等它复位再发起；
  /// 等待同样受整条链路的 deadline 约束。超时的加载无法从外部取消，它会
  /// 自己跑完，判读以 ack 的 error=load_timeout 为准。
  Future<bool?> _loadModel(String modelId, int deadline) async {
    if (!mounted) return null;
    final manager = ref.read(modelManagerProvider.notifier);
    while (manager.isBusy) {
      if (_nowMs() >= deadline || !mounted) return null;
      await Future<void>.delayed(_kBusyRetryInterval);
    }
    final remain = deadline - _nowMs();
    if (remain <= 0 || !mounted) return null;
    try {
      return await manager
          .loadModel(modelId)
          .timeout(Duration(milliseconds: remain));
    } on TimeoutException {
      return null;
    }
  }

  /// 拿「当前会话」的 id，姿势与 home_screen 一致：provider 里有就用；
  /// 没有（还没进过首页 / 列表为空）就按 `_initConversation` 那套先
  /// ensureLoaded、空则建一条，再镜像进 [currentConversationIdProvider]
  /// （同 `_setCurrentConversation`，保持「哪一串是当前会话」只有一个真源）。
  Future<String> _resolveConversationId() async {
    if (!mounted) return '';
    final existing = ref.read(currentConversationIdProvider);
    if (existing != null && existing.isNotEmpty) return existing;

    final notifier = ref.read(conversationsProvider.notifier);
    await notifier.ensureLoaded();
    var conversations = ref.read(conversationsProvider);
    if (conversations.isEmpty) {
      await notifier.create();
      conversations = ref.read(conversationsProvider);
    }
    if (conversations.isEmpty) return '';
    final id = conversations.first.id;
    ref.read(currentConversationIdProvider.notifier).state = id;
    return id;
  }

  /// 写回执（先写 .tmp 再 rename，宿主机轮询不会读到半包）。
  Future<void> _writeAck({
    required String tag,
    required bool ok,
    required String modelId,
    required int promptChars,
    required int tCmdSeen,
    int? tLoadDone,
    int? tSendReturn,
    String? error,
  }) async {
    try {
      final dir = Directory(kMeasureDir);
      if (!dir.existsSync()) dir.createSync(recursive: true);
      final tmp = File('$kMeasureAckPath.tmp');
      await tmp.writeAsString(jsonEncode(<String, dynamic>{
        'tag': tag,
        'ok': ok,
        'modelId': modelId,
        'promptChars': promptChars,
        'tCmdSeen': tCmdSeen,
        'tLoadDone': tLoadDone,
        'tSendReturn': tSendReturn,
        'error': error,
      }));
      await tmp.rename(kMeasureAckPath);
      // 一行 ASCII，便于 `adb logcat | grep '[measure] ack'` 直接判读。
      final loadMs = tLoadDone == null ? -1 : tLoadDone - tCmdSeen;
      final sendMs = (tLoadDone == null || tSendReturn == null)
          ? -1
          : tSendReturn - tLoadDone;
      debugPrint('[measure] ack tag=$tag ok=$ok load_ms=$loadMs '
          'send_ms=$sendMs error=${error ?? 'none'}');
    } catch (e) {
      debugPrint('[measure] 失败: 回执写入失败 $e');
    }
  }

  Future<void> _deleteCmd() async {
    try {
      final file = File(kMeasureCmdPath);
      if (file.existsSync()) await file.delete();
    } catch (e) {
      debugPrint('[measure] 失败: 命令文件删除失败 $e');
    }
  }

  Future<void> _deleteAck() async {
    try {
      final file = File(kMeasureAckPath);
      if (file.existsSync()) await file.delete();
    } catch (_) {
      // 删不掉旧回执不影响测量本身，静默。
    }
  }
}
