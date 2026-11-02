// 治理面板（P6）的行为钉死。
//
// 面板是平台"坏了能自解释"的那一半：状态必须诚实、详情必须能定位问题、
// 而且**插件出任何事都不许把面板带崩**（崩了用户就再也打不开它，等于平台失去自诊能力）。
import 'dart:convert';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:plugin_kernel/plugin_kernel.dart';
import 'package:plugin_sdk/testing.dart';
import 'package:tongyi_lite/plugins/builtin/en_dictation/en_dictation_plugin.dart';
import 'package:tongyi_lite/plugins/builtin/hello/hello_plugin.dart';
import 'package:tongyi_lite/plugins/host/host_profiles.dart';
import 'package:tongyi_lite/plugins/panel/plugins_screen.dart';
import 'package:tongyi_lite/plugins/plugin_host.dart';

/// 一改配置就炸的插件：`apply` 抛异常 → `setConfig` 返回的是 **`Ok(ChangeResult)` 里装着失败**。
/// 面板要是只看 Ok/Err，就会对着一个根本没生效的操作回一句「已更新」。
class _ExplodesOnConfig implements AppPlugin {
  _ExplodesOnConfig(this.manifest);

  static final manifestDef = PluginManifest(
    id: 'boom-config',
    name: '配置会炸',
    description: 'd',
    inject: const [],
    permissions: const [PluginPermission.pluginStorage],
    trust: PluginTrust.trusted,
    params: [
      const PluginParam(name: 'mode', label: '模式', type: PluginParamType.text, defaultValue: 'calm'),
    ],
  );

  @override
  final PluginManifest manifest;

  @override
  Outcome<Disposable?> apply(PluginCtx ctx) {
    if (ctx.stringConfig('mode', '') == 'boom') throw StateError('配置载入失败：磁盘满了');
    return const Ok<Disposable?>(null);
  }

  @override
  Future<Outcome<PluginRunResult>> run(PluginCtx ctx, PluginInput input) async =>
      Ok<PluginRunResult>(PluginRunResult(summary: 'ok'));
}

Future<PluginService> buildService({
  bool withVision = true,
  Set<String>? enabled,
  HostProfiles? profiles,
  bool withBoom = false,
}) async {
  final caps = CapabilityRegistry()
    ..register(FakeStore(), ownerPluginId: 'app')
    ..register(FakeInteract(numbers: const [5], choices: const ['开始听写']), ownerPluginId: 'app')
    ..register(FakeCapture(), ownerPluginId: 'app')
    ..register(FakeLlmComplete(), ownerPluginId: 'app')
    ..register(FakeSpeak(gapCap: const Duration(milliseconds: 1)), ownerPluginId: 'app');
  if (withVision) {
    caps.register(FakeLlmVision(response: '{"items":[{"text":"apple","note":"苹果"}]}'), ownerPluginId: 'app');
  }
  final builtin = BuiltinSourceReader()
    ..register(HelloBuiltinPlugin.manifestDef, HelloBuiltinPlugin.new)
    ..register(EnglishDictationPlugin.manifestDef, EnglishDictationPlugin.new);
  if (withBoom) builtin.register(_ExplodesOnConfig.manifestDef, () => _ExplodesOnConfig(_ExplodesOnConfig.manifestDef));
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
    enabledStore: MemoryEnabledStore(enabled ?? {'hello-note', 'en-dictation', if (withBoom) 'boom-config'}),
    profiles: profiles?.store(),
    activeProfile: () => profiles?.active,
    trace: InMemoryTraceSink(capacity: 200),
  );
  await service.boot();
  return service;
}

Future<void> pumpPanel(WidgetTester tester, PluginService? service, {HostProfiles? profiles}) async {
  tester.view.physicalSize = const Size(1080, 2400);
  tester.view.devicePixelRatio = 3;
  addTearDown(tester.view.reset);
  await tester.pumpWidget(ProviderScope(
    overrides: [
      pluginHostProvider.overrideWith((ref) async => service),
      // 档目录是宿主给的；面板只认这个 provider，自己去读盘/落盘的事一概不做。
      hostProfilesProvider.overrideWith((ref) async => profiles),
    ],
    child: const MaterialApp(home: PluginsScreen(pluginsDirHint: '文档/plugins/<插件名>/plugin.json')),
  ));
  await tester.pumpAndSettle();
}

/// 面板 + 一个真的档目录（建档/删档这两条路都要落盘，所以给临时目录 + 真 `HostProfiles`）。
class _Harness {
  _Harness(this.dir, this.profiles, this.service);

  final Directory dir;
  final HostProfiles profiles;
  final PluginService service;

