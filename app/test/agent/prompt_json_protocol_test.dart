import 'package:flutter_test/flutter_test.dart';

import 'package:tongyi_lite/agent/agent.dart';
import 'package:tongyi_lite/agent/llm/adapter.dart'
    show LlmFailure, LlmFailureCode;

void main() {
  final protocol = PromptJsonProtocol();

  Stream<String> tokens(String text) async* {
    for (var i = 0; i < text.length; i += 4) {
      yield text.substring(i, (i + 4).clamp(0, text.length));
    }
  }

  group('prompt-json protocol', () {
    test('解析原生工具调用 JSON', () async {
      const text = '{"tool_call": {"name": "get_time", "arguments": {}}}';
      final outcome = await protocol.parseStream(tokens(text));

      expect(outcome.hasToolCalls, isTrue);
      expect(outcome.toolCalls.single.name, 'get_time');
      expect(outcome.toolCalls.single.arguments, isEmpty);
    });

    test('解析 XML 格式工具调用（llama.cpp 原生）', () async {
      const text =
          '<tool_call>web_search<arg_key>q<arg_value>今天天气</tool_call>';
      final outcome = await protocol.parseStream(tokens(text));

      expect(outcome.hasToolCalls, isTrue);
      expect(outcome.toolCalls.single.name, 'web_search');
      expect(outcome.toolCalls.single.arguments?['q'], '今天天气');
    });

    test('XML 无参数工具调用', () async {
      const text = '<tool_call>get_time</tool_call>';
      final outcome = await protocol.parseStream(tokens(text));

      expect(outcome.hasToolCalls, isTrue);
      expect(outcome.toolCalls.single.name, 'get_time');
    });

    test('XML 名字前混入杂散 < 仍容错解析（真机 <tool_call><get_time</tool_call> 定案）',
        () async {
      const text = '<tool_call><get_time</tool_call>';
      final outcome = await protocol.parseStream(tokens(text));

      expect(outcome.hasToolCalls, isTrue);
      expect(outcome.toolCalls.single.name, 'get_time');
    });

    test('闭合标签漏 > 也能定位块尾', () async {
      const text = '<tool_call>get_time</tool_call';
      final outcome = await protocol.parseStream(tokens(text));

      expect(outcome.hasToolCalls, isTrue);
      expect(outcome.toolCalls.single.name, 'get_time');
    });

    test('想调工具但格式坏到解不开 → 抛 toolCallSyntax（不再漏标签当回答）',
        () async {
      // 无工具名、直接进参数区 → 容错也解不开；旧行为把整段原始标签
      // 当普通回答漏给用户（"返回都是tool标签"），现在进可重试失败瀑布。
      const text = '<tool_call><arg_key>query<arg_value>今天天气</tool_call>';
      await expectLater(
        protocol.parseStream(tokens(text)),
        throwsA(isA<LlmFailure>()
            .having((f) => f.code, 'code', LlmFailureCode.toolCallSyntax)),
      );
    });

    test('属性式 <function name=…><parameter name=…>（MiniCPM5 原生格式）',
        () async {
      const text = '<tool_call><function name="get_weather">'
          '<parameter name="city">Nanning</parameter>'
          '</function></tool_call>';
      final outcome = await protocol.parseStream(tokens(text));

      expect(outcome.hasToolCalls, isTrue);
      expect(outcome.toolCalls.single.name, 'get_weather');
      expect(outcome.toolCalls.single.arguments?['city'], 'Nanning');
    });

    test('属性式带回答前缀：前缀保留、块剔除', () async {
      const text = '我查一下。\n<function name="get_time"></function>';
      final outcome = await protocol.parseStream(tokens(text));

      expect(outcome.hasToolCalls, isTrue);
      expect(outcome.toolCalls.single.name, 'get_time');
      expect(outcome.text, contains('我查一下'));
      expect(outcome.text, isNot(contains('function')));
    });

    test('MiniCPM5 特殊标记 <|tool_call_start|>…<|tool_call_end|> 内嵌 JSON',
        () async {
      const text = '<|tool_call_start|>'
          '{"name": "get_weather", "arguments": {"city": "南宁"}}'
          '<|tool_call_end|>';
      final outcome = await protocol.parseStream(tokens(text));

      expect(outcome.hasToolCalls, isTrue);
      expect(outcome.toolCalls.single.name, 'get_weather');
      expect(outcome.toolCalls.single.arguments?['city'], '南宁');
      // 标记不残留在可见回答里。
      expect(outcome.text, isNot(contains('tool_call')));
    });

    test('MiniCPM5 特殊标记无参数调用', () async {
      const text = '<|tool_call_start|>get_time<|tool_call_end|>';
      final outcome = await protocol.parseStream(tokens(text));

      expect(outcome.hasToolCalls, isTrue);
      expect(outcome.toolCalls.single.name, 'get_time');
    });

    test('纯文本回答不受防泄漏兜底影响', () async {
      const text = '你好！有什么我可以帮你的吗？';
      final outcome = await protocol.parseStream(tokens(text));
      expect(outcome.hasToolCalls, isFalse);
      expect(outcome.text, text);
    });

    test('XML 未闭合且无任何收尾 → 判截断（抛 toolCallTruncated，不再静默）',
        () async {
      // 旧行为：整段当普通文本 → turn 静默"完成"，任务半途而废无提示。
      const text = '<tool_call>get_time';
      expect(
        () => protocol.parseStream(tokens(text)),
        throwsA(isA<LlmFailure>()
            .having((f) => f.code, 'code', LlmFailureCode.toolCallTruncated)),
      );
    });

    test('XML 坏格式（值误塞进 arg_key）容错配对', () async {
      const text =
          '<tool_call>web_search<arg_key>query<arg_key>AI news today</arg_value></tool_call>';
      final outcome = await protocol.parseStream(tokens(text));

      expect(outcome.hasToolCalls, isTrue);
      expect(outcome.toolCalls.single.name, 'web_search');
      expect(outcome.toolCalls.single.arguments?['query'], 'AI news today');
    });

    test('XML 坏格式（漏 </tool_call>，以 </arg_key> 收尾）容错解析', () async {
      // 真机实测模型坏格式：<tool_call>web_search<arg_key>query<arg_key>
      // AI news today</arg_value></arg_key>（无 </tool_call> 闭合）。
      const text =
          '<tool_call>web_search<arg_key>query<arg_key>AI news today</arg_value></arg_key>';
      final outcome = await protocol.parseStream(tokens(text));

      expect(outcome.hasToolCalls, isTrue);
      expect(outcome.toolCalls.single.name, 'web_search');
      expect(outcome.toolCalls.single.arguments?['query'], 'AI news today');
    });

    test('XML 标签内嵌 JSON 对象（Qwen/LFM 系训练分布）', () async {
      // LFM2.5 等模型的 chat template：<tool_call> 标签内是 JSON 对象。
      const text =
          '<tool_call>{"name": "web_search", "arguments": {"query": "今天天气"}}</tool_call>';
      final outcome = await protocol.parseStream(tokens(text));

      expect(outcome.hasToolCalls, isTrue);
      expect(outcome.toolCalls.single.name, 'web_search');
      expect(outcome.toolCalls.single.arguments?['query'], '今天天气');
    });

    test('[tool_name()] 签名式调用（LFM 退化输出）：无参数', () async {
      const text = '[get_time()]';
      final outcome = await protocol.parseStream(tokens(text));

      expect(outcome.hasToolCalls, isTrue);
      expect(outcome.toolCalls.single.name, 'get_time');
      expect(outcome.toolCalls.single.arguments, isNull);
    });

    test('[tool_name("arg")] 签名式调用：单参数映射到命名参数', () async {
      const text = '[web_search("今天天气")]';
      final outcome = await protocol.parseStream(tokens(text));

      expect(outcome.hasToolCalls, isTrue);
      expect(outcome.toolCalls.single.name, 'web_search');
      expect(outcome.toolCalls.single.arguments?['query'], '今天天气');
    });

    test('顶层 JSON 对象（OpenAI/LFM 风格，无 tool_call 包裹）', () async {
      const text =
          '{"name": "get_weather", "arguments": {"location": "武汉"}}';
      final outcome = await protocol.parseStream(tokens(text));

      expect(outcome.hasToolCalls, isTrue);
      expect(outcome.toolCalls.single.name, 'get_weather');
      expect(outcome.toolCalls.single.arguments?['location'], '武汉');
    });

    test('XML 块前后文本保留', () async {
      const text =
          '让我查询一下<tool_call>web_search<arg_key>q<arg_value>天气</tool_call>请稍等';
      final outcome = await protocol.parseStream(tokens(text));

      expect(outcome.hasToolCalls, isTrue);
      expect(outcome.toolCalls.single.name, 'web_search');
      expect(outcome.text, '让我查询一下请稍等');
    });

    test('XML 数组参数（todos）解析为 List', () async {
      const text =
          '<tool_call>todo_write<arg_key>todos<arg_value>[{"content": "明天开会", "status": "todo"}]</tool_call>';
      final outcome = await protocol.parseStream(tokens(text));

      expect(outcome.hasToolCalls, isTrue);
      final call = outcome.toolCalls.single;
      expect(call.name, 'todo_write');
      expect(call.arguments?['todos'], isA<List>());
      expect(call.arguments?['todos'][0]['content'], '明天开会');
    });

    test('带参数的工具调用', () async {
      const text =
          '{"tool_call": {"name": "calculator", "arguments": {"expression": "12*7+3"}}}';
      final outcome = await protocol.parseStream(tokens(text));

      expect(outcome.toolCalls.single.name, 'calculator');
      expect(outcome.toolCalls.single.arguments?['expression'], '12*7+3');
    });

    test('流式增量拼装（分片 token）正确解析', () async {
      final text = '{"tool_call":{"name":"calculator",'
          '"arguments":{"expression":"3.5*(2-1)"}}}';
      final outcome = await protocol.parseStream(tokens(text));
      expect(outcome.hasToolCalls, isTrue);
      expect(outcome.toolCalls.single.name, 'calculator');
      expect(outcome.toolCalls.single.arguments?['expression'], '3.5*(2-1)');
    });

    test('无 JSON → 整段作为普通文本回答（优雅降级）', () async {
      const text = '现在时间不方便查询，我直接回答你。';
      final outcome = await protocol.parseStream(tokens(text));

      expect(outcome.hasToolCalls, isFalse);
      expect(outcome.text, text);
    });

    test('JSON 解析失败 → 整段降级为文本', () async {
      const text = '{"tool_call": {"name": "broken"; 不是合法 JSON';
      final outcome = await protocol.parseStream(tokens(text));

      expect(outcome.hasToolCalls, isFalse);
      expect(outcome.text, text);
    });

    test('模型语法错误（逗号写成冒号）≠ 截断 → 降级为文本，不误报 token 不足',
        () async {
      // 补齐收尾括号后仍解不出 JSON，说明错误出自模型自己的语法，
      // 与 token 预算无关：此时报 toolCallTruncated 会让用户去调大
      // 「每轮生成 token」而毫无效果，故按协议契约降级为文本。
      const text = '{"name": "web_search", "arguments": {"query": "天气": 3}';
      final outcome = await protocol.parseStream(tokens(text));

      expect(outcome.hasToolCalls, isFalse);
      expect(outcome.text, text);
    });

    test('合法 JSON 但不是工具调用 → 整段降级为文本', () async {
      const text = '{"answer": "42"}';
      final outcome = await protocol.parseStream(tokens(text));

      expect(outcome.hasToolCalls, isFalse);
      expect(outcome.text, text);
    });

    test('括号不平衡且断在字符串内部 → 抛 toolCallTruncated（不可修复）', () async {
      // 断在字符串内部：参数内容已丢失，绝不伪造执行。
      const text =
          '{"tool_call": {"name": "file_write", "arguments": {"content": "abc';
      expect(
        () => protocol.parseStream(tokens(text)),
        throwsA(isA<LlmFailure>()
            .having((f) => f.code, 'code', LlmFailureCode.toolCallTruncated)),
      );
    });

    test('tool_call 包裹式只差收尾括号 → 自动补全执行', () async {
      const text = '{"tool_call": {"name": "get_time", "arguments": {';
      final outcome = await protocol.parseStream(tokens(text));

      expect(outcome.hasToolCalls, isTrue);
      expect(outcome.toolCalls.single.name, 'get_time');
    });

    test('截断在字符串内部（file_write 内容写一半）→ 抛 toolCallTruncated',
        () async {
      const text =
          '{"name": "file_write", "arguments": {"path": "a.txt", "content": "从前有座';
      expect(
        () => protocol.parseStream(tokens(text)),
        throwsA(isA<LlmFailure>()
            .having((f) => f.code, 'code', LlmFailureCode.toolCallTruncated)),
      );
    });

    test('只差收尾括号的截断 JSON → 自动补全执行（name 完整、参数无损）', () async {
      const text = '{"name": "web_search", "arguments": {"query": "今天天气"}';
      final outcome = await protocol.parseStream(tokens(text));

      expect(outcome.hasToolCalls, isTrue);
      expect(outcome.toolCalls.single.name, 'web_search');
      expect(outcome.toolCalls.single.arguments?['query'], '今天天气');
    });

    test('非工具的 JSON 片段（{"foo": 未完）→ 仍优雅降级为文本', () async {
      const text = '答案如下 {"foo": 4';
      final outcome = await protocol.parseStream(tokens(text));

      expect(outcome.hasToolCalls, isFalse);
      expect(outcome.text, text);
    });

    test('字符串内的大括号不破坏平衡扫描', () async {
      const text = '{"tool_call": {"name": "note", '
          '"arguments": {"content": "a{b}c"}}}';
      final outcome = await protocol.parseStream(tokens(text));

      expect(outcome.hasToolCalls, isTrue);
      expect(outcome.toolCalls.single.arguments?['content'], 'a{b}c');
    });

    test('工具段渲染：注入可用工具与协议指令', () {
      final registry = ToolRegistry();
      registry.register(ToolDefinition(
        name: 'get_time',
        description: '返回当前时间',
        parameters: const {'type': 'object', 'properties': {}},
        execute: (args) async => const ToolResult(content: 'ok'),
      ));
      registry.register(ToolDefinition(
        name: 'shell_exec',
        description: '执行 shell 命令',
        parameters: {
          'type': 'object',
          'properties': {
            'command': {'type': 'string', 'description': '要执行的命令'},
          },
          'required': ['command'],
        },
        execute: (args) async => const ToolResult(content: 'ok'),
      ));

      final section = protocol.buildToolSection(registry);
      expect(section, contains('[可用工具]'));
      expect(section, contains('get_time'));
      expect(section, contains('返回当前时间'));
      expect(section, contains('[工具调用协议]'));
      // 协议指令以 XML 呈现（真机实测 Spark/Qwen 均输出 XML 原生格式，
      // 遵循率更高；解析器双格式兼容 JSON+XML）。
      expect(section, contains('<tool_call>'));
      expect(section, contains('<arg_key>'));
      // 工具清单为文本格式：`- name: description`（贴近小模型训练分布）。
      expect(section, contains('- get_time: 返回当前时间'));
      // 带必填参数的工具呈现参数名提示（对照 DSH schema 呈现），
      // 让模型知道必须给出哪些参数——根治「只调工具不带参数」。
      expect(section,
          contains('- shell_exec: 执行 shell 命令（必填: command: string）'));
    });

    test('按模型渲染工具清单：受限模型不注入不可见工具', () {
      final registry = ToolRegistry();
      registry.register(ToolDefinition(
        name: 'hidden',
        description: 'x',
        parameters: const {'type': 'object'},
        execute: (args) async => const ToolResult(content: 'ok'),
      ));
      registry.restrictModel('m1', allow: {});

      // 默认视图（全局层）仍可见。
      expect(protocol.buildToolSection(registry), contains('hidden'));
      // 受限模型视图不注入该工具。
      expect(protocol.buildToolSection(registry, modelId: 'm1'), isEmpty);
    });

    test('按模型选择调用协议指令：Ling（Bailing V3）用原生闭合标签格式', () {
      final registry = ToolRegistry();
      registry.register(ToolDefinition(
        name: 'get_time',
        description: '返回当前时间',
        parameters: const {'type': 'object'},
        execute: (args) async => const ToolResult(content: 'ok'),
      ));

      // Ling 系：指令含闭合标签 <arg_key>…</arg_key> 示例（训练分布格式）。
      final ling = protocol.buildToolSection(
          registry, modelId: 'ling-3.0-tiny-q4_k_m');
      expect(ling, contains('<arg_key>query</arg_key>'));
      expect(ling, contains('<arg_value>今天天气</arg_value>'));

      // LFM 系：JSON 格式指令不变。
      final lfm = protocol.buildToolSection(
          registry, modelId: 'lfm2.5-8b-a1b-q4_0');
      expect(lfm, contains('{"name": "get_time", "arguments": {}}'));

      // 其它（Spark/Qwen 系）：半开标签 XML 格式指令不变。
      final generic =
          protocol.buildToolSection(registry, modelId: 'spark-x2.6-4b');
      expect(generic, contains('<tool_call>web_search<arg_key>query'));
    });
  });

  group('Ling（Bailing V3）原生工具调用格式解析', () {
    test('带参数：换行 + 闭合标签格式', () async {
      const text = '<tool_call>\nweb_search\n'
          '<arg_key>query</arg_key>\n'
          '<arg_value>今天天气</arg_value>\n'
          '</tool_call>';
      final outcome = await protocol.parseStream(tokens(text));

      expect(outcome.hasToolCalls, isTrue);
      expect(outcome.toolCalls.single.name, 'web_search');
      expect(outcome.toolCalls.single.arguments?['query'], '今天天气');
    });

    test('无参数：仅工具名一行', () async {
      const text = '好的，我来查一下。\n<tool_call>\nget_time\n</tool_call>';
      final outcome = await protocol.parseStream(tokens(text));

      expect(outcome.hasToolCalls, isTrue);
      expect(outcome.toolCalls.single.name, 'get_time');
      expect(outcome.toolCalls.single.arguments, isEmpty);
      expect(outcome.text, contains('好的，我来查一下。'));
      expect(outcome.text, isNot(contains('<tool_call>')));
    });

    test('数组参数：JSON 值按 JSON 解码', () async {
      const text = '<tool_call>\ntodo_write\n'
          '<arg_key>todos</arg_key>\n'
          '<arg_value>[{"content": "明天开会", "status": "todo"}]</arg_value>\n'
          '</tool_call>';
      final outcome = await protocol.parseStream(tokens(text));

      expect(outcome.hasToolCalls, isTrue);
      expect(outcome.toolCalls.single.name, 'todo_write');
      final todos = outcome.toolCalls.single.arguments?['todos'];
      expect(todos, isA<List<dynamic>>());
      expect((todos as List).first['content'], '明天开会');
    });

    test('think 包裹（Bailing V3 思考默认开）：think 块后跟工具调用块', () async {
      const text = '<think>用户想知道时间，我应该调用 get_time 工具。</think>\n'
          '<tool_call>\nget_time\n</tool_call>';
      final outcome = await protocol.parseStream(tokens(text));

      expect(outcome.hasToolCalls, isTrue);
      expect(outcome.toolCalls.single.name, 'get_time');
    });
  });
}
