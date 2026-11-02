// "示例即规格"的门禁：仓库里的五个示例必须被作者工具链**全部认得**。
//
// 现在的形状是 `examples/` 下**一层五个目录**：三个声明式插件（`zh_dictation` / `en_zh_cards` /
// `declarative_hello`）+ 两个代码级 Dart 包（`hello_plugin` / `speak_example`）。
// 这里同时钉着一条自律：**示例自己必须守住"一层目录 = 一个插件"** —— 以前声明式示例藏在
// `hello_plugin/declarative_example/` 里，`doctor` 看不见它（扫描只走一层），作者照抄就把自己的
// 插件也套了一层，然后对着"一个都没见到"发懵。
//
// 为什么值得单独钉一条：示例是第三方作者照抄的对象，也是文档的一部分。
// 一旦某个示例悄悄不再被 `doctor`/`validate` 认出来（改了目录结构、忘了文件），
// 平台就出现"文档说这样写、工具说这不是插件"的分歧 —— 而这种分歧从来不会自己报警。
import 'dart:convert';
import 'dart:io';

import 'package:plugin_kernel/plugin_kernel.dart';
import 'package:test/test.dart';

/// 真文件系统版（内核不许碰 `dart:io`，所以注入；与 `tool/plugins.dart` 的实现同构）。
class _IoFs implements PluginCliIo {
  @override
  bool exists(String path) => FileSystemEntity.typeSync(path) != FileSystemEntityType.notFound;

  @override
  bool isDir(String path) => Directory(path).existsSync();

  @override
  List<String> listDir(String path) =>
      Directory(path).listSync().map((e) => e.path.split(Platform.pathSeparator).last).toList()..sort();

  @override
  String? readString(String path) {
    final f = File(path);
    return f.existsSync() ? f.readAsStringSync() : null;
  }

  @override
  void writeString(String path, String content) {
    final f = File(path);
    f.parent.createSync(recursive: true);
    f.writeAsStringSync(content);
  }

  @override
  void deleteFile(String path) => File(path).deleteSync();

  @override
  void createDir(String path) => Directory(path).createSync(recursive: true);
}

Directory? _findRepoRoot() {
  var d = Directory.current;
  for (var i = 0; i < 6; i++) {
    if (File('${d.path}/examples/zh_dictation/plugin.json').existsSync()) return d;
    final parent = d.parent;
    if (parent.path == d.path) break;
    d = parent;
  }
  return null;
}

/// 与 app 侧 `kHostCapabilityIds` 同一份（真源在那边；这里若对不上，说明清单漂了）。
const _hostCaps = {
  'app.store',
  'app.interact',
  'app.speak',
  'app.capture',
  'llm.complete',
  'llm.vision',
};

void main() {
  final root = _findRepoRoot();

  test('五个示例目录全被工具链认得：三个声明式插件 + 两个代码级 Dart 包', () {
    expect(root, isNotNull, reason: '找不到仓库根 —— examples/zh_dictation 被挪走了？');
    final examples = '${root!.path}/examples';
    final data = Directory.systemTemp.createTempSync('examples_gate');
    addTearDown(() {
      if (data.existsSync()) data.deleteSync(recursive: true);
    });
    // 三个声明式插件都放进启用集，才谈得上"没有跑不了的"。
    // （`Directory.childFile` 在新 SDK 已移除，路径老实拼。）
    File('${data.path}/plugin_enabled.json')
        .writeAsStringSync(jsonEncode({
          'plugin.enabled': ['zh-dictation', 'en-zh-cards', 'poem-recite']
        }));

    final cli = PluginCli(_IoFs(), const PluginCliConfig(hostCapabilityIds: _hostCaps, appVersion: '0.2.8'));
    final r = cli.run(['doctor', '--plugins-dir', examples, '--data-dir', data.path]);
    final text = r.lines.join('\n');

    expect(r.exitCode, 0, reason: '示例是作者的样板，跑不出体检结论就是平台的锅：\n$text');
    // 三个声明式插件都得现身。
    expect(text, contains('zh-dictation'), reason: '实例 B 要被认出来');
    expect(text, contains('en-zh-cards'), reason: '实例 C 要被认出来');
    expect(text, contains('poem-recite'), reason: '声明式最小样例挪成一层目录后必须被认出来');
    expect(text, contains('只在 app 里跑'), reason: '声明式插件在 CLI 里判"待功能"是边界，不是毛病');
    // 两个代码级包：要说清"CLI 判不了它"，而不是骗作者去补一个 plugin.json。
    expect(text, contains('examples/hello_plugin'), reason: '它是代码级 Dart 包');
    expect(text, contains('examples/speak_example'), reason: '它是代码级 Dart 包');
    // 示例必须是"零提醒"的样板：装饰性参数（声明了没人用）、空 ask 步这些都不能出现在示例里。
    expect(text, isNot(contains('声明提醒')), reason: '示例带着校验提醒发布 = 作者照抄着写坏的声明');
    expect(text, isNot(contains('更里面一层')),
        reason: '示例自己不许再把声明套一层 —— 这条以前就是坏的，挪出来才修好');
    expect(text, isNot(contains('没有 plugin.json 的目录')),
        reason: '不许有"说不清是什么"的目录：每个看不见的东西都要有名字和原因');
  });

  test('三个声明式示例当场过 validate（示例就是规格，规格必须自证）', () {
    expect(root, isNotNull);
    final cli = PluginCli(_IoFs(), const PluginCliConfig(hostCapabilityIds: _hostCaps, appVersion: '0.2.8'));
    final r = cli.run(['validate', '${root!.path}/examples']);
    expect(r.exitCode, 0, reason: r.lines.join('\n'));
  });
}
