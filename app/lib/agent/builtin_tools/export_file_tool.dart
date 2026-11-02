/// export_file —— 把工作区产物导出到公共下载目录（WP6）。
///
/// 模型生成报告/文档（html/md/csv/png 等）后调用本工具，把 workspace 里的
/// 产物复制到系统 `Download/TongYi-Lite/`（MediaStore，文件管理器可见），
/// 返回 content:// URI；UI 工具卡凭 URI 渲染「打开」按钮直接查阅。
library;

import 'dart:io';

import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';

import '../../services/device_files_service.dart';
import '../tool_definition.dart';

/// 解析待导出路径：相对路径基于 workspace（与文件工具同一工作目录）；
/// 绝对路径原样使用（正常只出现在模型引用自己刚写过的 workspace 绝对路径）。
Future<String> _resolveSource(String raw) async {
  final trimmed = raw.trim();
  if (p.isAbsolute(trimmed)) return p.normalize(trimmed);
  final docs = await getApplicationDocumentsDirectory();
  return p.normalize(p.join(docs.path, 'workspace', trimmed));
}

/// 已知可查看的产物扩展名（超出则照常导出，仅提示里不列）。
const List<String> kArtifactExtensions = [
  '.html', '.htm', '.md', '.txt', '.csv', '.json', '.png', '.jpg', '.jpeg',
  '.svg', '.pdf', '.log',
];

ToolDefinition createExportFileTool() {
  return ToolDefinition(
    isConcurrencySafe: (_) => false, // 副作用工具：独占执行（P2-A）
    name: 'export_file',
    description: '把工作区里已生成的文件导出到系统下载目录（Download/TongYi-Lite/），'
        '用户即可在文件管理器查看。生成报告/网页/图表/数据文件后必须调用本工具交付。'
        '支持格式：${kArtifactExtensions.join(" ")} 等。',
    timeout: const Duration(seconds: 30),
    parameters: {
      'type': 'object',
      'properties': {
        'path': {
          'type': 'string',
          'description': '工作区内已存在的文件路径（相对或绝对）',
        },
        'name': {
          'type': 'string',
          'description': '导出后的文件名（可选，缺省沿用原文件名；'
              '建议带上日期如 report-20260929.html）',
        },
      },
      'required': ['path'],
    },
    execute: (args) async {
      final raw = args['path'];
      final path = raw is String ? raw.trim() : '';
      if (path.isEmpty) {
        return ToolResult.error('缺少 path 参数（应为工作区内文件路径）');
      }
      var name = args['name'] is String ? (args['name'] as String).trim() : '';
      final src = await _resolveSource(path);
      final file = File(src);
      if (!file.existsSync()) {
        return ToolResult.error('文件不存在：$src（先用 write_file 或 python_exec 生成）');
      }
      final size = file.lengthSync();
      if (name.isEmpty) name = p.basename(src);
      if (!name.contains('.') && src.contains('.')) {
        name = '$name${p.extension(src)}'; // 无扩展名时沿用源扩展
      }
      try {
        final uri = await DeviceFilesService.instance
            .exportFile(src: src, name: name)
            .timeout(const Duration(seconds: 25));
        // 源文件路径一并返回：部分 ROM 对 MediaStore URI 的 ACTION_VIEW
        // 授权挑剔，UI「打开」按钮凭源文件走 FileProvider 分层回退。
        return ToolResult(content: '已导出：$uri（$name，$size 字节）源文件：$src');
      } catch (e) {
        return ToolResult.error('导出失败：$e');
      }
    },
  );
}
