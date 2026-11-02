import 'dart:convert';

import 'package:plugin_kernel/plugin_kernel.dart';
import 'package:plugin_sdk/testing.dart';
import 'package:test/test.dart';

/// 故意 throw 的插件：平台必须把第三方作者的失误**关在门外**。
class _ThrowingPlugin implements AppPlugin {
  _ThrowingPlugin(this.manifest, {this.cancel = false, this.message = 'boom'});
  @override
  final PluginManifest manifest;
  final bool cancel;
  final String message;

  @override
  Outcome<Disposable?> apply(PluginCtx ctx) => const Ok<Disposable?>(null);

  @override
  Future<Outcome<PluginRunResult>> run(PluginCtx ctx, PluginInput input) async {
    if (cancel) {
      ctx.cancelToken.cancel('用户按了停止');
      ctx.cancelToken.throwIfCancelled(); // 抛取消信号
    }
    throw StateError(message);
  }
}

/// 只用来观察"预热有没有走到实现"。
class _RecordingSpeak implements Speak {
  _RecordingSpeak({this.available = true});

  final bool available;
  int warmed = 0;

  @override
  String? get unavailableReason => available ? null : '测试：这台机器上没有它';

  @override
  ServiceKey get key => ServiceKeys.speak;

  @override
  Future<void> warmUp() async => warmed += 1;

  @override
  Future<Outcome<void>> probe() async => const Ok<void>(null);

  @override
  Future<void> stop() async {}

  @override
  Future<bool> prewarm(List<String> texts, String voice) async => true;

  @override
  Stream<SpeakProgress> speak(SpeakRequest request, PluginCancelToken token) => const Stream<SpeakProgress>.empty();
}

/// 启动时给自己写一个会话内临时值：验证"临时值归 ConfigStore 所有"，
/// 面板与内核用 `stackFor` 才看得见（以前只有这个 ctx 自己知道）。
class _WritesSession implements AppPlugin {
  _WritesSession(this.manifest);
  @override
  final PluginManifest manifest;

  @override
  Outcome<Disposable?> apply(PluginCtx ctx) {
    ctx.setSessionOverride('gapSeconds', 11);
    return const Ok<Disposable?>(null);
  }

  @override
  Future<Outcome<PluginRunResult>> run(PluginCtx ctx, PluginInput input) async =>
      Ok<PluginRunResult>(PluginRunResult(summary: 'ok'));
}

/// apply 时注册一个带释放器的 effect：`shutdown` 没被调用时它就是泄漏的 Timer。
class _DisposingPlugin implements AppPlugin {
  _DisposingPlugin(this.manifest, this.onDispose);
  @override
  final PluginManifest manifest;
  final void Function() onDispose;

  @override
  Outcome<Disposable?> apply(PluginCtx ctx) {
    ctx.effect(() => onDispose());
    return const Ok<Disposable?>(null);
  }

  @override
  Future<Outcome<PluginRunResult>> run(PluginCtx ctx, PluginInput input) async =>
      Ok<PluginRunResult>(PluginRunResult(summary: 'ok'));
}

class _LogsInApply implements AppPlugin {
  _LogsInApply(this.manifest);
  @override
  final PluginManifest manifest;

  @override
  Outcome<Disposable?> apply(PluginCtx ctx) {
    ctx.log.info('我 apply 了一次');
    return const Ok<Disposable?>(null);
  }

  @override
  Future<Outcome<PluginRunResult>> run(PluginCtx ctx, PluginInput input) async =>
      Ok<PluginRunResult>(PluginRunResult(summary: 'ok'));
}

/// apply 里注册槽条目但**故意不挂 effect**（现实中作者常忘的那一步）。
class _LazySlotPlugin implements AppPlugin {
  _LazySlotPlugin(this.manifest);
  @override
  final PluginManifest manifest;

  @override
  Outcome<Disposable?> apply(PluginCtx ctx) {
    final r = ctx.slots.register(SlotContribution<Object?>(
      slotId: 'ghost.panel',
      pluginId: ctx.manifest.id,
      id: 'chip',
      label: '幽灵',
      payload: 'chip',
    ));
    if (r.isErr) return Err<Disposable?>(r.failureOrNull!);
    return const Ok<Disposable?>(null); // 注意：没把 r 挂进 ctx.effect
  }

  @override
  Future<Outcome<PluginRunResult>> run(PluginCtx ctx, PluginInput input) async =>
      Ok<PluginRunResult>(PluginRunResult(summary: 'ok'));
}

/// apply 里 provide 能力但**故意不挂 effect**。
class _LazyProvidePlugin implements AppPlugin {
  _LazyProvidePlugin(this.manifest);
  @override
  final PluginManifest manifest;

  @override
  Outcome<Disposable?> apply(PluginCtx ctx) {
    final r = ctx.capabilities.provide<Capability>(const ServiceKey<Capability>('demo.thing'), _DemoThing());
    return r.isErr ? Err<Disposable?>(r.failureOrNull!) : const Ok<Disposable?>(null);
  }

  @override
  Future<Outcome<PluginRunResult>> run(PluginCtx ctx, PluginInput input) async =>
      Ok<PluginRunResult>(PluginRunResult(summary: 'ok'));
}

class _DemoThing implements Capability {
  @override
  ServiceKey get key => const ServiceKey<Capability>('demo.thing');
  @override
  bool get available => true;
  @override
  String? get unavailableReason => null;
  @override
  Future<void> warmUp() async {}
  @override
  Future<Outcome<void>> probe() async => const Ok<void>(null);
}

class _CountingPlugin implements AppPlugin {
  _CountingPlugin(this.manifest);
  @override
  final PluginManifest manifest;
  int applyCount = 0;
  int runCount = 0;
  final List<String> disposed = [];

  @override
  Outcome<Disposable?> apply(PluginCtx ctx) {
    applyCount++;
    final r = ctx.slots.register(SlotContribution<Object?>(
      slotId: 'app.input.right',
      pluginId: manifest.id,
      id: 'chip',
      label: manifest.name,
      payload: 'icon',
    ));
    if (r.isErr) return Err<Disposable?>(r.failureOrNull!);
    ctx.effect(r.valueOrNull!);
    ctx.effect(() => disposed.add('chip'));
    return const Ok<Disposable?>(null);
  }

  @override
  Future<Outcome<PluginRunResult>> run(PluginCtx ctx, PluginInput input) async {
    runCount++;
    return Ok<PluginRunResult>(PluginRunResult(summary: '${manifest.id} 跑了', data: {'entry': input.entry.name}));
  }
}

class _MemoryEnabledStore implements EnabledStore {
  _MemoryEnabledStore([Set<String>? seed]) : ids = {...?seed};
  final Set<String> ids;
  int writes = 0;
  @override
  Set<String> read() => Set.of(ids);
  @override
  void write(Set<String> enabledIds) {
    ids
      ..clear()
      ..addAll(enabledIds);
    writes++;
  }
}

PluginManifest _m(String id, {int rank = 100, List<String> inject = const [], bool overridable = true, String engines = '', bool onByDefault = false, List<PluginParam> params = const []}) => PluginManifest(
      id: id,
      name: id,
      description: 'd',
      rank: rank,
      inject: inject,
      overridable: overridable,
      enginesApp: engines,
      params: params,
      enabledByDefault: onByDefault,
      trust: PluginTrust.trusted,
      permissions: const [PluginPermission.pluginStorage],
    );

Map<String, ({String json, String? prompt})> _dir(String id, Map<String, Object?> Function() body) =>
    {id: (json: jsonEncode(body()), prompt: null)};

