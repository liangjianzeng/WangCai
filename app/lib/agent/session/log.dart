

import 'dart:async';

import '../../models/chat_message.dart' show ChatMessage, InferenceStats, MessageRole;
import 'event.dart';

/// 影子区（DSH 表面替换遮蔽区）：[startSeq..endSeq]（含）被一次
/// compaction summary 遮蔽/替换。
final class ShadowRange {
  final int startSeq;
  final int endSeq;
  final int summarySeq;

  ShadowRange({required this.startSeq, required this.endSeq, required this.summarySeq});

  bool covers(int seq) => seq >= startSeq && seq <= endSeq;
}

/// 会话事件日志 —— Phase 0 唯一真相源。
///
/// 对照 DSH `SessionLog`（Part 4）：append-only，seq 严格递增，
/// 压缩/崩溃修复全用「追加 + replace 遮蔽」表达，无 delete 原语。
///
/// 不变量（设计文档 §14）：
/// 1. seq 严格递增；
/// 2. tool/result 的 source.callId 必须等于对应 assistant/message 中 tool-call 的 id；
/// 3. replace 遮蔽范围合法（startSeq <= endSeq）；
/// 4. replaceGeneration 仅在 replace 时递增（压缩「前进性」证明）。

final class SessionLog {
  final List<SessionEvent> _events;
  final List<ShadowRange> _shadowRanges;
  int _seq;
  int _replaceGen;
  final Set<int> _syntheticSeqs = {};

  SessionLog._({List<SessionEvent>? events})
      : _events = (events ?? []).toList(),
        _shadowRanges = <ShadowRange>[],
        _seq = events == null ? 0 : _maxSeq(events),
        _replaceGen = 0;

  /// 从事件列表构造（导入/测试）。
  factory SessionLog.fromEvents(List<SessionEvent> events) =>
      SessionLog._(events: events);

  /// 事件列表中的最大 seq（seq 递增，但用循环求 max 保证无序输入也正确）。
  static int _maxSeq(List<SessionEvent> events) {
    int m = 0;
    for (final e in events) {
      if (e.seq > m) m = e.seq;
    }
    return m;
  }

  // ---------------------------------------------------------------------------
  // 追加 / 代数
  // ---------------------------------------------------------------------------

  int get nextSeq => _seq + 1;
  int get lastSeq => _seq;

  int get eventsCount => _events.length;
  int get replaceGeneration => _replaceGen;

  /// 内容代数：任何 replace 递增（append 不变）。
  int get contentGeneration => _replaceGen;

  /// 内部事件（含结构/表面/log-only）。
  List<SessionEvent> get rawEvents => List.unmodifiable(_events);

  /// 事件广播流（Phase 6 UI 订阅）。append/replace 实时同步推送。
  ///
  /// sync: true —— 订阅者在 append 返回前即收到，保证与后续
  /// append 的顺序可见性（UI reducer 无竞态）。
  final StreamController<SessionEvent> _eventsCtrl =
      StreamController<SessionEvent>.broadcast(sync: true);

  Stream<SessionEvent> get events => _eventsCtrl.stream;

  /// 释放广播资源（会话销毁时调用；之后 append 不再推送）。
  void dispose() {
    _eventsCtrl.close();
  }

  /// 追加事件；返回新事件 seq。
  int append(String type, Map<String, dynamic> data, {
    Map<String, String>? source,
    String? surfaceOp,
    int? shadowsEndSeq,
    int? timeMs,
  }) {
    // 落盘前校验 payload（DSH snapshotJsonValue，Part 4.8 第 2 层）——fail-loud。
    sanitizePayload(data);
    final seq = _seq + 1;
    final event = SessionEvent(
      type: type,
      seq: seq,
      timeMs: timeMs ?? DateTime.now().millisecondsSinceEpoch,
      source: source,
      surfaceOp: surfaceOp,
      shadowsEndSeq: shadowsEndSeq,
      data: data,
    );
    _events.add(event);
    if (surfaceOp == 'replace') _replaceGen++;
    _seq = seq;
    if (!_eventsCtrl.isClosed) _eventsCtrl.add(event);
    return seq;
  }

