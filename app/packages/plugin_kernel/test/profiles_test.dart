// 方案档（Profile）的行为钉死。
//
// 这一组最重要的不是"档能用"，而是两条平台纪律：
// ① compose == preview（面板预览与 runtime 加载同一个纯函数，结构上不可能漂移）；
// ② fail-safe（档坏了绝不把用户的插件全关掉）。
import 'dart:convert';

import 'package:plugin_kernel/plugin_kernel.dart';
import 'package:plugin_sdk/testing.dart';
import 'package:test/test.dart';

PluginManifest _m(String id, {List<String> params = const []}) => PluginManifest(
      id: id,
      name: id,
      description: 'd',
      inject: const ['app.store'],
      trust: PluginTrust.declarative,
      permissions: const [PluginPermission.pluginStorage],
      params: [
        for (final p in params)
          PluginParam(name: p, label: p, type: PluginParamType.number, defaultValue: 5),
      ],
    );

class _NoopPlugin implements AppPlugin {
  _NoopPlugin(this.manifest);
  @override
  final PluginManifest manifest;
  @override
  Outcome<Disposable?> apply(PluginCtx ctx) => const Ok<Disposable?>(null);
  @override
  Future<Outcome<PluginRunResult>> run(PluginCtx ctx, PluginInput input) async =>
      const Ok<PluginRunResult>(PluginRunResult(summary: 'ok'));
}

/// 三个声明式插件：a / b / c（c 带一个可调参数 gap）。
BuiltinSourceReader _threePlugins() {
  final b = BuiltinSourceReader();
  for (final e in {'a': const <String>[], 'b': const <String>[], 'c': const ['gap']}.entries) {
    final m = _m(e.key, params: e.value);
    b.register(m, () => _NoopPlugin(m));
  }
  return b;
}

ProfileStore _store(Map<String, Object?> profiles) =>
    ProfileStore(source: () => {for (final e in profiles.entries) e.key: jsonEncode(e.value)});

