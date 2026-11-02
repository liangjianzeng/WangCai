/// `adb` 工具 —— 让智能体直接控制**另一台**安卓机（app 内纯 Dart ADB 客户端）。
///
/// 一个工具槽 + `action` 枚举（用户定案）：设备发现 / shell / GUI 注入 / 截图 /
/// push-pull / 安装 / 日志性能，全在这一个动作表里，不给模型铺 15 个工具名。
///
/// 安全边界（用户定案：**只按设置开关，不做逐次审批**）：
/// - 开关关闭 → 直接拒绝，连目标都不解析；
/// - **只能连设置页里配好的 [AdbTarget]**，模型无权指定任意 host:port
///   （否则一次提示词注入就能拿手机当跳板扫内网）；
/// - 命令黑名单堵掉 `uninstall` / `reboot` / `pm clear` / 根目录 `rm -rf`：
///   卸载与清数据会**连带清掉本 app 已下载的端侧模型缓存**（项目铁律）；
/// - 门禁全部写在 execute 体内（工具级预审批在本项目是死代码，见
///   docs/开发者模式可用性全面评估 P0-1/P0-2/P0-13/P0-14）。
library;

import 'dart:convert';
import 'dart:io';

import 'package:path_provider/path_provider.dart';

import '../tool_definition.dart';
import 'adb_client.dart';
import 'adb_connection.dart';
import 'adb_targets.dart';

/// 动作表（对外就是 `action` 参数的 enum，模型看到的取值与此完全一致）。
enum AdbAction {
  devices,
  shell,
  tap,
  longPress,
  swipe,
  key,
  text,
  screenshot,
  push,
  pull,
  ls,
  stat,
  install,
  logcat,
  dumpsys,
  perf,
}

const Map<AdbAction, String> kAdbActionNames = {
  AdbAction.devices: 'devices',
  AdbAction.shell: 'shell',
  AdbAction.tap: 'tap',
  AdbAction.longPress: 'long_press',
  AdbAction.swipe: 'swipe',
  AdbAction.key: 'key',
  AdbAction.text: 'text',
  AdbAction.screenshot: 'screenshot',
  AdbAction.push: 'push',
  AdbAction.pull: 'pull',
  AdbAction.ls: 'ls',
  AdbAction.stat: 'stat',
  AdbAction.install: 'install',
  AdbAction.logcat: 'logcat',
  AdbAction.dumpsys: 'dumpsys',
  AdbAction.perf: 'perf',
};

AdbAction? adbActionOf(String? name) {
  for (final e in kAdbActionNames.entries) {
    if (e.value == name) return e.key;
  }
  return null;
}

/// 回填模型的输出上限（字符）。logcat/dumpsys 能轻松吐几 MB，必须截。
const int kAdbOutputLimit = 6000;

/// 危险命令黑名单（只作用于 shell / dumpsys 的自由文本部分）。
final List<(RegExp, String)> _kAdbDenyRules = [
  (
    RegExp(r'\b(uninstall|pm\s+uninstall)\b', caseSensitive: false),
    '禁止卸载：会连带清空应用数据与本 app 已下载的模型缓存（项目铁律）。'
        '更新请用 action=install（内部固定 install -r -t 覆盖安装）'
  ),
  (
    RegExp(r'\b(reboot|bootloader|fastboot|shutdown)\b', caseSensitive: false),
    '禁止重启/进 bootloader：目标机会掉线且需要人工恢复'
  ),
  (
    // 注意是 \\b 不是 \\n：早先写成 '\\npm\\s+clear' 要求前面有**字面换行**，
    // 于是模型最爱发的行首 `pm clear 包名` 一条都不拦 —— 正是会清掉端侧模型缓存的那条。
    RegExp(r'\bpm\s+clear\b', caseSensitive: false),
    '禁止 pm clear：等价于清应用数据'
  ),
  (
    RegExp(r'\brm\s+(-[a-zA-Z]*[rf][a-zA-Z]*\s+)+/(data|system|storage|sdcard|mnt|bootstrap)\b',
        caseSensitive: false),
    '禁止对系统/应用目录做递归删除'
  ),
  (
    RegExp(r'\b(mkfs|dd\s+if=|format)\b', caseSensitive: false),
    '禁止裸设备写入/格式化'
  ),
];

