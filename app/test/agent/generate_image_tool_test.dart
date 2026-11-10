// generate_image 工具（入口②）单测：注册门控 / schema 契约 / 执行链
// （缺参 → 未配置 → 成功回调落库钩子）。服务经注入的 fake 隔离网络。
import 'package:dio/dio.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:wangcai/agent/agent.dart';
import 'package:wangcai/services/image_gen_service.dart';

/// fake 服务：继承真实类覆写 generate（工具的 service 注入口为具体类型）。
class _FakeSvc extends ImageGenService {
  _FakeSvc({this.result}) : super(dio: Dio());

  ImageGenResult? result;
  ImageGenConfig? lastConfig;
  String? lastPrompt;

  @override
  Future<ImageGenResult> generate({
    required ImageGenConfig config,
    required String prompt,
    String? size,
    String? negative,
    int? seed,
    int n = 1,
  }) async {
    lastConfig = config;
    lastPrompt = prompt;
    final r = result!;
    return ImageGenResult(paths: r.paths, seed: r.seed, size: r.size, ms: r.ms);
  }
}

class _FailingSvc extends ImageGenService {
  _FailingSvc() : super(dio: Dio());

  @override
  Future<ImageGenResult> generate({
    required ImageGenConfig config,
    required String prompt,
    String? size,
    String? negative,
    int? seed,
    int n = 1,
  }) async {
    throw ImageGenException(
        ImageGenErrorKind.unauthorized, '鉴权失败（API key 错误或已吊销）');
  }
}

void main() {
  group('注册门控（照 weather/web_search 先例）', () {
    test('默认（未传 loader）→ createBuiltinTools 不含 generate_image', () {
      final tools = createBuiltinTools();
      expect(tools.any((t) => t.name == 'generate_image'), isFalse);
    });

    test('传 loader → 注册；独占执行 + 6 分钟预算 + 必填 prompt', () {
      final tools = createBuiltinTools(
          imageGenConfigLoader: () async =>
              const ImageGenConfig(enabled: true, baseUrl: 'http://x'));
      final tool = tools.firstWhere((t) => t.name == 'generate_image');
      expect(tool.isConcurrencySafe!.call(const {}), isFalse,
          reason: '单卡串行：独占执行（同 export_file）');
      expect(tool.timeout, const Duration(minutes: 6));
      final required = (tool.parameters['required'] as List).cast<String>();
      expect(required, contains('prompt'));
      // 描述引导模型使用时机与耗时预期。
      expect(tool.description, contains('生成图片'));
      expect(tool.description, contains('2 分钟'));
    });
  });

  group('执行链', () {
    ToolDefinition toolWith(
            _FakeSvc svc, List<ImageGenResult>? onGen) =>
        createGenerateImageTool(
          configLoader: () async =>
              const ImageGenConfig(enabled: true, baseUrl: 'http://x'),
          service: svc,
          onGenerated: (r, p, m) => onGen?.add(r),
        );

    test('缺 prompt → 可读错误（validate 前的工具自检）', () async {
      final tool = toolWith(_FakeSvc(), null);
      final r = await tool.execute(const {'size': '1024x1024'});
      expect(r.isError, isTrue);
      expect(r.content, contains('prompt'));
    });

    test('成功：返回路径与 seed/尺寸/耗时，onGenerated 带模型名回调', () async {
      final calls = <ImageGenResult>[];
      final svc = _FakeSvc(
          result: const ImageGenResult(
              paths: ['/tmp/a.png', '/tmp/b.png'],
              seed: 7,
              size: '2048x2048',
              ms: 123456));
      final tool = toolWith(svc, calls);
      final r = await tool.execute({
        'prompt': '赛博朋克柴犬',
        'size': '2048x2048',
        'n': 2,
        'seed': 7,
      });
      expect(r.isError, isFalse);
      expect(r.content, contains('/tmp/a.png'));
      expect(r.content, contains('/tmp/b.png'));
      expect(r.content, contains('2048x2048'));
      expect(r.content, contains('seed 7'));
      expect(svc.lastPrompt, '赛博朋克柴犬');
      expect(calls, hasLength(1));
      expect(svc.lastConfig!.effectiveBaseUrl, 'http://x');
    });

    test('服务抛 ImageGenException → 错误文本给模型（不抛出）', () async {
      final tool = createGenerateImageTool(
        configLoader: () async =>
            const ImageGenConfig(enabled: true, baseUrl: 'http://x'),
        service: _FailingSvc(),
      );
      final r = await tool.execute(const {'prompt': 'x'});
      expect(r.isError, isTrue);
      expect(r.content, contains('生图失败'));
      expect(r.content, contains('鉴权失败'));
    });
  });
}
