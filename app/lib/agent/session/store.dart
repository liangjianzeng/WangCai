import 'dart:convert';
import 'dart:io';

import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';

import '../../models/chat_message.dart' show ChatMessage, MessageRole;
import 'event.dart';
import 'log.dart';

/// JSONL 会话存储（Phase 0）。
///
/// 对照 DSH 持久化（Part 5）：每会话一个 JSONL 文件
/// `ApplicationSupport/sessions/<conversationId>.jsonl`，首行 header，
/// 后续每行一个事件。文件操作 append-only，加载时做崩溃修复（closeOpenTurns）。
///
/// 端侧设计决策：
/// - 不压缩（JSONL 明文，文件小，读取简单）；
/// - 版本门：version <= kSessionFormatVersion 可读，否则抛（迁移链 Phase 2+）；
/// - 旧 SQLite 会话经 [importFromMessages] 一次性迁移（log-only 标记 imported）。

final class JsonlSessionStore {
  JsonlSessionStore();

  /// 会话文件路径（相对 ApplicationSupport/sessions）。
  Future<String> pathFor(String conversationId) async {
    final base = await getApplicationSupportDirectory();
    return p.join(base.path, 'sessions', '${_safe(conversationId)}.jsonl');
  }

  /// 确保 sessions 目录存在，返回目录路径。
  Future<String> _ensureDir() async {
    final base = await getApplicationSupportDirectory();
    final dir = p.join(base.path, 'sessions');
    if (!Directory(dir).existsSync()) {
      Directory(dir).createSync();
    }
    return dir;
  }

  /// 读取会话日志（load + 崩溃修复 + 版本门）。
  Future<SessionLog> load(String conversationId) async {
    final dirPath = await _ensureDir();
    final file = File(p.join(dirPath, '${_safe(conversationId)}.jsonl'));
    if (!file.existsSync()) {
      return SessionLog.fromEvents([]);
    }
    // 逐行解析
    final bytes = file.readAsBytesSync();
    final lines = bytes.isEmpty
        ? <String>[]
        : utf8.decode(bytes, allowMalformed: true).split('\n');
    final events = <SessionEvent>[];
    for (var i = 0; i < lines.length; i++) {
      final line = lines[i].trim();
      if (line.isEmpty) continue;
      // 首行可能是 header
      if (i == 0 && isHeaderLine(line)) continue;
      final e = SessionEvent.fromJsonLine(line);
      if (e != null) events.add(e);
      // 末行撕裂且非 header → 判损坏丢弃（DSH：完整帧内撕裂不抢救）
    }
    final log = SessionLog.fromEvents(events);
    // 崩溃修复：补未闭合 turn/step/tool 结果
    log.closeOpenTurns(cause: 'crash-repair');
    return log;
  }

  /// 追加事件到磁盘（append-only）。
  Future<void> appendEvent(String conversationId, SessionEvent event) async {
    final dirPath = await _ensureDir();
    final file = File(p.join(dirPath, '${_safe(conversationId)}.jsonl'));
    if (!file.existsSync()) {
      final h = SessionHeader(
        version: kSessionFormatVersion,
        conversationId: conversationId,
        createdAtMs: DateTime.now().millisecondsSinceEpoch,
      );
      await file.writeAsString('${h.toJson()}\n');
    }
    await file.writeAsString('${event.toJsonLine()}\n', mode: FileMode.append);
  }

  /// 完整重写日志文件（导入/迁移用）。
  Future<void> rewrite(String conversationId, SessionLog log) async {
    final dirPath = await _ensureDir();
    final file = File(p.join(dirPath, '${_safe(conversationId)}.jsonl'));
    final h = SessionHeader(
      version: kSessionFormatVersion,
      conversationId: conversationId,
      createdAtMs: DateTime.now().millisecondsSinceEpoch,
    );
    final sb = StringBuffer();
    sb.writeln(h.toJson());
    for (final e in log.rawEvents) {
      sb.writeln(e.toJsonLine());
    }
    await file.writeAsString(sb.toString());
  }

