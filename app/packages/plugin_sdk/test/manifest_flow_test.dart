import 'dart:convert';

import 'package:plugin_sdk/plugin_sdk.dart';
import 'package:test/test.dart';

void main() {
  const manifest = PluginManifest(
    id: 'english-dictation',
    name: '英语听写',
    description: '拍照抽词并按间隔朗读',
    whenToUse: '用户要听写单词时',
    icon: 'graphic_eq',
    source: PluginSource.builtin,
    trust: PluginTrust.trusted,
    enabledByDefault: true,
    inject: ['app.speak', 'llm.vision', 'app.capture'],
    permissions: [PluginPermission.speechSynthesis, PluginPermission.llmVision, PluginPermission.camera],
    enginesApp: '>=0.3.4',
    params: [
      PluginParam(name: 'gapSeconds', label: '间隔秒数', type: PluginParamType.number, defaultValue: 5, min: 1, max: 30, askAtStart: true),
    ],
    config: {'gapSeconds': 8},
    profiles: ['日常听写'],
    flow: FlowMeta(
      name: '听写一轮',
      description: '拍照 → 抽词 → 确认 → 朗读',
      whenToUse: '听写',
      phases: [FlowPhase(id: 'extract', title: '识别'), FlowPhase(id: 'play', title: '朗读', optional: true)],
      steps: [
        FlowStep(id: 'shoot', op: FlowStepOp.capture, phase: 'extract'),
        FlowStep(id: 'play', op: FlowStepOp.speakSequence, phase: 'play', onFailure: FlowStepFailure.skipWithWarning, timeoutSeconds: 120),
      ],
    ),
  );

  group('manifest 序列化', () {
    test('JSON 往返保真（面板保存/读取不能丢字段）', () {
      final back = PluginManifest.fromJson(jsonDecode(jsonEncode(manifest.toJson())) as Map<String, dynamic>);
      expect(back.id, manifest.id);
      expect(back.manifestVersion, kSupportedManifestVersion);
      expect(back.source, PluginSource.builtin);
      expect(back.trust, PluginTrust.trusted);
      expect(back.enabledByDefault, isTrue);
      expect(back.inject, manifest.inject);
      expect(back.permissions, manifest.permissions);
      expect(back.enginesApp, '>=0.3.4');
      expect(back.params.single.askAtStart, isTrue);
      expect(back.params.single.min, 1);
      expect(back.config['gapSeconds'], 8);
      expect(back.profiles, ['日常听写']);
      expect(back.flow!.steps.last.op, FlowStepOp.speakSequence);
      expect(back.flow!.steps.last.onFailure, FlowStepFailure.skipWithWarning);
      expect(back.flow!.phases.last.optional, isTrue);
    });

    test('omit-null 策略：没给的字段不落盘（保持 plugin.json 干净）', () {
      const minimal = PluginManifest(id: 'mini-plugin', name: 'M', description: 'd');
      final j = minimal.toJson();
      expect(j.containsKey('icon'), isFalse);
      expect(j.containsKey('flow'), isFalse);
      expect(j.containsKey('engines'), isFalse);
      expect(j['trust'], 'declarative');
      expect(j['manifestVersion'], 1);
    });

    test('rank 未写时按来源推（builtin 100 / user 200，同名遮蔽靠它）', () {
      expect(manifest.effectiveRank, 100);
      const user = PluginManifest(id: 'mini-plugin', name: 'M', description: 'd');
      expect(user.effectiveRank, 200);
      const pinned = PluginManifest(id: 'mini-plugin', name: 'M', description: 'd', rank: 300);
      expect(pinned.effectiveRank, 300);
    });

    test('config 里有参数时优先于 params 默认值（默认值层的唯一判定）', () {
      expect(manifest.effectiveParamValue(manifest.params.single), 8);
      expect(manifest.copyWithConfig(const {}).effectiveParamValue(manifest.params.single), 5);
    });

    test('未知枚举值降级而不是崩（前向兼容）', () {
      final j = manifest.toJson()
        ..['trust'] = 'from_the_future'
        ..['source'] = 'alien'
        ..['permissions'] = ['tts', 'mind_control'];
      final back = PluginManifest.fromJson(j);
      expect(back.trust, PluginTrust.declarative);
      expect(back.source, PluginSource.user);
      expect(back.permissions, [PluginPermission.speechSynthesis]);
    });
  });

  group('参数取值判定（校验器与运行时共用一份）', () {
    const n = PluginParam(name: 'gap', label: 'g', type: PluginParamType.number, min: 1, max: 10);
    const ch = PluginParam(name: 'v', label: 'v', type: PluginParamType.choice, options: ['a', 'b']);
    const txt = PluginParam(name: 't', label: 't', type: PluginParamType.text);

    test('number 区间内外', () {
      expect(n.acceptsValue(5), isTrue);
      expect(n.acceptsValue(1), isTrue);
      expect(n.acceptsValue(0), isFalse);
      expect(n.acceptsValue(10.5), isFalse);
      expect(n.acceptsValue('5'), isFalse);
    });
    test('choice 必须在候选项里', () {
      expect(ch.acceptsValue('a'), isTrue);
      expect(ch.acceptsValue('c'), isFalse);
    });
    test('text 有上限（防把整本书塞进配置）', () {
      expect(txt.acceptsValue('ok'), isTrue);
      expect(txt.acceptsValue('x' * 5000), isFalse);
    });
  });

  group('flow 契约', () {
    test('每个原语自带隐含权限（校验器与运行时同一真相）', () {
      expect(FlowStepOp.speakSequence.impliedPermissions, containsAll(<String>['tts', 'network']));
      expect(FlowStepOp.capture.impliedPermissions, containsAll(<String>['camera', 'photo_library']));
      expect(FlowStepOp.review.impliedPermissions, isEmpty);
    });

    test('wire 名解析：未知返回 null（由校验器报错，绝不静默当成某个已知步骤）', () {
      expect(flowStepOpFromWire('llm_extract'), FlowStepOp.llmExtract);
      expect(flowStepOpFromWire('llmExtract'), isNull);
      expect(permissionFromWire('storage:plugin'), PluginPermission.pluginStorage);
      expect(permissionFromWire('storage'), isNull);
    });

    test('FlowResult 三态闭集：没有"半途而废当成功"这一档', () {
      final cancelled = FlowResult.cancelled(reason: '用户停止', completedSteps: ['shoot']);
      expect(cancelled.isSuccess, isFalse);
      expect(cancelled.stopReason, FlowStopReason.cancelled);
      expect(cancelled.completedSteps, ['shoot'], reason: '必须说清停在哪');
      final failed = FlowResult.failed(error: '没认出单词', completedSteps: const ['shoot'], skippedSteps: const ['play']);
      expect(failed.stopReason, FlowStopReason.error);
      expect(failed.skippedSteps, ['play']);
      expect(FlowStopReason.values.length, 3);
    });

    test('flow JSON 往返（用户手改 plugin.json 后仍可读回）', () {
      final back = FlowMeta.fromJson(jsonDecode(jsonEncode(manifest.flow!.toJson())) as Map<String, dynamic>);
      expect(back.steps.map((s) => s.op), [FlowStepOp.capture, FlowStepOp.speakSequence]);
      expect(back.steps.last.timeoutSeconds, 120);
    });
  });

  group('能力键契约', () {
    test('ServiceKey 以 id + contractVersion 为身份（同名不同版本可共存）', () {
      const a = ServiceKey<LlmComplete>('llm.complete');
      const b = ServiceKey<LlmComplete>('llm.complete', contractVersion: 'v2');
      expect(a, isNot(b));
      expect(a, const ServiceKey<LlmComplete>('llm.complete'));
      expect(a.toString(), 'llm.complete@v1');
    });

    test('能力谎报不可用却没说原因 → probe 给出路（面板能解释）', () async {
      final c = _AlwaysDown();
      expect(c.available, isFalse);
      final r = await c.probe();
      expect(r.failureOrNull?.code, PluginFailureKind.missingCapability);
      expect(r.failureOrNull?.hint, contains('见「设置」页对应开关'),
          reason: '能力谎报不可用又没说原因时，SDK 必须替它给一条能照着做的出路（治理面板要拿它显示）');
    });
  });
}

class _AlwaysDown with CapabilityBase implements Capability {
  @override
  ServiceKey get key => const ServiceKey<_AlwaysDown>('x.thing');
  @override
  bool get available => false;
  @override
  String? get unavailableReason => '还没加载模型';
}