  /// 表面替换（DSH `SurfaceOp: replace`）。
  ///
  /// 遮蔽 [startSeq..endSeq]（含）的表面区，用 [newContent]（摘要文本）
  /// 替换；追加一条 compaction/summary 事件（surfaceOp=replace）。
  /// 返回 advance（恒 1，>0 才允许 overflow 重试）。
  /// 调用方须保证 startSeq <= endSeq。
  int replace({
    required int startSeq,
    required int endSeq,
    required String newContent,
    String? summaryProvider,
    String? summaryModel,
    int? summaryMaxTokens,
    int? timeMs,
  }) {
    if (endSeq < startSeq) {
      throw ArgumentError(
          'replace: endSeq ($endSeq) 必须 >= startSeq ($startSeq)');
    }
    final now = DateTime.now().millisecondsSinceEpoch;
    final summarySeq = append(
      kEventCompactionSummary,
      <String, dynamic>{
        'content': newContent,
        if (summaryProvider != null) 'provider': summaryProvider,
        if (summaryModel != null) 'model': summaryModel,
        if (summaryMaxTokens != null) 'maxTokens': summaryMaxTokens,
      },
      source: <String, String>{}..['kind'] = 'model',
      surfaceOp: 'replace',
      shadowsEndSeq: endSeq,
      timeMs: timeMs ?? now,
    );
    // 影子区：startSeq..endSeq
    final range = ShadowRange(
        startSeq: startSeq, endSeq: endSeq, summarySeq: summarySeq);
    _shadowRanges.add(range);
    return 1;
  }

  /// 判断某事件是否被任一影子区遮蔽。
  bool isShadowed(int seq) {
    for (final r in _shadowRanges) {
      if (r.covers(seq)) return true;
    }
    return false;
  }

  // ---------------------------------------------------------------------------
  // 投影
  // ---------------------------------------------------------------------------