  /// 从旧 SQLite ChatMessage 列表导入为 v1 日志（一次性迁移）。
  SessionLog importFromMessages(
    String conversationId,
    List<ChatMessage> messages,
  ) {
    final log = SessionLog.fromEvents([]);
    final now = DateTime.now().millisecondsSinceEpoch;
    for (final m in messages) {
      // 工具轮轨迹信封：还原为真实 assistant(toolCalls)/tool/result 事件，
      // 模型跨 turn 记得自己调过什么工具、拿到什么结果（WP1a）。
      // 还原失败（损坏/旧版本格式）→ 只留 imported 标记，绝不把信封 JSON
      // 当普通 assistant 文本投进模型历史。
      if (m.content.startsWith(kAgentTraceMessagePrefix)) {
        final restored = decodeAgentTraceMessage(m.content);
        if (restored != null) {
          final tMs = m.timestamp.millisecondsSinceEpoch;
          for (final e in restored) {
            final type = e['type']! as String;
            final data = e['data']! as Map<String, dynamic>;
            log.append(
              type,
              data,
              source: type == kEventToolResult
                  ? <String, String>{
                      'kind': 'tool',
                      'callId': '${data['callId'] ?? ''}',
                    }
                  : <String, String>{'kind': 'model', 'provider': 'trace'},
              timeMs: tMs,
            );
          }
        }
        log.append(
          kEventImported,
          <String, dynamic>{
            'originalId': m.id,
            'originalRole': m.role.name,
            if (restored == null) 'traceDecodeFailed': true,
          },
          source: <String, String>{'kind': 'import'},
          timeMs: now,
        );
        continue;
      }
      final isUser = m.role == MessageRole.user;
      // 模型视图（visionPaths 优先的长图切块序列）：重放历史时模型看到的
      // 与首发一致；切片已被清理时（7 天保留）消费侧按缺文件跳过/回退。
      final modelImages = m.modelImagePaths;
      log.append(
        isUser ? kEventUserMessage : kEventAssistantMessage,
        <String, dynamic>{
          'content': m.content,
          if (modelImages != null && modelImages.isNotEmpty)
            'imagePath': modelImages.first
          else if (m.imagePath != null)
            'imagePath': m.imagePath,
          if (modelImages != null && modelImages.length > 1)
            'imagePaths': modelImages,
          if (m.audioPath != null) 'audioPath': m.audioPath,
          if (m.inferenceStats != null) 'stats': m.inferenceStats!.toMap(),
        },
        source: <String, String>{'kind': 'import'},
        timeMs: m.timestamp.millisecondsSinceEpoch,
      );
      // log-only 导入标记（记录原 id，便于追溯）
      log.append(
        kEventImported,
        <String, dynamic>{
          'originalId': m.id,
          'originalRole': m.role.name,
        },
        source: <String, String>{'kind': 'import'},
        timeMs: now,
      );
    }
    return log;
  }

  /// 判断某会话是否已迁移（存在 .jsonl 文件）。
  Future<bool> isMigrated(String conversationId) async {
    final dirPath = await _ensureDir();
    return File(p.join(dirPath, '${_safe(conversationId)}.jsonl')).existsSync();
  }

  /// 删除会话文件。
  Future<void> delete(String conversationId) async {
    final dirPath = await _ensureDir();
    final file = File(p.join(dirPath, '${_safe(conversationId)}.jsonl'));
    if (file.existsSync()) await file.delete();
  }
}

/// 路径安全：把非法字符替换为下划线。
String _safe(String s) =>
    s.replaceAll(RegExp(r'[^A-Za-z0-9._-]'), '_');

// ---------------------------------------------------------------------------
// 工具轮轨迹信封（WP1a：跨 turn 保住工具上下文）
// ---------------------------------------------------------------------------

