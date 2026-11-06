import 'package:flutter_test/flutter_test.dart';

import 'package:wangcai/models/model_catalog.dart';
import 'package:wangcai/models/model_info.dart';

/// 模型管理页「体积 + 特性标签」描述行的标签清洗逻辑。
///
/// 背景（2026-10-30 用户反馈）：未下载模型的描述内容在列表里**出现重复**——
/// 折叠态次行与展开区各画一遍体积+前三个标签，点开就是上下两行一模一样。
/// 现在两处共用 settings_screen 的 `_modelMetaLine` 唯一渲染点，标签本身由
/// [modelFeatureTags] 负责去冗余（重复配置 / 眼睛图标已表达 / 模型名已写明）。
ModelConfig _cfg(String name, List<String> tags) => ModelConfig(
      id: 'ut-$name',
      name: name,
      type: ModelType.text,
      mirrors: const [MirrorEntry('https://example.com/a.gguf', 'test')],
      sizeBytes: 1024 * 1024,
      sizeMBDisplay: '1 MB',
      tags: tags,
    );

void main() {
  group('modelFeatureTags 去冗余', () {
    test('剔除主行眼睛图标已表达的视觉标签', () {
      final m = _cfg('LFM3-VL 2B (QAD Q4_0 视觉)',
          ['视觉', '视觉+语音', '官方量化', 'QAD 抗量化']);
      expect(modelFeatureTags(m), ['官方量化', 'QAD 抗量化']);
    });

    test('剔除目录里重复配置的同一标签', () {
      final m = _cfg('Demo 1B', ['推荐', '推荐', '智能体', ' 智能体 ', '速度快']);
      expect(modelFeatureTags(m), ['推荐', '智能体', '速度快']);
    });

    test('剔除模型名（去括号后）里已经写明的标签', () {
      // 括号内的精度说明由 cleanModelName 去掉，所以括号里的不算「名字里已有」；
      // 真正写在名字里的才不许再重复成 chip。
      final dup = _cfg('MiniCPM5 2B 智能体', ['智能体', '速度快']);
      expect(modelFeatureTags(dup), ['速度快']);
      final kept = _cfg('MiniCPM5 2B (Q8_0 智能体)', ['智能体', '精度更高']);
      expect(modelFeatureTags(kept), ['智能体', '精度更高']);
    });

    test('剔除空串与纯空白标签', () {
      final m = _cfg('Demo 1B', ['', '   ', '推荐']);
      expect(modelFeatureTags(m), ['推荐']);
    });

    test('limit = 折叠态只留最要紧的几条，展开（limit=null）给全量', () {
      final m = _cfg(
          'LFM 2.5 8B-A1B (Q4_K_M 智能体)', ['推荐', '智能体', 'MoE 高效', '官方量化']);
      expect(modelFeatureTags(m, limit: 3), ['推荐', '智能体', 'MoE 高效']);
      expect(modelFeatureTags(m).length, 4);
    });
  });

  group('真实目录：描述行不许出现重复信息', () {
    TestWidgetsFlutterBinding.ensureInitialized();

    test('每个目录模型的标签自身无重复、折叠态不超 3 条', () async {
      final models = await ModelCatalog.load();
      expect(models, isNotEmpty);
      for (final m in models) {
        final collapsed = modelFeatureTags(m, limit: 3);
        expect(collapsed.length, lessThanOrEqualTo(3),
            reason: '${m.id} 折叠态标签超过 3 条');
        expect(collapsed.toSet().length, collapsed.length,
            reason: '${m.id} 折叠态标签重复：$collapsed');
        final full = modelFeatureTags(m);
        expect(full.toSet().length, full.length,
            reason: '${m.id} 全量标签重复：$full');
        // 由眼睛图标表达的两条绝不该再以 chip 出现。
        expect(full.where(kModelIconCoveredTags.contains), isEmpty,
            reason: '${m.id} 视觉标签与主行眼睛图标重复：$full');
      }
    });
  });
}
