/// 轨迹导出（P0）—— SessionLog → JSONL，离线回放/评估/排障用。
///
/// 轨迹 = header 行 + 全部原始事件行（含结构/log-only 事件）。事件本身
/// 就是 append-only 的唯一真相源，导出无需任何再加工；回放侧按
/// `SessionEvent.fromJsonLine` 重建即可（测试里做 round-trip 验证）。
///
/// 落盘位置（生产）：`ApplicationSupport/traces/`，文件名带会话与时间戳；
/// 设置 `agentTraceExportEnabled` 开启后每回合结束自动写一份。
library;

import 'dart:convert';
import 'dart:io';

import 'session.dart';

/// 导出整份会话轨迹（header + 全事件 JSONL 文本）。
String exportTraceJsonl(SessionLog log, {String? conversationId}) {
  final buf = StringBuffer();
  buf.writeln(jsonEncode({
    'version': kSessionFormatVersion,
    'conversationId': conversationId ?? '',
    'exportedAt': DateTime.now().millisecondsSinceEpoch,
    'events': log.eventsCount,
  }));
  for (final e in log.rawEvents) {
    buf.writeln(e.toJsonLine());
  }
  return buf.toString();
}

/// 导出单个回合的轨迹（turn/start..turn/end 含端点）。
/// 该回合不存在时返回空字符串。
String exportTurnJsonl(SessionLog log, int turn) {
  final lines = <String>[];
  var inRange = false;
  for (final e in log.rawEvents) {
    if (!inRange) {
      if (e.type == kEventTurnStart &&
          (e.data['turn'] as num?)?.toInt() == turn) {
        inRange = true;
        lines.add(e.toJsonLine());
      }
      continue;
    }
    lines.add(e.toJsonLine());
    if (e.type == kEventTurnEnd &&
        (e.data['turn'] as num?)?.toInt() == turn) {
      break;
    }
  }
  return lines.isEmpty ? '' : '${lines.join('\n')}\n';
}

/// 把轨迹写入 [baseDir]（生产 = ApplicationSupport/traces），返回文件。
/// 文件名：`trace_<会话>_<毫秒时间戳>.jsonl`；会话 id 只保留安全字符。
Future<File> writeTraceFile(
  SessionLog log, {
  required String baseDir,
  String? conversationId,
}) async {
  final dir = Directory(baseDir);
  if (!await dir.exists()) await dir.create(recursive: true);
  final safeConv =
      (conversationId ?? 'conv').replaceAll(RegExp(r'[^\w-]'), '_');
  final ts = DateTime.now().millisecondsSinceEpoch;
  final file = File('${dir.path}/trace_${safeConv}_$ts.jsonl');
  await file.writeAsString(exportTraceJsonl(log, conversationId: conversationId));
  return file;
}
