/// 提示词档位回归 —— 2026-10-27 K90 真机定案的守门测试。
///
/// 事故：Ling-3.0-tiny（Q4_0，OpenCL，Adreno 830）智能体模式答非所问——
/// 系统提示 19507 字符 / 4580 token，模型整回合**零工具调用**却输出
/// 「已查询到当前天气」「文件已保存 /home/user/go.py」。同模型聊天档
/// （prompt 14~70 token）正常。定案：本地小模型走精简档，API 档保持现状。
///
/// 本文件锁死三件事：
/// 1. API 档永不受判档逻辑影响（用户要求「API 能力强保持现状」）；
/// 2. 精简档系统提示体量必须显著小于完整档（预算闸）；
/// 3. 完整档逐字节保持旧行为（不许被瘦身顺带改坏）。
import 'package:flutter_test/flutter_test.dart';

import 'package:tongyi_lite/agent/agent.dart';
import 'package:tongyi_lite/agent/protocol/native_tool_protocol.dart';

void main() {
  /// 一个"重描述 + 带沙箱升级参数"的工具 —— 模拟 python_exec/shell_exec
  /// 这类把 tiny 模型带偏、又把 prefill 撑爆的工具。
  ToolDefinition heavyTool(String name) => ToolDefinition(
        name: name,
        description: '在沙盒内执行 Python 代码：注意 stdin 是一次性喂入并关闭的批次输入，'
            '需要 input() 的脚本必须用 stdin 参数把输入一并传进来；'
            '长任务请缩小规模或改用其它工具，否则会被超时截断。',
        parameters: const {
          'type': 'object',
          'properties': {
            'code': {'type': 'string', 'description': '要执行的代码'},
            'sandbox_permissions': {'type': 'string'},
          },
          'required': ['code'],
        },
        execute: (args) async => const ToolResult(content: 'ok'),
      );

  ToolDefinition lightTool(String name, String desc,
          {List<String> required = const []}) =>
      ToolDefinition(
        name: name,
        description: desc,
        parameters: {
          'type': 'object',
          'properties': {
            for (final r in required)
              r: {'type': 'string', 'description': '$r 参数'},
          },
          'required': required,
        },
        execute: (args) async => const ToolResult(content: 'ok'),
      );

  ToolRegistry registry() {
    final r = ToolRegistry();
    r.register(lightTool('get_time', '返回当前日期与时间'));
    r.register(lightTool('get_weather', '查询指定城市当前天气',
        required: const ['location']));
    r.register(heavyTool('python_exec'));
    return r;
  }

  group('resolveAgentPromptTier 判档', () {
    test('API 档恒为完整档（用户定案：API 能力强保持现状）', () {
      expect(
        resolveAgentPromptTier(
            modelId: 'ling-3.0-tiny-q4_0', useApi: true),
        AgentPromptTier.full,
      );
      // 即使强制精简也不放行——API 档不受本地判档波及。
      expect(
        resolveAgentPromptTier(
            modelId: 'ling-3.0-tiny-q4_0',
            useApi: true,
            mode: kAgentPromptTierCompact),
        AgentPromptTier.full,
      );
    });

    test('显式覆盖优先于自动判定', () {
      expect(
        resolveAgentPromptTier(
            modelId: 'bonsai-8b-q4_k_m', mode: kAgentPromptTierCompact),
        AgentPromptTier.compact,
      );
      expect(
        resolveAgentPromptTier(
            modelId: 'ling-3.0-tiny-q4_0', mode: kAgentPromptTierFull),
        AgentPromptTier.full,
      );
    });

    test('auto：小模型 id 关键字命中精简档（真机那台就是 ling-3.0-tiny）', () {
      for (final id in const [
        'ling-3.0-tiny-q4_0',
        'ling-3.0-tiny-q4_k_m',
        'minicpm5-2b-q4_k_m',
        'qwen3.5-1.5b-q4_0',
        'some-model-a0.5b-q4',
      ]) {
        expect(resolveAgentPromptTier(modelId: id), AgentPromptTier.compact,
            reason: id);
      }
    });

    test('auto：量化文件 ≤3.5GB 判精简，≥5GB 判完整', () {
      expect(
        resolveAgentPromptTier(
            modelId: 'unnamed-moe-x',
            sizeBytes: 2500 * 1024 * 1024),
        AgentPromptTier.compact,
      );
      expect(
        resolveAgentPromptTier(
            modelId: 'unnamed-8b-x', sizeBytes: 5500 * 1024 * 1024),
        AgentPromptTier.full,
      );
    });

    test('auto：>8GB 的大 MoE 不因激活参数命名（a2b/a1b）被误判精简', () {
      // K90 实机在跑的 lfm2.5-24b-a2b-q4_0 = 13.5GB（总参 24B / 激活 2B）：
      // id 里含 '2b' 命中关键字，但体量否决必须先放行完整档——削它是过度瘦身。
      expect(
        resolveAgentPromptTier(
            modelId: 'lfm2.5-24b-a2b-q4_0', sizeBytes: 13578190880),
        AgentPromptTier.full,
      );
      // 大小未知时仍按 id 判（保持对 tiny 的默认收紧）。
      expect(resolveAgentPromptTier(modelId: 'lfm2.5-8b-a1b-q4_0'),
          AgentPromptTier.compact);
    });
    test('auto：总参两位数的 MoE（35b-a3b）即使体量未知也走完整档', () {
      // K90 上还有 minicpm-v4.7-35b-a3b-les：主 gguf 只有 1.6GB，若只看尺寸
      // 会被误判成小模型——总参命名否决堵掉这条路。
      expect(
        resolveAgentPromptTier(modelId: 'minicpm-v4.7-35b-a3b-les-q4_k_m',
            sizeBytes: 1662732800),
        AgentPromptTier.full,
      );
      // 单位数总量 / 纯激活命名不受影响，照旧收紧。
      expect(resolveAgentPromptTier(modelId: 'minicpm5-2b-q4_k_m',
          sizeBytes: 1500000000), AgentPromptTier.compact);
    });

    test('auto：判不准（未知 id + 大小未知）保守走完整档，行为同旧版', () {
      expect(resolveAgentPromptTier(modelId: 'weird-custom-gguf'),
          AgentPromptTier.full);
    });
  });

  group('buildSystemPrompt 精简档', () {
    test('瘦身：精简档体量不足完整档一半，且留在预算内', () {
      final full = buildSystemPrompt(
        modelName: 'ling-3.0-tiny',
        registry: registry(),
        protocol: PromptJsonProtocol(),
        modelId: 'ling-3.0-tiny-q4_0',
      );
      final compact = buildSystemPrompt(
        modelName: 'ling-3.0-tiny',
        registry: registry(),
        protocol: const PromptJsonProtocol(compact: true),
        modelId: 'ling-3.0-tiny-q4_0',
        tier: AgentPromptTier.compact,
      );
      expect(compact.length * 2 < full.length, isTrue,
          reason: '精简档 ${compact.length} / 完整档 ${full.length}');
      expect(compact.length < kAgentPromptCompactBudgetChars, isTrue);
    });

    test('命门四条留在，11 条长纪律与任务纪律必须缺席', () {
      final compact = buildSystemPrompt(
        modelName: 'ling-3.0-tiny',
        registry: registry(),
        protocol: const PromptJsonProtocol(compact: true),
        modelId: 'ling-3.0-tiny-q4_0',
        tier: AgentPromptTier.compact,
      );
      expect(compact, contains('【工具调用规则】'));
      expect(compact, contains('绝不编造结果，也绝不假装已经执行'));
      expect(compact, contains('信息不足就先问用户，不要猜'));
      expect(compact, contains('直接简短回答用户'));
      // 长纪律（tiny 遵循不动、纯烧 prefill）不得出现在精简档。
      expect(compact, isNot(contains('11. 不需要工具时直接回答用户。')));
      expect(compact, isNot(contains('python_exec / shell_exec 的 stdin')));
      expect(compact, isNot(contains('【任务执行纪律】')));
      expect(compact, isNot(contains('export_file')));
    });

    test('人格仍注入精简档（用户显式选择，瘦身不越权）', () {
      final compact = buildSystemPrompt(
        modelName: 'ling-3.0-tiny',
        registry: registry(),
        protocol: const PromptJsonProtocol(compact: true),
        modelId: 'ling-3.0-tiny-q4_0',
        tier: AgentPromptTier.compact,
        personaName: '写作助手',
        personaPrompt: '简洁、克制。',
      );
      expect(compact, contains('你是「写作助手」——TongYi-Lite 智能体'));
      expect(compact, contains('【人格设定】\n简洁、克制。'));
    });
  });

  group('buildSystemPrompt 完整档（不许被瘦身顺带改坏）', () {
    test('11 条工具纪律 + 任务纪律（API 档）原样保留', () {
      final api = buildSystemPrompt(
        modelName: 'gpt-x',
        registry: registry(),
        protocol: PromptJsonProtocol(),
        modelId: 'gpt-x',
        taskDiscipline: true,
      );
      expect(api, contains('11. 不需要工具时直接回答用户。'));
      expect(api, contains('9. 生成报告/网页/图表/数据文件等产物'));
      expect(api, contains('python_exec / shell_exec 的 stdin'));
      expect(api, contains('【任务执行纪律】'));
      // 完整档 + 文本协议：工具清单照常注入。
      expect(api, contains('[可用工具]'));
      expect(api, contains('[沙箱说明]'));
    });

    test('API 原生 tools 协议：工具走请求体，绝不注入文本清单', () {
      final api = buildSystemPrompt(
        modelName: 'gpt-x',
        registry: registry(),
        protocol: NativeToolProtocol(),
        modelId: 'gpt-x',
        taskDiscipline: true,
      );
      expect(api, isNot(contains('[可用工具]')));
      expect(api, isNot(contains('[工具调用协议]')));
      expect(api, contains('【任务执行纪律】'));
    });
  });

  group('PromptJsonProtocol 精简档呈现', () {
    test('长描述压成首句、沙箱说明省掉、必填标注保留、协议指令保留', () {
      final full = PromptJsonProtocol().buildToolSection(registry(),
          modelId: 'ling-3.0-tiny-q4_0');
      final compact = const PromptJsonProtocol(compact: true)
          .buildToolSection(registry(), modelId: 'ling-3.0-tiny-q4_0');

      expect(full, contains('[沙箱说明]'));
      expect(compact, isNot(contains('[沙箱说明]')));
      expect(full, contains('长任务请缩小规模或改用其它工具'));
      expect(compact, isNot(contains('长任务请缩小规模或改用其它工具')));
      // 必填参数提示是端侧头号失败模式的解药，瘦身不许削。
      expect(compact, contains('- get_weather: 查询指定城市当前天气（必填: location: string）'));
      // Ling（Bailing V3）原生格式指令在精简档仍是训练分布格式。
      expect(compact, contains('<arg_key>query</arg_key>'));
      // 协议指令段（格式示范）两档都必备、体量不变，所以这里只要求
      // 清单部分显著变小（长描述 + 沙箱说明合计 ≥300 字符）。
      expect(compact.length < full.length * 0.75, isTrue,
          reason: '完整 ${full.length} / 精简 ${compact.length}');
    });

    test('默认（compact=false）呈现与旧版逐字节一致', () {
      final r = registry();
      const legacy = PromptJsonProtocol();
      expect(legacy.buildToolSection(r, modelId: 'spark-x2.6-4b'),
          PromptJsonProtocol().buildToolSection(r, modelId: 'spark-x2.6-4b'));
      expect(legacy.buildToolSection(r, modelId: 'spark-x2.6-4b'),
          contains('- python_exec: 在沙盒内执行 Python 代码：注意 stdin 是一次性喂入并关闭的批次输入'));
    });

    test('工具清单为空时不注入任何工具段', () {
      expect(const PromptJsonProtocol(compact: true)
          .buildToolSection(ToolRegistry(), modelId: 'ling-3.0-tiny-q4_0'),
          isEmpty);
    });
  });

  group('精简档工具白名单', () {
    test('核心白名单含真话来源与提问工具，排除 python/shell/run_code', () {
      expect(kAgentCompactCoreTools, contains('get_time'));
      expect(kAgentCompactCoreTools, contains('get_weather'));
      expect(kAgentCompactCoreTools, contains('ask_user_question'));
      for (final banned in const [
        'python_exec',
        'shell_exec',
        'run_code',
        'edit_file',
        'search_text',
        'list_files',
      ]) {
        expect(kAgentCompactCoreTools, isNot(contains(banned)),
            reason: banned);
      }
    });

    test('白名单生效后重型工具既不可见也进不了提示词', () {
      final r = ToolRegistry();
      r.register(lightTool('get_weather', '查询指定城市当前天气',
          required: const ['location']));
      r.register(heavyTool('python_exec'));
      r.restrictModel('ling-3.0-tiny-q4_0', allow: kAgentCompactCoreTools.toSet());

      final visible =
          r.visibleFor('ling-3.0-tiny-q4_0').map((t) => t.name).toList();
      expect(visible, ['get_weather']);
      expect(
          const PromptJsonProtocol(compact: true).buildToolSection(r,
              modelId: 'ling-3.0-tiny-q4_0'),
          isNot(contains('python_exec')));
    });
  });
}