/// 造 `adb` 工具。
///
/// [targets] / [adbEnabled] 由接入层（chat_provider 建注册表时）从设置快照传入 ——
/// 与 `createSshExecTool(sshConfigs:)` 同一套回合级快照模式。
ToolDefinition createAdbTool({
  List<AdbTarget> targets = const [],
  AdbSecretStore? keyStore,
  bool adbEnabled = false,
}) {
  return ToolDefinition(
    // 独占执行：GUI 注入与安装都必须串行，两条并发命令打到同一台手机只会互相踩。
    isConcurrencySafe: (_) => false,
    name: 'adb',
    description:
        '通过 Wi-Fi ADB 直接控制另一台已配对的安卓手机（app 内置 ADB 客户端，无需电脑）。'
        '用 action 选动作：devices（列目标机与型号）、shell（远程 shell）、'
        'tap/long_press/swipe/key/text（界面注入）、screenshot（截屏存 PNG）、'
        'push/pull（传文件）、ls/stat（看目录）、install（覆盖安装 APK）、'
        'logcat（日志）、dumpsys（系统服务）、perf（帧率/内存/CPU）。'
        'target 填设备名或 ip:port，省略则用第一个启用的目标机；'
        '一次调用只做一件事，需要多步请连续调用（连接是即用即建，无需先 connect）。'
        '示例：action=shell,command="getprop ro.build.version.release"；'
        'action=tap,x=540,y=1200；action=screenshot。',
    parameters: const {
      'type': 'object',
      'properties': {
        'action': {
          'type': 'string',
          'enum': [
            'devices', 'shell', 'tap', 'long_press', 'swipe', 'key', 'text',
            'screenshot', 'push', 'pull', 'ls', 'stat', 'install', 'logcat',
            'dumpsys', 'perf'
          ],
          'description': '要做的动作',
        },
        'target': {
          'type': 'string',
          'description': '目标机名或 ip:port；省略 = 第一个启用的目标机',
        },
        'command': {
          'type': 'string',
          'description': 'shell 的动作内容；dumpsys 时填 "service 参数"（如 "meminfo com.xxx"）',
        },
        'x': {'type': 'integer', 'description': '横坐标（像素）'},
        'y': {'type': 'integer', 'description': '纵坐标（像素）'},
        'x2': {'type': 'integer', 'description': 'swipe 终点横坐标'},
        'y2': {'type': 'integer', 'description': 'swipe 终点纵坐标'},
        'duration_ms': {
          'type': 'integer',
          'description': 'swipe/长按 的时长（毫秒，默认 300）'
        },
        'key': {
          'type': 'string',
          'description': '按键名或编号，如 BACK / KEYCODE_HOME / 24（音量上=24）'
        },
        'text': {'type': 'string', 'description': 'text 动作要输入的文本（ASCII）'},
        'local_path': {
          'type': 'string',
          'description': '本机（app 可见）文件路径：push 的源 / pull、install 的目标'
        },
        'remote_path': {
          'type': 'string',
          'description': '目标机绝对路径，如 /data/local/tmp/a.apk'
        },
        'package': {
          'type': 'string',
          'description': 'perf 动作要观测的包名（省略则只给整机概览）'
        },
        'filter': {
          'type': 'string',
          'description': 'logcat 过滤，如 "ActivityManager:I *:S"'
        },
        'lines': {
          'type': 'integer',
          'description': 'logcat 取最后多少行（默认 200，上限 2000）'
        },
      },
      'required': ['action'],
    },
    execute: (args) async {
      // ---- 门禁（写在 execute 体内：工具级预审批在本项目不生效）----
      if (!adbEnabled) {
        return ToolResult.error(
            'ADB 远程控制未开启：请用户在「设置 → 开发者 → 远程控制（ADB）」里打开开关并添加目标手机。');
      }
      final enabled = targets.where((t) => t.enabled).toList();
      if (enabled.isEmpty) {
        return ToolResult.error('还没有可控制的手机：请在「设置 → 开发者 → 远程控制（ADB）」'
            '里添加目标机（ip:5555），并确认它已 `adb tcpip 5555` 且弹框允许了 USB 调试。');
      }
      final action = adbActionOf(args['action'] as String?);
      if (action == null) {
        return ToolResult.error(
            '未知的 action：${args['action']}。可选：${kAdbActionNames.values.join('/')}');
      }
      final target = _pickTarget(enabled, args['target'] as String?);
      if (target == null) {
        return ToolResult.error('找不到目标机「${args['target']}」。'
            '已配置的可用目标：${enabled.map((t) => "${t.name}(${t.serial})").join('、')}');
      }
      final cmd = (args['command'] as String?)?.trim() ?? '';
      final deny = _denyReason(action, cmd);
      if (deny != null) return ToolResult.error(deny);

      AdbClient? client;
      try {
        final store = keyStore ?? FlutterAdbSecretStore();
        final key = await loadOrCreateAdbKey(store);
        client = await AdbClient.connect(
            host: target.host, port: target.port, key: key);
        return await _run(client, target, action, args, cmd);
      } on AdbTransportException catch (e) {
        return ToolResult.error('${e.message}（目标机 ${target.serial}）');
      } on FormatException catch (e) {
        return ToolResult.error('设备授权密钥不可用：${e.message}。'
            '请在设置页重新生成密钥，并在目标机上重新点「允许 USB 调试」。');
      } catch (e) {
        return ToolResult.error('ADB 操作失败：$e');
      } finally {
        await client?.close();
      }
    },
  );
}

