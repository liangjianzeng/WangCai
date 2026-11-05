import 'dart:convert';

enum MessageRole { user, assistant }

/// 消息类型（2026-10-25 对话区重构 P0）：过程痕迹从 content 字符串前缀
/// （🔧/💭/🔔…）升级为一等类型。**新消息一律写类型**；content 里的前缀串
/// 仅作旧版本渲染兼容保留。历史脏数据无 kind 列时由 [_inferLegacyKind]
/// 按前缀推断，推断不出 = text。
enum MessageKind { text, toolActivity, thinking, notice, error, question }

MessageKind? _messageKindFromName(Object? name) {
  for (final k in MessageKind.values) {
    if (k.name == name) return k;
  }
  return null;
}

/// 旧前缀 → 类型推断（仅用于存量 DB 行；新代码不要再依赖前缀）。
/// 刻意**只映射旧过滤逻辑覆盖的前缀**（🔧/💭）：☑/📋/⚠️/🔔 等历史上按
/// 普通消息参与上下文/渲染，推断成特殊类型会静默改变行为——它们保持
/// text，由后续阶段逐步显式化。
MessageKind inferLegacyKind(String content) {
  if (content.startsWith('🔧TRACE')) return MessageKind.notice;
  if (content.startsWith('🔧')) return MessageKind.toolActivity;
  if (content.startsWith('💭')) return MessageKind.thinking;
  return MessageKind.text;
}

/// 工具活动单次调用的结构化数据（替代从 `🔧 name ✓summary` 字符串反解析）。
class ToolActivityData {
  /// 活动阶段：executing = 执行中（占位行）；done / failed = 终态。
  final String phase; // executing | done | failed
  final String name;

  /// 单行结果/参数摘要（UI 折叠行展示）。
  final String summary;

  /// 工具调用参数 JSON 原文（展开体 IN 段展示；null = 未捕获/旧数据）。
  final String? argsJson;

  /// 工具结果原文（展开体 OUT 段展示；截断策略由 UI 决定）。
  final String? resultText;
  final bool isError;

  /// 执行耗时（终态才有；null = 未知/旧数据）。
  final int? durationMs;

  const ToolActivityData({
    required this.phase,
    required this.name,
    this.summary = '',
    this.argsJson,
    this.resultText,
    this.isError = false,
    this.durationMs,
  });

  Map<String, dynamic> toMap() => {
        'phase': phase,
        'name': name,
        'summary': summary,
        'argsJson': argsJson,
        'resultText': resultText,
        'isError': isError,
        'durationMs': durationMs,
      };

  factory ToolActivityData.fromMap(Map<String, dynamic> map) =>
      ToolActivityData(
        phase: map['phase'] as String? ?? 'done',
        name: map['name'] as String? ?? '',
        summary: map['summary'] as String? ?? '',
        argsJson: map['argsJson'] as String?,
        resultText: map['resultText'] as String?,
        isError: map['isError'] as bool? ?? false,
        durationMs: (map['durationMs'] as num?)?.toInt(),
      );

  ToolActivityData copyWith({
    String? phase,
    String? summary,
    String? resultText,
    bool? isError,
    int? durationMs,
  }) =>
      ToolActivityData(
        phase: phase ?? this.phase,
        name: name,
        argsJson: argsJson ?? this.argsJson,
        summary: summary ?? this.summary,
        resultText: resultText ?? this.resultText,
        isError: isError ?? this.isError,
        durationMs: durationMs ?? this.durationMs,
      );
}

/// 解析消息 role：未知值（历史脏数据、将来新增的 role 如 system）回落为
/// user。此前多处用 `.first` 直接反序列化——一条脏消息就能让整个会话
/// 列表/消息读取抛 StateError 崩溃。
MessageRole messageRoleFromName(Object? name) {
  if (name == MessageRole.assistant.name) return MessageRole.assistant;
  return MessageRole.user;
}

/// 单次回复的性能统计（仅 assistant 消息有）。
class InferenceStats {
  final int firstTokenMs; // 首 token 延迟（发送到首个 token 的时间）
  final int totalMs;      // 总耗时
  final double tokPerSec; // 生成速率（token/秒）
  final int visionMs;     // 视觉编码耗时（仅视觉回复 >0）
  final int audioMs;      // 听音时间（音频编码耗时，仅语音回复 >0）

  const InferenceStats({
    required this.firstTokenMs,
    required this.totalMs,
    required this.tokPerSec,
    this.visionMs = 0,
    this.audioMs = 0,
  });

  Map<String, dynamic> toMap() => {
        'firstTokenMs': firstTokenMs,
        'totalMs': totalMs,
        'tokPerSec': tokPerSec,
        'visionMs': visionMs,
        'audioMs': audioMs,
      };

  factory InferenceStats.fromMap(Map<String, dynamic> map) => InferenceStats(
        firstTokenMs: (map['firstTokenMs'] as num?)?.toInt() ?? 0,
        totalMs: (map['totalMs'] as num?)?.toInt() ?? 0,
        tokPerSec: (map['tokPerSec'] as num?)?.toDouble() ?? 0,
        visionMs: (map['visionMs'] as num?)?.toInt() ?? 0,
        audioMs: (map['audioMs'] as num?)?.toInt() ?? 0,
      );
}

class ChatMessage {
  final String id;
  final String conversationId;
  final MessageRole role;
  final String content;
  final String? imagePath;

  /// 多图（WP 多图上传，≤10；[imagePath] 恒等于首张，兼容旧链路）。
  /// **用户视图**：UI（输入区预览/气泡/大图）永远展示这里的原图。
  final List<String>? imagePaths;

