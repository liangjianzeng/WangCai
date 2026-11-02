import 'dart:convert';

import 'package:plugin_kernel/plugin_kernel.dart';
import 'package:test/test.dart';

/// 内存文件系统（内核不许碰 `dart:io`，CLI 因此全部走注入）。
class MemIo implements PluginCliIo {
  final Map<String, String> files = {};
  final Set<String> dirs = {};

  @override
  bool exists(String path) => files.containsKey(path) || dirs.contains(path);

  @override
  bool isDir(String path) => dirs.contains(path);

  @override
  List<String> listDir(String path) {
    final prefix = path.endsWith('/') ? path : '$path/';
    final out = <String>{};
    for (final d in dirs) {
      if (d.startsWith(prefix)) {
        final rest = d.substring(prefix.length);
        if (rest.isNotEmpty) out.add(rest.split('/').first);
      }
    }
    for (final f in files.keys) {
      if (f.startsWith(prefix)) {
        final rest = f.substring(prefix.length);
        if (rest.isNotEmpty) out.add(rest.split('/').first);
      }
    }
    return out.toList()..sort();
  }

  @override
  String? readString(String path) => files[path];

  @override
  void writeString(String path, String content) {
    files[path] = content;
    // 与真实现一致：写文件等于把父目录也带出来（dart:io 版写之前会 create 目录）。
    var d = path;
    while (d.contains('/')) {
      d = d.substring(0, d.lastIndexOf('/'));
      if (d.isEmpty) break;
      dirs.add(d);
    }
  }

  @override
  void deleteFile(String path) => files.remove(path);

  @override
  void createDir(String path) => dirs.add(path);

  void seed(String path, String content) => writeString(path, content);
}

const _hostCaps = {'app.store', 'app.interact', 'app.speak', 'app.capture', 'llm.vision'};

PluginCliResult run(PluginCliIo io, List<String> args) =>
    PluginCli(io, const PluginCliConfig(hostCapabilityIds: _hostCaps, appVersion: '0.2.8')).run(args);