// ------------------------------------------------------------------ 动作实现

Future<ToolResult> _run(AdbClient client, AdbTarget target, AdbAction action,
    Map<String, dynamic> args, String cmd) async {
  switch (action) {
    case AdbAction.devices:
      final id = client.identity();
      final buf = StringBuffer('目标 ${target.serial}  在线\n');
      buf.write('型号=${id.model}  代号=${id.device}  产品=${id.productName}\n');
      buf.write('系统=${id.properties['ro.build.version.release']} '
          'SDK=${id.properties['ro.build.version.sdk']} '
          'ABI=${id.properties['ro.product.cpu.abi']}\n');
      buf.write('特性=${id.features.isEmpty ? "(无)" : id.features.join(",")}');
      return ToolResult(content: buf.toString());

    case AdbAction.shell:
      if (cmd.isEmpty) return ToolResult.error('shell 需要 command 参数');
      return _result(cmd, await client.shell(cmd), target);

    case AdbAction.tap:
      final xy = _xy(args);
      if (xy == null) return ToolResult.error('tap 需要整数坐标 x、y');
      return _input(client, 'input tap ${xy.$1} ${xy.$2}', '点击 (${xy.$1},${xy.$2})', target);

    case AdbAction.longPress:
      final xy = _xy(args);
      if (xy == null) return ToolResult.error('long_press 需要整数坐标 x、y');
      final dur = _int(args['duration_ms'], 300).clamp(50, 10000);
      return _input(client,
          'input swipe ${xy.$1} ${xy.$2} ${xy.$1} ${xy.$2} $dur',
          '长按 (${xy.$1},${xy.$2}) ${dur}ms',
          target);

    case AdbAction.swipe:
      final x1 = _intOrNull(args['x']),
          y1 = _intOrNull(args['y']),
          x2 = _intOrNull(args['x2']),
          y2 = _intOrNull(args['y2']);
      if (x1 == null || y1 == null || x2 == null || y2 == null) {
        return ToolResult.error('swipe 需要 x、y、x2、y2 四个整数坐标');
      }
      final dur = _int(args['duration_ms'], 300).clamp(50, 10000);
      return _input(
          client,
          'input swipe $x1 $y1 $x2 $y2 $dur',
          '滑动 ($x1,$y1)→($x2,$y2) ${dur}ms',
          target);

    case AdbAction.key:
      final k = ((args['key'] as String?) ?? '').trim().toUpperCase();
      if (k.isEmpty) return ToolResult.error('key 需要按键名或编号，如 BACK / 24');
      if (!RegExp(r'^[A-Z0-9_]+$').hasMatch(k)) {
        return ToolResult.error('按键名只能含字母/数字/下划线（收到「$k」）');
      }
      final code = RegExp(r'^\d+$').hasMatch(k) ? k : 'KEYCODE_$k';
      return _input(client, 'input keyevent $code', '按键 $code', target);

    case AdbAction.text:
      final t = (args['text'] as String?) ?? '';
      if (t.isEmpty) return ToolResult.error('text 需要 text 参数');
      final esc = adbInputTextArg(t);
      return _input(client, 'input text $esc', '输入「${_clip(t, 40)}」', target);

    case AdbAction.screenshot:
      final png = await client.screenshot();
      final dir = await _adbDir('screenshots');
      final file = File('${dir.path}/screen_${DateTime.now().millisecondsSinceEpoch}.png');
      await file.writeAsBytes(png, flush: true);
      final ok = png.length > 8 &&
          png[0] == 0x89 &&
          png[1] == 0x50 &&
          png[2] == 0x4e &&
          png[3] == 0x47;
      return ToolResult(content:
          '${ok ? '截图已保存' : '⚠️ 数据不像 PNG（可能息屏/被安全策略拦截）'}：${file.path} '
          '（${png.length} 字节）。可用 read_file/图像查看该文件。');

    case AdbAction.push:
      final local = (args['local_path'] as String?)?.trim() ?? '';
      final remote = (args['remote_path'] as String?)?.trim() ?? '';
      if (local.isEmpty || remote.isEmpty) {
        return ToolResult.error('push 需要 local_path 与 remote_path');
      }
      final f = File(local);
      if (!await f.exists()) return ToolResult.error('本机文件不存在：$local');
      final data = await f.readAsBytes();
      if (data.length > 512 * 1024 * 1024) {
        return ToolResult.error('文件过大（>${data.length} 字节），请用其他方式分发');
      }
      await client.push(data, remote);
      return ToolResult(content: '已推送 ${data.length} 字节 → ${target.serial}:$remote');

    case AdbAction.pull:
      final remote = (args['remote_path'] as String?)?.trim() ?? '';
      if (remote.isEmpty) return ToolResult.error('pull 需要 remote_path');
      final data = await client.pull(remote);
      final dir = await _adbDir('pull');
      final name = remote.split('/').where((s) => s.isNotEmpty).isEmpty
          ? 'pulled.bin'
          : remote.split('/').last;
      final file = File('${dir.path}/$name');
      await file.writeAsBytes(data, flush: true);
      return ToolResult(
          content: '已拉取 ${data.length} 字节 → ${file.path}（目标机 $remote）');

    case AdbAction.ls:
      final remote = (args['remote_path'] as String?)?.trim() ?? '';
      if (remote.isEmpty) return ToolResult.error('ls 需要 remote_path');
      final items = await client.ls(remote);
      if (items.isEmpty) return ToolResult(content: '$remote：空目录');
      final lines = items
          .take(200)
          .map((e) =>
              '${e.isDirectory ? "d" : e.isSymlink ? "l" : "-"} ${e.mode.toRadixString(8).padLeft(6, '0')} '
              '${e.size} ${_fmtTime(e.mtime)} ${e.path.split('/').last}')
          .join('\n');
      return ToolResult(content:
          '$remote 共 ${items.length} 项${items.length > 200 ? '（仅显示前 200）' : ''}\n$lines');

    case AdbAction.stat:
      final remote = (args['remote_path'] as String?)?.trim() ?? '';
      if (remote.isEmpty) return ToolResult.error('stat 需要 remote_path');
      final st = await client.stat(remote);
      return ToolResult(content: st == null
          ? '$remote：不存在'
          : '${st.path}  mode=0o${st.mode.toRadixString(8)} size=${st.size} '
              'mtime=${_fmtTime(st.mtime)} ${st.isDirectory ? "(目录)" : ""}');

    case AdbAction.install:
      final local = (args['local_path'] as String?)?.trim() ?? '';
      if (local.isEmpty) return ToolResult.error('install 需要 local_path（APK 路径）');
      final f = File(local);
      if (!await f.exists()) return ToolResult.error('本机 APK 不存在：$local');
      if (!local.toLowerCase().endsWith('.apk')) {
        return ToolResult.error('install 只接受 .apk 文件：$local');
      }
      final r = await client.installApk(await f.readAsBytes());
      final out = _clip(r.merged, 1200);
      return r.ok
          ? ToolResult(content: '已覆盖安装 ${_basename(local)} → ${target.serial}\n$out')
          : ToolResult.error('安装失败（exit=${r.exitCode}）：$out');

    case AdbAction.logcat:
      final lines = _int(args['lines'], 200).clamp(1, 2000);
      final text = await client.logcat(
          filter: (args['filter'] as String?)?.trim().isEmpty == true
              ? null
              : (args['filter'] as String?)?.trim(),
          lines: lines);
      return ToolResult(content: _clip(text, kAdbOutputLimit));

    case AdbAction.dumpsys:
      if (cmd.isEmpty) return ToolResult.error('dumpsys 需要 command，如 "meminfo com.xxx"');
      return _result('dumpsys $cmd', await client.shell('dumpsys $cmd'), target);

    case AdbAction.perf:
      final pkg = (args['package'] as String?)?.trim() ?? '';
      if (pkg.isNotEmpty && !RegExp(r'^[A-Za-z0-9._]+$').hasMatch(pkg)) {
        return ToolResult.error('包名格式不对：$pkg');
      }
      final parts = <String>[];
      if (pkg.isNotEmpty) {
        final gfx = await client.shell('dumpsys gfxinfo $pkg',
            timeout: const Duration(seconds: 25));
        parts.add('=== gfxinfo $pkg ===\n${_pickLines(gfx.stdout, [
              'Total frames rendered',
              'Janky frames',
              '50th',
              '90th',
              '99th',
              'HISTOGRAM',
            ])}');
        final mem = await client.shell('dumpsys meminfo $pkg',
            timeout: const Duration(seconds: 25));
        parts.add('=== meminfo $pkg ===\n${_pickLines(mem.stdout, [
              'TOTAL',
              'Java Heap',
              'Native Heap',
              'Graphics',
              'App Summary',
            ])}');
      }
      final top = await client.shell(
          "top -b -n 1 -m 8 -o %CPU,%MEM,NAME 2>/dev/null | head -20",
          timeout: const Duration(seconds: 25));
      parts.add('=== top ===\n${_clip(top.stdout, 1500)}');
      return ToolResult(content: _clip(parts.join('\n'), kAdbOutputLimit));
  }
}

