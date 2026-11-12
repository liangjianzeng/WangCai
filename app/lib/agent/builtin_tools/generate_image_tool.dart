/// generate_image —— 调本地/局域网 Unsloth Studio 生图（入口②·智能体工具）。
///
/// 与聊天区入口①（🎨 chip / 「/图」前缀）共用 [ImageGenService]（单飞队列
/// 全局串行，两入口天然互斥排队）。开关语义照 weather/web_search 先例：
/// 设置关闭时接入层根本不注册，模型看不见该工具，不会幻觉调用。
///
/// [onGenerated] 回调由接入层传入（chat_provider）：把成图以带 imagePaths
/// 的 assistant 消息落库，保证重进会话可回看（onTodosChanged 同款先例）。
///
/// **扩写纪律（2026-11-12 一实例三角色方案定案）**：本工具**不过**
/// [ImagePromptRewriter] 确认流——智能体回合里模型给的 prompt 本就是 LLM
/// 按工具描述写的完整提示词，再套一层「扩写→等用户确认」会把自主回合
/// 卡死在人机上。确认卡流只属于入口①（口语直发场景）。两态化实现见
/// chat_provider.generateImageDirect。
library;

import '../../services/image_gen_service.dart';
import '../tool_definition.dart';

ToolDefinition createGenerateImageTool({
  required Future<ImageGenConfig> Function() configLoader,
  void Function(ImageGenResult result, String prompt, String model)?
      onGenerated,

  /// 测试注入口（默认 [ImageGenService.instance] 单例）。
  ImageGenService? service,
}) {
  final svc = service ?? ImageGenService.instance;
  return ToolDefinition(
    name: 'generate_image',
    isConcurrencySafe: (_) => false, // 单卡串行：独占执行（同 export_file）
    timeout: const Duration(minutes: 6),
    description: '调用本地图像生成服务（Qwen-Image）生成图片。当用户要求'
        '「画/生成图片/配图/海报/插画」，或你的回答需要一张插图时调用。'
        '返回本地 PNG 路径，图片会自动出现在聊天区。串行排队：前面有生成'
        '任务时需等待。大图（2048x2048）约 2 分钟，默认 1024x1024 约 20-30 秒。',
    parameters: {
      'type': 'object',
      'properties': {
        'prompt': {
          'type': 'string',
          'description': '画面描述（建议具体：主体/风格/构图/光线，中英文均可）',
        },
        'negative_prompt': {
          'type': 'string',
          'description': '不希望出现的元素（可选）',
        },
        'size': {
          'type': 'string',
          'enum': List<String>.of(kImageGenSizes),
          'description': '尺寸档位（可选，默认 1024x1024；海报/大图用 2048x2048）',
        },
        'n': {
          'type': 'integer',
          'description': '生成张数 1-4（可选，默认 1）',
        },
        'seed': {
          'type': 'integer',
          'description': '随机种子（可选；同 seed 同提示词可复现相近画面）',
        },
      },
      'required': ['prompt'],
    },
    execute: (args) async {
      final prompt = (args['prompt'] as String?)?.trim() ?? '';
      if (prompt.isEmpty) return ToolResult.error('缺少 prompt 参数');
      final cfg = await configLoader();
      final size = args['size'] is String ? args['size'] as String : null;
      final n = args['n'] is int ? args['n'] as int : 1;
      final seed = args['seed'] is int ? args['seed'] as int : null;
      final negative =
          args['negative_prompt'] is String ? args['negative_prompt'] as String : null;
      try {
        final result = await svc.generate(
          config: cfg,
          prompt: prompt,
          size: size,
          negative: negative,
          seed: seed,
          n: n,
        );
        onGenerated?.call(result, prompt, cfg.model);
        final secs = (result.ms / 1000).toStringAsFixed(1);
        return ToolResult(content:
            '已生成 ${result.paths.length} 张图片（${result.size}，seed '
            '${result.seed}，$secs 秒），图片已插入聊天区：\n'
            '${result.paths.join('\n')}');
      } on ImageGenException catch (e) {
        return ToolResult.error('生图失败：${e.message}');
      } catch (e) {
        return ToolResult.error('生图失败：$e');
      }
    },
  );
}