void main() {
  late MemIo io;
  setUp(() => io = MemIo());

  group('scaffold', () {
    test('生成的东西当场自检通过并落盘（不合格宁可不写）', () {
      final r = run(io, ['scaffold', 'word-cards', '--name', '单词卡', '--desc', '按间隔念单词']);
      expect(r.exitCode, 0, reason: r.lines.join('\n'));
      expect(io.files.containsKey('plugins/word-cards/plugin.json'), isTrue);
      expect(io.files.containsKey('plugins/word-cards/prompt.md'), isTrue);
      expect(io.files['plugins/word-cards/plugin.json'], contains('"manifestVersion": 1'));
      expect(r.lines.any((l) => l.contains('下一步')), isTrue, reason: '要顺手告诉作者接下来干什么');
    });

    test('目录已存在时拒绝覆盖（作者手改过的东西不能被脚手架冲掉）', () {
      run(io, ['scaffold', 'word-cards']);
      io.writeString('plugins/word-cards/README.md', '我手写的笔记，不许丢');
      final r = run(io, ['scaffold', 'word-cards']);
      expect(r.exitCode, 1);
      expect(r.lines.join('\n'), contains('--force'));
      expect(io.files['plugins/word-cards/README.md'], '我手写的笔记，不许丢');
      final forced = run(io, ['scaffold', 'word-cards', '--force']);
      expect(forced.exitCode, 0);
      expect(io.files['plugins/word-cards/README.md'], isNot('我手写的笔记，不许丢'));
    });

    test('dart 形态生成到 builtin 目录并给出注册提示', () {
      final r = run(io, ['scaffold', 'word-cards', '--kind', 'dart']);
      expect(r.exitCode, 0, reason: r.lines.join('\n'));
      expect(io.files.keys.where((k) => k.endsWith('.dart')), ['lib/plugins/builtin/word-cards/word_cards_plugin.dart']);
      expect(r.lines.join('\n'), contains('builtin.register'));
    });

    test('非法 id：自检拒绝写盘（不给人一个装不上的骨架）', () {
      final r = run(io, ['scaffold', 'BAD']);
      expect(r.exitCode, 1);
      expect(r.lines.join('\n'), contains('自检'));
      expect(io.files, isEmpty);
    });
  });

  group('validate', () {
    test('合格目录退出 0', () {
      run(io, ['scaffold', 'good-one']);
      final r = run(io, ['validate', 'plugins']);
      expect(r.exitCode, 0, reason: r.lines.join('\n'));
      expect(r.lines.first, contains('✅'));
    });

    test('坏 JSON 退出 1 并指出错误码与出路', () {
      io.seed('plugins/broken/plugin.json', '{"id":"broken","name":}');
      final r = run(io, ['validate', 'plugins']);
      expect(r.exitCode, 1);
      final text = r.lines.join('\n');
      expect(text, contains('notJson'));
      expect(text, contains('→'), reason: '每条错误都要给"下一步做什么"');
    });

    test('目录不存在时说清并给出生成命令（不是甩一句 ENOENT）', () {
      final r = run(io, ['validate', 'nope']);
      expect(r.exitCode, 1);
      expect(r.lines.join('\n'), contains('scaffold'));
    });
  });

  group('doctor 对"看得见/看不见"的分类', () {
    Map<String, Object?> decl(String id) => {
          'manifestVersion': 1,
          'id': id,
          'name': id,
          'description': 'd',
          'trust': 'declarative',
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
        };

    test('三种"目录里没有 plugin.json"要分得开：套一层 / Dart 包 / 真的什么都没有', () {
      io.seed('plugins/good/plugin.json', jsonEncode(decl('good')));
      // ① 声明藏在子目录里（示例目录常有这种套法）
      io.seed('plugins/wrapped/inner/plugin.json', jsonEncode(decl('inner')));
      // ② 代码级插件的示例包：CLI 判不了，也不该骗作者说它坏了
      io.writeString('plugins/code_pkg/pubspec.yaml', 'name: code_pkg\n');
      io.writeString('plugins/code_pkg/lib/main.dart', 'void main() {}');
      // ③ 真的什么都没有
      io.createDir('plugins/nothing-here');

      final r = run(io, ['doctor', '--plugins-dir', 'plugins']);
      final text = r.lines.join('\n');
      expect(text, contains('更里面一层'), reason: '套一层的要说清声明真正在哪');
      expect(text, contains('plugins/wrapped/inner'), reason: '要说清声明真正在哪一层');
      expect(text, contains('Dart 包'), reason: '代码级示例要说明 CLI 判不了它，别让人以为插件坏了');
      expect(text, contains('plugins/code_pkg'));
      expect(text, contains('没有 plugin.json 的目录'), reason: '真的没文件的也要点名');
      expect(text, contains('plugins/nothing-here'));
      expect(text, isNot(contains('plugins/good')), reason: '正常加载的不能混进"看不见"名单');
    });

    test('一个目录既是 Dart 包又装着声明：两件事都得说，只报一件等于让作者猜另一半', () {
      io.seed('plugins/both/plugin.json', jsonEncode(decl('both')))
          ; // 这目录自己是插件，CLI 不该报它
      io.seed('plugins/hybrid/inner/plugin.json', jsonEncode(decl('inner')));
      io.writeString('plugins/hybrid/pubspec.yaml', 'name: hybrid\n');

      final text = run(io, ['doctor', '--plugins-dir', 'plugins']).lines.join('\n');
      expect(text, contains('更里面一层'));
      expect(text, contains('dart test'), reason: '它同时是个包，测试归它自己跑 —— 这句不能说漏');
      expect(text, isNot(contains('plugins/both')), reason: '规规矩矩一层目录的插件不该出现在这里');
    });
  });

  group('doctor 的「声明提醒」行（以前一次都没打印过）', () {
    Map<String, Object?> decl(String id, {Map<String, Object?>? extra}) => {
          'manifestVersion': 1,
          'id': id,
          'name': id,
          'description': 'd',
          'trust': 'declarative',
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
          ...?extra,
        };

    test('目录里全是读不出来的声明：首要一行就说这件事，还带错误原文', () {
      // 半截 JSON：连 descriptor 都建不起来，只能落到 broken。
      io.seed('plugins/half/plugin.json', '{ "manifestVersion": 1, "id": "half"');
      final lines = run(io, ['doctor', '--plugins-dir', 'plugins']).lines;
      final text = lines.join('\n');
      expect(lines.first, contains('读不出来'),
          reason: '作者先看的第一行就得是真相。「没找到插件」把人引去查目录名，'
              '而真相是自己把 plugin.json 写坏了 —— 已经算出来的错误不许只字不提');
      expect(text, isNot(contains('没找到插件')), reason: '目录里明明有声明，"没找到"就是误导');
      expect(text, contains('half/plugin.json'), reason: '点名到文件（相对插件目录），一个目录可能有好几个');
      expect(text, contains('FormatException'), reason: '错误原文已经在手上，不许只说"去跑 validate"');
      expect(text, contains('validate'), reason: '仍要指路到能看全部原文的地方');
    });

    test('能力 id 写歪到连加载都进不去的，同样不许人间蒸发', () {
      io.seed('plugins/badcap/plugin.json', jsonEncode({
        'manifestVersion': 1,
        'id': 'badcap',
        'name': 'badcap',
        'description': 'd',
        'trust': 'declarative',
        'permissions': ['storage:plugin'],
        'inject': ['no.such.capability'],
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
      }));
      final text = run(io, ['doctor', '--plugins-dir', 'plugins']).lines.join('\n');
      expect(text, contains('读不出来'), reason: '判坏 ≠ 消失；插件在 doctor 里看不见是最坏的结局');
      expect(text, contains('badcap/plugin.json'));
      expect(text, contains('no.such.capability'), reason: '要点名是哪个能力写歪了');
    });

    test('只有提醒的插件：说几条、带路径，而且不许被说成坏了', () {
      io.seed('plugins/only-warn/plugin.json', jsonEncode(decl('only-warn', extra: {
        'config': {'ghostKey': 1},
      })));
      final text = run(io, ['doctor', '--plugins-dir', 'plugins']).lines.join('\n');
      expect(text, contains('声明提醒 1 条'), reason: '提醒必须报条数 —— "有几条"作者自己数太累');
      expect(text, contains('config.ghostKey'), reason: '提醒要带路径，否则作者找不到改哪');
      expect(text, isNot(contains('硬问题')),
          reason: '"这样写更好"与"你这插件有问题"是两种语气，混了就是把环境问题说成指责');
    });

  });

  group('doctor', () {
    // doctor 的验收标准只有一条：作者看完输出**知道下一步动什么**。
    // 所以每个跑不了的插件必须落到一句「怎么办」，而且 CLI 与 app 面板判出来的终态必须一致。
    Map<String, Object?> manifest(String id, {required String trust, List<String> inject = const ['app.store']}) => {
          'manifestVersion': 1,
          'id': id,
          'name': '插件$id',
          'description': 'd',
          'trust': trust,
          'inject': inject,
          'permissions': ['storage:plugin', 'tts', 'network'],
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
        };

    test('跑不了的每条都落到「怎么办」，并摊开缺口 / 预算 / 启用集', () {
      io.seed('plugins/ok-one/plugin.json', jsonEncode(manifest('ok-one', trust: 'declarative')));
      io.seed('plugins/need-cap/plugin.json',
          jsonEncode(manifest('need-cap', trust: 'trusted', inject: ['app.store', 'net.search'])));
      io.writeString('plugin_data/plugin_enabled.json', jsonEncode({
        'plugin.enabled': ['ok-one'],
      }));

      final r = run(io, ['doctor', '--plugins-dir', 'plugins']);
      final text = r.lines.join('\n');
      expect(r.exitCode, 1, reason: '有插件跑不了就该给非零码，CI 才拦得住');
      expect(text, contains('net.search'), reason: '缺哪个能力要点名');
      expect(text, contains('怎么办'), reason: '只报状态不给下一步的体检等于让作者截图来回');
      expect(text, contains('未启用'), reason: 'need-cap 没进启用集，这一行直接给出路');
      expect(text, contains('预算'), reason: '预算用了多少要摊开，别等上线才发现超');
      expect(text, contains('/32768 B'), reason: 'prompt.md 上限要说得出数字');
      expect(text, contains('本机能力 5 个'));
      expect(text, isNot(contains('全部可运行')));
    });

    test('点名一个 id 就只体检它；点名错了要把可选项和下一步一起给出来', () {
      io.seed('plugins/ok-one/plugin.json', jsonEncode(manifest('ok-one', trust: 'declarative')));
      io.seed('plugins/ok-two/plugin.json', jsonEncode(manifest('ok-two', trust: 'declarative')));
      io.writeString('plugin_data/plugin_enabled.json',
          jsonEncode({
            'plugin.enabled': ['ok-one', 'ok-two']
          }));

      // 声明式插件在 CLI 里必然显示"待功能"（flow 引擎在 app 里）—— 这是 **CLI 的边界，不是插件的毛病**，
      // 所以既不能算失败退出码，也不能让作者去改一份本来没问题的 plugin.json。
      final one = run(io, ['doctor', 'ok-one', '--plugins-dir', 'plugins', '--data-dir', 'plugin_data']);
      final oneText = one.lines.join('\n');
      expect(one.exitCode, 0, reason: oneText);
      expect(oneText, contains('ok-one'));
      expect(oneText, contains('插件体检：1 个'));
      expect(oneText, isNot(contains('ok-two')), reason: '点名的就只报它，别把全文吐一遍');
      expect(oneText, contains('只在 app 里跑'), reason: '要说清这是 CLI 的边界');
      expect(oneText, contains('没有真问题'));

      final miss = run(io, ['doctor', 'nope', '--plugins-dir', 'plugins', '--data-dir', 'plugin_data']);
      final missText = miss.lines.join('\n');
      expect(miss.exitCode, 1);
      expect(missText, contains('没找到插件「nope」'));
      expect(missText, contains('ok-one'), reason: '要把可选项列出来，否则作者回去翻目录');
    });

    test('读不出来的声明也要露头，并指回 validate 看原文', () {
      io.seed('plugins/bad-one/plugin.json',
          '{"manifestVersion":1,"id":"BAD","name":"x","description":"d","trust":"trusted"}');
      final r = run(io, ['doctor', 'bad-one', '--plugins-dir', 'plugins']);
      final text = r.lines.join('\n');
      expect(r.exitCode, 1);
      expect(text, contains('没找到插件「bad-one」'), reason: '声明没读出来时 id 都不一定对得上');
      expect(text, contains('validate'), reason: '硬错误原文在 validate 那儿更全，要给个去处');
    });

    test('放错地方 / 少放 plugin.json 的目录要报出来，别让人对着空列表发懵', () {
      io.seed('plugins/real-one/plugin.json', jsonEncode(manifest('real-one', trust: 'declarative')));
      io.createDir('plugins/typoed-on'); // 作者以为放了声明，其实目录里什么都没有
      io.writeString('plugins/half-baked/README.md', '待写');
      final r = run(io, ['doctor', '--plugins-dir', 'plugins']);
      final text = r.lines.join('\n');
      expect(text, contains('没有 plugin.json 的目录'), reason: '"怎么一个都没见到"必须当场答出来');
      expect(text, contains('plugins/typoed-on'));
      expect(text, contains('plugins/half-baked'));
      expect(text, contains('scaffold'), reason: '顺手给一条少走弯路的路');
    });

    test('新插件默认没开 ≠ "已被你停用"：措辞不许把作者引去查谁动了设置', () {
      io.seed('plugins/fresh-one/plugin.json', jsonEncode(manifest('fresh-one', trust: 'declarative')));
      final r = run(io, ['doctor', 'fresh-one', '--plugins-dir', 'plugins', '--data-dir', 'empty_data']);
      final text = r.lines.join('\n');
      expect(text, contains('没在启用集里'));
      expect(text, isNot(contains('已被你停用')), reason: '启用集只存"开着的"，说不出是谁关的');
    });

    test('只是环境没到位（要更高 app 版本）算提醒不算错误：状态待功能 + 出路是升级 app', () {
      final m = manifest('need-app', trust: 'trusted');
      m['engines'] = {'app': '>=9.9.9'};
      io.seed('plugins/need-app/plugin.json', jsonEncode(m));
      io.writeString('plugin_data/plugin_enabled.json', jsonEncode({
        'plugin.enabled': ['need-app']
      }));

      final r = run(io, ['doctor', 'need-app', '--plugins-dir', 'plugins', '--data-dir', 'plugin_data']);
      final text = r.lines.join('\n');
      expect(r.exitCode, 1);
      expect(text, contains('待功能'));
      expect(text, contains('升级 app'), reason: '环境没到位的出路是升级，不是判作者写错');
      expect(text, contains('9.9.9'));
    });
  });

  group('scan', () {
    test('四种终态都能看见，并说清"缺什么 / 为什么被拒"', () {
      // 声明式插件在 flow 引擎（P5）上线前只能停在"待功能"，**绝不假装能跑** —— 这条也在 CLI 里可见。
      io.seed('plugins/ready-one/plugin.json', jsonEncode({
        'manifestVersion': 1, 'id': 'ready-one', 'name': '等引擎', 'description': 'd',
        'trust': 'declarative', 'inject': ['app.store'], 'permissions': ['storage:plugin', 'tts', 'network'],
        'flow': {'name': 'n', 'description': 'd', 'whenToUse': 'w',
          'phases': [{'id': 'p', 'title': '念'}],
          'steps': [{'id': 's', 'op': 'speak_sequence', 'phase': 'p', 'params': {'items': ['a']}}]},
      }));
      io.seed('plugins/gated-one/plugin.json', jsonEncode({
        'manifestVersion': 1, 'id': 'gated-one', 'name': '缺能力', 'description': 'd',
        'trust': 'declarative', 'inject': ['net.search'], 'permissions': ['network', 'storage:plugin'],
        'flow': {'name': 'n', 'description': 'd', 'whenToUse': 'w',
          'phases': [{'id': 'p', 'title': '念'}],
          'steps': [{'id': 's', 'op': 'store', 'phase': 'p'}]},
      }));
      io.seed('plugins/rejected-one/plugin.json',
          '{"manifestVersion":1,"id":"BAD","name":"x","description":"d","trust":"declarative"}');
      io.seed('plugins/off-one/plugin.json', jsonEncode({
        'manifestVersion': 1, 'id': 'off-one', 'name': '没启用', 'description': 'd',
        'trust': 'declarative', 'inject': ['app.store'], 'permissions': ['storage:plugin'],
        'flow': {'name': 'n', 'description': 'd', 'whenToUse': 'w',
          'phases': [{'id': 'p', 'title': '念'}],
          'steps': [{'id': 's', 'op': 'store', 'phase': 'p'}]},
      }));
      io.writeString('plugin_data/plugin_enabled.json', jsonEncode({
        'plugin.enabled': ['ready-one', 'gated-one', 'rejected-one'],
      }));

      final r = run(io, ['scan', '--plugins-dir', 'plugins', '--data-dir', 'plugin_data']);
      final text = r.lines.join('\n');
      expect(r.exitCode, 0, reason: text);
      expect(text, contains('flow.runner'), reason: '声明式插件要说清在等 flow 引擎');
      expect(text, contains('缺：net.search'), reason: '门控要说清缺哪个能力');
      expect(text, contains('被拒'));
      expect(text, contains('未启用'), reason: '没打勾的也要列出来，否则作者以为插件消失了');
      expect(text, contains('合计：0 可运行 / 2 待功能 / 0 被拒 / 1 未启用 / 1 个读不出来'),
          reason: '解析直接失败的也要在合计里露头，不能只躲在 ❌ 列表里');
    });

    test('目录是空的 → 教作者怎么开始', () {
      io.createDir('plugins');
      final r = run(io, ['scan', '--plugins-dir', 'plugins']);
      expect(r.exitCode, 0);
      expect(r.lines.join('\n'), contains('scaffold'));
    });
  });

  group('doctor 看 enabledByDefault 的三种"未启用"', () {
    // 「未启用」有三种完全不同的意思，混在一起报就是让作者白查一轮：
    // 默认没开 / 被手动关过 / 声明了默认开但 app 还没扫过它。
    Map<String, Object?> manifest(String id, {required bool onByDefault}) => {
          'manifestVersion': 1,
          'id': id,
          'name': '插件$id',
          'description': 'd',
          'trust': 'declarative',
          'enabledByDefault': onByDefault,
          'inject': ['app.store'],
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
        };

    test('声明了 enabledByDefault 且没被扫过：说清会自动打开，且不算作者的错', () async {
      io.seed('plugins/auto/plugin.json', jsonEncode(manifest('auto', onByDefault: true)));
      io.writeString('plugin_data/plugin_enabled.json', jsonEncode({'plugin.enabled': <String>[]}));

      final r = run(io, ['doctor', '--plugins-dir', 'plugins']);
      final text = r.lines.join('\n');

      // 第 81 轮实测：把 `pendingSeed` 塌成 false，原来那两条断言**全绿** —— 它们钉的是另一条
      // 无条件提示，等于什么都没钉住。要钉就钉这句完整的分岔话术。
      expect(text, contains('未启用，但它写了 enabledByDefault —— app 第一次扫到会自动打开'),
          reason: '三态里的这一态必须说得出"默认没开但会自动打开"；混成一句"未启用"就是让作者白查一轮');
      expect(text, contains('第一次扫到会自动打开'), reason: '否则作者以为要改 plugin.json，其实什么都不用动');
      expect(text, contains('不用你动手'));
      expect(r.exitCode, 0, reason: '它在 app 里其实是开的 —— 把没坏的东西报成问题，比不报更坏');
      expect(text, isNot(contains('个跑不了')));
    });

    test('账本里已经见过它：说明是被手动关的，要给出路并计入跑不了', () async {
      io.seed('plugins/auto/plugin.json', jsonEncode(manifest('auto', onByDefault: true)));
      io.writeString('plugin_data/plugin_enabled.json', jsonEncode({
        'plugin.enabled': <String>[],
        'plugin.seen': ['auto'],
      }));

      final r = run(io, ['doctor', '--plugins-dir', 'plugins']);
      final text = r.lines.join('\n');

      expect(text, contains('未启用（app 的「设置 → 插件」里打开，或 reset --enabled 清开关重来）'),
          reason: '被手动关的那一态要给出路，而且不许还留着"会自动打开"那句');
      // 判互斥必须**限定到那一行**：内核的 disabledReason 另有句话
      // 「没在启用集里；它声明了 enabledByDefault，app 第一次扫到会自动打开（若一直停在这儿，说明被手动关过）」，
      // 它对两种情况都算诚实，不该被这条判据误伤（第 81 轮第一版就误伤过 —— 红的是不该红的）。
      expect(text, isNot(contains('启用：未启用，但它写了 enabledByDefault')),
          reason: '反向判据：账本里已经见过它，「启用」那一行就再也不能走"会自动打开"那个分岔 —— 三态必须互斥');
      expect(text, contains('被手动关过'), reason: '见过又关着 = 有人关的，不能还说"会自动打开"');
      expect(r.exitCode, 1);
    });

    test('reset --enabled 只动启用集，不许把同文件的 plugin.seen 洗掉', () async {
      io.writeString('plugin_data/plugin_enabled.json', jsonEncode({
        'plugin.enabled': ['a', 'b'],
        'plugin.seen': ['a', 'b', 'c'],
      }));
      run(io, ['reset', '--data-dir', 'plugin_data', '--enabled', '--yes']);

      final left = jsonDecode(io.files['plugin_data/plugin_enabled.json']!) as Map<String, Object?>;
      expect(left.containsKey('plugin.enabled'), isFalse, reason: '该清的清了');
      expect((left['plugin.seen'] as List).toSet(), {'a', 'b', 'c'},
          reason: '整包重写会把账本洗掉 —— 文件推回手机后所有插件都变成"第一次见到"，被集体重新自动打开');
    });
  });

  group('reset', () {
    test('不加 --yes 一个字都不删', () {
      io.writeString('plugin_data/plugin_enabled.json', '{"plugin.enabled":["x"]}');
      io.writeString('plugin_data/plugin_store.json', '{"plugin:x:k":"词表"}');
      final r = run(io, ['reset', '--data-dir', 'plugin_data']);
      expect(r.exitCode, 1);
      expect(r.lines.join('\n'), contains('--yes'));
      expect(io.files.containsKey('plugin_data/plugin_store.json'), isTrue, reason: '没确认就不许动用户词表');
    });

    test('目录里没东西可清：要说"什么都没要删"并给猜测，不许报"完成，删了 0 个文件"', () {
      final text = run(io, ['reset', '--data-dir', 'plugin_data', '--yes']).lines.join('\n');
      expect(text, contains('什么都没要删'),
          reason: '"完成，删了 0 个文件"听起来像干完了活，其实什么都没发生 —— '
              '作者会以为开关已经被清了、回 app 一看插件还开着，然后开始怀疑 app');
      expect(text, contains('plugin_data'), reason: '要说清看的哪个目录，八成是 --data-dir 指错了');
    });

    test('预览行必须说清"清的是开关、播种账本 plugin.seen 会留着"', () {
      io.writeString('plugin_data/plugin_enabled.json', '{"plugin.enabled":["x"],"plugin.seen":["x"]}');
      final text = run(io, ['reset', '--data-dir', 'plugin_data']).lines.join('\n');
      expect(text, contains('将清空 插件开关'), reason: '未确认时要说清动的是哪一份，用户才知道自己在确认什么');
      expect(text, contains('--yes'), reason: '出路要写在同一句里');
      expect(text, contains('plugin.seen'), reason: '同文件里住着首次播种账本，预览不讲清，用户确认的就是个模糊承诺');
      expect(io.files.containsKey('plugin_data/plugin_enabled.json'), isTrue);
    });

    test('确认清空后要说人话：账本留着，以及为什么留着', () {
      io.writeString('plugin_data/plugin_enabled.json', '{"plugin.enabled":["x"],"plugin.seen":["x"]}');
      final text = run(io, ['reset', '--data-dir', 'plugin_data', '--enabled', '--yes']).lines.join('\n');
      expect(text, contains('已清空 插件开关'), reason: '动过手就要留声音');
      expect(text, contains('plugin.seen'), reason: '用户最想知道的是"我关掉的插件会不会又自己亮起来"');
      expect(text, contains('自动打开'), reason: '后果要说出口，不能只报文件路径');
      final kept = io.files['plugin_data/plugin_enabled.json'];
      expect(kept, isNotNull, reason: '还有 seen 要留，文件不许被整个删掉');
      expect(kept, contains('plugin.seen'));
      expect(kept, isNot(contains('plugin.enabled')));
    });

    test('只删开关，数据默认保留', () {
      io.writeString('plugin_data/plugin_enabled.json', '{"plugin.enabled":["x"]}');
      io.writeString('plugin_data/plugin_store.json', '{"plugin:x:k":"词表"}');
      final r = run(io, ['reset', '--data-dir', 'plugin_data', '--enabled', '--yes']);
      expect(r.exitCode, 0, reason: r.lines.join('\n'));
      expect(io.files.containsKey('plugin_data/plugin_enabled.json'), isFalse);
      expect(io.files.containsKey('plugin_data/plugin_store.json'), isTrue, reason: '词表是用户攒的，删它必须显式 --store');
    });
  });

  group('入口体验', () {
    test('无参数给用法并以 1 退出（脚本里能被 CI 抓到）', () {
      final r = run(io, const []);
      expect(r.exitCode, 1);
      expect(r.lines.join('\n'), contains('plugins.dart validate'));
    });

    test('未知子命令退出 2（与"校验不合格"的 1 区分开）', () {
      final r = run(io, ['frobnicate']);
      expect(r.exitCode, 2);
      expect(r.lines.join('\n'), contains('未知子命令'));
    });
  });

  group('校验口径 = 契约全集 ∪ 本机实现集（两个问法不许合并、也不许丢）', () {
    // doctor 的「本机缺几个」问的是 hostCapabilityIds；**校验**问的是 validationCaps。
    // 第 81 轮实测：把 validationCaps 改成只留契约全集，全量内核测试一声不响 —— 说明没人测过
    // 「宿主真实现、但没写进契约全集」的那类 id。这条补那个洞，并带反向判据。
    Map<String, Object?> m(String id, List<String> inject) => {
          'manifestVersion': 1,
          'id': id,
          'name': '插件$id',
          'description': 'd',
          'trust': 'declarative',
          'inject': inject,
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
        };

    test('宿主实现了但契约全集里没有的 id，不许报「本机没有提供能力」', () async {
      io.seed('plugins/hostonly/plugin.json',
          jsonEncode(m('hostonly', const ['app.store', 'app.wordplay'])));
      io.seed('plugins/bogus/plugin.json',
          jsonEncode(m('bogus', const ['app.store', 'no.such.capability'])));
      // 要钉「✅ 可运行」就得真把它启用 —— 不然它只是 ⬜ 未启用，那条正则什么都判不出来。
      // （id 也得挑**形态合法**的：`app.dictationPlayer` 这种驼峰会先撞「能力 id 不合法」那道闸，
      //  测试根本测不到能力口径 —— 第 81 轮踩过这个坑。）
      io.writeString('plugin_data/plugin_enabled.json',
          jsonEncode({'plugin.enabled': <String>['hostonly']}));

      final r = PluginCli(io, const PluginCliConfig(
        hostCapabilityIds: {..._hostCaps, 'app.wordplay'},
        appVersion: '0.2.8',
      )).run(['doctor', '--plugins-dir', 'plugins']);
      final text = r.lines.join('\n');

      // 两个问法各自钉**正面可见的结果**，不许只断"某句话没出现"：
      // 第 81 轮第一版就是拿 `isNot(contains('本机没有提供能力 "…"'))` 判的，把校验口径改掉
      // 之后被拒的插件走的是另一套措辞，那句"不该出现的话"本来就不会出现 —— 假断言，变异不红。
      //
      // 允许两个 tag：CLI 没有 flow.runner，声明式带 flow 的插件在 CLI 里就是
      // 「📱 只在 app 里跑」（gated on flow.runner，见 `_cliSideOnlyGate`）—— 那也是"加载成功"。
      // 关键在**不许变成读不出来 / ❌ 被拒**：那种情况下整行 🩺 都不存在，正则当场不匹配。
      expect(
        text,
        matches(RegExp(r'🩺 hostonly[^\n]*(✅ 可运行|📱 只在 app 里跑)')),
        reason: '宿主真实现、只是没写进契约全集的 id：校验口径必须并入本机那份，'
            '否则这个插件会被自己人判死（读不出来 / 被拒），作者去删一个能用的能力。',
      );
      expect(text, contains('能力：inject 2 项，本机全有'),
          reason: '「本机有没有」问的是 hostCapabilityIds，这一行必须说它全有（与上面那句互相印证）');
      // 反向判据走 `validate`：它逐份声明报 ✅/❌，比 doctor 的体检表更适合钉"坏声明不许人间蒸发"。
      final v = PluginCli(io, const PluginCliConfig(
        hostCapabilityIds: {..._hostCaps, 'app.wordplay'},
        appVersion: '0.2.8',
      )).run(['validate', 'plugins']);
      final vtext = v.lines.join('\n');
      expect(vtext, contains('✅ plugins/hostonly/plugin.json'),
          reason: '同一个 id：validate 与 doctor 两个问法必须给同一个答案（一个说能跑一个说读不出来 = 两份口径）');
      expect(vtext, contains('❌ plugins/bogus/plugin.json'),
          reason: '真没实现的 id 必须被点出来，不许为了"并入本机那份"把真没实现的能力也放行');
      expect(vtext, contains('本机没有提供能力 "no.such.capability"'),
          reason: '拦下还要说得出是哪个 id，让人间蒸发等于没拦');

      // 混合场景（有的能加载、有的读不出来）：doctor 不许把坏声明藏起来。
      // 第 81 轮查到、第 82 轮才修好 —— `picked.isEmpty` 那条分支第 75 轮就会点名了，
      // 漏的正是这条：以前坏声明整个不提，收尾印「✅ 没有真问题。」还退出 0（CI 上=体检通过）。
      expect(text, contains('读不出来的东西：'),
          reason: '有插件能加载时坏声明也必须点名；藏着 = 作者以为自己那份是好的');
      expect(text, contains('no.such.capability'), reason: '点名要点到具体是哪个 id 害的');
      expect(text, contains('个声明读不出来'),
          reason: '收尾那句必须报计数，而不是换回"没有真问题"那句好话');
      expect(text, contains('要看全部错误原文'),
          reason: '报了坏声明还得给出路：指到 validate 去看错误原文');
      expect(text, isNot(contains('✅ 没有真问题')),
          reason: '目录里明明有读不出来的声明，收尾那句就是谎话（反向判据，配上面几条一起看）');
      expect(r.exitCode, 1, reason: '有坏声明还退出 0，CI 上"体检通过"是假的');
    });
  });
}