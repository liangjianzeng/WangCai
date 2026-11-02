// 启用集与"首次播种账本"的落盘行为（宿主侧）。
//
// 这两份东西是**用户看到的开关状态**的唯一依据，所以必须钉住四件事：
// ① 写下去的下次开机读得回来（否则用户开过的插件重启就"消失"）；
// ② `plugin.seen` 让 `enabledByDefault` 只在**第一次见到**时生效（否则用户关掉的开关会被翻回来）；
// ③ 两个写者同住一个文件时**不许互相洗掉对方的键**（`plugin.enabled` / `plugin.seen` 各写各的）；
// ④ 文件坏了要能自愈（当空的用），绝不把异常抛到 UI。
import 'dart:convert';
import 'dart:io';

import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:tongyi_lite/plugins/host/plugin_files.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late Directory tmp;
  late JsonMapFile file;

  setUp(() {
    tmp = Directory.systemTemp.createTempSync('plugin_files');
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(const MethodChannel('plugins.flutter.io/path_provider'), (call) async {
      return tmp.path;
    });
    file = JsonMapFile('plugin_enabled.json');
  });

  tearDown(() async {
    await file.flush(); // 同步 API 的写是 fire-and-forget，等它落盘再删目录，否则测的是运气
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(const MethodChannel('plugins.flutter.io/path_provider'), null);
    if (tmp.existsSync()) tmp.deleteSync(recursive: true);
  });

  group('启用集（EnabledStore）', () {
    test('写下去的下次开机读得回来', () async {
      final store = FileEnabledStore(file);
      await store.warm();
      store.write({'zh-dictation', 'hello'});
      await file.flush();

      final reboot = FileEnabledStore(JsonMapFile('plugin_enabled.json')); // 新实例 = 新进程
      await reboot.warm();
      expect(reboot.read(), {'zh-dictation', 'hello'}, reason: '开关状态丢了，用户就是"我明明开过了"');
    });

    test('文件不存在时是空集（全部未启用），不是崩', () async {
      final store = FileEnabledStore(JsonMapFile('nope.json'));
      await store.warm();
      expect(store.read(), isEmpty);
    });
  });

  group('首次播种账本（FirstRunSeeder）', () {
    test('第一次见到的算 fresh 并落盘；重启后同一批不再 fresh', () async {
      final seeder = FileFirstRunSeeder(file);
      await seeder.warm();
      expect(seeder.firstTimeSeen(['hello', 'zh-dictation']), {'hello', 'zh-dictation'});
      await file.flush();

      final reboot = FileFirstRunSeeder(JsonMapFile('plugin_enabled.json'));
      await reboot.warm();
      expect(reboot.firstTimeSeen(['hello', 'zh-dictation']), isEmpty,
          reason: '已经见过的再算 fresh，用户关掉的插件就会被悄悄翻回"开"');
    });

    test('后来新装的插件单独算 fresh（老插件不受影响）', () async {
      final seeder = FileFirstRunSeeder(file);
      await seeder.warm();
      seeder.firstTimeSeen(['hello']);
      await file.flush();

      final again = FileFirstRunSeeder(JsonMapFile('plugin_enabled.json'));
      await again.warm();
      expect(again.firstTimeSeen(['hello', 'poem']), {'poem'});
    });

    test('账本与启用集同住一个文件（不多一个真相源），两份互不覆盖', () async {
      final enabled = FileEnabledStore(file);
      final seeder = FileFirstRunSeeder(file);
      await enabled.warm();
      await seeder.warm();
      // 两个写者几乎同时下手 —— 以前这里会互相把对方的键洗掉（各持一份旧快照）。
      enabled.write({'hello'});
      seeder.firstTimeSeen(['hello', 'poem']);
      await file.flush();

      final raw = jsonDecode(File('${tmp.path}/plugin_enabled.json').readAsStringSync()) as Map<String, Object?>;
      expect(raw['plugin.enabled'], ['hello'], reason: '写账本不许顺手把启用集洗掉');
      expect((raw['plugin.seen'] as List).toSet(), {'hello', 'poem'}, reason: '反过来也不行');
    });

    test('账本被写坏（不是数组）时当空的用，不抛', () async {
      File('${tmp.path}/plugin_enabled.json').writeAsStringSync('{"plugin.seen": "hello"}');
      final seeder = FileFirstRunSeeder(file);
      await seeder.warm();
      expect(seeder.firstTimeSeen(['poem']), {'poem'}, reason: '坏文件自愈：宁可重算一次 fresh，也不许把平台带崩');
    });
  });
}
