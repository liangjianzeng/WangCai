/// 架构方向机器检查（P1 验收门）。
///
/// 这四条是插件平台**长期不腐**的护栏，写成测试而不是文档条款：
/// 一旦有人从插件里伸手进 UI，CI 当场红。
library;

import 'dart:io';

import 'package:plugin_kernel/plugin_kernel.dart';
import 'package:test/test.dart';

/// 从本包往上找到 app 根（有 `pubspec.yaml` 且 name 是 tongyi_lite 的那层）。
Directory? _findAppRoot() {
  var dir = Directory.current;
  for (var i = 0; i < 6; i++) {
    final pubspec = File('${dir.path}/pubspec.yaml');
    if (pubspec.existsSync()) {
      final text = pubspec.readAsStringSync();
      if (RegExp(r'^name:\s*tongyi_lite\s*$', multiLine: true).hasMatch(text)) return dir;
    }
    final parent = dir.parent;
    if (parent.path == dir.path) break;
    dir = parent;
  }
  return null;
}

List<File> _dartFiles(Directory dir) => dir.existsSync()
    ? dir
        .listSync(recursive: true)
        .whereType<File>()
        .where((f) => f.path.endsWith('.dart') && !f.path.contains('/.dart_tool/'))
        .toList(growable: false)
    : const [];

/// 抽出 `import 'package:...'` 与相对 import 的目标。
List<String> _importsOf(File f) {
  final out = <String>[];
  for (final line in f.readAsLinesSync()) {
    final m = RegExp("""^(?:import|export)\\s+['"]([^'"]+)['"]""").firstMatch(line.trim());
    if (m != null) out.add(m.group(1)!);
  }
  return out;
}

void main() {
  group('方向纪律（谁都不许伸手进谁的内部）', () {
    test('规则 A：SDK 与内核是纯 Dart —— 不许出现 Flutter / app 的 import', () {
      final files = <File>[
        ..._dartFiles(Directory('lib')),
        ..._dartFiles(Directory('../plugin_sdk/lib')),
      ];
      expect(files, isNotEmpty, reason: '没扫到文件说明路径不对，这条检查就白写了');
      for (final f in files) {
        for (final imp in _importsOf(f)) {
          expect(imp.startsWith('package:flutter/'), isFalse, reason: '${f.path} 引入了 $imp');
          expect(imp.startsWith('package:tongyi_lite/'), isFalse, reason: '${f.path} 引入了 $imp');
          expect(imp.contains('/lib/screens/'), isFalse, reason: '${f.path} 引入了 $imp');
        }
      }
    });

    test('规则 A2：内核 lib 不许碰 dart:io / dart:ffi（宿主才碰磁盘与原生）', () {
      for (final f in _dartFiles(Directory('lib'))) {
        for (final imp in _importsOf(f)) {
          expect(imp == 'dart:io' || imp == 'dart:ffi', isFalse,
              reason: '${f.path} 引入了 $imp —— 内核必须能在 flutter test / dart test 里离线跑');
        }
      }
    });

    test('规则 B/C：app 侧 lib/plugins 不许反向 import 宿主内部，内置插件之间不许互连', () {
      final root = _findAppRoot();
      if (root == null) {
        // 单独在纯 Dart 包里跑（CI 分包跑）时没有 app 根：跳过而不是假绿。
        markTestSkipped('没找到 app 根，B/C 两条本轮不适用');
        return;
      }
      final plugins = Directory('${root.path}/lib/plugins');
      if (!plugins.existsSync()) {
        markTestSkipped('lib/plugins 还没建（P2 落地后这条自动开始生效）');
        return;
      }
      final forbidden = RegExp(r'lib/(screens|providers|agent|tts|services)/');
      for (final f in _dartFiles(plugins)) {
        // 唯一的例外：`lib/plugins/host/**` 是**宿主接缝层**——把真 TTS/存储/对话框适配成能力，
        // 它天生要同时够到两边。插件（builtin/）与作者代码依旧一律禁止伸手拿宿主内部。
        final isHostSeam = f.path.contains('/lib/plugins/host/');
        if (!isHostSeam) {
          for (final imp in _importsOf(f)) {
            expect(forbidden.hasMatch(imp), isFalse,
                reason: '${f.path} 反向依赖了宿主内部（$imp）：宿主只能被注入，不能被插件伸手拿');
          }
        }
        // 内置插件互相看不见：要共享就沉淀成能力（capability）或提到 SDK。
        final self = RegExp(r'lib/plugins/builtin/([^/]+)/').firstMatch(f.path)?.group(1);
        if (self != null) {
          for (final imp in _importsOf(f)) {
            final target = RegExp(r'plugins/builtin/([^/]+)/').firstMatch(imp)?.group(1);
            expect(target == null || target == self, isTrue,
                reason: '内置插件 $self 直接 import 了 $target：把它们共用的东西做成能力或提进 SDK');
          }
        }
      }
    });

    test('规则 D：宿主槽是冻结件 —— 数量与 id 集不许悄悄变（改它必须走契约评审）', () {
      expect(kHostSlotContract.map((s) => s.id).toSet(), {
        'app.input.left',
        'app.input.right',
        'app.input.activity',
        'app.input.attachments',
        'app.composer.dock',
        'app.input.dock',
        'app.input.overlay',
        'app.composer.takeover',
        'app.chat.node',
        'app.tool.view',
        'app.settings.section',
      });
      expect(kPanelSlotContract.map((s) => s.id), ['app.plugins.tab', 'app.plugins.detail.action']);
    });
  });

  test('规则 E：契约承诺的钩子必须有调用者（预热 / 卸载 / 后台预取）', () {
    String read(List<String> cands) {
      final p = cands.firstWhere((x) => File(x).existsSync(), orElse: () => '');
      expect(p, isNotEmpty, reason: '找不到 ${cands.first}：路径变了要连着改这条门禁，不许悄悄跳过。');
      return File(p).readAsStringSync();
    }

    final host = read(['../../lib/plugins/plugin_host.dart', 'lib/plugins/plugin_host.dart']);
    expect(host, contains('warmUpCapabilities('),
        reason: 'CapabilityRegistry.warmUpAll 是契约承诺的钩子。没人调用它，离线音色表就永远懒加载到第一次朗读，'
            '而契约里写的「启动后低优先级预热」是句空话。');
    // 只查"文件里出现过 .shutdown(" 太松：挪进一个没人调的函数照样过。钉住它必须挂在 onDispose 上。
    expect(RegExp(r'ref\.onDispose\([\s\S]{0,80}?shutdown\(').hasMatch(host), isTrue,
        reason: 'fiber 树必须随平台丢弃一起卸：`ref.onDispose(() => unawaited(service.shutdown()))` 这句一丢，'
            '每次重扫就多漏一份 Timer / 订阅 / provide 出去的能力，而且全程没有任何症状。');
    final runner = read([
      'lib/src/flow_runner.dart',
      '../../packages/plugin_kernel/lib/src/flow_runner.dart',
    ]);
    expect(runner, contains('prewarm('),
        reason: 'Speak.prewarm 由 runner 负责调用；不叫它，「第一条立刻播、其余后台预取」就是句广告词。');
  });
}
