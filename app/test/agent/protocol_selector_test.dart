import 'package:flutter_test/flutter_test.dart';

import 'package:tongyi_lite/agent/agent.dart';

/// 模拟原生 tools 协议（测试用）。
class _FakeNativeProtocol implements ToolProtocol {
  @override
  String get id => 'native-tools';

  @override
  bool supports(EngineCapabilities caps) => caps.nativeToolCall;

  @override
  int priority(EngineCapabilities caps) => 100;

  @override
  String buildToolSection(ToolRegistry registry, {String modelId = ''}) => '';

  @override
  Future<StreamOutcome> parseStream(Stream<String> stream) async =>
      const StreamOutcome(text: '');
}

/// 模拟 grammar 协议（测试用）。
class _FakeGrammarProtocol implements ToolProtocol {
  @override
  String get id => 'grammar-json';

  @override
  bool supports(EngineCapabilities caps) => caps.structuredOutput;

  @override
  int priority(EngineCapabilities caps) => 50;

  @override
  String buildToolSection(ToolRegistry registry, {String modelId = ''}) => '';

  @override
  Future<StreamOutcome> parseStream(Stream<String> stream) async =>
      const StreamOutcome(text: '');
}

void main() {
  group('protocol selector', () {
    final protocols = <ToolProtocol>[
      PromptJsonProtocol(),
      _FakeNativeProtocol(),
      _FakeGrammarProtocol(),
    ];

    test('无原生/结构化能力 → 默认选 prompt-json 兜底', () {
      final caps = const EngineCapabilities();
      final selected = selectProtocol(protocols, caps);
      expect(selected.id, PromptJsonProtocol.kId);
    });

    test('原生工具调用 → 选 native-tools（优先级最高）', () {
      final caps = const EngineCapabilities(nativeToolCall: true);
      final selected = selectProtocol(protocols, caps);
      expect(selected.id, 'native-tools');
    });

    test('仅结构化输出 → 选 grammar-json', () {
      final caps = const EngineCapabilities(structuredOutput: true);
      final selected = selectProtocol(protocols, caps);
      expect(selected.id, 'grammar-json');
    });

    test('原生 + 结构化同时具备 → 原生优先（原生 > 结构化 > JSON 文本）', () {
      final caps = const EngineCapabilities(
          nativeToolCall: true, structuredOutput: true);
      final selected = selectProtocol(protocols, caps);
      expect(selected.id, 'native-tools');
    });

    test('无协议支持 → 抛 StateError', () {
      // 只有 native + grammar，能力为 false → 无候选。
      final onlyHigh = <ToolProtocol>[
        _FakeNativeProtocol(),
        _FakeGrammarProtocol(),
      ];
      expect(
        () => selectProtocol(onlyHigh, const EngineCapabilities()),
        throwsStateError,
      );
    });

    test('无协议注册 → 抛 ArgumentError', () {
      expect(
        () => selectProtocol(<ToolProtocol>[], const EngineCapabilities()),
        throwsArgumentError,
      );
    });

    test('能力合并：运行时探测覆盖静态声明，缺失字段回退声明', () {
      const declared = EngineCapabilities(
        nativeToolCall: true,
        toolTemplate: 'spark-native',
        maxContextTokens: 1000000,
      );
      const probed = EngineCapabilities(
        nativeToolCall: true,
        maxContextTokens: 32768,
      );
      final resolved = EngineCapabilities.resolve(
        declared: declared,
        probed: probed,
      );
      expect(resolved.nativeToolCall, isTrue);
      // 运行时探测是"事实"：上下文以实测为准。
      expect(resolved.maxContextTokens, 32768);
      // 探测缺失的字段回退声明。
      expect(resolved.toolTemplate, 'spark-native');
    });

    test('探测为 null → 完全采用静态声明', () {
      const declared = EngineCapabilities(
        nativeToolCall: true,
        maxContextTokens: 1000000,
      );
      final resolved =
          EngineCapabilities.resolve(declared: declared, probed: null);
      expect(resolved.nativeToolCall, isTrue);
      expect(resolved.maxContextTokens, 1000000);
    });
  });
}