  String pathOf(String name) => '${dir.path}/$name.json';
  bool has(String name) => File(pathOf(name)).existsSync();
  Map<String, dynamic> bodyOf(String name) => jsonDecode(File(pathOf(name)).readAsStringSync()) as Map<String, dynamic>;
}

Future<_Harness> pumpPanelWithDir(
  WidgetTester tester, {
  String? active,
  List<String> names = const [],
  List<String> broken = const [],
}) async {
  final dir = Directory.systemTemp.createTempSync('panel_profile');
  addTearDown(() {
    if (dir.existsSync()) dir.deleteSync(recursive: true);
  });
  for (final n in names) {
    File('${dir.path}/$n.json').writeAsStringSync(jsonEncode({'enabled': ['hello-note', 'en-dictation']}));
  }
  for (final n in broken) {
    File('${dir.path}/$n.json').writeAsStringSync('{坏文件');
  }
  final profiles = HostProfiles(dirPath: dir.path, activeStore: MemoryActiveProfileStore(active), active: active);
  final service = await buildService(profiles: profiles);
  await pumpPanel(tester, service, profiles: profiles);
  return _Harness(dir, profiles, service);
}

/// 点一个 `FilledButton`（按 key 找）。对话框里的按钮位置随内容高度浮动，
/// `tester.tap` 判不到就**静默不响应**（比红测更坏），所以直接触发回调。
void pressFilled(WidgetTester tester, Key key) {
  final button = tester.widget<FilledButton>(find.byKey(key));
  expect(button.onPressed, isNotNull, reason: '按钮被禁用说明前置状态不对：$key');
  button.onPressed!();
}

/// 等真实文件 IO 落定：【按条件轮询】，不给固定预算（预算型等法靠运气，机器一忙就偶发红）。
/// 等不到就把 [what] 报出来 —— 这样真回归仍然会红，不是把失败藏进无限等待。
Future<void> settleIoUntil(WidgetTester tester, bool Function() done, String what) async {
  await tester.runAsync(() async {
    // 最少推 8 帧再允许提前退出：条件常常**先于 UI 追上**就成立（文件早删掉了），
    // 一成立就 break 会让后面的 `find.…` 断言看到一棵还没重建的树 —— 第一次改完就是被这个红教育的。
    for (var i = 0; i < 200; i++) {
      await tester.pump(const Duration(milliseconds: 20));
      await Future<void>.delayed(const Duration(milliseconds: 5));
      if (i >= 8 && done()) break;
    }
  });
  expect(done(), isTrue, reason: '等不到：$what（要么真 IO 没落定，要么代码回归了）');
}

Finder _tileOf(String name) => find.ancestor(of: find.text(name), matching: find.byType(Material)).first;

