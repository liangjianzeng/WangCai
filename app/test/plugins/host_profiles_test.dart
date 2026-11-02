// 方案档的宿主侧（P6）：读盘、当前档持久化、一键换场景的副作用。
//
// 这里钉的是"用户点一下换档之后到底发生了什么"：
// ① 档文件坏了不许连累别的档；② 换档后插件集真的变了；
// ③ **面板预览说的和切完真的是同一件事**（compose == preview 在 app 侧的兑现）；
// ④ 档没表态就不许碰用户的人格/模型；⑤ 改了环境必须归零 KV。
import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:plugin_kernel/plugin_kernel.dart';
import 'package:plugin_sdk/testing.dart';
import 'package:tongyi_lite/plugins/builtin/en_dictation/en_dictation_plugin.dart';
import 'package:tongyi_lite/plugins/builtin/hello/hello_plugin.dart';
import 'package:tongyi_lite/plugins/host/host_profiles.dart';

Future<PluginService> buildService({HostProfiles? profiles}) async {
  final caps = CapabilityRegistry()
    ..register(FakeStore(), ownerPluginId: 'app')
    ..register(FakeInteract(numbers: const [5], choices: const ['开始听写']), ownerPluginId: 'app')
    ..register(FakeCapture(), ownerPluginId: 'app')
    ..register(FakeLlmVision(response: '{"items":[{"text":"apple","note":"苹果"}]}'), ownerPluginId: 'app')
    ..register(FakeLlmComplete(), ownerPluginId: 'app')
    ..register(FakeSpeak(gapCap: const Duration(milliseconds: 1)), ownerPluginId: 'app');
  final builtin = BuiltinSourceReader()
    ..register(HelloBuiltinPlugin.manifestDef, HelloBuiltinPlugin.new)
    ..register(EnglishDictationPlugin.manifestDef, EnglishDictationPlugin.new);
  final service = PluginService(
    loader: PluginLoader(
      capabilities: caps,
      builtin: builtin,
      appVersion: '0.2.8',
      knownCapabilityIds: kKnownCapabilityIds,
    ),
    capabilities: caps,
    slots: SlotRegistry(),
    configStore: ConfigStore(),
    enabledStore: MemoryEnabledStore({'hello-note', 'en-dictation'}),
    // 与装配根同样的接法：档从哪读、当前是哪个档由宿主告诉内核（语义仍归内核）。
    profiles: profiles?.store(),
    activeProfile: () => profiles?.active,
    trace: InMemoryTraceSink(),
  );
  await service.boot();
  return service;
}

/// 记录调用的假设置侧（真实现会落到 settingsProvider，这里只验"该动/不该动"）。
class _SpySink implements ProfileSettingsSink {
  _SpySink({this.personaId, this.defaultModelId}); // 没有用例给 activeApiModelId 传初值，就不留这个假旋钮
  @override
  String? personaId;
  @override
  String? defaultModelId;
  @override
  String? activeApiModelId;
  final List<String> calls = [];