void main() {
  late CapabilityRegistry caps;
  late SlotRegistry slots;
  late ConfigStore config;
  late BuiltinSourceReader builtin;
  late Map<String, ({String json, String? prompt})> userDir;
  late _MemoryEnabledStore enabled;
  late InMemoryTraceSink trace;
  late PluginLoader loader;
  late PluginService service;

  void build({String appVersion = '0.4.0', Set<String>? on, FirstRunSeeder? seeder}) {
    loader = PluginLoader(
      capabilities: caps,
      builtin: builtin,
      userSources: [DeclarationDirSourceReader(() => userDir)],
      appVersion: appVersion,
      knownCapabilityIds: {'app.speak', 'app.store', 'llm.vision', 'app.capture', 'app.interact', 'llm.complete', 'net.search', 'asr.transcribe'},
    );
    enabled.ids.addAll(on ?? const {});
    loader.setEnabledIds(enabled.ids);
    service = PluginService(
      loader: loader,
      capabilities: caps,
      slots: slots,
      configStore: config,
      enabledStore: enabled,
      trace: trace,
      firstRun: seeder,
    );
  }

  setUp(() {
    caps = CapabilityRegistry();
    slots = SlotRegistry();
    config = ConfigStore();
    builtin = BuiltinSourceReader();
    userDir = {};
    enabled = _MemoryEnabledStore();
    trace = InMemoryTraceSink();
    caps.register(FakeSpeak(), ownerPluginId: 'app');
    caps.register(FakeStore(), ownerPluginId: 'app');
  });

  group('启动与开关', () {
    test('boot 先把宿主 11 槽声明好（冻结件真的落地了）', () async {
      build();
      await service.boot();
      for (final d in kHostSlotContract) {
        expect(slots.isDeclared(d.id), isTrue, reason: d.id);
      }
    });

    test('启用的内置插件被加载，图标进槽；停用后账本干净', () async {
      final p = _CountingPlugin(_m('alpha'));
      builtin.register(p.manifest, () => p);
      build(on: {'alpha'});
      final r = await service.boot();
      expect(r.valueOrNull?.application, PluginApplication.applied);
      expect(p.applyCount, 1);
      expect(slots.entries('app.input.right').map((e) => e.id), ['chip']);

      await service.setEnabled('alpha', false);
      expect(p.disposed, ['chip']);
      expect(slots.entries('app.input.right'), isEmpty);
      expect(service.view().first.running, isFalse);
    });

    test('没启用的插件绝不加载（不注册、不占槽）', () async {
      final p = _CountingPlugin(_m('beta'));
      builtin.register(p.manifest, () => p);
      build();
      await service.boot();
      expect(p.applyCount, 0);
      expect(service.view().first.loaded.status, PluginLoadStatus.disabled);
    });

    test('重复 setEnabled 同一状态 = unchanged（不产生写盘与重载）', () async {
      final p = _CountingPlugin(_m('gamma'));
      builtin.register(p.manifest, () => p);
      build(on: {'gamma'});
      await service.boot();
      final writes = enabled.writes;
      final r = await service.setEnabled('gamma', true);
      expect(r.valueOrNull?.changed, isFalse);
      expect(enabled.writes, writes);
      expect(p.applyCount, 1);
    });
  });

  group('门控与失败', () {
    test('用户目录里的代码级插件不许蹭 flow.runner 那句提示（等的路根本不是同一条）', () async {
      // 目录里放一个 trust=trusted 却没有代码的插件：今天根本没有任何机制能加载磁盘上的 Dart。
      // 挂 `flow.runner` 的标签 = 骗作者去接 flow 引擎，接完依然跑不起来还查不出原因。
      Map<String, Object?> m(String id, String trust) => {
            'manifestVersion': 1,
            'id': id,
            'name': id,
            'description': 'd',
            'trust': trust,
          };
      // 声明式插件必须带 flow（没 flow 的声明式插件本来就该被判坏，别混进这条测试）。
      final declJson = jsonEncode({
        ...m('declarative-one', 'declarative'),
        'permissions': ['storage:plugin'],
        'flow': {
          'name': 'n',
          'description': 'd',
          'whenToUse': 'w',
          'phases': [
            {'id': 'p', 'title': '念'}
          ],
          'steps': [
            {'id': 's', 'op': 'store', 'phase': 'p'}
          ],
        },
      });
      userDir = {
        'code-less': (json: jsonEncode(m('code-less', 'trusted')), prompt: null),
        'declarative-one': (json: declJson, prompt: '念单词'),
      };
      build(on: {'code-less', 'declarative-one'});
      await service.boot();

      final codeLess = service.result!.byId('code-less')!;
      expect(codeLess.status, PluginLoadStatus.gated);
      expect(codeLess.gatedOn, ['plugin.code.loader']);
      expect(codeLess.gatedHint, contains('内置插件'), reason: '要给真正走得通的出路');
      expect(codeLess.gatedHint, isNot(contains('flow')), reason: '不许把人往 flow 引擎上引');

      final decl = service.result!.byId('declarative-one')!;
      expect(decl.gatedOn, ['flow.runner'], reason: '声明式等的确实是 flow 引擎，这条标签不能串');

      // 用户按下"跑一下"时，四类"跑不起来"必须各自说清**是什么 + 下一步去哪**。
      // 这四句以前测试里一个字都没有 —— 改坏了不会红，用户在面板上撞到的就是空白的"跑不起来"。
      // 这四条分支都在碰 input 之前就返回 Err，所以 entry 用枚举里最中性的一个即可。
      final input = PluginInput(entry: PluginEntryKind.composerAction);
      final gatedRun = await service.run('code-less', input);
      expect(gatedRun.failureOrNull?.message, contains('还缺：plugin.code.loader'),
          reason: '要说清缺的是哪个能力，不能只说"跑不起来"');
      expect(gatedRun.failureOrNull?.hint, contains('看「插件」页里写明的前置条件'),
          reason: '光说缺能力不够，必须把用户下一步去哪说死在测试里');
      final missingRun = await service.run('no-such-plugin', input);
      expect(missingRun.failureOrNull?.message, contains('没有「no-such-plugin」这个插件'));
      // 同一种病（插件不在清单里）在四个入口必须是**同一句话**：以前 run() 给的是
      // 「在「插件」页确认它是否已启用」——那是"已被停用"分支的处方，拿它治"根本没这个插件"，
      // 用户会把开关翻来覆去地点，而插件压根没装上。
      expect(missingRun.failureOrNull?.hint, contains('刷新插件列表再看看'),
          reason: '同一失败在 trialConfig/setConfig/resetConfig/run 四个入口必须同词，否则用户学不到可迁移的经验');
    });

    test('prompt.md 超预算 → 判坏并说清挤上下文；空 prompt.md 只是提醒，插件还能跑', () async {
      // 这条预算在作者机器上（CLI validate）也能查，但**用户手放文件只有扫描这一道关**；
      // 而 prompt.md 是整段进模型上下文的，超了就是"模型突然变笨"这种查都查不出来的坑。
      Map<String, Object?> m(String id) => {
            'manifestVersion': 1,
            'id': id,
            'name': id,
            'description': 'd',
            'trust': 'trusted',
          };
      userDir = {
        'huge-prompt': (json: jsonEncode(m('huge-prompt')), prompt: 'apple 苹果\n' * 9000),
        'empty-prompt': (json: jsonEncode(m('empty-prompt')), prompt: ''),
      };
      build(on: {'huge-prompt', 'empty-prompt'});
      await service.boot();

      expect(service.result!.byId('huge-prompt'), isNull, reason: '超预算的 prompt 不许带上线');
      final issues = service.result!.broken['huge-prompt/plugin.json'];
      expect(issues, isNotNull);
      final msg = issues!.map((i) => i.message).join(' ');
      expect(msg, contains('32KB'));
      expect(msg, contains('上下文'), reason: '要用人话讲清为什么超了不行');

      // 空 prompt.md 是"作者该改"，不是"不能用"：插件照常出现，只挂一条声明提醒。
      final empty = service.result!.byId('empty-prompt')!;
      expect(empty.status, isNot(PluginLoadStatus.rejected));
      expect(empty.descriptor.issues.any((i) => i.severity == IssueSeverity.warning), isTrue,
          reason: '空提示词要提醒，但不能把插件判死');
    });

    test('plugin.json 超预算 → 只标坏那一条并说清超了多少，别的一条不受影响', () async {
      // 预算不是文档里的数字：一个 70KB 的清单能把扫描拖死、把面板刷成一坨。
      // 这里验的是"坏文件只坏自己" + 人话原因（用户看得见该改哪个文件）。
      Map<String, Object?> m(String id) => {
            'manifestVersion': 1,
            'id': id,
            'name': id,
            'description': 'd',
            'trust': 'trusted',
          };
      userDir = {
        'ok-one': (json: jsonEncode(m('ok-one')), prompt: null),
        'fat-one': (json: jsonEncode({...m('fat-one'), 'description': '肥' * (80 * 1024)}), prompt: null),
      };
      build(on: {'ok-one', 'fat-one'});
      await service.boot();

      expect(service.result!.byId('fat-one'), isNull, reason: '超预算的不许进插件表');
      final issues = service.result!.broken['fat-one/plugin.json'];
      expect(issues, isNotNull, reason: '但要出现在"坏声明"名单里，让用户知道该改哪个文件');
      expect(issues!.map((i) => i.message).join(' '), contains('64KB'));
      expect(service.result!.byId('ok-one'), isNotNull, reason: '隔壁那条必须照常加载');
      expect(service.result!.broken.containsKey('ok-one/plugin.json'), isFalse);
    });

    test('extension 级（第三方 Dart 源码）：没实现隔离就停在待功能，且不蹭 flow 那句提示', () async {
      // 它等的不是 flow 引擎，是 isolate broker。原因说错，别人会去接 flow，接完照样跑不起来。
      userDir = _dir('thirdparty', () => {
            'manifestVersion': 1,
            'id': 'thirdparty',
            'name': '第三方 Dart 插件',
            'description': 'd',
            'trust': 'extension',
          });
      build(on: {'thirdparty'});
      await service.boot();
      final loaded = service.result!.byId('thirdparty')!;
      expect(loaded.status, PluginLoadStatus.gated);
      expect(loaded.gatedOn, ['extension.broker']);
      expect(loaded.gatedHint, contains('进程外隔离'));
      expect(loaded.gatedHint, contains('declarative'), reason: '要给出路：现在能用的替代是什么');
      expect(service.result!.broken['thirdparty/plugin.json'], isNull, reason: '作者没写错，是平台还没做');
    });

    test('内置代码挂 extension 名 = 配置不符（骗审计比不写更坏）', () async {
      final p = _CountingPlugin(PluginManifest(
        id: 'fake-extension',
        name: '假隔离',
        description: 'd',
        inject: const [],
        permissions: const [PluginPermission.pluginStorage],
        trust: PluginTrust.extension,
      ));
      builtin.register(p.manifest, () => p);
      build(on: {'fake-extension'});
      await service.boot();
      final loaded = service.result!.byId('fake-extension')!;
      expect(loaded.status, PluginLoadStatus.rejected);
      expect(loaded.disabledReason, contains('trusted'));
    });

    test('能力不齐 → gated，且 run 说清缺什么而不是静默失败', () async {
      final p = _CountingPlugin(_m('needs-tts', inject: ['app.speak', 'net.search']));
      builtin.register(p.manifest, () => p);
      build(on: {'needs-tts'});
      await service.boot();
      final loaded = service.result!.byId('needs-tts')!;
      expect(loaded.status, PluginLoadStatus.gated);
      expect(loaded.gatedOn, ['net.search']);
      expect(p.applyCount, 0);

      final r = await service.run('needs-tts', const PluginInput(entry: PluginEntryKind.composerAction));
      expect(r.failureOrNull?.code, PluginFailureKind.missingCapability);
      expect(r.failureOrNull?.message, contains('net.search'));
      expect(r.failureOrNull?.hint, contains('看「插件」页里写明的前置条件'),
          reason: '门控失败要指到能看见前置条件的地方；isNotNull 保不住这个指路');
    });

    test('补上能力后 reload → 自动起来（门控是动态的）', () async {
      final p = _CountingPlugin(_m('needs-asr', inject: ['asr.transcribe']));
      builtin.register(p.manifest, () => p);
      build(on: {'needs-asr'});
      await service.boot();
      expect(service.result!.byId('needs-asr')!.status, PluginLoadStatus.gated);
      caps.register(FakeTranscribe(), ownerPluginId: 'app');
      await service.reload();
      expect(service.result!.byId('needs-asr')!.status, PluginLoadStatus.active);
      expect(p.applyCount, 1);
    });

    test('apply 抛异常的插件停在 failed，不拖累别的插件', () async {
      builtin.register(_m('ok-one'), () => _CountingPlugin(_m('ok-one')));
      builtin.register(_m('bad-one'), () => _ExplodingPlugin(_m('bad-one')));
      build(on: {'ok-one', 'bad-one'});
      final r = await service.boot();
      expect(r.valueOrNull?.application, PluginApplication.failed);
      expect(r.valueOrNull?.stage, 'apply');
      expect(service.view().firstWhere((v) => v.id == 'ok-one').running, isTrue);
      expect(service.view().firstWhere((v) => v.id == 'bad-one').state, FiberState.failed);
      expect(service.view().firstWhere((v) => v.id == 'bad-one').lastFailure?.message, contains('插件启动时出了点问题'));
      // 引用产品原句：那条「N 个插件启动失败」的横幅是用户在面板上唯一能看到"有几个没起来"的地方，
      // 改坏了没人红 —— 见 tool/check_fail_texts.py 与 §11-C「不许转述型断言」。
      expect(r.valueOrNull?.failure?.message, contains('个插件启动失败'),
          reason: '别的插件都正常时，"有几个没起来"必须有一条合计告诉用户');

      // 用户在这条失败的插件上按"跑一下"：说的必须是"它出了点问题 + 去看诊断 + 可重试"，
      // 不许和"缺东西/被停用/清单写坏"混成一句（那四条各有各的处方，第 46/47 轮已分别钉死）。
      final failedRun = await service.run('bad-one', PluginInput(entry: PluginEntryKind.composerAction));
      expect(failedRun.failureOrNull?.message, contains('出了点问题'), reason: failedRun.failureOrNull?.message);
      // 实测这一支的真话是「停用再启用试试；仍不行看诊断树」——先打印现状再断言（第 27 轮规矩），
      // 别照着自己脑补的文案钉（我上一版就脑补成了 :572 那句）。
      expect(failedRun.failureOrNull?.hint, contains('停用再启用试试；仍不行看诊断树'),
          reason: '失败态的出路要具体到动作，且不能和缺东西/被停用那几条混成一句');
    });
  });

  group('本次运行的日志要能单独拎出来（byTrace 以前零调用者）', () {
    test('重载后"最近日志"混着历次，runLog 只有当前实例那一份', () async {
      const g = PluginParam(name: 'gapSeconds', label: '间隔', type: PluginParamType.number, defaultValue: 5, min: 1, max: 30);
      final m = _m('talky', params: const [g]);
      builtin.register(m, () => _LogsInApply(m));
      build(on: {'talky'});
      await service.boot();
      const input = PluginInput(entry: PluginEntryKind.composerAction);
      await service.run('talky', input); // 第一次 apply → traceId t1
      final first = service.diagnostics('talky');

      // 改配置才会真的换实例（`reload()` 在 epoch 没变时是空转，traceId 也不换）。
      await service.setConfig(id: 'talky', patch: const {'gapSeconds': 9});
      await service.run('talky', input);
      final second = service.diagnostics('talky');

      expect((second['logs'] as List).length, greaterThan((second['runLog'] as List).length),
          reason: '最近日志是历次混在一起的 —— 只看它，就会把旧实例的失败当成现在的问题');
      final run = (second['runLog'] as List).cast<Map<String, Object?>>();
      expect(run, isNotEmpty);
      expect(run.every((r) => r['traceId'] == second['traceId']), isTrue,
          reason: '这一节只许是**当前实例**的记录 —— 混进旧实例的就不是"本次运行"');
      expect(run.where((r) => '${r['message']}'.contains('我 apply 了一次')), hasLength(1),
          reason: '当前实例只 apply 过一次；旧实例那条该被筛掉');
      expect(first['traceId'], isNot(second['traceId']), reason: '每次重载换一个新 traceId');
    });
  });

  group('贡献物自动挂 effect（作者忘了也不会留幽灵）', () {
    const gap = PluginParam(name: 'gapSeconds', label: '间隔', type: PluginParamType.number, defaultValue: 5, min: 1, max: 30);

    test('重载后槽里不许留着上一份实例的条目', () async {
      final m = _m('ghost', params: const [gap]);
      builtin.register(m, () => _LazySlotPlugin(m));
      build(on: {'ghost'});
      // 槽由"宿主/作者声明一次"，插件只往里注册 —— 与真实场景一致（重载不该重声明）。
      expect(
          service.slots.declare(const SlotDef(
            id: 'ghost.panel',
            kind: SlotKind.list,
            scope: SlotScope.root,
            ownerPluginId: 'ghost',
            description: '测试用槽',
          )).isOk,
          isTrue);
      await service.boot();
      await service.setConfig(id: 'ghost', patch: const {'gapSeconds': 9}); // 触发重载

      expect(service.slots.entries('ghost.panel').length, 1, reason: '先确认真装上了');
      await service.shutdown();
      // 「同 id 视为同格」会让重载后的重复注册悄悄合并，所以判据放在卸载之后：
      // 插件 apply 里注册了槽却**没自己挂 effect**（作者常忘的那一步），
      // 内核不兜住就留下幽灵条目 —— 面板还说"它占了这个位置"，可那个插件早就不存在了。
      expect(service.slots.entries('ghost.panel'), isEmpty,
          reason: '插件没了，槽里还留着它的条目 = 幽灵 chip：面板说它占着位置，点了没反应，也不报错');
    });

    test('插件卸载后，它 provide 的能力必须从注册表消失（不能还能 resolve 到）', () async {
      final m = _m('giver', params: const [gap]);
      builtin.register(m, () => _LazyProvidePlugin(m));
      build(on: {'giver'});
      await service.boot();

      final key = const ServiceKey<Capability>('demo.thing');
      expect(service.capabilities.resolve<Capability>(key).isOk, isTrue, reason: '先确认真的使用中');
      await service.shutdown();
      expect(service.capabilities.resolve<Capability>(key).isErr, isTrue,
          reason: '插件已经卸载，注册表里还留着它的实现 = 调用会被交给一个死人');
    });
  });

  group('方案档门控（knownProfiles 以前在测试里从没被赋值过）', () {
    const json = '{"manifestVersion":1,"id":"ghost-profile","name":"档外插件","description":"d","trust":"trusted","profiles":["夜间模式"]}';

    test('声明了不存在的方案档 → 提醒要说清"在哪个档里都不会出现"并指向插件方案', () {
      final r = parseDeclaration(
        location: '文档/plugins/ghost-profile',
        source: PluginSource.user,
        json: json,
        knownProfiles: {'日常听写'},
      );
      final hits = r.issues.where((i) => i.message.contains('在哪个档里都不会出现')).toList();
      expect(hits, isNotEmpty,
          reason: '只说"被门控"不够 —— 用户会反复去点开关，其实名字写错了，哪个档里都没它');
      expect(hits.single.hint, contains('插件方案'), reason: '要说清去哪儿核对名字');
      expect(hits.single.severity, IssueSeverity.warning);
      expect(r.descriptor, isNotNull, reason: '是档位名字对不上，不是作者写错；判坏就是把环境问题说成指责');
    });

    test('本机一个方案档都没有（没选档）时，不许报这条提醒', () {
      final r = parseDeclaration(
        location: '文档/plugins/ghost-profile',
        source: PluginSource.user,
        json: json,
        knownProfiles: const {},
      );
      expect(r.issues.any((i) => i.message.contains('在哪个档里都不会出现')), isFalse,
          reason: '空集合 = 本机没有档目录这个概念，拿它去判作者的声明全是误报');
    });
  });

  group('shutdown 必须真的被调用（否则 effect 全泄漏）', () {
    test('宿主 dispose 时 fiber 全卸、释放器跑完', () async {
      final m = _m('leak-me');
      var disposed = 0;
      builtin.register(m, () => _DisposingPlugin(m, () => disposed++));
      build(on: {'leak-me'});
      await service.boot();
      await service.run('leak-me', const PluginInput(entry: PluginEntryKind.composerAction));
      expect(disposed, 0, reason: '还没关，不该提前释放');

      await service.shutdown();
      expect(disposed, 1, reason: 'effect 的释放器不跑 = Timer / 订阅 / 能力注册永远留着（切档、重建平台都泄漏）');
      expect((service.diagnostics('leak-me')['effectTree'] as List), isEmpty,
          reason: '账本也要清干净：留着条目就是"释放了"的假象');
    });
  });

  group('能力预热（warmUpAll 这条链以前没人调用）', () {
    test('warmUpCapabilities 真的走到实现，且只碰可用的', () async {
      // 用负 priority：harness 的 setUp 已经在 app.speak 上占了 priority 0，
      // 同 priority 的第二次注册会被**拒**（`register` 返回 Err）—— 判据被丢弃就等于测了个寂寞。
      final ready = _RecordingSpeak();
      final down = _RecordingSpeak(available: false);
      expect(caps.register(ready, ownerPluginId: 'app', priority: -2).isOk, isTrue);
      expect(caps.register(down, ownerPluginId: 'app', priority: -1).isOk, isTrue);
      build();
      await service.boot();

      await service.warmUpCapabilities();
      expect(ready.warmed, 1, reason: '实现写了 warmUp 却永远没人调 = 首字永远慢一拍');
      expect(down.warmed, 0, reason: '不可用的能力不该被预热（它可能正等着用户去开开关）');
    });
  });

  group('重试不许对"没东西可重试"的插件报成功', () {
    test('清单没过（rejected）：说清改 plugin.json 再重扫，而不是空转一轮', () async {
      final p = _CountingPlugin(PluginManifest(
        id: 'bad-trust',
        name: '坏信任级',
        description: 'd',
        inject: const [],
        permissions: const [PluginPermission.pluginStorage],
        trust: PluginTrust.extension,
      ));
      builtin.register(p.manifest, () => p);
      build(on: {'bad-trust'});
      await service.boot();
      expect(service.result!.byId('bad-trust')!.status, PluginLoadStatus.rejected);
      final rejRun = await service.run('bad-trust', PluginInput(entry: PluginEntryKind.composerAction));
      expect(rejRun.failureOrNull?.message, contains('的声明有问题，跑不起来'),
          reason: 'rejected 的真相是"你自己写坏了"，不是"本机缺东西" —— 说错方向作者会去查能力表');
      expect(rejRun.failureOrNull?.hint, contains('打开插件详情看具体是哪一条'));

      final r = await service.retry('bad-trust');
      final v = r.valueOrNull!;
      expect(v.application, PluginApplication.failed, reason: 'Ok 里必须装着失败，面板才不会回一句"已重试"');
      expect(v.changed, isFalse);
      expect(v.failure!.message, contains('没有可重试的东西'));
      expect(v.failure!.hint, contains('plugin.json'), reason: '出路要给到"改清单再重扫"，不是让人再按一次');
      expect(p.applyCount, 0, reason: '被拒的插件从头到尾没 apply 过，重试也不该有副作用');
    });

    test('关着的插件：重试不替你打开开关', () async {
      builtin.register(_m('off-plugins'), () => _CountingPlugin(_m('off-plugins')));
      build(); // 故意不进启用集
      await service.boot();

      // 关着的插件被"跑一下"撞到时：必须说清它是被停用的 + 去哪打开（这四句以前一个字都没有）。
      final offRun = await service.run('off-plugins', PluginInput(entry: PluginEntryKind.composerAction));
      // 形状也要钉住：这句必须是「名字」已被停用 —— 名字空了、或退化成裸「已被停用」，用户就不知道是哪条插件。
      expect(offRun.failureOrNull?.message, matches(RegExp(r'^「.+」已被停用$')), reason: offRun.failureOrNull?.message);
      expect(offRun.failureOrNull?.hint, contains('去「插件」页打开它'));

      final r = await service.retry('off-plugins');
      final v = r.valueOrNull!;
      expect(v.application, PluginApplication.failed);
      // 断**产品原句**而不是自己的转述：转述型断言（`contains('是关着的')`、`contains('开关')`）
      // 在产品把话改得面目全非时照样绿 —— 门禁 `tool/check_fail_texts.py` 就是为抓这个而立的。
      expect(v.failure!.message, contains('是关着的：重试不会替你打开开关'),
          reason: '"已重试"是最坏的回答：用户以为按过了');
      expect(v.failure!.hint, contains('先把条目的开关打开'),
          reason: '光说"是关着的"不够，必须把用户下一步去哪说死在测试里');
    });

    test('体检单独列"出过错的日志"，不被最近 30 条挤掉', () async {
      builtin.register(_m('noisy'), () => _CountingPlugin(_m('noisy')));
      build(on: {'noisy'});
      await service.boot();

      // 先落一条真正的失败，再用 40 条 debug 把它冲出"最近"可见区。
      trace.emit(TraceRecord(traceId: 't', pluginId: 'noisy', level: TraceLevel.fail, message: '离线朗读没起来'));
      for (var i = 0; i < 40; i++) {
        trace.emit(TraceRecord(traceId: 't', pluginId: 'noisy', level: TraceLevel.debug, message: '心跳 $i'));
      }
      final d = service.diagnostics('noisy');
      final fails = (d['logFailures'] as List).cast<Map<String, Object?>>();
      expect(fails.map((e) => e['message']), contains('离线朗读没起来'),
          reason: '最该看见的那条不许被刷屏挤掉 —— 面板只显示最近 30 条');
      expect((d['logs'] as List).length, greaterThan((d['logFailures'] as List).length),
          reason: '两份不是一回事：一份全量、一份只留 warn/fail');
    });
  });

  group('「先试试这组值」（会话层的唯一入口）', () {
    const gap = PluginParam(name: 'gapSeconds', label: '间隔', type: PluginParamType.number, defaultValue: 5, min: 1, max: 30);

    test('试值只进会话层：值生效、fiber 重载，但用户设置一个字没动', () async {
      final m = _m('trial', params: const [gap]);
      builtin.register(m, () => _CountingPlugin(m));
      build(on: {'trial'});
      await service.boot();

      final r = await service.trialConfig(id: 'trial', patch: const {'gapSeconds': 12});
      expect(r.valueOrNull!.changed, isTrue, reason: '试出来的值该真的去影响运行');
      expect(service.configStore.stackFor(m).value('gapSeconds'), 12);
      expect(service.configStore.userOf('trial'), isEmpty, reason: '不落盘 —— 这条入口的全部意义就在这');
      expect(service.configStore.sessionOf('trial'), {'gapSeconds': 12});
    });

    test('越界的试值被拒，且不会"看起来试过了"', () async {
      final m = _m('trial2', params: const [gap]);
      builtin.register(m, () => _CountingPlugin(m));
      build(on: {'trial2'});
      await service.boot();

      final r = await service.trialConfig(id: 'trial2', patch: const {'gapSeconds': 900});
      expect(r.isErr, isTrue, reason: '越界的试值属硬拒：与保存同一条判据');
      expect(r.failureOrNull!.message, contains('不能大于 30'));
      expect(service.configStore.sessionOf('trial2'), isEmpty);
      expect(service.configStore.stackFor(m).value('gapSeconds'), 5);
    });

    test('会话里试过一个值之后，保存照样算「改了」（不被合并值判成没变化）', () async {
      final m = _m('mask', params: const [gap]);
      builtin.register(m, () => _CountingPlugin(m));
      build(on: {'mask'});
      await service.boot();

      await service.trialConfig(id: 'mask', patch: const {'gapSeconds': 11});
      final r = await service.setConfig(id: 'mask', patch: const {'gapSeconds': 7});
      expect(r.valueOrNull!.changed, isTrue,
          reason: '用户层真变了；临时值只是暂时压着，回一句「没有变化」等于把保存说成没保存');
      expect(service.configStore.userOf('mask'), {'gapSeconds': 7});
      expect(service.configStore.stackFor(m).value('gapSeconds'), 11, reason: '临时值仍该压在上面 —— 这是它存在的意义');
    });

    test('插件自己 setSessionOverride 的值，面板读 stackFor 必须看得见', () async {
      final m = _m('self-session', params: const [gap]);
      builtin.register(m, () => _WritesSession(m));
      build(on: {'self-session'});
      await service.boot();

      expect(service.configStore.sessionOf('self-session'), {'gapSeconds': 11},
          reason: '以前它写进 ctx 的私人笔记本：面板标着「插件默认」，实际念的却是 11 —— 显示与实际不一致');
      expect(service.configStore.stackFor(m).layerOf('gapSeconds'), ConfigLayer.session);
    });
  });

  group('恢复默认（面板上的「恢复默认」）', () {
    const gap = PluginParam(name: 'gapSeconds', label: '间隔', type: PluginParamType.number, defaultValue: 5);

    test('用户层真的被清掉，值回到插件声明的默认（不是只把输入框洗白）', () async {
      final m = _m('cfg', params: const [gap]);
      builtin.register(m, () => _CountingPlugin(m));
      build(on: {'cfg'});
      await service.boot();

      await service.setConfig(id: 'cfg', patch: const {'gapSeconds': 12});
      expect(service.configStore.userOf('cfg'), {'gapSeconds': 12}, reason: '先确认确实改过');

      final r = await service.resetConfig(id: 'cfg');
      expect(r.valueOrNull!.changed, isTrue);
      expect(service.configStore.userOf('cfg'), isEmpty, reason: '清不掉就是又一个"面板说了但没生效"');
      expect(service.configStore.stackFor(m).value('gapSeconds'), 5, reason: '清完要真的回到声明的默认值');
    });

    test('「本次临时试的值」也得一起清掉（否则「已恢复默认」是句谎话）', () async {
      // 机检的是 `plugin_service.resetConfig` 里那句 `configStore.clearSessionOverrides(id)`：
      // 只清用户层却报「已恢复默认」，用户下次看到的还是刚才试出来的 90 秒 —— 全程没有红字。
      // 第 80 轮实测：删掉那一句，本文件 48 条**全绿**，所以这条断言必须补上。
      final m = _m('cfg3', params: const [gap]);
      builtin.register(m, () => _CountingPlugin(m));
      build(on: {'cfg3'});
      await service.boot();

      final t = await service.trialConfig(id: 'cfg3', patch: const {'gapSeconds': 90});
      expect(t.isOk, isTrue, reason: '先摆一个只在会话层的临时值（试值同判据，90 秒得先过校验）');
      expect(service.configStore.sessionOf('cfg3'), {'gapSeconds': 90},
          reason: '临时值确实只落在会话层');
      expect(service.configStore.userOf('cfg3'), isEmpty, reason: '试值不许顺手落进用户层');

      final r = await service.resetConfig(id: 'cfg3');
      expect(r.isOk, isTrue);
      expect(service.configStore.sessionOf('cfg3'), isEmpty,
          reason: '会话层没清 = 面板说"已恢复默认"，用户下次看到的还是试出来的 90 秒');
      expect(service.configStore.stackFor(m).value('gapSeconds'), 5,
          reason: '两层都清了，读到的才真是插件声明的默认');
    });

    test('没动过时是空操作：不空转 revision，也不给用户"我恢复了什么"的错觉', () async {
      final m = _m('cfg2', params: const [gap]);
      builtin.register(m, () => _CountingPlugin(m));
      build(on: {'cfg2'});
      await service.boot();

      final rev = service.configStore.revisionOf('cfg2');
      final r = await service.resetConfig(id: 'cfg2');
      expect(r.valueOrNull!.changed, isFalse, reason: '本来就没改过，报"已恢复"是撒谎');
      expect(service.configStore.revisionOf('cfg2'), rev, reason: '不许为了好看空转一次 revision');
    });
  });

  group('首次播种 enabledByDefault', () {
    test('磁盘插件声明 enabledByDefault 也才算数（以前只对内置件生效，第三方写了等于没写）', () async {
      userDir = _dir('poem', () => {
            'manifestVersion': 1,
            'id': 'poem',
            'name': '古诗抽查',
            'description': 'd',
            'trust': 'declarative',
            'enabledByDefault': true,
            'permissions': ['llm:chat', 'tts', 'network'],
            'flow': {
              'name': 'poem',
              'description': 'd',
              'whenToUse': 'w',
              'phases': [
                {'id': 'p1', 'title': '跑'}
              ],
              'steps': [
                {'id': 'say', 'op': 'speak_sequence', 'phase': 'p1', 'params': {'items': ['床前明月光']}}
              ],
            },
          });
      build(seeder: MemoryFirstRunSeeder());
      await service.boot();
      // 这个测试的 loader 没接 declarativeFactory（flow 引擎在别的用例里验），
      // 所以只判"绝不该是 disabled"—— 关键点是被**漏在启用集之外**，不是 flow 跑不跑。
      expect(service.result!.byId('poem')!.status, isNot(PluginLoadStatus.disabled),
          reason: '作者写了 enabledByDefault，装进来就该是开的 —— 装完还得去面板点一下的默认值不是默认值');
      expect(enabled.ids, contains('poem'), reason: '播种必须落到 EnabledStore 这个唯一真源里，面板才看得见');
    });

    test('用户关掉之后再也不会被打开（"见没见过"比声明说了算）', () async {
      builtin.register(_m('smoke', onByDefault: true), () => _CountingPlugin(_m('smoke', onByDefault: true)));
      // 第二次开机：seeder 从磁盘读回来的 seen 里已经有它了。
      build(seeder: MemoryFirstRunSeeder({'smoke'}));
      await service.boot();
      expect(service.result!.byId('smoke')!.status, PluginLoadStatus.disabled,
          reason: '每次扫描都按声明重播的话，用户关掉的开关会被悄悄翻回来');
      expect(enabled.ids, isEmpty);
    });

    test('同一个 service 里 reload 也不重复播种；没声明的插件不会被顺手打开', () async {
      builtin.register(_m('on-one', onByDefault: true), () => _CountingPlugin(_m('on-one', onByDefault: true)));
      builtin.register(_m('off-one'), () => _CountingPlugin(_m('off-one')));
      final seeder = MemoryFirstRunSeeder();
      build(seeder: seeder);
      await service.boot();
      expect(service.result!.byId('on-one')!.status, PluginLoadStatus.active);
      expect(service.result!.byId('off-one')!.status, PluginLoadStatus.disabled,
          reason: '没写 enabledByDefault 就是关的 —— 平台不许"看起来方便"地乱开');
      expect(seeder.seen, containsAll(<String>['on-one', 'off-one']), reason: '见过的都要记账，哪怕没播上');

      // 用户关掉它，再热重扫：不许复活。
      enabled.write(const {});
      await service.reload();
      expect(service.result!.byId('on-one')!.status, PluginLoadStatus.disabled);
    });

    test('没接 FirstRunSeeder 就不播（宁可不动，也不瞎开插件）', () async {
      builtin.register(_m('nobody', onByDefault: true), () => _CountingPlugin(_m('nobody', onByDefault: true)));
      build(); // 不传 seeder
      await service.boot();
      expect(service.result!.byId('nobody')!.status, PluginLoadStatus.disabled,
          reason: '播种是有持久化前提的动作，宿主没接账本时保持沉默才是安全的');
    });
  });

  group('启用集只有一个真源', () {
    test('boot 自己从 EnabledStore 读启用集（宿主忘了 setEnabledIds 也不会全员停用）', () async {
      builtin.register(_m('from-store'), () => _CountingPlugin(_m('from-store')));
      enabled.ids.addAll({'from-store'}); // 只放进 store，**故意不**调 loader.setEnabledIds
      build();
      await service.boot();
      expect(service.result!.byId('from-store')!.status, PluginLoadStatus.active,
          reason: '冷启动必须认持久化的开关，否则用户开过的插件重启就"消失"了');

      // 再"重启"一次：新 service 共用同一个 store，结论必须一致。
      final again = PluginService(
        loader: PluginLoader(
          capabilities: caps,
          builtin: builtin,
          knownCapabilityIds: {'app.speak', 'app.store'},
        ),
        capabilities: caps,
        slots: SlotRegistry(),
        configStore: ConfigStore(),
        enabledStore: enabled,
        trace: InMemoryTraceSink(),
      );
      await again.boot();
      expect(again.result!.byId('from-store')!.status, PluginLoadStatus.active);
    });
  });

  group('rank 遮蔽与坏文件', () {
    test('用户目录同名插件遮蔽内置，且面板看得见覆盖关系', () async {
      final built = _CountingPlugin(_m('dictation', rank: 100));
      builtin.register(built.manifest, () => built);
      userDir = _dir('dictation', () => {
            'manifestVersion': 1,
            'id': 'dictation',
            'name': '我的听写',
            'description': 'd',
            'trust': 'trusted',
            'source': 'user',
            'rank': 200,
            'params': [
              {'name': 'gap', 'label': '间隔', 'type': 'number', 'default': 5}
            ],
          });
      build(on: {'dictation'});
      await service.reload();
      expect(service.result!.shadowed['dictation'], contains('遮蔽了'));
      // 用户版没有实现体 → 停在 gated（绝不自作主张跑内置那份）
      expect(service.result!.byId('dictation')!.status, PluginLoadStatus.gated);
      expect(built.applyCount, 0);
    });

    test('内置 overridable:false 时用户版本被忽略并给出建议', () async {
      builtin.register(_m('locked', overridable: false), () => _CountingPlugin(_m('locked', overridable: false)));
      userDir = _dir('locked', () => {
            'manifestVersion': 1,
            'id': 'locked',
            'name': '我的覆盖版',
            'description': 'd',
            'trust': 'trusted',
          });
      build(on: {'locked'});
      await service.reload();
      expect(service.result!.broken['locked/plugin.json']!.single.message, contains('不允许被覆盖'));
      expect(service.result!.broken['locked/plugin.json']!.single.hint, contains('想定制就换一个新的 id'),
          reason: '只说"不许覆盖"是把人堵死；出路（换 id 自己做一个）必须说出口');
      expect(service.result!.byId('locked')!.status, PluginLoadStatus.active);
    });

    test('一个 plugin.json 写坏，只拒它自己，别的照常加载', () async {
      builtin.register(_m('good-one'), () => _CountingPlugin(_m('good-one')));
      userDir = {
        'broken': (json: '{"id":"broken","name":}', prompt: null), // 语法坏
        'also-broken': (json: '{"manifestVersion":1,"id":"BAD_ID","name":"x","description":"d","trust":"trusted"}', prompt: null),
      };
      build(on: {'good-one'});
      final r = await service.reload();
      expect(r.valueOrNull?.warnings.length, 2);
      expect(r.valueOrNull?.warnings.first, contains('broken'));
      expect(service.result!.byId('good-one')!.status, PluginLoadStatus.active);
    });

    test('所有来源同时读崩 → 沿用上一次好的树（不让 app 突然少一排功能）', () async {
      builtin.register(_m('keep-me'), () => _CountingPlugin(_m('keep-me')));
      final flakyBuiltin = _FlakyBuiltin(builtin);
      var dirBoom = false;
      loader = PluginLoader(
        capabilities: caps,
        builtin: flakyBuiltin,
        userSources: [
          DeclarationDirSourceReader(() {
            if (dirBoom) throw StateError('目录读不动了');
            return userDir;
          }),
        ],
        knownCapabilityIds: {'app.speak', 'app.store'},
      );
      enabled.ids.add('keep-me'); // 启用集只认 EnabledStore（见下面那组测试）
      service = PluginService(loader: loader, capabilities: caps, slots: slots, configStore: config, enabledStore: enabled, trace: trace);
      await service.boot();
      expect(service.result!.byId('keep-me')!.status, PluginLoadStatus.active);

      flakyBuiltin.boom = true;
      dirBoom = true;
      final r = await service.reload();
      expect(r.valueOrNull?.usedLastGood, isTrue);
      expect(r.valueOrNull?.warnings.any((w) => w.contains('沿用上一次好的清单')), isTrue);
      expect(service.result!.byId('keep-me'), isNotNull, reason: '旧树必须还在，用户才看得见并去修');
      expect(r.valueOrNull?.warnings.any((w) => w.contains('先沿用上一次读到的 1 个插件')), isTrue,
          reason: '来源级兜底要说清了兜了什么');
      // 兜底必须留下"怎么修"的活口：这条 issue 的 message/hint 以前测试里一个字都没有 ——
      // 只报"沿用旧清单"等于告诉用户"现在能用"，却没人告诉他哪个来源坏了、该拿它怎么办。
      final sourceIssues = service.result!.broken.values.expand((e) => e).toList();
      expect(sourceIssues.any((i) => i.message.contains('这个插件来源读不了')), isTrue,
          reason: '要点名是"来源读不了"，不是某个插件写坏了');
      expect(sourceIssues.any((i) => (i.hint ?? '').contains('修好它或先把它移走')), isTrue,
          reason: '要给一个当场做得动的动作（修 or 移走），不是"请联系开发者"');
    });

    test('engines.app 不满足 → 不加载并说清要哪个版本', () async {
      userDir = _dir('future', () => {
            'manifestVersion': 1,
            'id': 'future',
            'name': '太新了',
            'description': 'd',
            'trust': 'trusted',
            'engines': {'app': '>=9.9.9'},
          });
      build(appVersion: '0.4.0', on: {'future'}); // 得先"启用"，才轮得到门控这一层
      await service.reload();
      final p = service.result!.byId('future')!;
      // app 太旧是**环境问题**，不是作者写错：停在 gated（待功能）并给一句能照着做的出路，
      // 不能画成"声明有问题"（那是在怪作者，而且用户不知道该干嘛）。
      expect(p.status, PluginLoadStatus.gated);
      expect(p.gatedHint, contains('需要 app >=9.9.9'));
      expect(p.gatedHint, contains('本机是 0.4.0'),
          reason: '既要"要哪个版本"也要"我这是什么"，否则用户判断不了差多远');
      expect(p.gatedHint, contains('升级 app 后再启用它'),
          reason: '出路原句钉住：以前只断 4 个字转述，产品删掉"再启用它"不会红');
      expect(service.result!.broken['future/plugin.json'], isNull, reason: '不该进"坏声明"名单');
    });

    test('声明式插件在 flow 引擎上线前停在 gated（绝不假装能跑）', () async {
      userDir = _dir('declarative-one', () => {
            'manifestVersion': 1,
            'id': 'declarative-one',
            'name': '声明式',
            'description': 'd',
            'trust': 'declarative',
            'inject': ['app.speak'],
            'permissions': ['tts', 'network'],
            'flow': {
              'name': 'n',
              'description': 'd',
              'whenToUse': 'w',
              'phases': [
                {'id': 'p', 'title': '念'}
              ],
              'steps': [
                {'id': 's', 'op': 'speak_sequence', 'phase': 'p', 'params': {'items': ['a']}}
              ],
            },
          });
      build(on: {'declarative-one'});
      await service.reload();
      final p = service.result!.byId('declarative-one')!;
      expect(p.status, PluginLoadStatus.gated);
      expect(p.gatedOn, ['flow.runner']);
    });
  });

  group('配置改动 → 是否重载', () {
    test('改生效值会重载插件（epoch 含配置指纹）', () async {
      const withParam = PluginManifest(
        id: 'cfg-one',
        name: 'cfg-one',
        description: 'd',
        trust: PluginTrust.trusted,
        permissions: [PluginPermission.pluginStorage],
        params: [PluginParam(name: 'gap', label: '间隔', type: PluginParamType.number, defaultValue: 5, volatile: false)],
      );
      final p = _CountingPlugin(withParam);
      builtin.register(withParam, () => p);
      build(on: {'cfg-one'});
      await service.boot();
      expect(p.applyCount, 1);

      final r = await service.setConfig(id: 'cfg-one', patch: const {'gap': 9}, expectedRevision: 0);
      expect(r.valueOrNull?.changed, isTrue);
      expect(r.valueOrNull?.application, PluginApplication.applied);
      expect(p.applyCount, 2, reason: '生效值变了，必须重载而不是让旧值继续跑');
    });

    test('只改易变值：changed=false，不重载也不提示"配置已改动"', () async {
      const withVolatile = PluginManifest(
        id: 'cfg-two',
        name: 'cfg-two',
        description: 'd',
        trust: PluginTrust.trusted,
        permissions: [PluginPermission.pluginStorage],
        params: [PluginParam(name: 'lastGap', label: '上次间隔', type: PluginParamType.number, defaultValue: 5, volatile: true)],
      );
      final p = _CountingPlugin(withVolatile);
      builtin.register(withVolatile, () => p);
      build(on: {'cfg-two'});
      await service.boot();
      final r = await service.setConfig(id: 'cfg-two', patch: const {'lastGap': 12}, expectedRevision: 0);
      expect(r.valueOrNull?.changed, isFalse);
      expect(p.applyCount, 1, reason: '易变值变了不值得重载');
    });

    test('用过期 revision 保存 → 失败并指名 save 阶段', () async {
      const withParam = PluginManifest(
        id: 'cfg-three',
        name: 'cfg-three',
        description: 'd',
        trust: PluginTrust.trusted,
        permissions: [PluginPermission.pluginStorage],
        params: [PluginParam(name: 'gap', label: '间隔', type: PluginParamType.number, defaultValue: 5)],
      );
      builtin.register(withParam, () => _CountingPlugin(withParam));
      build(on: {'cfg-three'});
      await service.boot();
      await service.setConfig(id: 'cfg-three', patch: const {'gap': 6}, expectedRevision: 0);
      final r = await service.setConfig(id: 'cfg-three', patch: const {'gap': 3}, expectedRevision: 0);
      expect(r.valueOrNull?.application, PluginApplication.failed);
      expect(r.valueOrNull?.stage, 'save');
      expect(r.valueOrNull?.failure?.message, contains('被别人改过'));
    });
  });

  group('运行入口三合一', () {
    test('chip / slash / 智能体工具走同一条 run，插件里能分辨入口', () async {
      final p = _CountingPlugin(_m('runner'));
      builtin.register(p.manifest, () => p);
      build(on: {'runner'});
      await service.boot();
      final a = await service.run('runner', const PluginInput(entry: PluginEntryKind.composerAction));
      final b = await service.run('runner', const PluginInput(entry: PluginEntryKind.slashCommand, text: '/tingxie'));
      expect(a.valueOrNull?.data['entry'], 'composerAction');
      expect(b.valueOrNull?.data['entry'], 'slashCommand');
      expect(p.runCount, 2);
    });

    test('停用后 run 明确拒绝并给出路（不是"点了没反应"）', () async {
      builtin.register(_m('off-one'), () => _CountingPlugin(_m('off-one')));
      build();
      await service.boot();
      final r = await service.run('off-one', const PluginInput(entry: PluginEntryKind.composerAction));
      expect(r.isErr, isTrue);
      expect(r.failureOrNull?.message, matches(RegExp(r'^「.+」已被停用$')), reason: r.failureOrNull?.message);
      expect(r.failureOrNull?.hint, contains('去「插件」页打开它'),
          reason: '两字「插件」等于没指路：必须说到哪一页、做什么动作');
    });

    test('不存在的插件 id → 说清没有这个插件', () async {
      build();
      await service.boot();
      final r = await service.run('nope', const PluginInput(entry: PluginEntryKind.composerAction));
      expect(r.failureOrNull?.message, contains('没有「nope」这个插件'),
          reason: '两字「没有」什么都能过；id 必须被原样报回来，用户才知道是哪条点错了');
    });
  });

  group('诊断', () {
    test('diagnostics 给出 effect 树 + 槽账本 + 最近日志（面板三块）', () async {
      builtin.register(_m('diag-one'), () => _CountingPlugin(_m('diag-one')));
      build(on: {'diag-one'});
      await service.boot();
      final d = service.diagnostics('diag-one');
      expect(d['state'], 'active');
      expect((d['effectTree'] as List), isNotEmpty);
      expect((d['slots'] as List).single['registrant'], 'diag-one');
      expect((d['logs'] as List).any((r) => (r['message'] as String).startsWith('fiber →')), isTrue);
    });
  });

group('插件抛异常不许击穿平台', () {
    test('run 里 throw → 收成 runtimeError，原文进 cause，调用方不被炸', () async {
      const m = PluginManifest(id: 'boom-one', name: '会炸的', description: 'd', trust: PluginTrust.trusted);
      builtin.register(m, () => _ThrowingPlugin(m, message: 'boom 掉了'));
      build(on: {'boom-one'});
      await service.boot();
      final r = await service.run('boom-one', const PluginInput(entry: PluginEntryKind.composerAction));
      expect(r.isErr, isTrue);
      expect(r.failureOrNull!.code, PluginFailureKind.runtimeError);
      expect(r.failureOrNull!.message, contains('出了点问题'), reason: '给用户的是人话');
      expect(r.failureOrNull!.hint, contains('在「插件」页打开它的诊断记录看详情'),
          reason: '炸了的出路是看诊断树（原文在 cause 里），不是去看前置条件');
      expect(r.failureOrNull!.hint, contains('可先重试一次'), reason: '还要给一个当场做得动的动作');
      expect(r.failureOrNull!.cause, contains('boom 掉了'), reason: '给诊断的是原文（含插件自己抛的字符串）');
      expect(trace.records.any((x) => x.level == TraceLevel.fail), isTrue);
    });

    test('run 里抛取消信号 → Ok + userVisible=false（取消不是失败）', () async {
      const m = PluginManifest(id: 'cancel-one', name: '会被停的', description: 'd', trust: PluginTrust.trusted);
      builtin.register(m, () => _ThrowingPlugin(m, cancel: true));
      build(on: {'cancel-one'});
      await service.boot();
      final r = await service.run('cancel-one', const PluginInput(entry: PluginEntryKind.composerAction));
      expect(r.isOk, isTrue, reason: r.failureOrNull?.message);
      expect(r.valueOrNull!.userVisible, isFalse, reason: '用户自己停的，不该弹提示');
      expect(r.valueOrNull!.summary, contains('已取消'));
      // 第 84 轮补：只断 isOk + summary 时，`cancelReasonOf` 改成恒 null 也照样绿 ——
      // 原因丢了，用户不知道自己刚才动的是哪一个（听写连念三个词时尤其要分得清）。
      expect(r.valueOrNull!.data['reason'], '用户按了停止',
          reason: '取消原因必须由 `cancelReasonOf` 带出来并落到 data 里，面板才说得出"为什么停了"');
    });
  });
}

class _ExplodingPlugin implements AppPlugin {
  _ExplodingPlugin(this.manifest);
  @override
  final PluginManifest manifest;
  @override
  Outcome<Disposable?> apply(PluginCtx ctx) => throw StateError('启动就炸');
  @override
  Future<Outcome<PluginRunResult>> run(PluginCtx ctx, PluginInput input) async => const Ok<PluginRunResult>(PluginRunResult());
}

/// 内置注册表"突然读不动"的探针（last-good 回退用例用：整棵树都读崩时该沿用上一次好的）。
class _FlakyBuiltin extends BuiltinSourceReader {
  _FlakyBuiltin(BuiltinSourceReader seed)
      : super({
          for (final e in seed.read())
            if (e.manifest != null && e.factory != null)
              e.manifest!.id: (manifest: e.manifest!, factory: e.factory!),
        });

  bool boom = false;

  @override
  List<SourceEntry> read() {
    if (boom) throw StateError('注册表读不动了');
    return super.read();
  }
}