void main() {
  /// 点「建好」。对话框里按钮位置随内容高度浮动，`tester.tap` 判不到就会**静默不响应**
  /// （比红测更坏），所以这里直接触发回调，把建档这条路真跑一遍。
  void _pressCreate(WidgetTester tester) {
    final button = tester.widget<FilledButton>(find.byKey(const Key('profile-create-ok')));
    expect(button.onPressed, isNotNull, reason: '按钮被禁用说明前置状态不对');
    button.onPressed!();
  }

  group('面板「新建方案档」', () {
    Future<(Directory, HostProfiles, PluginService)> setup(WidgetTester tester, {String? active}) async {
      final dir = Directory.systemTemp.createTempSync('panel_profile');
      addTearDown(() {
        if (dir.existsSync()) dir.deleteSync(recursive: true);
      });
      final profiles = HostProfiles(dirPath: dir.path, activeStore: MemoryActiveProfileStore(active), active: active);
      final service = await buildService(profiles: profiles);
      await pumpPanel(tester, service, profiles: profiles);
      return (dir, profiles, service);
    }

    Future<void> openDialog(WidgetTester tester) async {
      // 坑记一笔：`find.byType` 是**精确类型**匹配，而 `TextButton.icon` 造出来的是私有子类
      // （`_TextButtonWithIcon`）—— 按 `TextButton` 或 `ButtonStyleButton` 找都是 0 个，必须用谓词判类型。
      final button = find
          .ancestor(
              of: find.text('新建'),
              matching: find.byWidgetPredicate((w) => w is ButtonStyleButton))
          .first;
      await tester.ensureVisible(button);
      await tester.tap(button);
      await tester.pumpAndSettle();
      expect(find.byType(AlertDialog), findsOneWidget, reason: '点了新建就得有框，静默不弹是最坏的');
    }

    testWidgets('打开就把现在开着的插件预勾上（读的是 previewProfile，与 runtime 同源）', (tester) async {
      await setup(tester);
      await openDialog(tester);

      // key 挂在 CheckboxListTile 上（整行可点），不是里面的 Checkbox —— 取错类型就是 cast 崩。
      CheckboxListTile boxOf(String id) => tester.widget<CheckboxListTile>(find.byKey(Key('profile-pick-$id')));
      expect(boxOf('hello-note').value, isTrue);
      expect(boxOf('en-dictation').value, isTrue, reason: '最常做的动作是"照现在这样存一份再关掉几个"');
      expect(find.text('建好不会自动切过去 —— 点它的卡片才生效。'), findsOneWidget,
          reason: '这句话是承诺，也是防误解的说明');
    });

    testWidgets('勾掉一个插件建好：落盘的档就是那个集合，而且**没有偷偷切过去**', (tester) async {
      final (dir, profiles, _) = await setup(tester);
      await openDialog(tester);

      await tester.enterText(find.byKey(const Key('profile-name-field')), '通勤');
      final box = find.byKey(const Key('profile-pick-en-dictation'));
      await tester.ensureVisible(box);
      await tester.tap(box);
      await tester.pumpAndSettle();

      // 建档要落盘：**真实文件 IO 在 testWidgets 的假时钟里永远不会完成**，必须 `runAsync` 包起来。
      // 循环里两样都得给：`pump(时长)` 推进假时钟（面板/宿主的代码跑在假区里，它的 await 靠假时钟续跑），
      // 真 `Future.delayed` 给 dart:io 的完成回调落进队列的机会 —— 少任何一样，写完 tmp 后的 rename 永远等不到。
      _pressCreate(tester);
      // 条件轮询而不是固定预算：见 settleIoUntil 的注释（第 72 轮的偶发红就是从固定 100ms 来的）。
      await settleIoUntil(tester, () => File('${dir.path}/通勤.json').existsSync(), '建档没落盘');

      final file = File('${dir.path}/通勤.json');
      expect(file.existsSync(), isTrue, reason: '面板说建好了就得真有这个文件');
      final body = jsonDecode(file.readAsStringSync()) as Map<String, dynamic>;
      expect(body['enabled'], ['hello-note'], reason: '勾掉的那个不能混进来');

      // 建完仍是"不用档"：用户点的是存一份，不是换成它。
      expect(profiles.active, isNull);
      expect(find.textContaining('还没切过去'), findsOneWidget);
    });

    testWidgets('档名不合格就地报错，不弹 SnackBar、也不落盘', (tester) async {
      final (dir, _, _) = await setup(tester);
      await openDialog(tester);

      await tester.enterText(find.byKey(const Key('profile-name-field')), '课堂/通勤');
      _pressCreate(tester); // 这一步只有校验，不落盘，普通 pump 就够
      await tester.pumpAndSettle();

      expect(find.textContaining('不能用来做文件名的字符'), findsOneWidget, reason: '话要留在正在填的框上');
      expect(find.byType(AlertDialog), findsOneWidget, reason: '没填对就不该关框');
      expect(dir.listSync().where((e) => e.path.endsWith('.json')), isEmpty, reason: '报错的输入不许留下文件');

      // 改对了就能建（错误状态得能自己恢复，不许卡死在红字上）。
      await tester.enterText(find.byKey(const Key('profile-name-field')), '课堂');
      _pressCreate(tester);
      // 条件轮询而不是固定预算：见 settleIoUntil 的注释（第 72 轮的偶发红就是从固定 100ms 来的）。
      await settleIoUntil(tester, () => File('${dir.path}/课堂.json').existsSync(), '改正档名之后仍然没建出来（错误状态卡死了）');
      expect(File('${dir.path}/课堂.json').existsSync(), isTrue);
    });
  });

  group('面板删方案档', () {
    Future<void> tapDelete(WidgetTester tester, String name) async {
      final button = find.byKey(Key('profile-delete-$name'));
      expect(button, findsOneWidget, reason: '每个档都得有看得见的删除入口（长按手势手机上等于没有）');
      await tester.ensureVisible(button);
      await tester.tap(button);
      await tester.pumpAndSettle();
      expect(find.byType(AlertDialog), findsOneWidget, reason: '删文件不可撤销，必须先问');
    }

    testWidgets('删当前在用的档：确认框说清"回到不用档"，删完插件列表不许受影响', (tester) async {
      final h = await pumpPanelWithDir(tester, active: '课堂', names: ['课堂', '通勤']);
      expect(h.has('通勤'), isTrue);

      await tapDelete(tester, '课堂');
      expect(find.textContaining('而且正在用它'), findsOneWidget, reason: '要说清删的是在用的那个');
      expect(find.textContaining('回到「不用档（逐个开关）」'), findsOneWidget, reason: '删完会变成什么样必须写在脸上');
      expect(find.textContaining('插件本身、以及它们各自存的参数都不动'), findsOneWidget,
          reason: '用户最怕"档没了插件也没了"，这句必须说');

      pressFilled(tester, const Key('profile-delete-confirm'));
      await settleIoUntil(tester, () => !h.has('课堂'), '确认删「课堂」之后档文件还在');

      expect(h.has('课堂'), isFalse, reason: '确认了就得真删掉');
      expect(h.has('通勤'), isTrue, reason: '只删点的那一个');
      expect(h.profiles.active, isNull, reason: '删掉在用的档必须回落到不用档');
      expect(find.textContaining('已回到「不用档（逐个开关）」'), findsOneWidget);
      // 删档不是删插件：列表里两个插件还在、还标着"可运行"。
      expect(find.text('记事小卡'), findsOneWidget);
      expect(find.text('英语听写'), findsOneWidget);
      expect(find.text('可运行'), findsWidgets);
    });

    testWidgets('按「取消」就一个字节都不许动', (tester) async {
      final h = await pumpPanelWithDir(tester, names: ['课堂']);
      await tapDelete(tester, '课堂');
      await tester.tap(find.text('取消'));
      await tester.pumpAndSettle();

      expect(h.has('课堂'), isTrue, reason: '没确认就不许碰文件');
      expect(find.byType(AlertDialog), findsNothing);
      expect(find.textContaining('课堂 · 2 件'), findsOneWidget, reason: '档还得留在列表里');
    });

    testWidgets('读不动的坏档也能从面板删掉 —— 手机上没文件管理器时这是它唯一的出路', (tester) async {
      final h = await pumpPanelWithDir(tester, broken: ['烂档']);
      expect(find.textContaining('烂档（读不动）'), findsOneWidget, reason: '坏档要现身，但只标它自己');

      await tapDelete(tester, '烂档');
      expect(find.textContaining('读不动'), findsWidgets, reason: '确认框要认得出这是坏档，话要说对');
      pressFilled(tester, const Key('profile-delete-confirm'));
      await settleIoUntil(tester, () => !h.has('烂档'), '坏档删不掉（读不动的档也得有出路）');

      expect(h.has('烂档'), isFalse);
      // SnackBar 里也会出现"烂档"这个词（'删掉了「烂档」'），所以只查芯片本身 ——
      // 拿全文当断言对象会被自己的提示语骗过。
      expect(find.textContaining('烂档（读不动）'), findsNothing, reason: '删完就不该继续挂着吓人的红标');
    });

    testWidgets('档文件已经被外部删掉：不谎称"删掉了"，也不当异常报错', (tester) async {
      final h = await pumpPanelWithDir(tester, names: ['幽灵']);
      File(h.pathOf('幽灵')).deleteSync(); // 用户在文件管理器里先删了

      await tapDelete(tester, '幽灵');
      pressFilled(tester, const Key('profile-delete-confirm'));
      await settleIoUntil(
          tester, () => find.textContaining('本来就不存在').evaluate().isNotEmpty, '没弹出「本来就不存在」的诚实回执');

      expect(find.textContaining('本来就不存在'), findsOneWidget, reason: '诚实：没删成要说没删成');
      expect(find.textContaining('没成功'), findsNothing, reason: '这不是故障，不该吓人');
    });
  });

  testWidgets('列表把状态说清楚：能跑的说"可运行"，缺能力的说"待功能"并列出缺什么', (tester) async {
    final service = await buildService(withVision: false);
    await pumpPanel(tester, service);

    expect(find.text('记事小卡'), findsOneWidget);
    expect(find.text('英语听写'), findsOneWidget);
    expect(find.text('可运行'), findsOneWidget);
    expect(find.text('待功能'), findsOneWidget);
    expect(find.text('缺：llm.vision'), findsOneWidget);
    expect(find.textContaining('1 个在等功能'), findsOneWidget);
    expect(find.textContaining('第三方插件放：文档/plugins/'), findsOneWidget);
  });

  testWidgets('开关真的走服务（不是只改 UI 样子）', (tester) async {
    final service = await buildService();
    await pumpPanel(tester, service);
    expect(service.isEnabled('hello-note'), isTrue);

    await tester.tap(find.descendant(of: _tileOf('记事小卡'), matching: find.byType(Switch)));
    await tester.pumpAndSettle();

    expect(service.isEnabled('hello-note'), isFalse);
    expect(find.text('未启用'), findsWidgets);
  });

  testWidgets('详情能自解释：为什么能跑 / 占了哪些位置 / 起了哪些资源', (tester) async {
    final service = await buildService();
    await pumpPanel(tester, service);

    await tester.tap(find.text('记事小卡'));
    await tester.pumpAndSettle();

    expect(find.textContaining('运行中，资源都挂在 effect 树上'), findsOneWidget);
    expect(find.textContaining('app.input.right'), findsWidgets, reason: '占用位置要列得出来');
    expect(find.textContaining('它要的能力与权限'), findsOneWidget);
    expect(find.textContaining('app.store'), findsWidgets);
    // 内置件没有 JSON 原文，也得说清楚，不能显示空白让人以为坏了（在抽屉底部，要滚下去）。
    final raw = find.textContaining('内置插件没有 JSON 原文');
    await tester.dragUntilVisible(raw, find.byType(Scrollable).last, const Offset(0, -160));
    expect(raw, findsOneWidget);
  });

  testWidgets('待功能的插件：详情里说人话并给出路', (tester) async {
    final service = await buildService(withVision: false);
    await pumpPanel(tester, service);

    await tester.tap(find.text('英语听写'));
    await tester.pumpAndSettle();

    expect(find.textContaining('缺能力：llm.vision'), findsOneWidget);
    expect(find.textContaining('等宿主把那项能力接上'), findsOneWidget);
  });

  testWidgets('参数可编辑并落进配置（用户不用改 plugin.json）', (tester) async {
    final service = await buildService();
    await pumpPanel(tester, service);

    await tester.tap(find.text('英语听写'));
    await tester.pumpAndSettle();
    expect(find.text('设置'), findsWidgets);

    final field = find.widgetWithText(TextField, '间隔秒数');
    expect(field, findsOneWidget);
    await tester.enterText(field, '9');
    // 半屏抽屉里的按钮要先滚进视口：`tester.tap` 打偏只打印警告、不报错，
    // 于是"点了保存"其实是没点 —— 这类假通过必须用 ensureVisible 堵掉。
    final save = find.widgetWithText(FilledButton, '保存');
    expect(save, findsOneWidget);
    // 直接触发按钮回调：手势命中测试不是这块逻辑的一部分（点了没反应的那类 bug
    // 由上面"开关真的走服务"那条覆盖），这里要钉的是"表单值→配置"这条链。
    tester.widget<FilledButton>(save).onPressed!();
    await tester.pumpAndSettle();

    final stack = service.configStore.stackFor(EnglishDictationPlugin.manifestDef);
    expect(stack.value('gapSeconds'), 9.0);
  });

  testWidgets('参数行说出"这个值从哪层来"（四层配置不能靠用户猜）', (tester) async {
    final service = await buildService();
    await pumpPanel(tester, service);
    await service.setConfig(id: 'en-dictation', patch: const {'gapSeconds': 9});

    await tester.tap(find.text('英语听写'));
    await tester.pumpAndSettle();

    expect(find.textContaining('你的改动'), findsWidgets,
        reason: '改过的必须标出来 —— 否则"我改的到底生效没、是不是被方案档盖住了"只能猜');
    expect(find.textContaining('插件默认'), findsWidgets, reason: '没动的要标成默认，与"你的改动"分得开');
  });

  // 第 89 轮：`_layerTag` 是四路 switch，面板测试以前只钉过 `你的改动` / `插件默认` 两路 ——
  // 另两路改成任何句子测试都不响。而这两路恰恰最会骗人：
  // 「本次会话临时」说漏了，用户以为"先试试这组值"已经存下来了；
  // 「方案档给的」说漏了，用户以为那个值是自己改的，于是反复改同一个框、越改越不对。
  testWidgets('四层标签要说全：「方案档给的」与「本次会话临时」不许缺席', (tester) async {
    final dir = Directory.systemTemp.createTempSync('panel_layers');
    addTearDown(() {
      if (dir.existsSync()) dir.deleteSync(recursive: true);
    });
    File('${dir.path}/课堂.json').writeAsStringSync(jsonEncode({
      'enabled': ['hello-note', 'en-dictation'],
      'config': {
        'en-dictation': {'repeatTimes': 3},
      },
    }));
    final profiles =
        HostProfiles(dirPath: dir.path, activeStore: MemoryActiveProfileStore('课堂'), active: '课堂');
    final service = await buildService(profiles: profiles);
    // 会话层（「先试试这组值」那条路）：不落盘、只活到下次重载。
    await service.trialConfig(id: 'en-dictation', patch: const {'gapSeconds': 7});
    await pumpPanel(tester, service, profiles: profiles);

    await tester.tap(find.text('英语听写'));
    await tester.pumpAndSettle();

    expect(find.textContaining('方案档给的'), findsWidgets,
        reason: '「每个词念几遍」是档里写的 3 —— 不标出来，用户以为是自己改的，就会反复改同一个框');
    expect(find.textContaining('本次会话临时'), findsWidgets,
        reason: '「间隔秒数」是临时试的 7 —— 说漏了，用户以为已经存下来，重启后发现回到 5 只会觉得 app 不可信');
    expect(find.textContaining('插件默认'), findsWidgets,
        reason: '没动过的还要标"插件默认"：三路同屏才分得清谁压着谁');

    // 标签对了、值错了同样是骗人 —— 一起钉住生效值。
    final stack = service.configStore.stackFor(EnglishDictationPlugin.manifestDef);
    expect(stack.value('gapSeconds'), 7.0, reason: '会话层压过默认');
    expect(stack.value('repeatTimes'), 3.0, reason: '档里的值真的进来了（否则上面那个标签是空的）');
  });

  testWidgets('「恢复默认」真的清掉用户层（不是只把输入框洗白）', (tester) async {
    final service = await buildService();
    await pumpPanel(tester, service);
    await service.setConfig(id: 'en-dictation', patch: const {'gapSeconds': 12});
    expect(service.configStore.userOf('en-dictation'), isNotEmpty);

    await tester.tap(find.text('英语听写'));
    await tester.pumpAndSettle();
    final reset = find.widgetWithText(TextButton, '恢复默认');
    expect(reset, findsOneWidget);
    tester.widget<TextButton>(reset).onPressed!(); // 同"保存"那条：钉的是回调这条链，不是命中测试
    await tester.pumpAndSettle();

    expect(service.configStore.userOf('en-dictation'), isEmpty, reason: '清不掉就是"面板说了但没生效"');
    expect(service.configStore.stackFor(EnglishDictationPlugin.manifestDef).value('gapSeconds'), 5,
        reason: '清完回到插件自己声明的默认值，方案档与声明默认都不该被牵连');
  });

  testWidgets('保存后 apply 失败：面板说失败那句，绝不回「已更新」', (tester) async {
    final service = await buildService(withBoom: true);
    await pumpPanel(tester, service);

    await tester.tap(find.text('配置会炸'));
    await tester.pumpAndSettle();
    await tester.enterText(find.widgetWithText(TextField, '模式'), 'boom');
    tester.widget<FilledButton>(find.widgetWithText(FilledButton, '保存')).onPressed!();
    await tester.pumpAndSettle();

    // `setConfig` 把 apply 失败包成 `Ok(ChangeResult(application: failed))` ——
    // "受理了但没干活"如果被报成"已更新"，用户就再也不会去查第二遍。
    expect(find.textContaining('插件启动时出了点问题'), findsWidgets, reason: '失败原话要出现在回执里');
    expect(find.textContaining('已更新'), findsNothing);
    expect(find.textContaining('已保存设置'), findsNothing);
    expect(service.view().firstWhere((v) => v.id == 'boom-config').state, FiberState.failed);
  });

  testWidgets('面板里填越界的数字：回执说清范围，值不落盘', (tester) async {
    final service = await buildService();
    await pumpPanel(tester, service);

    await tester.tap(find.text('英语听写'));
    await tester.pumpAndSettle();
    await tester.enterText(find.widgetWithText(TextField, '间隔秒数'), '99');
    tester.widget<FilledButton>(find.widgetWithText(FilledButton, '保存')).onPressed!();
    await tester.pumpAndSettle();

    // 以前这个 99 会一路写进 config，运行时 `numberConfig` 照直读 → 99 秒才念下一个词。
    expect(find.textContaining('不能大于 60'), findsWidgets, reason: '范围要说出来，别让用户猜');
    expect(find.textContaining('已更新'), findsNothing);
    expect(service.configStore.userOf('en-dictation').containsKey('gapSeconds'), isFalse,
        reason: '被拒的写不许留下半个键');
  });

  testWidgets('「先试试这组值」：值真的生效、来源标成临时，但一个字没写进设置', (tester) async {
    final service = await buildService();
    await pumpPanel(tester, service);

    await tester.tap(find.text('英语听写'));
    await tester.pumpAndSettle();
    await tester.enterText(find.widgetWithText(TextField, '间隔秒数'), '11');
    tester.widget<TextButton>(find.widgetWithText(TextButton, '先试试这组值')).onPressed!();
    await tester.pumpAndSettle();

    // 试出来的值必须真的去影响运行（否则"试试"是个装饰按钮）……
    expect(service.configStore.stackFor(EnglishDictationPlugin.manifestDef).value('gapSeconds'), 11);
    // ……又必须与用户的设置分得清清楚楚（面板那句「本次会话临时」靠 session 层归 store 才成立）。
    expect(service.configStore.userOf('en-dictation'), isEmpty,
        reason: '试一下不该动用户的设置 —— 那正是这条入口存在的全部理由');
    expect(service.configStore.sessionOf('en-dictation')['gapSeconds'], 11.0,
        reason: '整组值一起试（与保存同一形态），但只在会话层');

    await tester.tap(find.text('英语听写'));
    await tester.pumpAndSettle();
    expect(find.textContaining('你的改动'), findsNothing, reason: '没写进设置就不许标成"你的改动"');

    // 「恢复默认」连着临时值一起清：只清一层却报"已恢复默认"，下次看到的还是那个试出来的值。
    tester.widget<TextButton>(find.widgetWithText(TextButton, '恢复默认')).onPressed!();
    await tester.pumpAndSettle();
    expect(service.configStore.sessionOf('en-dictation'), isEmpty, reason: '恢复默认必须把试出来的值也清掉');
    expect(service.configStore.stackFor(EnglishDictationPlugin.manifestDef).value('gapSeconds'), 5);
  });

  testWidgets('让位的条目不许还说"它占了这个位置"', (tester) async {
    final service = await buildService();
    // 记事小卡的入口出过错 → 已经让位：界面上根本没有它了。
    expect(service.slots.reportEntryError('app.input.right', 'note-chip', pluginId: 'hello-note'), isTrue);
    await pumpPanel(tester, service);

    await tester.tap(find.text('记事小卡'));
    await tester.pumpAndSettle();

    expect(find.textContaining('已让位'), findsOneWidget,
        reason: '说它还在占位置就是骗人 —— 用户会去按一个界面上不存在的东西');
    expect(find.textContaining('app.input.right ← note-chip'), findsOneWidget);
  });

  testWidgets('平台没起来时面板照常打开，说清楚并留给用户退路', (tester) async {
    await pumpPanel(tester, null);
    expect(find.textContaining('插件平台没能启动'), findsOneWidget);
    expect(find.textContaining('聊天不受影响'), findsOneWidget);
  });

  testWidgets('重新扫描不许因为插件异常而崩', (tester) async {
    final service = await buildService();
    await pumpPanel(tester, service);

    await tester.tap(find.byTooltip('重新扫描插件目录'));
    await tester.pumpAndSettle();

    expect(find.byType(PluginsScreen), findsOneWidget, reason: '面板还在，用户仍能自诊');
  });

  testWidgets('方案档区块：列出有哪些档、各开几件，点一下就切过去', (tester) async {
    final dir = Directory.systemTemp.createTempSync('panel_profiles');
    addTearDown(() => dir.deleteSync(recursive: true));
    File('${dir.path}/课堂.json').writeAsStringSync(jsonEncode({
      'enabled': ['hello-note'],
      'config': {'hello-note': {'note': '课堂模式'}},
    }));
    final host = HostProfiles(dirPath: dir.path, activeStore: MemoryActiveProfileStore());
    final service = await buildService(profiles: host);
    await pumpPanel(tester, service, profiles: host);

    expect(find.text('方案档'), findsOneWidget);
    expect(find.textContaining('不用档（逐个开关）'), findsOneWidget);
    // 预览数字必须来自内核 compose：切之前就告诉用户"这个档开 1 件"。
    expect(find.textContaining('课堂 · 1 件'), findsOneWidget, reason: '预览要说清开几件');

    await tester.tap(find.textContaining('课堂 · 1 件'));
    await tester.pumpAndSettle();

    expect(host.active, '课堂', reason: '点一下就得真的切过去');
    expect(service.composition.profile, '课堂');
    expect(service.result!.byId('en-dictation')!.status, PluginLoadStatus.disabled);
    expect(find.textContaining('已切到「课堂」'), findsOneWidget, reason: '切完要当面回执');
  });

  testWidgets('档坏了要标出来，不许让它凭空消失', (tester) async {
    final dir = Directory.systemTemp.createTempSync('panel_broken_profile');
    addTearDown(() => dir.deleteSync(recursive: true));
    File('${dir.path}/坏档.json').writeAsStringSync('{这不是 JSON');
    final host = HostProfiles(dirPath: dir.path, activeStore: MemoryActiveProfileStore());
    final service = await buildService(profiles: host);
    await pumpPanel(tester, service, profiles: host);

    expect(find.textContaining('坏档（读不动）'), findsOneWidget);

    await tester.tap(find.textContaining('坏档（读不动）'));
    await tester.pumpAndSettle();
    expect(find.byType(PluginsScreen), findsOneWidget, reason: '切到坏档也不许崩面板');
    expect(find.textContaining('插件平台没能启动'), findsNothing);
  });

  testWidgets('app 太旧的插件：说"待功能+升级 app"，不判作者"声明有问题"，也不重复刷黄条', (tester) async {
    // 这是 P6 版本协商的验收：环境没到位（app 旧）是 gated + 一句出路，
    // 不是 rejected（那是怪作者 JSON 写错），而且同一件事不许既出 gatedHint 又出"声明提醒"两个黄条。
    final caps = CapabilityRegistry()
      ..register(FakeStore(), ownerPluginId: 'app')
      ..register(FakeInteract(), ownerPluginId: 'app');
    final user = DeclarationDirSourceReader(() => {
          'future': (
            json: jsonEncode({
              // 按冻结契约的**完整形状**写（examples/en_zh_cards 同款最小集）：
              // 少字段会被判成"声明有问题"，那样测的就不是版本协商了。
              'manifestVersion': 1,
              'id': 'future',
              'name': '来自未来的插件',
              'description': '要求一个还很远的 app 版本',
              'whenToUse': '测版本协商时用',
              'source': 'user',
              'trust': 'declarative',
              'engines': {'app': '>=9.9.9'},
              'inject': ['app.store'],
              'permissions': ['storage:plugin'],
              'requiresSdk': 'v1',
              'flow': {
                'name': '存一条',
                'description': '存一条笔记',
                'whenToUse': '测试',
                'phases': [
                  {'id': 's', 'title': '存'},
                ],
                'steps': [
                  {'id': 's', 'op': 'store', 'phase': 's'},
                ],
              },
            }),
            prompt: null,
          ),
        });
    final service = PluginService(
      loader: PluginLoader(
        capabilities: caps,
        builtin: BuiltinSourceReader(),
        userSources: [user],
        appVersion: '0.2.8',
        knownCapabilityIds: kKnownCapabilityIds,
      ),
      capabilities: caps,
      slots: SlotRegistry(),
      configStore: ConfigStore(),
      enabledStore: MemoryEnabledStore({'future'}),
      trace: InMemoryTraceSink(capacity: 100),
    );
    await service.boot();
    await pumpPanel(tester, service);

    expect(service.result!.byId('future')!.status, PluginLoadStatus.gated);
    expect(find.textContaining('需要 app >=9.9.9'), findsOneWidget, reason: '列表上就要说清差什么');
    expect(find.textContaining('声明有问题'), findsNothing, reason: '不是作者的错，别画成坏声明');
    expect(find.textContaining('声明提醒'), findsNothing, reason: 'gatedHint 已经说过，不重复刷第二条黄条');

    await tester.tap(find.text('来自未来的插件'));
    await tester.pumpAndSettle();
    expect(find.textContaining('声明提醒（还能跑，但作者该改）'), findsOneWidget);
    expect(find.textContaining('engines.app'), findsWidgets, reason: '详情里要能看到那条警告原文（含 path）');
  });

  testWidgets('本机能力清单：可替换能力的两份实现都列出来，谁在用、谁被挡住一目了然', (tester) async {
    final service = await buildService();
    // 再压一份"坏了的"高优先级实现上去：这正是离线朗读没生效时的样子。
    service.capabilities.register(_BrokenSpeak(), ownerPluginId: 'app', priority: -1);
    await pumpPanel(tester, service);

    await tester.tap(find.textContaining('本机能力（'));
    await tester.pumpAndSettle();

    expect(find.text('app.speak'), findsOneWidget);
    expect(find.textContaining('priority -1：离线那份坏了'), findsOneWidget,
        reason: '不可用的那份必须带着自己的原因出现，否则"为什么没走离线"永远是悬案');
    expect(find.textContaining('priority 0'), findsWidgets, reason: '被遮蔽的那份也要列出来');

    await tester.tap(find.byTooltip('试一下').first);
    await tester.pumpAndSettle();
    expect(find.textContaining('试过了'), findsOneWidget, reason: 'probe 的结果要当面回执');
    expect(find.byType(PluginsScreen), findsOneWidget);
  });
}

/// 一个"坏了"的 `app.speak`：只用来验证面板怎么解释不可用与被遮蔽。
class _BrokenSpeak with CapabilityBase implements Speak {
  @override
  final ServiceKey<Speak> key = ServiceKeys.speak;

  @override
  bool get available => false;

  @override
  String? get unavailableReason => '离线那份坏了：模型没就位';

  @override
  Stream<SpeakProgress> speak(SpeakRequest request, PluginCancelToken cancelToken) async* {}

  @override
  Future<void> stop() async {}

  @override
  Future<bool> prewarm(List<String> texts, String voice) async => false;
}