  /// 派生模型可见消息（DSH deriveMessages）——纯函数。
  ///
  /// 返回 role/content 对（engine messagesJson 可用）：
  /// - user/system message → {role:user, content}
  /// - assistant message  → {role:assistant, content, [tool_calls]}
  /// - user message       → {role:user, content}
  /// - system prompt      → {role:system, content}（本地引擎首条 system 位）
  /// - assistant message  → {role:assistant, content, [tool_calls]}
  /// - tool result        → {role:tool, tool_call_id, content}
  /// - compaction summary → {role:user, content}（影子区被它遮蔽）
  /// 结构事件/log-only 事件**不投影**；影子区内的表面事件被跳过（已压缩）。
  List<Map<String, dynamic>> deriveModelMessages() {
    final out = <Map<String, dynamic>>[];
    // system 事件恒置队首：每轮 agent 构造时才 append system，晚于导入的
    // 历史事件；若按事件序原样投影，第二轮起 system 落在消息中间，
    // OpenAI 兼容服务端直接 400 拒收（本地 chatml 也会被中段系统块污染）。
    final systemMsgs = <Map<String, dynamic>>[];
    // failure-note 每 (turn,step) 只投影最新一条：同一 step 连续重试多次时，
    // 旧失败原因已过时（模型只需要最终那次为什么失败），全量投影会撑上下文。
    final latestNoteSeq = <String, int>{};
    for (final e in _events) {
      if (e.type == kEventAssistantFailureNote) {
        latestNoteSeq['${e.data['turn']}:${e.data['step']}'] = e.seq;
      }
    }
    for (final e in _events) {
      if (isLogOnly(e.type)) continue;
      if (isShadowed(e.seq)) continue; // 已被压缩遮蔽
      switch (e.type) {
        case kEventSystemMessage:
          systemMsgs.add({
            'role': 'system',
            'content': e.data['content'] as String? ?? '',
          });
          break;
        case kEventUserMessage:
          out.add({
            'role': 'user',
            'content': e.data['content'] as String? ?? '',
            // API 路线视觉：adapter 按此键把图片转 image_url part；
            // 本地路线转换器只取 role/content，此键不透传给 native。
            if (e.data['imagePath'] is String)
              'imagePath': e.data['imagePath'] as String,
            // 多图（WP 多图上传）：API 路线全量发送；首张与 imagePath 重合，
            // adapter 需去重。
            if (e.data['imagePaths'] is List &&
                (e.data['imagePaths'] as List).isNotEmpty)
              'imagePaths': (e.data['imagePaths'] as List)
                  .map((p) => '$p')
                  .toList(),
          });
          break;
        case kEventAssistantMessage:
          final entry = <String, dynamic>{};
          entry['role'] = 'assistant';
          entry['content'] = e.data['content'] as String? ?? '';
          final calls = e.data['toolCalls'] as List<dynamic>?;
          if (calls != null && calls.isNotEmpty) {
            final tc = <Map<String, dynamic>>[];
            for (final c in calls) {
              if (c is Map<String, dynamic>) {
                tc.add({
                  'type': 'tool_call',
                  // 写入侧键是 call_id（_appendAssistant）；历史/导入数据可能
                  // 是 id。此前只读 id 导致配对 id 恒为空串——API 原生路线的
                  // role:tool 消息因此配不上 tool_calls（服务端 400）。
                  'id': (c['call_id'] as String?) ??
                      (c['id'] as String?) ??
                      '',
                  'function_name': c['function_name'] as String? ??
                      (c['name'] as String? ?? (c['function'] as Map<String, dynamic>?)?['name'] ?? ''),
                  // arguments 保留原始形式（协议解析出 Map 或 String）；
                  // 模型可见历史需与模型自身产出一致（prompt-JSON 中为对象）。
                  'arguments':
                      c['arguments'] ?? (c['function']?['arguments'] ?? const {}),
                });
              }
            }
            entry['tool_calls'] = tc;
          }
          out.add(entry);
          break;
        case kEventToolResult:
          out.add({
            'role': 'tool',
            'tool_call_id': e.data['callId'] as String? ?? '',
            // 投影剪枝（对照 DSH tool-result-pruner）：超长工具结果在**模型
            // 可见投影**里截成头+尾，原文仍在事件日志（UI 视图完整显示）。
            // 没有这层，API 档工具结果内联后永不裁剪，长会话历史无界增长。
            'content': _pruneToolResult(e.data['content'] as String? ?? ''),
          });
          break;
        case kEventCompactionSummary:
          out.add({'role': 'user', 'content': e.data['content'] as String? ?? ''});
          break;
        case kEventAssistantFailureNote:
          // 同一 (turn,step) 只留最新一条（见上方 latestNoteSeq 预扫描）。
          if (latestNoteSeq['${e.data['turn']}:${e.data['step']}'] != e.seq) {
            break;
          }
          out.add({
            'role': 'user',
            'content': '[上次尝试失败: ${e.data['code']}] '
                '${e.data['content'] ?? ''} '
                '先分析原因并修正输出（截断→精简、语法错→严格按格式），'
                '不要原样重发。',
          });
          break;
        default:
        // 结构事件（turn/step）不投影
      }
    }
    // system 恒在最前（见上方说明）；其余保持事件序。
    return <Map<String, dynamic>>[...systemMsgs, ...out];
  }

  // ---------------------------------------------------------------------------
  // 投影剪枝（对照 DSH tool-result-pruner，Phase E-ctx）
  // ---------------------------------------------------------------------------

