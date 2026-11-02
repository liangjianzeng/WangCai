import 'dart:convert';

/// 会话事件信封与事件词表 —— Phase 0 会话日志基础。
///
/// 对照 DSH `SessionEvent`（Part 4）：append-only 唯一真相源，
/// 所有行为（压缩/崩溃修复/重放）都变成日志原语。
///
/// 设计要点：
/// - [SessionEvent] 不可变；[seq] 会话内全局唯一、严格递增；
/// - [type] 用字符串（DSH 词表），便于未来跨 runtime 互通与版本演进；
/// - 事件分三类：结构（turn/step 边界，不进历史）、表面（user/assistant/tool/
///   system，进模型历史）、log-only（失败尝试/重试/溢写，不进模型历史但可审计）；
/// - [ignorable]：旧运行时可安全跳过（格式兼容键）。

// ---------------------------------------------------------------------------
// 事件类型常量（v1 词表；新增普通类型必须配 ignorable，否则升格式版本）
// ---------------------------------------------------------------------------

// 结构事件（turn/step 边界；不进模型历史；崩溃修复依据）
const String kEventTurnStart = 'turn/start';
const String kEventTurnEnd = 'turn/end';
const String kEventStepStart = 'step/start';
const String kEventStepEnd = 'step/end';

// 表面事件（进模型历史；deriveModelMessages 投影）
const String kEventUserMessage = 'user/message';
const String kEventSystemMessage = 'system/message';
const String kEventAssistantMessage = 'assistant/message';
const String kEventToolCall = 'tool/call';
const String kEventToolResult = 'tool/result';
const String kEventCompactionSummary = 'compaction/summary';

/// 失败反思注记（WP1b）：LLM 重试前注入的"上次为什么失败"提示。
/// surface（进模型历史）但 ignorable（旧运行时跳过只少一条提示，
/// 不致语义残缺——满足"新增普通类型必须配 ignorable"的 v1 兼容门槛）。
const String kEventAssistantFailureNote = 'assistant/failure-note';

// log-only 事件（不进模型历史；UI/诊断可用；崩溃修复参与 pending 销账）
const String kEventAssistantAttempt = 'assistant/attempt';
const String kEventLlmRetry = 'llm/retry';
const String kEventLlmRetryStarted = 'llm/retry-started';
const String kEventSpillLocate = 'spill/locate';

// 导入迁移标记（旧 SQLite 会话导入时给每条消息附加；log-only）
const String kEventImported = 'imported';

// ---------------------------------------------------------------------------
// 事件类别（决定投影/忽略策略）
// ---------------------------------------------------------------------------

enum EventTypeCategory {
  /// 结构事件：turn/step 边界。不进模型历史，是崩溃修复的依据。
  structural,

  /// 表面事件：进模型历史（user/assistant/tool/system/compaction）。
  surface,

  /// log-only 事件：失败尝试/重试/溢写/导入标记。不进模型历史，可审计。
  logOnly,
}

/// 各事件类型的类别。未登记的新类型默认 [logOnly]（安全：不污染模型历史）。
const Map<String, EventTypeCategory> kEventCategory = {
  kEventTurnStart: EventTypeCategory.structural,
  kEventTurnEnd: EventTypeCategory.structural,
  kEventStepStart: EventTypeCategory.structural,
  kEventStepEnd: EventTypeCategory.structural,
  kEventUserMessage: EventTypeCategory.surface,
  kEventSystemMessage: EventTypeCategory.surface,
  kEventAssistantMessage: EventTypeCategory.surface,
  kEventToolCall: EventTypeCategory.surface,
  kEventToolResult: EventTypeCategory.surface,
  kEventCompactionSummary: EventTypeCategory.surface,
  kEventAssistantFailureNote: EventTypeCategory.surface,
  kEventAssistantAttempt: EventTypeCategory.logOnly,
  kEventLlmRetry: EventTypeCategory.logOnly,
  kEventLlmRetryStarted: EventTypeCategory.logOnly,
  kEventSpillLocate: EventTypeCategory.logOnly,
  kEventImported: EventTypeCategory.logOnly,
};

EventTypeCategory categoryOf(String type) =>
    kEventCategory[type] ?? EventTypeCategory.logOnly;

bool isStructural(String type) => categoryOf(type) == EventTypeCategory.structural;
bool isSurface(String type) => categoryOf(type) == EventTypeCategory.surface;
bool isLogOnly(String type) => categoryOf(type) == EventTypeCategory.logOnly;

/// 该事件类型是否「可忽略」。
///
/// 含义（DSH Part 5.6）：旧运行时遇到它时应**安全跳过**而非拒绝整个会话。
/// - log-only 类型全为 true（失败尝试/重试/溢写/导入标记不影响模型重建）；
/// - 结构类型全为 false（turn/step 边界缺失会导致语义残缺，须修复而非忽略）；
/// - 表面类型全为 false（进模型历史的事件缺失会改变重建结果）。
const Set<String> kIgnorableTypes = {
  kEventAssistantAttempt,
  kEventLlmRetry,
  kEventLlmRetryStarted,
  kEventSpillLocate,
  kEventImported,
  kEventAssistantFailureNote,
};

bool ignorableOf(String type) => kIgnorableTypes.contains(type);

/// 会话格式版本号。
///
/// 升版本门槛（DSH Part 5.6）：旧运行时**会静默读错**新日志才升版本；
/// 加可选属性 / 加带 `ignorable` 的普通事件 → 同版本；
/// 加必选属性 / 改 header / 删改名 → 升版本并写迁移边。
const int kSessionFormatVersion = 1;

/// 日志 header 行（首行），独立于事件行。
final class SessionHeader {
  final int version;
  final String conversationId;
  final int createdAtMs;