  /// **模型视图**（长图切块/缩放后的路径序列；null = 与 [imagePaths] 相同）。
  /// 切块是后端为视觉模型准备的输入细节，用户不应看到碎片——只有发给
  /// 模型（本地 JNI / API buildMessages / 智能体 kick）时才消费本字段。
  final List<String>? visionPaths;

  /// 智能体附件文件名列表（≤5；本体在 documents/uploads/<convId>/）。
  final List<String>? attachments;
  final String? audioPath;
  final DateTime timestamp;
  final bool isStreaming;
  final InferenceStats? inferenceStats;

  /// 消息类型（过程痕迹一等化，见 [MessageKind]）。
  final MessageKind kind;

  /// 工具活动结构化数据（kind == toolActivity 时可空 = 旧数据，UI 走
  /// content 前缀兼容渲染）。
  final ToolActivityData? toolData;

  /// notice / error 的机器码（turnTrace / compacted / retry / …）。
  final String? noticeCode;

  ChatMessage({
    required this.id,
    required this.conversationId,
    required this.role,
    required this.content,
    this.imagePath,
    List<String>? imagePaths,
    List<String>? visionPaths,
    this.attachments,
    this.audioPath,
    DateTime? timestamp,
    this.isStreaming = false,
    this.inferenceStats,
    MessageKind? kind,
    this.toolData,
    this.noticeCode,
  })  : kind = kind ??
            (toolData != null
                ? MessageKind.toolActivity
                : MessageKind.text),
        imagePaths = (imagePaths != null && imagePaths.isNotEmpty)
            ? imagePaths
            : (imagePath != null ? [imagePath] : null),
        visionPaths = (visionPaths != null && visionPaths.isNotEmpty)
            ? visionPaths
            : null,
        timestamp = timestamp ?? DateTime.now();

  /// 展示用类型规则：kind 列缺失的旧 DB 行在**读取层**（fromMap / storage
  /// 映射）按前缀推断后填充，运行期一律直接用 [kind]，不再做前缀兜底。
  static MessageKind resolveKind({
    required MessageKind? stored,
    required ToolActivityData? toolData,
    required String content,
  }) =>
      stored ??
      (toolData != null ? MessageKind.toolActivity : inferLegacyKind(content));

  /// 模型侧取图入口：有切块序列用切块，否则用原图。UI 展示禁用本 getter。
  List<String>? get modelImagePaths =>
      (visionPaths != null && visionPaths!.isNotEmpty) ? visionPaths : imagePaths;

  Map<String, dynamic> toMap() {
    return {
      'id': id,
      'conversationId': conversationId,
      'role': role.name,
      'content': content,
      'imagePath': imagePath,
      'imagePaths': imagePaths == null
          ? null
          : jsonEncode(imagePaths),
      'visionPaths': visionPaths == null
          ? null
          : jsonEncode(visionPaths),
      'attachments':
          attachments == null ? null : jsonEncode(attachments),
      'audioPath': audioPath,
      'timestamp': timestamp.millisecondsSinceEpoch,
      'isStreaming': isStreaming ? 1 : 0,
      'inferenceStats': inferenceStats?.toMap(),
      'kind': kind.name,
      'toolData': toolData == null ? null : jsonEncode(toolData!.toMap()),
      'noticeCode': noticeCode,
    };
  }

  factory ChatMessage.fromMap(Map<String, dynamic> map) {
    final stats = map['inferenceStats'];
    List<String>? _decodeList(Object? raw) {
      if (raw is! String || raw.isEmpty) return null;
      try {
        final decoded = jsonDecode(raw);
        if (decoded is List && decoded.isNotEmpty) {
          return decoded.map((e) => '$e').toList();
        }
      } catch (_) {}
      return null;
    }

    return ChatMessage(
      id: map['id'] as String,
      conversationId: map['conversationId'] as String,
      role: messageRoleFromName(map['role']),
      content: map['content'] as String,
      imagePath: map['imagePath'] as String?,
      imagePaths: _decodeList(map['imagePaths']),
      visionPaths: _decodeList(map['visionPaths']),
      attachments: _decodeList(map['attachments']),
      audioPath: map['audioPath'] as String?,
      timestamp: DateTime.fromMillisecondsSinceEpoch(map['timestamp'] as int),
      isStreaming: (map['isStreaming'] as int?) == 1,
      inferenceStats: stats is Map<String, dynamic> ? InferenceStats.fromMap(stats) : null,
      kind: resolveKind(
        stored: _messageKindFromName(map['kind']),
        toolData: _decodeToolData(map['toolData']),
        content: map['content'] as String? ?? '',
      ),
      toolData: _decodeToolData(map['toolData']),
      noticeCode: map['noticeCode'] as String?,
    );
  }

  static ToolActivityData? _decodeToolData(Object? raw) {
    if (raw is! String || raw.isEmpty) return null;
    try {
      final decoded = jsonDecode(raw);
      if (decoded is Map<String, dynamic>) return ToolActivityData.fromMap(decoded);
    } catch (_) {}
    return null;
  }

  ChatMessage copyWith({
    String? content,
    bool? isStreaming,
    InferenceStats? inferenceStats,
    List<String>? attachments,
    MessageKind? kind,
    ToolActivityData? toolData,
    String? noticeCode,
  }) {
    return ChatMessage(
      id: id,
      conversationId: conversationId,
      role: role,
      content: content ?? this.content,
      imagePath: imagePath,
      imagePaths: imagePaths,
      visionPaths: visionPaths,
      attachments: attachments ?? this.attachments,
      audioPath: audioPath,
      timestamp: timestamp,
      isStreaming: isStreaming ?? this.isStreaming,
      inferenceStats: inferenceStats ?? this.inferenceStats,
      kind: kind ?? this.kind,
      toolData: toolData ?? this.toolData,
      noticeCode: noticeCode ?? this.noticeCode,
    );
  }
}