/// 轨迹信封消息前缀。role=assistant、content = 前缀 + JSON。
///
/// `🔧` 开头保证三处既有过滤行为不破坏：
/// - 普通聊天历史构建按 `🔧` 前缀排除（chat_provider._isToolActivityMessage）；
/// - 工具活动消息配对搜索 `🔧 正在调用` 不会命中；
/// - UI parseToolActivity 解析失败返回 null → 历史回看静默跳过。
const String kAgentTraceMessagePrefix = '🔧TRACE';

// ---------------------------------------------------------------------------
// 手动压缩（存储级确定性裁剪；provider 层 manualCompact 的纯函数核心）
// ---------------------------------------------------------------------------

/// 手动压缩计划：把较早轮次的 🔧TRACE 工具轮信封从存储清出。
final class StorageCompactionPlan {
  /// 最早一条旧信封的消息 id——**原位改写**为 [summaryEnvelope]
  ///（保持 id/时间戳 → 消息排序不变）。
  final String firstId;

  /// 摘要信封内容（kAgentTraceMessagePrefix + 单条 user/message 事件，
  /// 下一轮导入时投影为 user 摘要——与回合内压缩投影语义一致）。
  final String summaryEnvelope;

  /// 其余待删除的旧信封消息 id。
  final List<String> deleteIds;

  /// 旧信封里触达过的工具名（供日志与测试断言）。
  final List<String> toolNames;

  /// 摘要字符数。
  int get summaryChars => summaryEnvelope.length;

  const StorageCompactionPlan({
    required this.firstId,
    required this.summaryEnvelope,
    required this.deleteIds,
    required this.toolNames,
  });
}

/// 计算手动压缩计划（纯函数，无 I/O）。
///
/// 保留**最近一条** 🔧TRACE 信封（最近一轮的工具上下文，模型最需要），
/// 其余信封全部压缩——工具结果是上下文 token 大户。可见消息（user/
/// assistant 文本）一律不动。单条工具结果摘录 [excerptLen] 字、最多
/// [maxExcerpts] 条。信封不足 2 条（无"较早"内容可压）返回 null。
///
/// 注意：不能用「尾部保留 N 个用户轮」做门槛——短对话（≤N 轮）会把全部
/// 信封都当"最近"保护起来，手动压缩永远没东西可压（真机实测教训）。
StorageCompactionPlan? planStorageCompaction(
  List<ChatMessage> messages, {
  int maxExcerpts = 12,
  int excerptLen = 300,
}) {
  final oldEnvelopes = <ChatMessage>[
    for (final m in messages)
      if (m.content.startsWith(kAgentTraceMessagePrefix)) m,
  ];
  // 最后一条信封保留；不足 2 条 → 无可压缩。
  if (oldEnvelopes.length < 2) return null;
  oldEnvelopes.removeLast();

  // 摘要：从旧信封还原事件，收集工具名 + 结果摘录。
  final toolNames = <String>{};
  final excerpts = <String>[];
  for (final m in oldEnvelopes) {
    final events = decodeAgentTraceMessage(m.content);
    if (events == null) continue;
    for (final e in events) {
      if (e['type'] != kEventToolResult) continue;
      final data = e['data'];
      if (data is! Map<String, dynamic>) continue;
      final name = data['name'];
      if (name is String && name.isNotEmpty) toolNames.add(name);
      if (excerpts.length >= maxExcerpts) continue;
      var content = data['content'] as String? ?? '';
      if (content.isEmpty) continue;
      if (content.length > excerptLen) {
        content = '${content.substring(0, excerptLen)}…';
      }
      excerpts.add('[${name ?? 'tool'}] $content');
    }
  }
  final summaryBuf = StringBuffer(
      '（手动压缩）较早轮次的工具结果已省略以释放上下文；'
      '此前已调用过工具：${toolNames.isEmpty ? '无' : toolNames.join('、')}。');
  if (excerpts.isNotEmpty) {
    summaryBuf.write('\n${excerpts.join('\n')}');
    if (excerpts.length >= maxExcerpts) {
      summaryBuf.write('\n（其余工具结果已省略）');
    }
  }
  final summary = summaryBuf.toString();

  // 摘要以 user/message 事件编码进 TRACE 信封（同前缀保证导入放行 +
  // UI 不渲染；decode 还原为 user/message 事件 → 投影为 user 摘要）。
  final summaryEnvelope = kAgentTraceMessagePrefix +
      jsonEncode(<String, dynamic>{
        'v': 1,
        'events': <Map<String, dynamic>>[
          <String, dynamic>{
            'type': kEventUserMessage,
            'data': <String, dynamic>{'content': summary},
          },
        ],
      });

  return StorageCompactionPlan(
    firstId: oldEnvelopes.first.id,
    summaryEnvelope: summaryEnvelope,
    deleteIds: [
      for (var i = 1; i < oldEnvelopes.length; i++) oldEnvelopes[i].id,
    ],
    toolNames: toolNames.toList(),
  );
}

