import 'dart:convert';
import 'package:sqflite/sqflite.dart';
import 'package:path/path.dart';
import '../models/chat_message.dart';
import '../models/conversation.dart';

class StorageService {
  static final StorageService _instance = StorageService._internal();
  factory StorageService() => _instance;
  StorageService._internal();

  static Database? _db;

  Future<Database> get database async {
    if (_db != null) return _db!;
    _db = await _init();
    return _db!;
  }

  Future<Database> _init() async {
    final path = join(await getDatabasesPath(), 'tongyilite.db');
    return await openDatabase(
      path,
      version: 6,
      onCreate: _onCreate,
      onUpgrade: _onUpgrade,
    );
  }

  /// 数据库版本升级迁移。**幂等**：先读 messages 现有列，缺哪列补哪列，
  /// 避免库状态不一致（列已存在但 user_version 落后）时 ALTER 撞上
  /// 「duplicate column name」崩溃——那种崩溃会把整个会话库打成不可打开，
  /// 表现为发送失败 + 会话列表全空，而数据其实还在库里。
  Future<void> _onUpgrade(Database db, int oldVersion, int newVersion) async {
    // PRAGMA table_info 返回现有列名；table 名是常量，无需参数化。
    final cols = await db.rawQuery('PRAGMA table_info(messages)');
    final names = cols.map((c) => c['name'] as String).toSet();

    if (oldVersion < 2 && !names.contains('inferenceStats')) {
      // v1 → v2：messages 表新增 inferenceStats 列（回复性能统计 JSON）。
      await db.execute(
        "ALTER TABLE messages ADD COLUMN inferenceStats TEXT",
      );
    }
    if (oldVersion < 3 && !names.contains('audioPath')) {
      // v2 → v3：messages 表新增 audioPath 列（语音消息的录音文件路径）。
      // 此前模型里有 audioPath 字段但表里没有该列，语音消息重进会话后
      // 「语音」标记全部丢失。
      await db.execute(
        "ALTER TABLE messages ADD COLUMN audioPath TEXT",
      );
    }
    if (oldVersion < 4) {
      // v3 → v4：多图 + 智能体附件（JSON 数组字符串；缺列时 toMap/fromMap
      // 已做 null 容错）。列不存在时带多图/附件的 saveMessage 会崩，
      // 所以 upgrade 与 create 两条建表路径都要有这两列。
      if (!names.contains('imagePaths')) {
        await db.execute(
          "ALTER TABLE messages ADD COLUMN imagePaths TEXT",
        );
      }
      if (!names.contains('attachments')) {
        await db.execute(
          "ALTER TABLE messages ADD COLUMN attachments TEXT",
        );
      }
    }
    // 模型视图列（长图切块序列，JSON 数组）：与版本无关的列级检查——
    // 任何历史版本升级上来缺这列都补上。展示仍用 imagePaths，
    // visionPaths 仅供模型侧重发历史时使用。
    if (!names.contains('visionPaths')) {
      await db.execute(
        "ALTER TABLE messages ADD COLUMN visionPaths TEXT",
      );
    }
    // v6：消息类型化（对话区重构 P0）——kind/toolData/noticeCode 三列。
    // 与版本无关的列级检查（同 visionPaths 的幂等策略）。
    if (!names.contains('kind')) {
      await db.execute("ALTER TABLE messages ADD COLUMN kind TEXT");
    }
    if (!names.contains('toolData')) {
      await db.execute("ALTER TABLE messages ADD COLUMN toolData TEXT");
    }
    if (!names.contains('noticeCode')) {
      await db.execute("ALTER TABLE messages ADD COLUMN noticeCode TEXT");
    }
  }

  Future<void> _onCreate(Database db, int version) async {
    await db.execute('''
      CREATE TABLE conversations (
        id TEXT PRIMARY KEY,
        title TEXT NOT NULL DEFAULT '新对话',
        modelId TEXT DEFAULT 'qwen3.5-2b-mtp-ud-q4_k_xl',
        messageCount INTEGER DEFAULT 0,
        createdAt INTEGER NOT NULL,
        updatedAt INTEGER NOT NULL
      )
    ''');

    await db.execute('''
      CREATE TABLE messages (
        id TEXT PRIMARY KEY,
        conversationId TEXT NOT NULL,
        role TEXT NOT NULL,
        content TEXT NOT NULL,
        imagePath TEXT,
        imagePaths TEXT,
        visionPaths TEXT,
        attachments TEXT,
        audioPath TEXT,
        createdAt INTEGER NOT NULL,
        isStreaming INTEGER DEFAULT 0,
        inferenceStats TEXT,
        kind TEXT,
        toolData TEXT,
        noticeCode TEXT,
        FOREIGN KEY (conversationId) REFERENCES conversations(id) ON DELETE CASCADE
      )
    ''');

    await db.execute(
      'CREATE INDEX idx_messages_conv_time ON messages(conversationId, createdAt)',
    );
  }

