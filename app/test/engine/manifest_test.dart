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
      // 1fa151d（2026-11-05）：实测冷编 130–420s，预算钉 600s —— 旧值 81s/36s
      // 会硬杀编译导致 blob 永不落盘。
      expect(npu.timingHints.coldCompileMs, 600000);
      expect(m['openai-remote']!.kind, 'remote');
    });

    test('admission：4B@c1024 拦截；1.7B@c1024 与 4B@c512 放行', () {
      final npu = bundledManifests()['wangcai-npu']!;
      expect(npu.checkAdmission(ctx: 1024, paramsB: 4.0), isNotEmpty);
      expect(npu.checkAdmission(ctx: 1024, paramsB: 1.7), isEmpty);
      expect(npu.checkAdmission(ctx: 512, paramsB: 4.0), isEmpty);
    });

    test('admission 世代条件（2026-11-05）：appliesGenerations 名单外豁免', () {
      const rule = AdmissionRule(
          ifCtxGt: 512,
          appliesGenerations: ['ultra1'],
          message: 'm',
          suggestion: 's');
      expect(rule.triggers(ctx: 1024, paramsB: 4.0, generation: 'ultra1'),
          isTrue);
      expect(rule.triggers(ctx: 1024, paramsB: 4.0, generation: 'ultra2'),
          isFalse);
      expect(rule.triggers(ctx: 1024, paramsB: 4.0, generation: null), isTrue,
          reason: '未探测 → 保守全量生效');
      // 默认（无 appliesGenerations）全世代适用 —— 现有 4B 规则即此形态。
      const plain = AdmissionRule(ifCtxGt: 512, message: 'm', suggestion: 's');
      expect(plain.triggers(ctx: 1024, paramsB: 4.0, generation: 'ultra3'),
          isTrue);
    });

    test('admission 实测豁免：ctx 门槛规则让位实测档，非 ctx 规则不让位', () {
      const rule = AdmissionRule(
          ifCtxGt: 512, ifParamsBAtLeast: 3.5, message: 'm', suggestion: 's');
      expect(rule.triggers(ctx: 1024, paramsB: 4.0, measuredCtx: 1024), isFalse,
          reason: '该机已在 1024 跑成功过 → 先验被实测证伪，放行');
      expect(rule.triggers(ctx: 1024, paramsB: 4.0, measuredCtx: 512), isTrue,
          reason: '实测只到 512，1024 仍按先验拦');
      const pureParam =
          AdmissionRule(ifParamsBAtLeast: 7.0, message: 'm', suggestion: 's');
      expect(pureParam.triggers(ctx: 1024, paramsB: 8.0, measuredCtx: 4096),
          isTrue, reason: '纯参数量禁令与实测 ctx 无关，不让位');
      // 无参数量条件的纯 ctx 规则同样豁免（实测就是 ctx 的证据）。
      const ctxOnly = AdmissionRule(ifCtxGt: 2048, message: 'm', suggestion: 's');
      expect(ctxOnly.triggers(ctx: 4096, paramsB: null, measuredCtx: 4096),
          isFalse);
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