/// 单个字符串值的截断上限（防长工具结果把 SQLite 消息撑爆；
/// 超限结果本应已被 spill 换成定位符，这里只是兜底）。
const int _kTraceValueCapChars = 8000;

/// 编码本轮工具轮轨迹信封：取最后一个 turn/start 之后的
/// assistant/message(带 toolCalls) + tool/result 事件。
/// 无工具轮返回 null（纯直答 turn 不需要信封）。
String? encodeAgentTraceMessage(SessionLog log) {
  final events = log.rawEvents;
  var start = 0;
  for (var i = events.length - 1; i >= 0; i--) {
    if (events[i].type == kEventTurnStart) {
      start = i;
      break;
    }
  }
  final payload = <Map<String, dynamic>>[];
  for (var i = start; i < events.length; i++) {
    final e = events[i];
    if (e.type == kEventAssistantMessage) {
      final calls = e.data['toolCalls'];
      if (calls is List && calls.isNotEmpty) {
        payload.add({'type': e.type, 'data': _capTraceStrings(e.data)});
      }
    } else if (e.type == kEventToolResult) {
      payload.add({'type': e.type, 'data': _capTraceStrings(e.data)});
    }
  }
  if (payload.isEmpty) return null;
  return kAgentTraceMessagePrefix + jsonEncode({'v': 1, 'events': payload});
}

/// 解码轨迹信封为事件载荷列表（每项 {type, data}）。
/// 非法/损坏返回 null——调用方必须跳过内容，不得当普通文本投进模型历史。
List<Map<String, dynamic>>? decodeAgentTraceMessage(String content) {
  if (!content.startsWith(kAgentTraceMessagePrefix)) return null;
  try {
    final json =
        jsonDecode(content.substring(kAgentTraceMessagePrefix.length));
    if (json is! Map) return null;
    final events = json['events'];
    if (events is! List) return null;
    final out = <Map<String, dynamic>>[];
    for (final e in events) {
      if (e is! Map) return null;
      final type = e['type'];
      final data = e['data'];
      if (type is! String || data is! Map) return null;
      out.add(<String, dynamic>{
        'type': type,
        'data': Map<String, dynamic>.from(data),
      });
    }
    return out;
  } catch (_) {
    return null;
  }
}

/// 递归截断 data 树里的超长字符串（信封落 SQLite 的体积兜底）。
Map<String, dynamic> _capTraceStrings(Map<String, dynamic> data) =>
    data.map((k, v) => MapEntry(k, _capTraceValue(v)));

Object? _capTraceValue(Object? v) {
  if (v is String) {
    if (v.length <= _kTraceValueCapChars) return v;
    return '${v.substring(0, _kTraceValueCapChars)}…[轨迹截断]';
  }
  if (v is List) return v.map(_capTraceValue).toList();
  if (v is Map) {
    return v.map((k, val) => MapEntry('$k', _capTraceValue(val)));
  }
  return v;
}