  SessionHeader({
    required this.version,
    required this.conversationId,
    required this.createdAtMs,
  });

  String toJson() =>
      '{"version":$version,"conversationId":"${_escape(conversationId)}","createdAt":$createdAtMs}';

  factory SessionHeader.fromJson(Map<String, dynamic> m) => SessionHeader(
        version: (m['version'] as num?)?.toInt() ?? kSessionFormatVersion,
        conversationId: (m['conversationId'] as String?) ?? '',
        createdAtMs: (m['createdAt'] as num?)?.toInt() ??
            DateTime.now().millisecondsSinceEpoch,
      );

  /// 当前 reader 能否完整读取该 header。
  bool canBeReadBy(int readerVersion) => version <= readerVersion;
}

/// 简单的 JSON 字符串转义（用于手写 header）。
String _escape(String s) =>
    s.replaceAll('\\', '\\\\').replaceAll('"', '\\"').replaceAll('\n', '\\n').replaceAll('\r', '\\r');

/// 一次会话事件的不可变信封（append-only 写入，永不原地改写）。
final class SessionEvent {
  final String type;
  /// 会话内全局唯一、严格递增的序列号（从 1 起）。
  final int seq;
  /// 事件产生时间（epoch millis）。崩溃修复时复用最后一条真实事件的时间戳（不伪造）。
  final int timeMs;
  /// 来源自证（DSH Part 4.7）。
  /// - tool/result：{kind:'tool', callId:'...'}
  /// - assistant/message：{kind:'model', provider:'...', model:'...'}
  /// - user/message：{kind:'user'}
  /// - 导入：{kind:'import'}
  final Map<String, String>? source;
  /// 表面操作。`append`（默认）或 `replace`（遮蔽声明）。
  final String? surfaceOp;
  /// 若 `surfaceOp == 'replace'`：遮蔽到哪个 seq（含）。
  final int? shadowsEndSeq;
  /// 类型特定载荷。落盘前须过 [sanitizePayload] 校验（拒绝非法 JSON 值）。
  final Map<String, dynamic> data;
  /// 旧运行时可否安全跳过（ignorable）。
  final bool? ignorable;

  SessionEvent({
    required this.type,
    required this.seq,
    required this.timeMs,
    this.source,
    this.surfaceOp,
    this.shadowsEndSeq,
    required this.data,
  }) : ignorable = ignorableOf(type);

  DateTime get time =>
      DateTime.fromMillisecondsSinceEpoch(timeMs).toUtc().toLocal();

  bool get isIgnorable => ignorable ?? false;
  bool get isReplace => surfaceOp == 'replace';

  /// 事件 → JSON 行（一行一个事件，DSH 的 JSONL 帧）。
  String toJsonLine() {
    final body = <String, dynamic>{
      'type': type,
      'seq': seq,
      'time': timeMs,
      'data': data,
    };
    if (source != null) body['source'] = source;
    if (surfaceOp != null) body['surfaceOp'] = surfaceOp;
    if (shadowsEndSeq != null) body['shadowsEndSeq'] = shadowsEndSeq;
    if (ignorable != null) body['ignorable'] = ignorable;
    return jsonEncode(body);
  }

  static SessionEvent? fromJsonLine(String line) {
    final t = line.trim();
    if (t.isEmpty) return null;
    Map<String, dynamic>? m;
    try {
      m = jsonDecode(t) as Map<String, dynamic>;
    } on FormatException {
      return null;
    }
    final type = m['type'] as String?;
    final seq = m['seq'] as int?;
    final timeMs = m['time'] as int?;
    if (type == null || seq == null || timeMs == null) return null;
    return SessionEvent(
      type: type,
      seq: seq,
      timeMs: timeMs,
      source: (m['source'] as Map<String, dynamic>?)?.cast<String, String>(),
      surfaceOp: m['surfaceOp'] as String?,
      shadowsEndSeq: m['shadowsEndSeq'] as int?,
      data: (m['data'] as Map<String, dynamic>?) ?? {},
    );
  }
}

/// 将任意 payload 转成可安全落盘/序列化的 JSON。
///
/// 对照 DSH `snapshotJsonValue`（Part 4.8）：拒绝
/// 非有限数、循环引用、class 实例等。用 JSON-encode 兜底——
/// `jsonEncode` 对 Map/List 递归序列化，对非 JSON 值（如 Set）会抛异常，恰好 fail-loud。
Map<String, dynamic> sanitizePayload(Map<String, dynamic> payload) {
  // 直接尝试编码；非法值（Set/非 JSON 值）会在此抛 ArgumentError。
  jsonEncode(payload);
  return payload;
}

/// 判断一行是否为 header 行（首行）。
bool isHeaderLine(String line) {
  final t = line.trim();
  if (t.isEmpty || !t.startsWith('{')) return false;
  try {
    final m = jsonDecode(t) as Map<String, dynamic>;
    return m.containsKey('conversationId') && m['version'] != null;
  } on FormatException {
    return false;
  }
}

/// 将一行解析成 [SessionHeader] 或 [SessionEvent]。返回 null 表示无法识别。
SessionHeader? parseHeaderLine(String line) {
  if (!isHeaderLine(line)) return null;
  Map<String, dynamic>? m;
  try {
    m = jsonDecode(line.trim()) as Map<String, dynamic>;
  } on FormatException {
    return null;
  }
  return SessionHeader.fromJson(m);
}

/// 将一行解析成 [SessionEvent]；失败返回 null。
SessionEvent? parseEventLine(String line) {
  if (isHeaderLine(line)) return null;
  return SessionEvent.fromJsonLine(line);
}