/// 端侧 AGENTS.md 加载（Phase 5）。
///
/// 路径（DSH Part 12.6）：
/// - 全局：`ApplicationSupport/AGENTS.md`（用户全局，rank 低）。
/// - 工作区：`workspace/AGENTS.md`（若存在，rank 高，后覆盖前）。
///
/// 内容：低权威 workspace guidance。注入作为 `workspace:guidance`
/// section（§7.2 系统提示的末尾）。
library;

import 'dart:io';

import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';

/// 加载的 AGENTS.md 内容。
final class AgentsMd {
  final String content;
  final List<String> sources;

  const AgentsMd(this.content, this.sources);
  bool get isEmpty => content.trim().isEmpty;
}

/// 加载 AGENTS.md（全局 + 工作区）。
Future<AgentsMd> loadAgentsMd({String? workspacePath}) async {
  final global = await _readGlobal();
  String? workspaceContent;
  List<String> sources = <String>[];
  String combined = global ?? '';
  if (global != null && global.trim().isNotEmpty) {
    sources.add('global');
  }
  // 工作区 AGENTS.md（若 workspacePath 非空且文件存在）。
  if (workspacePath != null && workspacePath.trim().isNotEmpty) {
    final file = File(p.join(workspacePath, 'AGENTS.md'));
    if (file.existsSync()) {
      workspaceContent = file.readAsStringSync();
      if (workspaceContent.trim().isNotEmpty) {
        sources.add('workspace');
      }
    }
  }
  // 组合：全局 + 工作区（后覆盖前；用换行分隔）。
  if (workspaceContent != null && workspaceContent.trim().isNotEmpty) {
    combined = combined.isEmpty
        ? workspaceContent
        : '$combined\n\n$workspaceContent';
  }
  return AgentsMd(combined.trim(), sources);
}

Future<String?> _readGlobal() async {
  final dir = await getApplicationSupportDirectory();
  final file = File(p.join(dir.path, 'AGENTS.md'));
  if (!file.existsSync()) return null;
  try {
    return file.readAsStringSync();
  } catch (_) {
    return null;
  }
}
