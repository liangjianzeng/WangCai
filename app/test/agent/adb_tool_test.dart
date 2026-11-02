/// `adb` 工具层单测：门禁、命令黑名单、输入转义、目标机选择，
/// 外加一条"打到假 adbd 的端到端调用"。
///
/// 门禁为什么全在 execute 体内：本项目的工具级预审批早就是死代码
/// （docs/开发者模式可用性评估 P0-1/P0-2/P0-13/P0-14），只有 execute 里的判断算数。
library;

import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:tongyi_lite/agent/adb/adb_targets.dart';
import 'package:tongyi_lite/agent/tool_definition.dart';
import 'package:tongyi_lite/agent/adb/adb_tool.dart';

import 'fake_adbd.dart';

AdbTarget _t(String id, String host, {int port = 5555, bool enabled = true, String? name}) =>
    AdbTarget(id: id, name: name ?? id, host: host, port: port, enabled: enabled);

ToolDefinition _tool({
  List<AdbTarget> targets = const [],
  bool enabled = true,
  AdbSecretStore? keyStore,
}) =>
    createAdbTool(targets: targets, adbEnabled: enabled, keyStore: keyStore);

void main() {
  group('动作枚举', () {
    test('wire 名用 snake_case，且与枚举一一对应', () {
      expect(kAdbActionNames[AdbAction.longPress], 'long_press');
      expect(kAdbActionNames[AdbAction.dumpsys], 'dumpsys');
      expect(kAdbActionNames.values.toSet().length, kAdbActionNames.length);
      expect(adbActionOf('long_press'), AdbAction.longPress);
      expect(adbActionOf('longPress'), isNull,
          reason: '只认 wire 名；模型写驼峰时得到的是"未知动作 + 可选清单"');
      expect(adbActionOf('nope'), isNull);
    });

    test('schema 只必填 action，其余按动作自选', () {
      final tool = _tool();
      expect(tool.name, 'adb');
      expect(tool.parameters['required'], contains('action'));
      expect((tool.parameters['properties'] as Map).containsKey('command'), isTrue);
    });

    test('声明为不可并发（一条连接同一时刻只干一件事）', () {
      expect(_tool().isConcurrencySafe!({'action': 'shell'}), isFalse);
    });
  });

  group('目标机解析', () {
    test('serial 形态：省略端口=5555，脏输入返回 null', () {
      expect(AdbTarget.parseSerial('100.1.2.3'), (host: '100.1.2.3', port: 5555));
      expect(AdbTarget.parseSerial('100.1.2.3:5556'), (host: '100.1.2.3', port: 5556));
      // 用户从聊天里粘贴常带空格 —— 容忍，别逼人重打。
      expect(AdbTarget.parseSerial(' 100.1.2.3 : 5556 '), (host: '100.1.2.3', port: 5556));
      expect(AdbTarget.parseSerial('100.1.2.3:0'), isNull);
      expect(AdbTarget.parseSerial('100.1.2.3:99999'), isNull);
      // 主机名也要能填（局域网/mDNS），只有空串才是真非法。
      expect(AdbTarget.parseSerial('abc'), (host: 'abc', port: 5555));
      expect(AdbTarget.parseSerial(''), isNull);
    });

    test('配置解析：跳过没主机/重复的，缺 id 自动补', () {
      final list = parseAdbTargets([
        {'name': '小米13', 'host': '100.1.1.1', 'port': 5555},
        {'name': '坏', 'host': ''},
        {'host': '100.1.1.1', 'port': 5555}, // 重复 → 只留一条
        {'host': '100.1.1.2'},
      ]);
      expect(list.map((e) => e.host).toList(), ['100.1.1.1', '100.1.1.2']);
      expect(list.first.name, '小米13');
      expect(list.last.id, isNotEmpty, reason: '手搓 JSON 没 id 也要能编辑/删除');
      expect(parseAdbTargets(null), isEmpty);
      expect(parseAdbTargets('不是列表'), isEmpty);
    });

    test('toJson/fromJson 往返保住开关与端口', () {
      final t = _t('a', '100.1.1.1', port: 37351, enabled: false, name: 'K90');
      final back = AdbTarget.fromJson(jsonDecode(jsonEncode(t.toJson())));
      expect(back, t);
      expect(back.serial, '100.1.1.1:37351');
    });
  });

  group('门禁（全部在 execute 体内）', () {
    test('总开关关着 → 直接拒，并指路设置页', () async {
      final r = await _tool(enabled: false, targets: [_t('a', '100.1.1.1')])
          .execute({'action': 'devices'});
      expect(r.isError, isTrue);
      expect(r.content, contains('远程控制（ADB）'));
    });

    test('没配目标机 → 拒，并说明要加白名单', () async {
      final r = await _tool().execute({'action': 'devices'});
      expect(r.isError, isTrue);
      expect(r.content, contains('目标机'));
    });

    test('未知动作 → 拒绝并给出可选动作清单', () async {
      final r = await _tool(targets: [_t('a', '100.1.1.1')])
          .execute({'action': 'reboot_bootloader'});
      expect(r.isError, isTrue);
      expect(r.content, contains('tap'));
    });

    test('目标机不在白名单 → 拒绝（绝不接受模型现编 ip）', () async {
      final r = await _tool(targets: [_t('a', '100.1.1.1')]).execute({
        'action': 'shell',
        'command': 'getprop',
        'target': '10.0.0.9:5555',
      });
      expect(r.isError, isTrue);
      expect(r.content, contains('100.1.1.1'), reason: '错误里要回显可用目标，否则模型瞎试');
    });

    test('全部目标机都被禁用 → 拒绝', () async {
      final r = await _tool(targets: [_t('a', '100.1.1.1', enabled: false)])
          .execute({'action': 'devices'});
      expect(r.isError, isTrue);
    });
  });

  group('命令黑名单（护住模型缓存与设备）', () {
    Future<String?> deny(String cmd) async {
      final r = await _tool(targets: [_t('a', '100.1.1.1')])
          .execute({'action': 'shell', 'command': cmd});
      return r.isError ? r.content : null;
    }

    test('uninstall / pm clear 一律拒（会清掉已下载模型缓存）', () async {
      expect(await deny('pm uninstall com.xxx'), contains('模型缓存'));
      expect(await deny('adb uninstall com.xxx'), contains('模型缓存'));
      expect(await deny('pm clear com.xxx'), contains('pm clear'),
          // 行首裸命令必须拦住：早先正则写成 \npm…（要求前置换行）时这条会漏。
          reason: '文案可以不同，但必须明确拒绝并说明等价于清数据');
    });

    test('reboot / bootloader / 关机 一律拒', () async {
      expect(await deny('reboot'), isNotNull);
      expect(await deny('reboot bootloader'), isNotNull);
      expect(await deny('svc power shutdown'), isNotNull);
    });

    test('系统目录 rm -rf 与 dd/mkfs 一律拒', () async {
      expect(await deny('rm -rf /system/app'), isNotNull);
      expect(await deny('rm -rf /data/data'), isNotNull);
      expect(await deny('dd if=/dev/zero of=/dev/block/sda'), isNotNull);
      expect(await deny('mkfs.ext4 /data/local/tmp/x'), isNotNull);
    });

    test('普通命令不许被误伤', () async {
      // 这些会走到"真连接"，本机没有目标机 → 报的是连接类错误，而不是黑名单。
      final e = await deny('dumpsys meminfo com.xxx');
      expect(e, isNotNull);
      expect(e, isNot(contains('不允许')));
    });
  });

  group('文本注入转义', () {
    test('空格转 %s，元字符转义', () {
      expect(adbInputTextArg('hello world'), 'hello%sworld');
      expect(adbInputTextArg(r'a;b'), contains(r'\;'));
      expect(adbInputTextArg('a\$b'), contains(r'\$'));
    });

    test('非 ASCII 直接拒并说明要装 ADBKeyboard', () {
      expect(() => adbInputTextArg('中文'), throwsA(isA<FormatException>()));
      try {
        adbInputTextArg('中文');
      } on FormatException catch (e) {
        expect(e.message, contains('ADBKeyboard'));
      }
    });
  });

  test('端到端：工具打到假 adbd，shell 动作真跑通', () async {
    final adbd = FakeAdbd(
      reply: FakeReplyStub(map: {
        'uptime': FakeReply(stdout: 'up 1 day\n'),
      }),
    );
    await adbd.start();
    addTearDown(adbd.stop);
    final tool = _tool(
      targets: [_t('a', '127.0.0.1', port: adbd.port, name: '假机')],
      keyStore: InMemoryAdbSecretStore(),
    );
    final r = await tool.execute({'action': 'shell', 'command': 'uptime'});
    expect(r.isError, isFalse, reason: r.content);
    expect(r.content, contains('up 1 day'));
    expect(adbd.lastShellCmd, 'uptime');
  });
}