// ------------------------------------------------------------------ 小工具

ToolResult _result(String cmd, AdbShellResult r, AdbTarget target) {
  final body = _clip(r.merged, kAdbOutputLimit);
  final hint = _injectHint(r);
  if (r.ok) {
    return ToolResult(content: body.isEmpty ? '✓ 已执行（无输出）：$cmd' : body);
  }
  return ToolResult.error(
      'exit=${r.exitCode}：$cmd${body.isEmpty ? '' : '\n$body'}$hint');
}

/// GUI 注入在 MIUI/ColorOS 上最常见的失败：缺「USB 调试（安全设置）」。
/// 模型自己从 `SecurityException: INJECT_EVENTS` 推不出该点哪个开关，直接把话给它。
String? _injectHint(AdbShellResult r) {
  final all = '${r.stdout}${r.stderr}';
  if (all.contains('INJECT_EVENTS') ||
      (all.contains('SecurityException') && all.contains('input'))) {
    return '\n提示：目标机需要在「开发者选项 → USB 调试（安全设置）」里授权（小米/红米等 '
        'MIUI 机型要求登录小米账号并插 SIM 卡才能打开该开关），否则 input 注入一律被拒。';
  }
  if (all.contains('chmod') && all.contains('Permission denied')) {
    return '\n提示：目标机 adbd 是 shell 身份，只能写 /data/local/tmp 等世界可写目录。';
  }
  return null;
}

