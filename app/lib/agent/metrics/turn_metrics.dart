/// 回合级执行指标（P0 遥测）—— 从 SessionLog 事件流**纯派生**。
///
/// 设计原则：循环零侵入。指标不从 ReactLoopAgent 内部计数器来，而是回合
/// 结束后扫描该 turn 的日志事件区间统计——llm/retry、assistant/attempt、
/// tool/call、compaction/summary 等事件本身就是事实记录，日志即指标源。
///
/// 用途：回答「智能体笨在哪一段」——截断/重试多？撞步数上限？重复调用
/// 不收敛？压缩频繁？数据落 JSONL（`ApplicationSupport/metrics/`），真机
/// 跑几天后 pull 回来聚合，所有执行质量优化都有了度量基线。
library;

import 'dart:convert';
import 'dart:io';

import '../session/session.dart';

/// 一个回合的执行指标快照。
class TurnMetrics {
  /// 回合号（会话内从 1 起）。
  final int turn;

  final int startedAtMs;
  final int endedAtMs;

  /// turn/end 原因（completed/error/interrupted/maxSteps/blocked/user）。
  final String endReason;

  /// 模型请求步数（step/start 计数）。
  final int steps;

  /// 工具调用次数（tool/call 计数，含被去重回缓的重复调用）。
  final int toolCalls;

  /// 完全同签名（name+args）的重复调用次数。
  final int duplicateToolCalls;

  /// 触发渐进提醒（3/5/8 次重复守护）的次数。
  final int repeatReminders;

  /// LLM 有界重试次数（llm/retry 计数）。
  final int llmRetries;

  /// 失败码计数（assistant/attempt + llm/retry 的 code 合并）。
  final Map<String, int> failureCodes;

  /// 压缩（compaction/summary）次数。
  final int compactions;

  const TurnMetrics({
    required this.turn,
    required this.startedAtMs,
    required this.endedAtMs,
    required this.endReason,
    required this.steps,
    required this.toolCalls,
    required this.duplicateToolCalls,
    required this.repeatReminders,
    required this.llmRetries,
    required this.failureCodes,
    required this.compactions,
  });

  int get durationMs => endedAtMs - startedAtMs;
  bool get maxStepsHit => endReason == 'maxSteps';
  bool get interrupted => endReason == 'interrupted';
  bool get failed => endReason == 'error';

  Map<String, dynamic> toJson() => {
        'turn': turn,
        'startedAt': startedAtMs,
        'endedAt': endedAtMs,
        'durationMs': durationMs,
        'endReason': endReason,
        'steps': steps,
        'toolCalls': toolCalls,
        'duplicateToolCalls': duplicateToolCalls,
        'repeatReminders': repeatReminders,
        'llmRetries': llmRetries,
        'failureCodes': failureCodes,
        'compactions': compactions,
      };

  factory TurnMetrics.fromJson(Map<String, dynamic> m) => TurnMetrics(
        turn: (m['turn'] as num?)?.toInt() ?? 0,
        startedAtMs: (m['startedAt'] as num?)?.toInt() ?? 0,
        endedAtMs: (m['endedAt'] as num?)?.toInt() ?? 0,
        endReason: m['endReason'] as String? ?? 'unknown',
        steps: (m['steps'] as num?)?.toInt() ?? 0,
        toolCalls: (m['toolCalls'] as num?)?.toInt() ?? 0,
        duplicateToolCalls: (m['duplicateToolCalls'] as num?)?.toInt() ?? 0,
        repeatReminders: (m['repeatReminders'] as num?)?.toInt() ?? 0,
        llmRetries: (m['llmRetries'] as num?)?.toInt() ?? 0,
        failureCodes:
            (m['failureCodes'] as Map<String, dynamic>?)?.cast<String, int>() ??
                const {},
        compactions: (m['compactions'] as num?)?.toInt() ?? 0,
      );

  String toJsonLine() => jsonEncode(toJson());

