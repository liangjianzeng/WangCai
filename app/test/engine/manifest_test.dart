import 'package:flutter_test/flutter_test.dart';
import 'package:wangcai/engine/bundled_manifests.dart';
import 'package:wangcai/engine/engine_config.dart';
import 'package:wangcai/engine/engine_manifest.dart';

void main() {
  group('模板渲染', () {
    test('必填占位符 + 默认值 + 可选成对删除', () {
      final args = renderArgsTemplate(
        [
          '-m', '{model}',
          '--mmproj', '{mmproj?}',
          '-c', '{ctx=1024}',
          '--port', '{port}',
        ],
        {'model': 'a.gguf', 'port': '8123'},
      );
      expect(args, ['-m', 'a.gguf', '-c', '1024', '--port', '8123']);
    });

    test('提供 mmproj 则成对保留', () {
      final args = renderArgsTemplate(
          ['-m', '{model}', '--mmproj', '{mmproj?}'],
          {'model': 'a.gguf', 'mmproj': 'm.gguf'});
      expect(args, ['-m', 'a.gguf', '--mmproj', 'm.gguf']);
    });

    test('必填缺值抛错', () {
      expect(() => renderArgsTemplate(['-m', '{model}'], {}),
          throwsArgumentError);
    });
  });

  group('内置 manifest', () {
    test('四个驱动可解析且关键字段正确', () {
      final m = bundledManifests();
      expect(m.keys, containsAll(['wangcai-npu', 'llamacpp-vulkan', 'llamacpp-cuda', 'openai-remote']));
      final npu = m['wangcai-npu']!;
      expect(npu.kind, 'llamaServer');
      // M0-3 实测校正：server 参数集不含 -st
      expect(npu.argsTemplate, isNot(contains('-st')));
      expect(npu.argsTemplate, containsAll(<String>['-np', '1', '-fa', '1', '--jinja']));
      expect(npu.capabilities.nativeToolCall, isTrue);
      expect(npu.timingHints.coldCompileMs, 36000);
      expect(m['openai-remote']!.kind, 'remote');
    });

    test('admission：4B@c1024 拦截；1.7B@c1024 与 4B@c512 放行', () {
      final npu = bundledManifests()['wangcai-npu']!;
      expect(npu.checkAdmission(ctx: 1024, paramsB: 4.0), isNotEmpty);
      expect(npu.checkAdmission(ctx: 1024, paramsB: 1.7), isEmpty);
      expect(npu.checkAdmission(ctx: 512, paramsB: 4.0), isEmpty);
    });
  });

  group('profileId（D6 缓存目录隔离）', () {
    EngineConfig cfg({int? ctx, int? chunk, String? dev}) => EngineConfig(
        engineId: 'wangcai-npu',
        modelPath: 'models/LFM3.gguf',
        ctx: ctx ?? 1024,
        chunk: chunk,
        device: dev ?? 'NPU');

    test('同参数同 id；影响编译的参数变 → id 变', () {
      expect(cfg().profileId, cfg().profileId);
      expect(cfg().profileId, isNot(cfg(ctx: 512).profileId));
      expect(cfg().profileId, isNot(cfg(chunk: 128).profileId));
      expect(cfg().profileId, isNot(cfg(dev: 'CPU').profileId));
    });

    test('extraEnv 顺序无关同 id', () {
      final a = EngineConfig(
          engineId: 'e',
          modelPath: 'm',
          extraEnv: const {'A': '1', 'B': '2'});
      final b = EngineConfig(
          engineId: 'e',
          modelPath: 'm',
          extraEnv: const {'B': '2', 'A': '1'});
      expect(a.profileId, b.profileId);
    });
  });
}