Future<ToolResult> _input(
    AdbClient client, String command, String what, AdbTarget target) async {
  final r = await client.shell(command);
  if (r.ok) return ToolResult(content: '✓ $what @ ${target.serial}');
  final hint = _injectHint(r) ?? '';
  return ToolResult.error(
      '$what 失败（exit=${r.exitCode}）：${_clip(r.merged, 600)}$hint');
}

/// `input text` 的参数拼装：空格转 `%s`，shell 元字符逐个反斜杠转义。
///
/// 非 ASCII 直接拒绝并说清原因 —— Android 的 `input text` 走 KeyCharacterMap，
/// 中文必须靠 ADBKeyboard 之类的输入法（v1 未实现），静默丢字比报错更糟。
String adbInputTextArg(String text) {
  if (text.contains('\n') || text.contains('\r')) {
    throw const FormatException(
        'text 不含换行：换行请用 action=key,key=ENTER 单独发一次');
  }
  final sb = StringBuffer();
  for (final r in text.runes) {
    if (r == 0x20) {
      sb.write('%s');
      continue;
    }
    if (r < 0x21 || r > 0x7e) {
      throw FormatException(
          'text 只支持可打印 ASCII（收到 U+${r.toRadixString(16)}）。'
          '中文需目标机装 ADBKeyboard 输入法，本工具暂不支持；'
          '可改用 action=shell 配合 `am broadcast` 或剪贴板方案');
    }
    final ch = String.fromCharCode(r);
    sb.write(RegExp(r'^[A-Za-z0-9._/@:+-]$').hasMatch(ch) ? ch : '\\$ch');
  }
  return sb.toString();
}