  // ----- Conversations -----

  Future<Conversation> createConversation({String title = '新对话'}) async {
    final db = await database;
    final id = DateTime.now().millisecondsSinceEpoch.toString();
    final now = DateTime.now().millisecondsSinceEpoch;
    await db.insert('conversations', {
      'id': id,
      'title': title,
      'modelId': 'qwen3.5-2b-mtp-ud-q4_k_xl',
      'messageCount': 0,
      'createdAt': now,
      'updatedAt': now,
    });
    return Conversation(id: id, title: title);
  }

  Future<List<Conversation>> getAllConversations() async {
    final db = await database;
    final rows = await db.query(
      'conversations',
      orderBy: 'updatedAt DESC',
    );
    return rows.map((r) => Conversation(
      id: r['id'] as String,
      title: r['title'] as String,
      modelId: r['modelId'] as String? ?? 'qwen3.5-2b-mtp-ud-q4_k_xl',
      messageCount: r['messageCount'] as int? ?? 0,
      createdAt: DateTime.fromMillisecondsSinceEpoch(r['createdAt'] as int),
      updatedAt: DateTime.fromMillisecondsSinceEpoch(r['updatedAt'] as int),
    )).toList();
  }

  Future<void> deleteConversation(String id) async {
    final db = await database;
    await db.delete('conversations', where: 'id = ?', whereArgs: [id]);
  }

  /// 更新会话元信息：标题 / 消息条数 / 更新时间。
  /// 只更新传入的非空字段；updatedAt 始终刷新为当前时间。
  Future<void> updateConversation({
    required String id,
    String? title,
    int? messageCount,
  }) async {
    final db = await database;
    final updates = <String, dynamic>{
      'updatedAt': DateTime.now().millisecondsSinceEpoch,
    };
    if (title != null) updates['title'] = title;
    if (messageCount != null) updates['messageCount'] = messageCount;
    await db.update('conversations', updates, where: 'id = ?', whereArgs: [id]);
  }

  // ----- Messages -----