  /// 单条工具结果的投影剪枝阈值（字符）。超过则模型只看到头/尾片段。
  static const int _pruneThreshold = 8192;
  static const int _pruneHead = 4096;
  static const int _pruneTail = 1024;

  /// 超长工具结果 → 头 4096 + 省略标记（含被省略字符数）+ 尾 1024。
  /// 只作用于模型可见投影：存储原文不动，UI 视图（deriveChatMessages）完整。
  static String _pruneToolResult(String content) {
    if (content.length <= _pruneThreshold) return content;
    final omitted = content.length - _pruneHead - _pruneTail;
    final head = content.substring(0, _pruneHead);
    final tail = content.substring(content.length - _pruneTail);
    return '$head\n[…中间省略 $omitted 字符，完整结果见会话日志…]\n$tail';
  }

  /// 派生 UI 视图（ChatMessage 投影）。
  /// user/assistant/compaction → ChatMessage；tool/result → assistant-role
  /// 「工具回执」消息（content=工具结果文本）。
  List<ChatMessage> deriveChatMessages() {
    final out = <ChatMessage>[];
    for (final e in _events) {
      if (isLogOnly(e.type)) continue;
      if (isShadowed(e.seq)) continue;
      switch (e.type) {
        case kEventUserMessage:
        case kEventSystemMessage:
          out.add(ChatMessage(
            id: 'msg-${e.seq}',
            conversationId: '',
            role: MessageRole.user,
            content: e.data['content'] as String? ?? '',
            timestamp: DateTime.fromMillisecondsSinceEpoch(e.timeMs),
          ));
          break;
        case kEventAssistantMessage:
          out.add(ChatMessage(
            id: 'msg-${e.seq}',
            conversationId: '',
            role: MessageRole.assistant,
            content: e.data['content'] as String? ?? '',
            imagePath: e.data['imagePath'] as String?,
            audioPath: e.data['audioPath'] as String?,
            timestamp: DateTime.fromMillisecondsSinceEpoch(e.timeMs),
            inferenceStats: _parseStats(e.data['stats'] as Map<String, dynamic>?),
          ));
          break;
        case kEventToolResult:
          out.add(ChatMessage(
            id: 'msg-${e.seq}',
            conversationId: '',
            role: MessageRole.assistant,
            content: e.data['content'] as String? ?? '',
            timestamp: DateTime.fromMillisecondsSinceEpoch(e.timeMs),
            inferenceStats: InferenceStats(
                firstTokenMs: 0,
                totalMs: 0,
                tokPerSec: 0,
            ),
          ));
          break;
        case kEventCompactionSummary:
          out.add(ChatMessage(
            id: 'msg-${e.seq}',
            conversationId: '',
            role: MessageRole.user,
            content: '[上下文已压缩] ${e.data['content'] as String? ?? ''}',
            timestamp: DateTime.fromMillisecondsSinceEpoch(e.timeMs),
          ));
          break;
        default:
      }
    }
    return out;
  }

  // ---------------------------------------------------------------------------
  // 崩溃修复（DSH Part 3.12）
  // ---------------------------------------------------------------------------

