import 'dart:convert';
import 'dart:io';

import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';

/// 用户对模型自定义显示名称的持久化（与推理引擎设置分离，独立文件）。
///
/// 文件位于应用文档目录下的 `model_display_names.json`，
/// 内容为 `{ "<modelId>": "<自定义名称>" }` 的映射。
class ModelDisplayNameService {
  static const _fileName = 'model_display_names.json';

  Future<String> _resolvePath() async {
    final dir = await getApplicationDocumentsDirectory();
    return p.join(dir.path, _fileName);
  }

  /// 读取全部自定义名称；文件不存在或损坏时返回空映射。
  Future<Map<String, String>> load() async {
    try {
      final file = File(await _resolvePath());
      if (!await file.exists()) return {};
      final content = await file.readAsString();
      if (content.trim().isEmpty) return {};
      final json = jsonDecode(content) as Map<String, dynamic>;
      return json.map((k, v) => MapEntry(k, v as String));
    } catch (_) {
      // 任何解析错误都回落到空映射，不影响主流程。
      return {};
    }
  }

  /// 写入全部自定义名称。失败时抛出异常由调用方处理。
  ///
  /// 原子写入（与 SettingsService.save 同一策略）：先写 `.tmp` 再 rename，
  /// 避免崩溃/断电留下半截 JSON 导致自定义名称全部丢失。
  Future<void> save(Map<String, String> map) async {
    final path = await _resolvePath();
    final tmp = File('$path.tmp');
    await tmp.writeAsString(jsonEncode(map));
    await tmp.rename(path);
  }
}
