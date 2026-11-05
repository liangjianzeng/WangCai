class Conversation {
  final String id;
  final String title;
  final String modelId;

  /// 归属项目 id（v0.0.3 项目层级，SQLite v7 新列）。
  /// null = 未迁移的旧行，语义上等同内置默认项目（读取侧按此回落）。
  final String? projectId;
  final int messageCount;
  final DateTime createdAt;
  final DateTime updatedAt;

  /// 用户手动改过名 = 钉住（v0.0.4.1 DSH rename-pins 语义，SQLite v8 新列）：
  /// true 后自动命名（首条 prompt 推导/未来 LLM）都不得再改写标题。
  final bool titlePinned;

  Conversation({
    required this.id,
    required this.title,
    this.modelId = 'qwen3.5-2b-mtp-ud-q4_k_xl',
    this.projectId,
    this.messageCount = 0,
    this.titlePinned = false,
    DateTime? createdAt,
    DateTime? updatedAt,
  })  : createdAt = createdAt ?? DateTime.now(),
        updatedAt = updatedAt ?? DateTime.now();

  Map<String, dynamic> toMap() {
    return {
      'id': id,
      'title': title,
      'modelId': modelId,
      if (projectId != null) 'projectId': projectId,
      'messageCount': messageCount,
      'titlePinned': titlePinned ? 1 : 0,
      'createdAt': createdAt.millisecondsSinceEpoch,
      'updatedAt': updatedAt.millisecondsSinceEpoch,
    };
  }

  factory Conversation.fromMap(Map<String, dynamic> map) {
    return Conversation(
      id: map['id'] as String,
      title: map['title'] as String? ?? '',
      modelId: map['modelId'] as String? ?? 'qwen3.5-2b-mtp-ud-q4_k_xl',
      projectId: map['projectId'] as String?,
      messageCount: map['messageCount'] as int? ?? 0,
      titlePinned: (map['titlePinned'] as int? ?? 0) == 1,
      createdAt: DateTime.fromMillisecondsSinceEpoch(map['createdAt'] as int),
      updatedAt: DateTime.fromMillisecondsSinceEpoch(map['updatedAt'] as int),
    );
  }
}