  // 真设置侧是"接受就改值"，这里照做：KV 归零的判定靠**回读前后差**，
  // 假实现若只记不调，测的就不是那条真规则。
  @override
  Future<void> usePersona(String? id) async {
    calls.add('persona:$id');
    personaId = id;
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

void main() {
  late Directory dir;

  setUp(() => dir = Directory.systemTemp.createTempSync('profiles_test'));
  tearDown(() {
    if (dir.existsSync()) dir.deleteSync(recursive: true);
  });

  void writeProfile(String name, Map<String, Object?> body) {
    File('${dir.path}/$name.json').writeAsStringSync(jsonEncode(body));
  }

  HostProfiles host({String? active, ActiveProfileStore? activeStore}) => HostProfiles(
        dirPath: dir.path,
        activeStore: activeStore ?? MemoryActiveProfileStore(active),
        active: active,
      );

  group('面板建档', () {
    test('建好：文件真的落盘、内容是可读的形状、并且**不切过去**', () async {
      final active = MemoryActiveProfileStore('课堂');
      final h = host(active: '课堂', activeStore: active);

      final r = await h.create('通勤', {'hello-note', 'en-dictation'}, note: '路上用');
      expect(r.isOk, isTrue, reason: r.toString());

      final file = File('${dir.path}/通勤.json');
      expect(file.existsSync(), isTrue);
      final body = jsonDecode(file.readAsStringSync()) as Map<String, dynamic>;
      expect(body['enabled'], ['en-dictation', 'hello-note'], reason: '排序写出来，作者手改/diff 都友好');
      expect(body['note'], '路上用');

      // 建完仍是原来的档：用户点的是"存一份"，不是"换成这个"。
      expect(h.active, '课堂');
      expect(active.read(), '课堂');
    });

    test('同名档绝不覆盖（作者可能正在文件管理器里手写那份）', () async {
      writeProfile('课堂', {'enabled': ['hello-note']});
      final r = await host().create('课堂', {'hello-note', 'en-dictation'});
      expect(r.isErr, isTrue);
      expect(r.failureOrNull!.code, PluginFailureKind.badContent);
      expect(r.failureOrNull!.message, matches(RegExp(r'^已经有叫「.+」的方案档了$')),
      reason: '形状钉住：重名必须把撞的那个档名回显出来，光说「已经有」用户不知道该改哪个（第一版我猜成「已经有叫「X」了」，红给我看了：真话中间还有「的方案档」）');
      expect(r.failureOrNull!.hint, contains('课堂.json'), reason: '出路要指到那份文件本身');

      final still = jsonDecode(File('${dir.path}/课堂.json').readAsStringSync()) as Map<String, dynamic>;
      expect(still['enabled'], ['hello-note'], reason: '原样没动');
    });

    test('档名不合格当场拒绝，并说清为什么（不去猜落盘会怎么炸）', () async {
      final r = await host().create('课堂/通勤', {'hello-note'});
      expect(r.isErr, isTrue);
      expect(r.failureOrNull!.message, contains('档名不能用'));
      expect(r.failureOrNull!.hint, contains('文件名的字符'));
      expect(File('${dir.path}/课堂.json').existsSync(), isFalse);
    });

    test('目录写不下去时给人话 + 留原因，不抛给用户一个异常', () async {
      final ghost = HostProfiles(dirPath: '${dir.path}/不存在/再深一层', activeStore: MemoryActiveProfileStore());
      // 造一个"父目录是文件"的死路：create 目录必然失败。
      File('${dir.path}/不存在').writeAsStringSync('占位');
      final r = await ghost.create('课堂', {'hello-note'});
      expect(r.isErr, isTrue);
      expect(r.failureOrNull!.message, contains('方案档没建成'),
      reason: '要说破「方案档」这个用户听得懂的名词，不是笼统一句没建成（什么没建成？）');
      expect(r.failureOrNull!.hint, contains('看看存储是否可写'),
      reason: '出路要具体到动作（查存储可写、换档名），两字「存储」什么都指不到');
      // 参谋保留：同上：这条断的是「原始异常必须留下」（漏了就没法查为什么写不进盘），文案由 message/hint 那两条管。
      expect(r.failureOrNull!.cause, isNotNull, reason: '原始异常进诊断，不进 message');
    });
  });

  group('档目录读盘', () {
    test('坏档只标坏它自己，好档照常可用', () {
      writeProfile('课堂', {'enabled': ['hello-note']});
      File('${dir.path}/自习.json').writeAsStringSync('{这不是 JSON');

      final store = host().store();
      expect(store.names(), unorderedEquals(['课堂', '自习']), reason: '坏档也要列得出来，用户才知道去修');
      expect(store.names(), [...store.names()]..sort(), reason: '面板顺序必须稳定，不能跟着文件系统心情变');
      expect(store.brokenProfiles().map((e) => e.name), ['自习']);
      expect(store.profile('课堂'), isNotNull);
      expect(store.profile('课堂')!.enabled, {'hello-note'});
    });

    test('整个目录读不动 = 没有档，而不是"把所有插件关掉"', () async {
      final ghost = HostProfiles(dirPath: '${dir.path}/不存在', activeStore: MemoryActiveProfileStore());
      expect(ghost.store().names(), isEmpty);

      // 标题说的是「不是把所有插件关掉」——那就得看运行时插件集，光看 compose 是空话（这条以前是把 service 丢掉不查的）。
      final service = await buildService(profiles: ghost);
      final loaded = service.result!.plugins;
      expect(loaded.map((p) => p.descriptor.manifest.id), containsAll(<String>['hello-note', 'en-dictation']),
          reason: '档目录读不动时插件集不许缩水：fail-safe 是照原开关，不是干脆都不跑');
      expect(loaded.map((p) => p.status), isNot(contains(PluginLoadStatus.disabled)),
          reason: '读不到档就把插件判成已停用 = 用户以为是自己关的，其实是没读到档');
      final c = ghost.store().compose(active: '课堂', persistedEnabled: {'hello-note', 'en-dictation'});
      expect(c.enabled, {'hello-note', 'en-dictation'}, reason: 'fail-safe：档读不到就照原开关');
      expect(c.warnings, isNotEmpty);
    });
  });

  group('一键换场景', () {

    test('switchTo 之后 runtime 必须真的换了插件集（不是只改了档文件）', () async {
      // 这一条测的是「受理了没干活」那一族：`switchTo` 里那句 `service.reload()` 一旦被删，
      // 档文件照改、面板照显示新档名，而 runtime 还是旧插件集 —— 全程没有红字。
      writeProfile('课堂', {'enabled': ['hello-note']});
      final hp = host();
      final service = await buildService(profiles: hp);
      await service.reload();

      Set<String> runningIds() => service
          .view()
          .where((v) => v.loaded.status == PluginLoadStatus.active)
          .map((v) => v.id)
          .toSet();

      expect(runningIds(), containsAll(<String>['hello-note', 'en-dictation']),
          reason: '换档前两个内置件都该在跑，否则下面没有对照组（这条测试就退化成假断言）');

      final r = await hp.switchTo(service, '课堂');
      expect(r.profile, '课堂');
      expect(r.enabled, {'hello-note'}, reason: 'switchTo 自己报的生效集就得是档里那份');
      expect(
        service.composition.enabled,
        {'hello-note'},
        reason: 'runtime 真正用的那份必须跟着换：预览报一套、runtime 做一套，用户以为已经换了场景。',
      );
      expect(runningIds(), {'hello-note'},
          reason: '真正加载着的 fiber 集必须只剩被放行那个；en-dictation 还挂着 = 换档没落地');

      // 用户看得见的说法：调一个被档停用的插件，得说「已被停用」，不是"没这个插件"、也不是空转成功。
      final denied =
          await service.run('en-dictation', const PluginInput(entry: PluginEntryKind.composerAction));
      expect(denied.isErr, isTrue, reason: '被档停用的插件不许照跑');
      expect(
        denied.failureOrNull?.message,
        contains('「英语听写」已被停用'), // 产品说的是**显示名**（实测 Actual），不是 id —— 断原句，不猜测
        reason: '话要说对：是"被档停用了"，不是"本机没这个能力"，也不是"没有这个插件"。',
      );
    });
    test('档白名单真的改变插件集；当前档持久化（重启还在）', () async {
      writeProfile('课堂', {'enabled': ['hello-note']});
      final active = MemoryActiveProfileStore();
      // 同一个 HostProfiles 实例既喂给 service（activeProfile 闭包读它），又被用来切档：
      // 两个实例会各记各的档名，切了等于没切。
      final h = host(activeStore: active);
      final service = await buildService(profiles: h);

      final r = await h.switchTo(service, '课堂');
      expect(r.profile, '课堂');
      expect(r.enabled, {'hello-note'});
      expect(service.result!.byId('hello-note')!.status, PluginLoadStatus.active);
      expect(service.result!.byId('en-dictation')!.status, PluginLoadStatus.disabled);
      expect(active.read(), '课堂');
      expect(active.writes, 1);

      // "重启"：新的 HostProfiles 读同一个存储，档名必须还在。
      expect(host(activeStore: active).active, '课堂');
    });

    test('面板预览说的 == 切完真的（同一个 compose，不许各算一套）', () async {
      writeProfile('自习', {'enabled': ['hello-note', 'en-dictation'], 'disabled': ['en-dictation']});
      final h = host();
      final service = await buildService(profiles: h);
      final preview = service.previewProfile('自习');
      final r = await h.switchTo(service, '自习');
      expect(preview.enabled, r.enabled, reason: '预览与 runtime 必须一致');
      expect(r.enabled, {'hello-note'});
      expect(r.profile, '自习');
    });

    test('档不存在：插件集保持原样 + 一句人话提醒，绝不全员停用', () async {
      final h = host();
      final service = await buildService(profiles: h);
      final r = await h.switchTo(service, '没这个档');
      expect(r.profile, '没这个档');
      expect(r.notes.any((w) => w.contains('找不到方案档')), isTrue);
      expect(r.enabled, containsAll(['hello-note', 'en-dictation']));
    });

    test('档没表态就不碰人格/模型；表态了就切，并回报 resetKv', () async {
      writeProfile('上课', {'enabled': ['hello-note'], 'personaId': 'p-teacher'});
      writeProfile('裸档', {'enabled': ['hello-note']});
      final h = host();
      final service = await buildService(profiles: h);

      final bare = _SpySink(personaId: 'standard', defaultModelId: 'm0');
      await h.switchTo(service, '裸档', sink: bare);
      expect(bare.calls, isEmpty, reason: '档没写就不许替用户改设置');
      expect(bare.personaId, 'standard');

      final sink = _SpySink(personaId: 'standard');
      final r = await h.switchTo(service, '上课', sink: sink);
      expect(sink.calls, ['persona:p-teacher']);
      expect(r.resetKv, isTrue, reason: '换了人格=换了提示词前缀，KV 必须归零，否则新档跑旧人格');
    });

    test('取消档：回到逐个开关，档名从存储里清掉', () async {
      writeProfile('课堂', {'enabled': ['hello-note']});
      final active = MemoryActiveProfileStore('课堂');
      final h = host(activeStore: active);
      final service = await buildService(profiles: h);
      final r = await h.switchTo(service, null);
      expect(r.profile, isNull);
      expect(active.read(), isNull);
      expect(r.enabled, containsAll(['hello-note', 'en-dictation']), reason: '取消档之后照用户自己的开关');
    });

    test('删掉正在用的档：当前档自动清空（不留悬空档名）', () async {
      writeProfile('课堂', {'enabled': ['hello-note']});
      final active = MemoryActiveProfileStore('课堂');
      final h = host(activeStore: active);
      expect(await h.delete('课堂'), isTrue);
      expect(h.active, isNull);
      expect(await h.delete('课堂'), isFalse, reason: '再删一次要说清楚"本来就没有"');
    });

    test('save 出来的档能被内核读回（作者手写与面板生成同构）', () async {
      final h = host();
      await h.save('手搓', {'enabled': ['hello-note'], 'config': {'hello-note': {'note': 'abc'}}});
      final p = h.store().profile('手搓')!;
      expect(p.enabled, {'hello-note'});
      expect(p.config['hello-note'], {'note': 'abc'});
    });
  });
}