  /// 从会话日志提取第 [turn] 回合的指标；该回合不存在（无 turn/start）
  /// 返回 null。事件区间 = turn/start(turn) 起至 turn/end(turn)（含）。
  static TurnMetrics? fromLog(SessionLog log, int turn) {
    SessionEvent? startEvent;
    SessionEvent? endEvent;
    final range = <SessionEvent>[];
    var inRange = false;
    for (final e in log.rawEvents) {
      if (e.type == kEventTurnStart && (e.data['turn'] as num?)?.toInt() == turn) {
        // 崩溃修复可能留下多个同名 turn/start；取第一个未闭合区间。
        if (!inRange) {
          inRange = true;
          startEvent = e;
          range.add(e);
          continue;
        }
      }
      if (!inRange) continue;
      range.add(e);
      if (e.type == kEventTurnEnd &&
          (e.data['turn'] as num?)?.toInt() == turn) {
        endEvent = e;
        break;
      }
    }
    if (startEvent == null) return null;

    var steps = 0;
    var toolCalls = 0;
    var repeatReminders = 0;
    var llmRetries = 0;
    var compactions = 0;
    final signatures = <String>{};
    var duplicateToolCalls = 0;
    final failureCodes = <String, int>{};

    void bumpFailure(String? code) {
      if (code == null || code.isEmpty) return;
      failureCodes[code] = (failureCodes[code] ?? 0) + 1;
    }

    for (final e in range) {
      switch (e.type) {
        case kEventStepStart:
          steps++;
          break;
        case kEventToolCall:
          toolCalls++;
          // 同签名重复 = name + 规范化参数 JSON（与循环去重同口径）。
          final sig = _signature(e.data['name'] as String?,
              e.data['arguments'] as Map<String, dynamic>?);
          if (!signatures.add(sig)) duplicateToolCalls++;
          break;
        case kEventToolResult:
          final content = e.data['content'];
          if (content is String && content.contains('[提醒：这是本回合第')) {
            repeatReminders++;
          }
          break;
        case kEventAssistantAttempt:
          bumpFailure(e.data['code'] as String?);
          break;
        case kEventLlmRetry:
          llmRetries++;
          bumpFailure(e.data['code'] as String?);
          break;
        case kEventCompactionSummary:
          compactions++;
          break;
        default:
          break;
      }
    }

    return TurnMetrics(
      turn: turn,
      startedAtMs: startEvent.timeMs,
      endedAtMs: endEvent?.timeMs ?? startEvent.timeMs,
      endReason: endEvent?.data['reason'] as String? ?? 'unclosed',
      steps: steps,
      toolCalls: toolCalls,
      duplicateToolCalls: duplicateToolCalls,
      repeatReminders: repeatReminders,
      llmRetries: llmRetries,
      failureCodes: failureCodes,
      compactions: compactions,
    );
  }

  /// 工具调用签名（与 ReactLoopAgent._toolCallSignature 同口径；
  /// 此处从日志事件的 arguments Map 出发）。
  static String _signature(String? name, Map<String, dynamic>? args) {
    var body = '';
    try {
      body = jsonEncode(args ?? const {});
    } on FormatException {
      body = '';
    } on ArgumentError {
      body = '';
    }
    return '${name ?? ''}#$body';
  }
}

/// 回合指标存储：JSONL 追加落盘 + 内存 ring 聚合。
///
/// [baseDir] 注入（生产 = ApplicationSupport/metrics，测试 = 临时目录），
/// agent 层不依赖 Flutter 插件。
class TurnMetricsStore {
  final String baseDir;
  final int maxInMemory;
  final List<TurnMetrics> _recent = [];

  TurnMetricsStore({required this.baseDir, this.maxInMemory = 500});

  File get _file => File('$baseDir/turn_metrics.jsonl');

  /// 记录一个回合；JSONL 追加（单行损坏不影响其他行），内存 ring 保留
  /// 最近 [maxInMemory] 条。
  Future<void> record(TurnMetrics m) async {
    _recent.add(m);
    if (_recent.length > maxInMemory) _recent.removeAt(0);
    final dir = Directory(baseDir);
    if (!await dir.exists()) await dir.create(recursive: true);
    await _file.writeAsString('${m.toJsonLine()}\n',
        mode: FileMode.append, flush: false);
  }

  /// 最近记录（内存 ring，时间序）。
  List<TurnMetrics> get recent => List.unmodifiable(_recent);

  /// 聚合摘要：按 endReason 分布 + 质量比值（重复率/重试率/撞限率）。
  /// [turns] 为空时返回全 0 摘要。
  Map<String, dynamic> aggregate() {
    var steps = 0, toolCalls = 0, duplicates = 0, retries = 0, reminders = 0;
    var totalMs = 0;
    final endReasons = <String, int>{};
    final failureCodes = <String, int>{};
    for (final m in _recent) {
      steps += m.steps;
      toolCalls += m.toolCalls;
      duplicates += m.duplicateToolCalls;
      retries += m.llmRetries;
      reminders += m.repeatReminders;
      totalMs += m.durationMs;
      endReasons[m.endReason] = (endReasons[m.endReason] ?? 0) + 1;
      m.failureCodes.forEach((k, v) => failureCodes[k] = (failureCodes[k] ?? 0) + v);
    }
    final n = _recent.length;
    return {
      'turns': n,
      'endReasons': endReasons,
      'avgSteps': n == 0 ? 0 : steps / n,
      'avgDurationMs': n == 0 ? 0 : totalMs / n,
      'toolCalls': toolCalls,
      'duplicateToolCalls': duplicates,
      'repeatReminders': reminders,
      'llmRetries': retries,
      'failureCodes': failureCodes,
    };
  }
}