void main() {
  group('建档（面板「新建方案档」背后的那一小块内核）', () {
    test('档名判的是"能不能当文件名 + 扫不扫得到"，理由必须是人话', () {
      expect(profileNameProblem('课堂'), isNull);
      expect(profileNameProblem('  通勤  '), isNull, reason: '首尾空白是输入习惯，不是错误');
      expect(profileNameProblem(''), contains('不能空着'));
      expect(profileNameProblem('   '), contains('不能空着'), reason: '全空白等于没填');
      expect(profileNameProblem('a' * 41), contains('太长'));
      expect(profileNameProblem('.隐藏'), contains('隐藏文件'), reason: '点开头扫目录扫不到，用户会以为档丢了');
      expect(profileNameProblem('课堂.json'), contains('.json'), reason: '档名带后缀会变成 课堂.json.json');
      for (final bad in ['课堂/通勤', '课堂\\通勤', '课堂:通勤', '课堂*通勤', '课堂?通勤', '课堂"通勤', '课堂<通勤']) {
        expect(profileNameProblem(bad), contains('不能用来做文件名的字符'), reason: '这些名字落盘会炸或跑出目录');
      }
    });

    test('建档形状与 fromJson 严格对齐：写出来的档内核一定读得懂', () {
      final draft = profileDraftJson(
        enabled: {'zh-dictation', 'hello-note'},
        note: '  上课用  ',
        personaId: 'p-teacher',
        modelId: '  ',
      );
      // 排序写出来（同一次选择永远生成同样文本），空白字段整条不写（档没表态 = 宿主不碰）。
      expect(draft['enabled'], ['hello-note', 'zh-dictation']);
      expect(draft['note'], '上课用');
      expect(draft['personaId'], 'p-teacher');
      expect(draft.containsKey('modelId'), isFalse, reason: '空白不等于表态要清空用户模型');
      expect(draft.containsKey('disabled'), isFalse);

      final store = ProfileStore(source: () => {'课堂': jsonEncode(draft)});
      expect(store.profile('课堂')!.enabled, {'hello-note', 'zh-dictation'});
      expect(store.profile('课堂')!.broken, isEmpty, reason: '面板写的档内核读不懂 = 两头各写一遍的病');
      final c = store.compose(active: '课堂', persistedEnabled: {'en-dictation'}, allIds: {'hello-note', 'zh-dictation', 'en-dictation'});
      expect(c.enabled, {'hello-note', 'zh-dictation'});
      expect(c.personaId, 'p-teacher');
    });
  });

  late CapabilityRegistry caps;
  late MemoryEnabledStore enabled;
  late ConfigStore config;
  late PluginService service;

  void build({ProfileStore? profiles, String? Function()? active}) {
    caps = CapabilityRegistry()..register(FakeStore(), ownerPluginId: 'app');
    enabled = MemoryEnabledStore({'a', 'b', 'c'});
    config = ConfigStore();
    service = PluginService(
      loader: PluginLoader(
        capabilities: caps,
        builtin: _threePlugins(),
        appVersion: '0.4.0',
        knownCapabilityIds: kKnownCapabilityIds,
        declarativeFactory: (d) => () => _NoopPlugin(d.manifest),
      ),
      capabilities: caps,
      slots: SlotRegistry(),
      configStore: config,
      enabledStore: enabled,
      profiles: profiles,
      activeProfile: active,
      trace: InMemoryTraceSink(),
    );
  }

  group('方案档决定插件集', () {
    test('档内白名单：只有档里写的插件会起来，其余按未启用停着', () async {
      build(profiles: _store({'课堂': {'enabled': ['a', 'c']}}), active: () => '课堂');
      await service.boot();
      expect(service.result!.byId('a')!.status, PluginLoadStatus.active);
      expect(service.result!.byId('c')!.status, PluginLoadStatus.active);
      expect(service.result!.byId('b')!.status, PluginLoadStatus.disabled,
          reason: '档说没开的插件不许偷偷跑（用户看到的就是"没开"）');
      expect(service.composition.restrictedByProfile, isTrue, reason: '面板要能说"这是档帮你关的"');
    });

    test('档没表态插件集时，照你原来的开关走（档只调参数也是合法用法）', () async {
      build(profiles: _store({'自习': {'config': {'a': {'gap': 2}}}}), active: () => '自习');
      await service.boot();
      expect(service.result!.plugins.where((p) => p.status == PluginLoadStatus.active).map((p) => p.id),
          containsAll(['a', 'b', 'c']));
      expect(service.composition.restrictedByProfile, isFalse);
    });

    test('档内 disabled 先白后黑都要生效', () async {
      build(profiles: _store({'课堂': {'enabled': ['a', 'b', 'c'], 'disabled': ['b']}}), active: () => '课堂');
      await service.boot();
      expect(service.isEnabled('b'), isFalse);
      expect(service.isEnabled('a'), isTrue);
    });

    test('档里写了本机没有的插件：不算错，但要说清楚', () async {
      build(profiles: _store({'课堂': {'enabled': ['a', 'ghost-plugin']}}), active: () => '课堂');
      final r = await service.boot();
      expect(r.valueOrNull!.warnings.any((w) => w.contains('本机没有')), isTrue, reason: '${r.valueOrNull?.warnings}');
      expect(service.result!.byId('a')!.status, PluginLoadStatus.active);
    });
  });

  group('档位层参数', () {
    test('档给的参数进档位层；用户显式改过的仍然更大', () async {
      build(profiles: _store({'课堂': {'config': {'c': {'gap': 2}}}}), active: () => '课堂');
      await service.boot();
      final m = _m('c', params: const ['gap']);
      expect(config.stackFor(m).value('gap'), 2, reason: '档位层覆盖内置默认');

      await service.setConfig(id: 'c', patch: {'gap': 9});
      expect(config.stackFor(m).value('gap'), 9.0, reason: '用户亲手改的赢过档');
    });

    test('换档后旧档删掉的键必须真的消失（整体替换，不是累加）', () async {
      var doc = <String, Object?>{'课堂': {'config': {'c': {'gap': 2, 'repeatTimes': 3}}}};
      final store = ProfileStore(source: () => {for (final e in doc.entries) e.key: jsonEncode(e.value)});
      String? active = '课堂';
      build(profiles: store, active: () => active);
      await service.boot();
      expect(config.profileOf('c')['repeatTimes'], 3);

      doc = {'课堂': {'config': {'c': {'gap': 2}}}}; // 作者把 repeatTimes 从档里删了
      await service.reload();
      expect(config.profileOf('c').containsKey('repeatTimes'), isFalse,
          reason: '档里删掉的键阴魂不散 = 用户再也改不回来');
      expect(config.profileOf('c')['gap'], 2, reason: '档里还留着的键得继续在');
    });
  });

  group('compose == preview 与 fail-safe', () {
    test('compose 是纯函数：同样输入两次结果相同，且不脏调用方的集合', () {
      final store = _store({'课堂': {'enabled': ['a', 'b'], 'disabled': ['b'], 'config': {'a': {'gap': 1}}}});
      final persisted = {'a', 'b', 'c'};
      final r1 = store.compose(active: '课堂', persistedEnabled: persisted, allIds: {'a', 'b', 'c'});
      final r2 = store.compose(active: '课堂', persistedEnabled: persisted, allIds: {'a', 'b', 'c'});
      expect(r1.enabled, r2.enabled);
      expect(r1.config, r2.config);
      expect(persisted, {'a', 'b', 'c'}, reason: 'compose 不许改调用方传进来的集合');
      expect(r1.enabled, {'a'});
    });

    test('runtime 生效的启用集 == 面板预览读到的那个（同一个函数，不是两份逻辑）', () async {
      final store = _store({'课堂': {'enabled': ['a', 'c']}});
      build(profiles: store, active: () => '课堂');
      await service.boot();
      final preview = store.compose(active: '课堂', persistedEnabled: enabled.read(), allIds: {'a', 'b', 'c'});
      final booted = service.view().where((v) => v.loaded.status == PluginLoadStatus.active).map((v) => v.id).toSet();
      expect(booted, preview.enabled, reason: '预览说开两个、实际开两个');
      expect(service.composition.enabled, preview.enabled);
    });

    test('档不存在 / JSON 坏了：退回原来的开关 + 一句警告，绝不全员停用', () async {
      build(profiles: _store({'课堂': {'enabled': ['a']}}), active: () => '不存在');
      final r = await service.boot();
      expect(r.valueOrNull!.warnings.any((w) => w.contains('找不到方案档')), isTrue);
      expect(service.result!.plugins.where((p) => p.status == PluginLoadStatus.active).length, 3,
          reason: '档没读成，用户原来开的必须还开着');

      // 坏 JSON 的档
      final brokenStore = ProfileStore(source: () => {'课堂': '{这不是 JSON'});
      build(profiles: brokenStore, active: () => '课堂');
      final r2 = await service.boot();
      expect(r2.valueOrNull!.warnings.any((w) => w.contains('读不动')), isTrue);
      expect(service.result!.plugins.where((p) => p.status == PluginLoadStatus.active).length, 3);
      expect(brokenStore.brokenProfiles().single.broken, isNotEmpty, reason: '面板要能指出是档坏了');
    });

    test('档读盘直接抛：也只当"没这个档"，不许把平台带崩', () {
      final boom = ProfileStore(source: () => throw StateError('目录没了'));
      final r = boom.compose(active: '课堂', persistedEnabled: {'a'}, allIds: {'a'});
      expect(r.enabled, {'a'});
      expect(r.warnings.any((w) => w.contains('找不到方案档')), isTrue);
    });

    test('人格 / 模型选择随档带出来（宿主拿去落设置；不表态就是 null）', () async {
      final store = _store({'课堂': {'enabled': ['a'], 'personaId': 'p-teacher', 'modelId': 'm-1'}});
      build(profiles: store, active: () => '课堂');
      await service.boot();
      expect(service.composition.personaId, 'p-teacher');
      expect(service.composition.modelId, 'm-1');

      build(profiles: _store({'自习': {'enabled': ['a']}}), active: () => '自习');
      await service.boot();
      expect(service.composition.personaId, isNull, reason: '档没写就别替用户改人格');
    });
  });

    _applyProfileGroup();
}