  /// 扫描日志，对未闭合的 turn/step/工具调用追加合成事件（closeOpenTurns）。
  ///
  /// 不修改已有事件，只在尾部追加合成事件；时间戳复用最后一条真实事件的
  /// 时间戳（不伪造），seq 顺延。返回本次追加的合成事件数。
  int closeOpenTurns({String cause = 'interrupted'}) {
    if (_events.isEmpty) return 0;
    final lastTime = _lastRealEventTime();

    int openTurn = -1;
    int openStep = -1;
    final pendingCalls = <String, Map<String, dynamic>>{};

    for (final e in _events) {
      switch (e.type) {
        case kEventTurnStart:
          openTurn = e.data['turn'] as int? ?? -1;
          openStep = -1;
          pendingCalls.clear();
          break;
        case kEventTurnEnd:
          openTurn = -1;
          openStep = -1;
          pendingCalls.clear();
          break;
        case kEventStepStart:
          openStep = e.data['step'] as int? ?? -1;
          break;
        case kEventStepEnd:
          openStep = -1;
          pendingCalls.clear();
          break;
        case kEventAssistantMessage:
          final calls = e.data['toolCalls'] as List<dynamic>?;
          if (calls != null) {
            for (final c in calls) {
              if (c is Map<String, dynamic>) {
                // 写入侧键是 call_id（_appendAssistant）；导入/历史数据可能是 id。
                final id = (c['call_id'] as String?) ??
                    (c['id'] as String?) ??
                    '';
                if (id != '') {
                  pendingCalls[id] = {
                    'callId': id,
                    'step': e.data['step'] as int? ?? -1,
                    'callSeq': null,
                  };
                }
              }
            }
          }
          break;
        case kEventToolCall:
          final cid = e.data['callId'] as String? ?? '';
          if (cid != '') {
            pendingCalls[cid] = {
              'callId': cid,
              'step': e.data['step'] as int? ?? -1,
              'callSeq': e.seq,
            };
          }
          break;
        case kEventToolResult:
          pendingCalls.remove(e.data['callId'] as String?);
          break;
        default:
      }
    }

    var count = 0;

    // 补未销账的工具调用结果（区分 started/notStarted）
    for (final pc in pendingCalls.values) {
      count = _appendSyntheticToolResult(pc, lastTime) + count;
    }
    if (count > 0) {
      // 已合成，无需再处理
    }

    // 补 step/end
    if (openStep != -1) {
      final s = append(
        kEventStepEnd,
        {'turn': openTurn, 'step': openStep},
        timeMs: lastTime,
      );
      _syntheticSeqs.add(s);
      count++;
    }

    // 补 turn/end
    if (openTurn != -1) {
      final s = append(
        kEventTurnEnd,
        {'turn': openTurn, 'reason': {'kind': cause}},
        timeMs: lastTime,
      );
      _syntheticSeqs.add(s);
      count++;
    }
    return count;
  }

  int _lastRealEventTime() {
    // 最后一条非 ignorable 事件的时间戳；无则当前。
    for (var i = _events.length - 1; i >= 0; i--) {
      if (!_events[i].isIgnorable) return _events[i].timeMs;
    }
    return _events.isEmpty ? 0 : _events[0].timeMs;
  }

  /// 追加一条合成工具结果；返回 1。
  int _appendSyntheticToolResult(Map<String, dynamic> pc, int lastTime) {
    final started = pc['callSeq'] != null;
    final turn = pc['turn'] as int? ?? -1;
    final content = started
        ? 'The tool call was interrupted after it was started; its outcome is '
            'unknown. The tool may have partially executed with side effects. '
            'Please verify before retrying.'
        : 'The tool call was interrupted before it started; no execution occurred.';
    append(
      kEventToolResult,
      <String, dynamic>{
        'turn': turn,
        'step': pc['step'],
        'callId': pc['callId'],
        'name': '',
        'content': content,
        'isError': true,
      },
      source: <String, String>{}..['callId'] = (pc['callId'] as String? ?? ''),
      timeMs: lastTime,
    );
    return 1;
  }

  /// 本次修复追加的合成事件 seq（避免重复修复）。
  Set<int> get syntheticSeqs => Set.unmodifiable(_syntheticSeqs);
  bool get hasSyntheticClosers => _syntheticSeqs.isNotEmpty;

  InferenceStats? _parseStats(Map<String, dynamic>? stats) {
    if (stats == null) return null;
    return InferenceStats(
      firstTokenMs: (stats['firstTokenMs'] as num?)?.toInt() ?? 0,
      totalMs: (stats['totalMs'] as num?)?.toInt() ?? 0,
      tokPerSec: (stats['tokPerSec'] as num?)?.toDouble() ?? 0,
    );
  }
}