  /// messages 行 → ChatMessage 的统一映射（getMessages / getAllMessages 共用，
  /// 避免两份映射各自漂移——此前 audioPath 缺列、role 崩溃就是漂移的产物）。
  ChatMessage _mapMessageRow(Map<dynamic, dynamic> r) {
    final statsJson = r['inferenceStats'] as String?;
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
      id: r['id'] as String,
      conversationId: r['conversationId'] as String,
      role: messageRoleFromName(r['role']),
      content: r['content'] as String,
      imagePath: r['imagePath'] as String?,
      imagePaths: _decodeList(r['imagePaths']),
      visionPaths: _decodeList(r['visionPaths']),
      attachments: _decodeList(r['attachments']),
      audioPath: r['audioPath'] as String?,
      timestamp: DateTime.fromMillisecondsSinceEpoch(r['createdAt'] as int),
      isStreaming: (r['isStreaming'] as int?) == 1,
      inferenceStats: statsJson != null && statsJson.isNotEmpty
          ? InferenceStats.fromMap(jsonDecode(statsJson) as Map<String, dynamic>)
          : null,
      toolData: _decodeToolData(r['toolData']),
      noticeCode: r['noticeCode'] as String?,
      // kind 缺失（旧行）→ 按前缀/工具数据推断后固化到实例。
      kind: ChatMessage.resolveKind(
        stored: _kindFromName(r['kind']),
        toolData: _decodeToolData(r['toolData']),
        content: r['content'] as String? ?? '',
      ),
    );
  }

  static MessageKind? _kindFromName(Object? name) {
    if (name is! String || name.isEmpty) return null;
    for (final k in MessageKind.values) {
      if (k.name == name) return k;
    }
    return null;
  }

  static ToolActivityData? _decodeToolData(Object? raw) {
    if (raw is! String || raw.isEmpty) return null;
    try {
      final decoded = jsonDecode(raw);
      if (decoded is Map<String, dynamic>) {
        return ToolActivityData.fromMap(decoded);
      }
    } catch (_) {}
    return null;
  }

  /// 取某会话最近 [limit] 条消息（时间升序返回）。
  ///
  /// 语义修正（2026-09-30 健康审查 P0）：此前 `ASC + limit` 在超限会话里
  /// 取到的是**最旧** N 条——长会话/多工具轮后模型历史被裁掉最新消息
  /// （连刚发的用户提问都可能看不到）。改为 DESC 取尾再反转为升序，
  /// 调用方语义不变。
  Future<List<ChatMessage>> getMessages(String conversationId, {int limit = 200}) async {
    final db = await database;
    final rows = await db.query(
      'messages',
      where: 'conversationId = ?',
      whereArgs: [conversationId],
      orderBy: 'createdAt DESC',
      limit: limit,
    );
    return rows.map(_mapMessageRow).toList().reversed.toList();
  }

  Future<void> saveMessage(ChatMessage msg) async {
    final db = await database;
    // Remove streaming flag on the last message
    await db.update(
      'messages',
      {'isStreaming': 0},
      where: 'conversationId = ? AND isStreaming = 1',
      whereArgs: [msg.conversationId],
    );
    await db.insert('messages', {
      'id': msg.id,
      'conversationId': msg.conversationId,
      'role': msg.role.name,
      'content': msg.content,
      'imagePath': msg.imagePath,
      'imagePaths':
          msg.imagePaths == null ? null : jsonEncode(msg.imagePaths),
      'visionPaths':
          msg.visionPaths == null ? null : jsonEncode(msg.visionPaths),
      'attachments':
          msg.attachments == null ? null : jsonEncode(msg.attachments),
      'audioPath': msg.audioPath,
      'createdAt': msg.timestamp.millisecondsSinceEpoch,
      'isStreaming': msg.isStreaming ? 1 : 0,
      'inferenceStats': msg.inferenceStats != null
          ? jsonEncode(msg.inferenceStats!.toMap())
          : null,
      'kind': msg.kind.name,
      'toolData':
          msg.toolData == null ? null : jsonEncode(msg.toolData!.toMap()),
      'noticeCode': msg.noticeCode,
    }, conflictAlgorithm: ConflictAlgorithm.replace);
  }

  Future<List<ChatMessage>> getAllMessages(String conversationId) async {
    final db = await database;
    final rows = await db.query(
      'messages',
      where: 'conversationId = ?',
      whereArgs: [conversationId],
      orderBy: 'createdAt ASC',
    );
    return rows.map(_mapMessageRow).toList();
  }

  /// 各会话最后一条消息内容（P2 抽屉摘要行；一次 SQL 批量取，免 N 次查询）。
  Future<Map<String, String>> lastMessageSnippets() async {
    final db = await database;
    final rows = await db.rawQuery(
        'SELECT m.conversationId AS cid, m.content AS content FROM messages m '
        "JOIN (SELECT conversationId, MAX(createdAt) AS mc FROM messages "
        'GROUP BY conversationId) t '
        'ON m.conversationId = t.conversationId AND m.createdAt = t.mc');
    return {
      for (final r in rows)
        r['cid'] as String: ((r['content'] as String?) ?? '').trim(),
    };
  }

  Future<void> clearConversation(String conversationId) async {
    final db = await database;
    await db.delete('messages', where: 'conversationId = ?', whereArgs: [conversationId]);
  }

  /// 按 id 批量删除消息（手动压缩清理旧工具轮轨迹信封用；可见消息不受影响）。
  Future<void> deleteMessages(List<String> ids) async {
    if (ids.isEmpty) return;
    final db = await database;
    await db.delete(
      'messages',
      where: 'id IN (${List.filled(ids.length, '?').join(',')})',
      whereArgs: ids,
    );
  }

  // ----- Storage stats -----

  Future<Map<String, int>> getStorageStats() async {
    final db = await database;
    final result = await db.rawQuery('SELECT SUM(LENGTH(content)) as total FROM messages');
    final historyBytes = (result.first['total'] as int?) ?? 0;

    return {
      'conversations': (await db.query('conversations')).length,
      'messages': (await db.query('messages')).length,
      'historyBytes': historyBytes,
    };
  }
}
