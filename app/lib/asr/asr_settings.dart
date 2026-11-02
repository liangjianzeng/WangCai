/// ASR 配置（自 DSH-Phone 搬迁的解耦层）。
///
/// DSH-Phone 原实现经 SSHConfig（SharedPreferences）存取档位与热词；
/// 本项目统一走 InferenceSettings 持久化（settings JSON）：
/// - 档位：`asrEnhancedMode`（true = beam search + blankPenalty 增强）；
/// - 热词：`asrHotwordCategories` 启用分类（空 = 全部）+
///   `asrHotwordCustom` 自定义词（每行一个）。
/// 词表内热词 → beam 解码器 ContextGraph 偏置；词表外（如名字用字）
/// → 识别输出同音后校正（HotwordCorrector）。每次长按说话读一次设置
/// （本地 JSON 读，毫秒级，可接受）。
library;

import 'package:flutter/foundation.dart' show debugPrint;

import '../services/settings_service.dart';
import 'default_hotwords.dart';

/// 识别档位。
enum AsrMode { standard, enhanced }

/// ASR 配置存取（解耦 DSH SSHConfig 的替代面）。
class AsrSettings {
  static Future<InferenceSettings> _settings() => SettingsService().load();

  /// 识别档位。
  static Future<AsrMode> loadAsrMode() async {
    try {
      final s = await _settings();
      return s.asrEnhancedMode ? AsrMode.enhanced : AsrMode.standard;
    } on Exception catch (e) {
      debugPrint('[AsrSettings] loadAsrMode failed: $e');
      return AsrMode.standard;
    }
  }

  /// 热词表（每行一个词；sherpa 按换行切分，逗号连写会失效）。
  /// = 启用分类的生效词（默认词 + 用户增词 − 用户删词）+ 自定义词
  /// （去重、去空行）。
  static Future<String> loadHotwords() async {
    try {
      final s = await _settings();
      var enabled = s.asrHotwordCategories;
      // 陈旧 id 兜底：热词分类表改版后，旧配置里可能全是失效 id——
      // 交集为空但配置非空时按"全部启用"处理，避免热词整体静默失效。
      final validIds = hotwordCategories.map((c) => c.id).toSet();
      enabled = enabled.where(validIds.contains).toList();
      final words = <String>{};
      for (final cat in hotwordCategories) {
        // 未配置分类 = 全部启用；配置后只取启用的。
        if (enabled.isNotEmpty && !enabled.contains(cat.id)) continue;
        words.addAll(effectiveCategoryWords(
            cat.id, s.asrHotwordAdded, s.asrHotwordRemoved));
      }
      for (final line in s.asrHotwordCustom.split('\n')) {
        final w = line.trim();
        if (w.isNotEmpty) words.add(w);
      }
      return words.join('\n');
    } on Exception catch (e) {
      debugPrint('[AsrSettings] loadHotwords failed: $e');
      return [for (final cat in hotwordCategories) ...cat.words].join('\n');
    }
  }
}