/// 假的设置侧：能故意"拒绝"某一项（真实设置也会因人格不存在而拒绝）。
class _Sink implements ProfileSettingsSink {
  _Sink({this.personaId, this.defaultModelId, this.activeApiModelId});
  @override
  String? personaId;
  @override
  String? defaultModelId;
  @override
  String? activeApiModelId;
  final List<String> calls = [];
  bool rejectPersona = false;

  @override
  Future<void> usePersona(String? id) async {
    calls.add('persona:$id');
    if (!rejectPersona) personaId = id;
  }

  @override
  Future<void> useDefaultModel(String? id) async {
    calls.add('model:$id');
    defaultModelId = id;
  }

  @override
  Future<void> useApiModel(String? id) async {
    calls.add('api:$id');
    activeApiModelId = id;
  }
}

void _applyProfileGroup() {
  group('切档落到设置', () {
  test('档没表态就一个都不碰（换档不等于替用户清行人格/模型）', () async {
    final sink = _Sink(personaId: 'standard', defaultModelId: 'm0');
    final store = _store({'自习': {'enabled': ['a']}});
    final c = store.compose(active: '自习', persistedEnabled: {'a'}, allIds: {'a', 'b', 'c'});
    expect(await applyProfileSettings(sink, c), isEmpty);
    expect(sink.calls, isEmpty);
    expect(sink.personaId, 'standard');
    expect(sink.defaultModelId, 'm0');
  });

  test('档表态了就三项都切，并带上 API 档（与本地默认模型分开，不串台）', () async {
    final sink = _Sink(activeApiModelId: 'm-old'); // API 档原来有值：换档必须真的盖掉它，而不是留着旧的
    final store = _store({
      '上课': {'enabled': ['a'], 'personaId': 'p-t', 'modelId': 'm-local', 'apiModelId': 'm-api'},
    });
    final c = store.compose(active: '上课', persistedEnabled: {'a'}, allIds: {'a', 'b', 'c'});
    expect(await applyProfileSettings(sink, c), isEmpty);
    expect(sink.calls, ['persona:p-t', 'model:m-local', 'api:m-api']);
  });

  test('设置侧拒绝（人格不存在）→ 人话提醒，不抛也不假装成功', () async {
    final sink = _Sink(personaId: 'standard')..rejectPersona = true;
    final store = _store({'上课': {'personaId': 'ghost-persona'}});
    final c = store.compose(active: '上课', persistedEnabled: {'a'}, allIds: {'a'});
    final notes = await applyProfileSettings(sink, c);
    expect(notes.single, contains('本机没有'));
    expect(sink.personaId, 'standard', reason: '被拒绝就不许留下半截状态');
  });

  test('空串按"不表态"处理（档文件手写成 "modelId": "" 不该把模型清空）', () async {
    final sink = _Sink(defaultModelId: 'm0');
    final store = _store({'上课': {'modelId': '   '}});
    final c = store.compose(active: '上课', persistedEnabled: {'a'}, allIds: {'a'});
    expect(await applyProfileSettings(sink, c), isEmpty);
    expect(sink.defaultModelId, 'm0');
  });
});
}