AdbTarget? _pickTarget(List<AdbTarget> enabled, String? want) {
  if (want == null || want.trim().isEmpty) return enabled.first;
  final w = want.trim();
  for (final t in enabled) {
    if (t.serial == w || t.name == w || t.id == w) return t;
  }
  // 允许写成 "10.0.0.5"（没带端口）
  final parsed = AdbTarget.parseSerial(w);
  if (parsed != null) {
    for (final t in enabled) {
      if (t.host == parsed.host && (t.port == parsed.port || w == t.host)) return t;
    }
  }
  return null;
}

String? _denyReason(AdbAction action, String cmd) {
  if (cmd.isEmpty) return null;
  if (action != AdbAction.shell && action != AdbAction.dumpsys) return null;
  for (final rule in _kAdbDenyRules) {
    if (rule.$1.hasMatch(cmd)) return '该命令被安全策略拒绝：${rule.$2}';
  }
  return null;
}

(int, int)? _xy(Map<String, dynamic> args) {
  final x = _intOrNull(args['x']), y = _intOrNull(args['y']);
  if (x == null || y == null) return null;
  return (x, y);
}

int _int(dynamic v, int dflt) => _intOrNull(v) ?? dflt;

int? _intOrNull(dynamic v) {
  if (v is int) return v;
  if (v is double) return v.toInt();
  if (v is String) return int.tryParse(v.trim());
  return null;
}

String _clip(String s, int max) {
  final t = s.trim();
  if (t.length <= max) return t;
  return '${t.substring(0, max)}\n…（已截断，共 ${t.length} 字符）';
}

String _clipMid(String s, int head, int tail) =>
    s.length <= head + tail + 8 ? s : '${s.substring(0, head)}\n…\n${s.substring(s.length - tail)}';

String _basename(String p) => p.split('/').where((s) => s.isNotEmpty).isEmpty
    ? p
    : p.split('/').last;

String _fmtTime(int epochSec) {
  if (epochSec <= 0) return '-';
  final dt = DateTime.fromMillisecondsSinceEpoch(epochSec * 1000);
  String two(int v) => v.toString().padLeft(2, '0');
  return '${dt.month}-${dt.day} ${two(dt.hour)}:${two(dt.minute)}';
}

/// 从大段 dumpsys 输出里挑出关心的行（整段回填会瞬间吃满上下文）。
String _pickLines(String text, List<String> needles) {
  final lines = const LineSplitter().convert(text);
  final hits = <String>[];
  for (final l in lines) {
    if (needles.any((n) => l.contains(n))) hits.add(l.trim());
    if (hits.length >= 40) break;
  }
  return hits.isEmpty ? _clipMid(text, 600, 300) : hits.join('\n');
}

Future<Directory> _adbDir(String sub) async {
  final docs = await getApplicationDocumentsDirectory();
  final dir = Directory('${docs.path}/adb/$sub');
  if (!await dir.exists()) await dir.create(recursive: true);
  return dir;
}
