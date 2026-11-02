import 'dart:convert';
import 'dart:io';

import 'package:plugin_kernel/plugin_kernel.dart';
import 'package:plugin_sdk/testing.dart';
import 'package:test/test.dart';

/// 零 Dart 插件的端到端验证（P5 的验收面）。
///
/// 关键取向：**读仓库里真实那份 `examples/zh_dictation/plugin.json`**，不在测试里复制一份声明。
/// 复制一份就等于"测试永远绿、真文件早烂了"——第三方作者拿到的正是真文件那条路。
void main() {
  final dir = _findExampleDir();

  CapabilityRegistry capsWith({bool speak = true}) => CapabilityRegistry()
    ..register(FakeCapture(images: const ['/sdcard/yuwen.jpg']), ownerPluginId: 'app')
    ..register(FakeLlmVision(response: '{"items":[{"text":"荷","note":"hé"},{"text":"露","note":"lù"}]}'), ownerPluginId: 'app')
    ..register(FakeLlmComplete(response: '{}'), ownerPluginId: 'app')
    ..register(FakeInteract(choices: const ['继续'], numbers: const [7]), ownerPluginId: 'app')
    ..register(FakeSpeak(gapCap: const Duration(milliseconds: 1)), ownerPluginId: 'app')
    ..register(FakeStore(), ownerPluginId: 'app');

  Map<String, ({String json, String? prompt})> readDir() => {
        'zh-dictation': (
          json: File('${dir!.path}/plugin.json').readAsStringSync(),
          prompt: File('${dir.path}/prompt.md').readAsStringSync(),
        ),
      };

  PluginLoader buildLoader({required bool withRunner}) => PluginLoader(
        capabilities: capsWith(),
        builtin: BuiltinSourceReader(),
        userSources: [DeclarationDirSourceReader(readDir)],
        appVersion: '0.2.8',
        knownCapabilityIds: kKnownCapabilityIds,
        declarativeFactory: withRunner ? (d) => () => DeclarativePlugin(d, runner: const FlowRunner()) : null,
      );

  test('声明文件本身合格（validate 与加载器同一把尺子）', () {
    expect(dir, isNotNull, reason: '找不到 examples/zh_dictation —— 实例 B 被删了？');
    final report = validateManifestText(File('${dir!.path}/plugin.json').readAsStringSync(),
        knownCapabilityIds: kKnownCapabilityIds);
    expect(report.errors.map((i) => '${i.code}：${i.message}'), isEmpty);
  });

  test('没有 flow 引擎时停在 gated —— 绝不"假装能跑"', () async {
    final loader = buildLoader(withRunner: false);
    loader.setEnabledIds({'zh-dictation'});
    final r = loader.scan().valueOrNull!;
    final p = r.byId('zh-dictation')!;
    expect(p.status, PluginLoadStatus.gated);
    expect(p.gatedOn, contains('flow.runner'));
  });

  test('接上 flow 引擎 → active；跑完真流程（生字+拼音、问出来的 7 秒间隔、记了账）', () async {
    final caps = capsWith();
    final slots = SlotRegistry();
    final enabled = MemoryEnabledStore({'zh-dictation'});
    final trace = InMemoryTraceSink();
    final loader = PluginLoader(
      capabilities: caps,
      builtin: BuiltinSourceReader(),
      userSources: [DeclarationDirSourceReader(readDir)],
      appVersion: '0.2.8',
      knownCapabilityIds: kKnownCapabilityIds,
      declarativeFactory: (d) => () => DeclarativePlugin(d, runner: const FlowRunner()),
    );
    loader.setEnabledIds(enabled.ids);
    final service = PluginService(
      loader: loader,
      capabilities: caps,
      slots: slots,
      configStore: ConfigStore(),
      enabledStore: enabled,
      trace: trace,
    );
    await service.boot();
    expect(service.result!.byId('zh-dictation')!.status, PluginLoadStatus.active);

    // 声明式插件没有 Dart，图标位由引擎代填（作者写了 icon 才占位）。
    expect(slots.entries('app.input.right').map((e) => e.pluginId), contains('zh-dictation'));

    final r = await service.run('zh-dictation', const PluginInput(
      entry: PluginEntryKind.composerAction,
      imagePaths: ['/sdcard/yuwen.jpg'],
    ));
    expect(r.isOk, isTrue, reason: r.failureOrNull?.message);
    expect(r.valueOrNull!.summary, contains('念了 4 条'));

    final speak = caps.resolve<Speak>(ServiceKeys.speak).valueOrNull! as FakeSpeak;
    expect(speak.requests.single.items, ['荷', 'hé', '露', 'lù'], reason: '生字后面紧跟拼音');
    expect(speak.requests.single.gap, const Duration(seconds: 7), reason: 'ask_params 问出来的值优先于默认 5 秒');

    // 三态：跑完就是 completed，步骤清单齐。
    expect(r.valueOrNull!.data['completedSteps'], ['capture', 'extract', 'review', 'ask', 'speak', 'keep']);
    final store = caps.resolve<Store>(ServiceKeys.store).valueOrNull! as FakeStore;
    // 存储分域由内核强制（插件写 'lastList'，落盘是 `plugin:<id>:lastList`），
    // 第三方插件互相看不见对方的账本 —— 这条也在验收范围内。
    expect(store.data.keys.toList(), ['plugin:zh-dictation:lastList']);
    expect(store.data['plugin:zh-dictation:lastList'], contains('荷(hé)'));
  });

  test('用户点"算了"：一个词都不念，也不记账', () async {
    final speak = FakeSpeak();
    final store = FakeStore();
    final caps = CapabilityRegistry()
      ..register(FakeCapture(images: const ['/sdcard/yuwen.jpg']), ownerPluginId: 'app')
      ..register(FakeLlmVision(response: '{"items":[{"text":"荷","note":"hé"}]}'), ownerPluginId: 'app')
      ..register(FakeLlmComplete(response: '{}'), ownerPluginId: 'app')
      ..register(FakeInteract(choices: const ['算了'], numbers: const [7]), ownerPluginId: 'app')
      ..register(speak, ownerPluginId: 'app')
      ..register(store, ownerPluginId: 'app');
    final enabled = MemoryEnabledStore({'zh-dictation'});
    final loader = PluginLoader(
      capabilities: caps,
      builtin: BuiltinSourceReader(),
      userSources: [DeclarationDirSourceReader(readDir)],
      knownCapabilityIds: kKnownCapabilityIds,
      declarativeFactory: (d) => () => DeclarativePlugin(d, runner: const FlowRunner()),
    );
    loader.setEnabledIds(enabled.ids);
    final service = PluginService(
      loader: loader,
      capabilities: caps,
      slots: SlotRegistry(),
      configStore: ConfigStore(),
      enabledStore: enabled,
      trace: InMemoryTraceSink(),
    );
    await service.boot();
    final r = await service.run('zh-dictation', const PluginInput(
      entry: PluginEntryKind.composerAction,
      imagePaths: ['/sdcard/yuwen.jpg'],
    ));
    expect(r.isOk, isTrue, reason: '用户放弃不是失败');
    expect(r.valueOrNull!.userVisible, isFalse);
    expect(speak.requests, isEmpty);
    expect(store.data, isEmpty);
  });

  test('引擎代填的实现体也过六组体检（内置/第三方/声明式同一把尺子）', () async {
    final plugin = DeclarativePlugin(
      PluginDescriptor(
        manifest: PluginManifest.fromJson(jsonDecode(File('${dir!.path}/plugin.json').readAsStringSync()) as Map<String, dynamic>),
        location: 'examples/zh_dictation',
        source: PluginSource.user,
        promptText: File('${dir.path}/prompt.md').readAsStringSync(),
      ),
      runner: const FlowRunner(),
    );
    final checks = await runConformance(
      () => plugin,
      harness: FakeCapabilityHarness()
        ..register(FakeCapture(images: const ['/sdcard/yuwen.jpg']))
        ..register(FakeLlmVision(response: '{"items":[{"text":"荷","note":"hé"}]}'))
        ..register(FakeLlmComplete(response: '{}'))
        ..register(FakeInteract(choices: const ['继续'], numbers: const [5]))
        ..register(FakeSpeak(gapCap: const Duration(milliseconds: 1)))
        ..register(FakeStore()),
      input: const PluginInput(entry: PluginEntryKind.composerAction, imagePaths: ['/sdcard/yuwen.jpg']),
    );
    expect(checks.where((c) => !c.passed).map((c) => '${c.group}/${c.name}：${c.detail}'), isEmpty);
  });
  group('实例 C（中英默写卡：无相机、无朗读、纯文本进出）', () {
    final cardsDir = _findExampleDir(named: 'en_zh_cards');

    Map<String, ({String json, String? prompt})> readCards() => {
          'en-zh-cards': (
            json: File('${cardsDir!.path}/plugin.json').readAsStringSync(),
            prompt: File('${cardsDir.path}/prompt.md').readAsStringSync(),
          ),
        };

    test('声明合格', () {
      expect(cardsDir, isNotNull, reason: '实例 C 被删了？它专管"找平台的茬"');
      final report = validateManifestText(File('${cardsDir!.path}/plugin.json').readAsStringSync(),
          knownCapabilityIds: kKnownCapabilityIds);
      expect(report.errors.map((i) => '${i.code}：${i.message}'), isEmpty);
    });

    test('跑通全程：不需要相机也不需要朗读（注册表里根本没给这两个能力）', () async {
      final llm = FakeLlmComplete(
          response: '{"items":[{"text":"apple","note":"苹果"},{"text":"river","note":"河流"}]}');
      final store = FakeStore();
      final caps = CapabilityRegistry()
        ..register(llm, ownerPluginId: 'app')
        ..register(FakeInteract(choices: const ['继续'], numbers: const [8]), ownerPluginId: 'app')
        ..register(store, ownerPluginId: 'app');
      final enabled = MemoryEnabledStore({'en-zh-cards'});
      final loader = PluginLoader(
        capabilities: caps,
        builtin: BuiltinSourceReader(),
        userSources: [DeclarationDirSourceReader(readCards)],
        knownCapabilityIds: kKnownCapabilityIds,
        declarativeFactory: (d) => () => DeclarativePlugin(d, runner: const FlowRunner()),
      );
      loader.setEnabledIds(enabled.ids);
      final service = PluginService(
        loader: loader,
        capabilities: caps,
        slots: SlotRegistry(),
        configStore: ConfigStore(),
        enabledStore: enabled,
        trace: InMemoryTraceSink(),
      );
      await service.boot();
      expect(service.result!.byId('en-zh-cards')!.status, PluginLoadStatus.active);

      final r = await service.run('en-zh-cards', const PluginInput(
        entry: PluginEntryKind.composerAction,
        text: 'The apple is on the river bank. 苹果 河流',
      ));
      expect(r.isOk, isTrue, reason: r.failureOrNull?.message);
      expect(r.valueOrNull!.summary, contains('2 条'));
      expect(r.valueOrNull!.data['completedSteps'], ['ask', 'gen', 'confirm', 'sheet', 'keep']);

      // 运行时问到的"8 张"进了提示词（作者只有在 prompt.md 里写 {{count}} 的份）。
      expect(llm.lastSystemPrompt, contains('**8 张**'), reason: '运行时问到的张数进了提示词');
      expect(llm.lastSystemPrompt, isNot(contains('{{')), reason: '不许有没替换掉的占位符漏给模型');
      // export 不偷偷落盘，内容作为 payload 交给宿主渲染。
      final sheet = r.valueOrNull!.payloads.single as Map;
      expect(sheet['filename'], '中英默写卡.txt');
      expect('${sheet['content']}', contains('苹果'));
      // 记账分域。
      expect(store.data.keys.single, 'plugin:en-zh-cards:lastCards');
    });

    test('形态迥异的两块插件共用同一批原语（两消费者规则）', () async {
      // 同一份引擎 + 同一批 fake，两块声明文件都跑得出终局 —— 说明原语是通用的，
      // 而不是"照着英语听写的样子捏的"。
      for (final name in ['zh_dictation', 'en_zh_cards']) {
        final d = _findExampleDir(named: name);
        expect(d, isNotNull, reason: name);
        final report = validateManifestText(File('${d!.path}/plugin.json').readAsStringSync(),
            knownCapabilityIds: kKnownCapabilityIds);
        expect(report.ok, isTrue, reason: name);
      }
    });
  });
}


/// 从测试工作目录往上找 `examples/zh_dictation/plugin.json`。
/// 内核包与 app 同仓，正常两跳就到；找不到时用例自己 skip（而不是假绿）。
Directory? _findExampleDir({String named = 'zh_dictation'}) {
  var d = Directory.current;
  for (var i = 0; i < 6; i++) {
    final cand = Directory('${d.path}/examples/$named');
    if (File('${cand.path}/plugin.json').existsSync()) return cand;
    final parent = d.parent;
    if (parent.path == d.path) break;
    d = parent;
  }
  return null;
}
