/// 插件 CLI（P3 作者工具链）—— **纯逻辑 + 注入的文件系统**，因此能离线测试。
///
/// 真 IO 由 `tool/plugins.dart` 提供（`dart:io` 版实现），内核里一行 `dart:io` 都不许出现
/// （架构门的 A2 条）。四个子命令对应作者的一天：
///
/// ```
/// plugins.dart scaffold my-plugin --name 单词卡 --kind declarative   # 生成（自带自检）
/// plugins.dart validate ./plugins                                     # 装机前逐条校验
/// plugins.dart scan --plugins-dir ./plugins                           # 看加载终态与缺什么
/// plugins.dart reset --data-dir ./plugin_data --enabled --yes          # 清开关（词表数据默认不动）
/// plugins.dart doctor english-dictation                                 # 为什么没跑起来
/// ```
library;

import 'dart:convert';

import 'package:plugin_sdk/plugin_sdk.dart';

import 'capability_registry.dart';
import 'loader.dart';
import 'plugin_service.dart';
import 'scaffold.dart';

/// CLI 用到的文件操作（可注入 → 可用内存盘离线测）。
abstract interface class PluginCliIo {
  bool exists(String path);
  bool isDir(String path);
  List<String> listDir(String path);
  String? readString(String path);
  void writeString(String path, String content);
  void deleteFile(String path);
  void createDir(String path);
}

final class PluginCliResult {
  const PluginCliResult(this.exitCode, this.lines);
  final int exitCode;
  final List<String> lines;
}

/// 宿主真实提供的能力 id（由 app 传入，CLI 自己绝不猜）。
final class PluginCliConfig {
  const PluginCliConfig({required this.hostCapabilityIds, this.appVersion = '0.0.0'});
  final Set<String> hostCapabilityIds;
  final String appVersion;

  /// 校验口径 = 契约全集 ∪ 本机实现集（本机自己加的能力也算数）。
  Set<String> get validationCaps => kKnownCapabilityIds.union(hostCapabilityIds);
}

class PluginCli {
  PluginCli(this.io, this.config);

  final PluginCliIo io;
  final PluginCliConfig config;
  final List<String> _out = [];

  void _line([String s = '']) => _out.add(s);

  PluginCliResult run(List<String> args) {
    if (args.isEmpty || args.first == '--help' || args.first == 'help') {
      _usage();
      return PluginCliResult(args.isEmpty ? 1 : 0, List.unmodifiable(_out));
    }
    final cmd = args.first;
    final rest = args.sublist(1);
    switch (cmd) {
      case 'validate':
        return _exit(_validate(rest));
      case 'scan':
        return _exit(_scan(rest));
      case 'scaffold':
        return _exit(_scaffold(rest));
      case 'doctor':
        return _exit(_doctor(rest));
      case 'reset':
        return _exit(_reset(rest));
      default:
        _line('未知子命令：$cmd');
        _usage();
        return PluginCliResult(2, List.unmodifiable(_out));
    }
  }

  PluginCliResult _exit(bool ok) => PluginCliResult(ok ? 0 : 1, List.unmodifiable(_out));

  void _usage() {
    _line('''插件平台命令行

  plugins.dart validate [目录]                 逐个校验 plugin.json（默认 ./plugins）
  plugins.dart scan [--plugins-dir 目录]       用真·加载器看终态（active/gated/rejected/disabled）
  plugins.dart scaffold <id> [--name 名] [--desc 说明]
                [--kind declarative|dart] [--out 目录] [--force]
  plugins.dart reset [--data-dir 目录] [--enabled] [--store] --yes
  plugins.dart doctor [插件 id] [--plugins-dir 目录] [--data-dir 目录]
                为什么没跑起来的体检：状态 / 缺哪个能力 / 预算用了多少 / 启没启用 / 提醒几条

宿主能力清单由 app 传入（当前 ${config.hostCapabilityIds.length} 个），本机没有的会判为"待功能上线"。''');
  }

  // ——— validate ———

  Map<String, String> _flags(List<String> args) {
    final out = <String, String>{};
    final positional = <String>[];
    for (var i = 0; i < args.length; i++) {
      final a = args[i];
      if (a.startsWith('--')) {
        final key = a.substring(2);
        if (i + 1 < args.length && !args[i + 1].startsWith('--')) {
          out[key] = args[++i];
        } else {
          out[key] = 'true';
        }
      } else {
        positional.add(a);
      }
    }
    out['_positional'] = positional.join('\n');
    return out;
  }

  List<String> _positional(Map<String, String> flags) =>
      (flags['_positional'] ?? '').isEmpty ? const [] : (flags['_positional']!).split('\n');

  bool _validate(List<String> args) {
    final flags = _flags(args);
    final root = _positional(flags).isEmpty ? (flags['dir'] ?? 'plugins') : _positional(flags).first;
    if (!io.exists(root)) {
      _line('目录不存在：$root');
      _line('先用 scaffold 生成一个：dart run tool/plugins.dart scaffold my-plugin');
      return false;
    }
    final found = _declarations(root);
    if (found.isEmpty) {
      _line('$root 里没有找到任何 plugin.json');
      _line('提示：每个插件一个子目录，目录里放 plugin.json（声明式再放 prompt.md）。');
      return false;
    }
    var bad = 0;
    for (final e in found.entries) {
      final report = validateManifestText(e.value, knownCapabilityIds: config.validationCaps);
      if (report.ok && report.warnings.isEmpty) {
        _line('✅ ${e.key}');
        continue;
      }
      _line('${report.ok ? '⚠️' : '❌'} ${e.key}');
      for (final i in report.issues) {
        _line('   ${i.isError ? '错误' : '提醒'} [${i.code.name}] ${i.path}：${i.message}');
        if (i.hint != null) _line('        → ${i.hint}');
      }
      if (!report.ok) bad += 1;
    }
    _line('');
    _line(bad == 0 ? '共 ${found.length} 个声明，全部合格。' : '$bad/${found.length} 个声明不合格，装机也不会被加载。');
    return bad == 0;
  }

  /// 找声明：既支持 `root/<id>/plugin.json`，也支持 `root/plugin.json` 与 `root/<id>.json`。
  Map<String, String> _declarations(String root) {
    final out = <String, String>{};
    if (!io.isDir(root)) {
      final text = io.readString(root);
      if (text != null) out[root] = text;
      return out;
    }
    for (final name in io.listDir(root)) {
      final direct = '$root/$name/plugin.json';
      if (io.exists(direct)) {
        final text = io.readString(direct);
        if (text != null) out[direct] = text;
        continue;
      }
      if (name.endsWith('.json')) {
        final text = io.readString('$root/$name');
        if (text != null) out['$root/$name'] = text;
      }
    }
    final single = io.readString('$root/plugin.json');
    if (single != null) out['$root/plugin.json'] = single;
    return out;
  }

  // ——— scan ———

  /// 用真·加载器建一次快照（`scan` 与 `doctor` **共用同一套判据**）。
  ///
  /// 这条是纪律不是便利：CLI 与 app 里看到的终态必须一模一样，
  /// 否则作者按 CLI 改完、上真机还是不对，排查就变成"信哪个"。
  ({PluginLoader loader, _FileEnabledStore enabled, LoadResult? res, String? failure}) _load(
    String pluginsDir,
    String? dataDir,
  ) {
    final caps = CapabilityRegistry();
    for (final id in config.hostCapabilityIds) {
      caps.register(_HostStub(id), ownerPluginId: 'app');
    }

    final userDir = <String, ({String json, String? prompt})>{};
    if (io.isDir(pluginsDir)) {
      for (final e in _declarations(pluginsDir).entries) {
        final dirName = e.key
            .substring(pluginsDir.length + 1)
            .split('/')
            .firstWhere((s) => s.isNotEmpty && s != 'plugin.json');
        final promptPath = '${e.key.substring(0, e.key.length - 'plugin.json'.length)}prompt.md';
        userDir[dirName] = (json: e.value, prompt: io.readString(promptPath));
      }
    }

    final loader = PluginLoader(
      capabilities: caps,
      builtin: BuiltinSourceReader(),
      userSources: [DeclarationDirSourceReader(() => userDir)],
      appVersion: config.appVersion,
      knownCapabilityIds: config.validationCaps,
    );
    final enabled = _FileEnabledStore(io, dataDir);
    loader.setEnabledIds(enabled.read());

    final r = loader.scan();
    if (r.isErr) {
      return (loader: loader, enabled: enabled, res: null, failure: r.failureOrNull?.message ?? '未知原因');
    }
    return (loader: loader, enabled: enabled, res: r.valueOrNull!, failure: null);
  }

  bool _scan(List<String> args) {
    final flags = _flags(args);
    final pluginsDir = flags['plugins-dir'] ?? 'plugins';
    final dataDir = flags['data-dir'];

    final snap = _load(pluginsDir, dataDir);
    if (snap.res == null) {
      _line('扫描失败：${snap.failure}');
      return false;
    }
    final res = snap.res!;
    _line('插件目录：$pluginsDir（本机能力 ${config.hostCapabilityIds.length} 个，app ${config.appVersion}）');
    _line('');
    _line('状态       id                        名称              说明');
    for (final p in res.plugins) {
      final tag = switch (p.status) {
        PluginLoadStatus.active => '✅ 可运行',
        PluginLoadStatus.gated => '⏳ 待功能',
        PluginLoadStatus.rejected => '❌ 被拒',
        PluginLoadStatus.disabled => '⬜ 未启用',
      };
      final note = switch (p.status) {
        PluginLoadStatus.gated => '缺：${p.gatedOn.join('、')}',
        PluginLoadStatus.disabled => p.disabledReason ?? '可在面板里打开',
        PluginLoadStatus.rejected => (res.broken[p.descriptor.location]?.first.message) ?? '声明有问题',
        PluginLoadStatus.active => '${p.descriptor.manifest.effectiveRank} 优先级 · ${p.descriptor.location}',
      };
      _line('${tag.padRight(10)} ${p.id.padRight(25)} ${p.descriptor.manifest.name.padRight(16)} $note');
    }
    if (res.shadowed.isNotEmpty) {
      _line('');
      for (final e in res.shadowed.entries) {
        _line('🔁 ${e.key}：${e.value}');
      }
    }
    if (res.broken.isNotEmpty) {
      _line('');
      _line('读不出来的东西：');
      for (final e in res.broken.entries) {
        _line('  ❌ ${e.key}');
        for (final i in e.value) {
          _line('       ${i.path}：${i.message}');
        }
      }
    }
    if (res.usedLastGood) {
      _line('');
      _line('⚠️ 本轮没读到最新清单，沿用了上一次的结果。');
    }
    _line('');
    _line('合计：${res.byStatus(PluginLoadStatus.active).length} 可运行 / '
        '${res.byStatus(PluginLoadStatus.gated).length} 待功能 / '
        '${res.byStatus(PluginLoadStatus.rejected).length} 被拒 / '
        '${res.byStatus(PluginLoadStatus.disabled).length} 未启用'
        '${res.broken.isEmpty ? '' : ' / ${res.broken.length} 个读不出来（见上面 ❌）'}');
    if (res.plugins.isEmpty) {
      _line('（目录是空的。生成一个：dart run tool/plugins.dart scaffold my-plugin）');
    }
    if (res.byStatus(PluginLoadStatus.disabled).isNotEmpty) {
      _line('提示：未启用的插件在 app「设置 → 插件」里打开，或用 reset 清空开关。');
    }
    return true;
  }

  // ——— scaffold ———

  bool _scaffold(List<String> args) {
    final flags = _flags(args);
    final pos = _positional(flags);
    if (pos.isEmpty) {
      _line('缺少插件 id（例：scaffold my-plugin）');
      return false;
    }
    final id = pos.first;
    final spec = ScaffoldSpec(
      id: id,
      name: flags['name'] ?? id,
      description: flags['desc'] ?? '（写一句这个插件干什么，面板与智能体都靠它决定要不要用）',
      kind: flags['kind'] == 'dart' ? ScaffoldKind.dart : ScaffoldKind.declarative,
      whenToUse: flags['whenToUse'] ?? '',
      ownerDataHint: flags['hint'] ?? '',
    );
    final files = generatePluginFiles(spec);
    final check = selfCheckGenerated(files, knownCapabilityIds: config.validationCaps);
    if (check.isErr) {
      _line('❌ 生成物没通过自检，已拒绝写盘：${check.failureOrNull?.message}');
      _line('   ${check.failureOrNull?.hint ?? ''}');
      return false;
    }
    final out = flags['out'] ?? (spec.kind == ScaffoldKind.declarative ? 'plugins/$id' : 'lib/plugins/builtin/$id');
    if (io.isDir(out) && flags['force'] != 'true') {
      _line('目录已存在：$out（要覆盖加 --force）');
      return false;
    }
    io.createDir(out);
    for (final e in files.entries) {
      final path = '$out/${e.key}';
      if (io.exists(path) && flags['force'] != 'true') {
        _line('↷ 已存在，跳过：$path');
        continue;
      }
      io.writeString(path, e.value);
      _line('✍️  $path（${e.value.length} 字符）');
    }
    _line('');
    _line('自检通过（宿主能力 ${config.hostCapabilityIds.length} 个都齐）。下一步：');
    _line('  dart run tool/plugins.dart validate ${flags['out'] ?? 'plugins'}');
    if (spec.kind == ScaffoldKind.declarative) {
      _line('  然后整目录推到手机 文档/plugins/$id/ ，在「设置 → 插件」里重新扫描并打开。');
    } else {
      _line('  把 $id 注册进 lib/plugins/plugin_host.dart 的 builtin.register(...)，跑 conformance 测试。');
    }
    return true;
  }

  // ——— reset ———

  // ——— doctor ———

  /// 一条命令回答**"我这个插件为什么没跑起来 / 本机到底有什么"**。
  ///
  /// 作者排障最贵的不是改，是猜：状态判成了"待功能"，到底是缺能力、缺模型、还是没启用？
  /// 这里把判据全摊开（状态 / 缺哪个能力 / 预算用了多少 / 启没启用 / 提醒几条），
  /// 并且**每条末尾必须给一句"怎么办"** —— 只报状态不给出路的工具，最后都变成截图来回。
  bool _doctor(List<String> args) {
    final flags = _flags(args);
    final pluginsDir = flags['plugins-dir'] ?? 'plugins';
    final dataDir = flags['data-dir'];
    final wanted = _positional(flags).isEmpty ? null : _positional(flags).first;

    final snap = _load(pluginsDir, dataDir);
    if (snap.res == null) {
      _line('体检做不了：扫描本身就失败了 —— ${snap.failure}');
      return false;
    }
    final res = snap.res!;
    final enabledIds = snap.enabled.read();
    final seenIds = snap.enabled.seen();

    final picked = <LoadedPlugin>[
      for (final p in res.plugins)
        if (wanted == null || p.id == wanted) p,
    ];
    if (picked.isEmpty) {
      // 「没找到插件」是这句最坏的写法：作者会去查目录名，而真相是自己把 plugin.json 写坏了。
      // 目录里确实有声明、只是全都读不出来时，**首要一行就得说这件事，并把第一条错误原文带上**
      // （只说"先跑 validate"等于把已经算出来的答案又塞回另一个命令里）。
      if (wanted == null && res.broken.isNotEmpty) {
        _line('目录 $pluginsDir 里没有能加载的插件，但有 ${res.broken.length} 个声明读不出来：');
        for (final e in res.broken.entries) {
          if (e.value.isEmpty) {
            _line('  · ${e.key}：（没有更细的原因，跑 validate 看原文）');
            continue;
          }
          _line('  · ${e.key}：${e.value.first.message}');
          for (final extra in e.value.skip(1).take(2)) {
            _line('      · ${extra.path}：${extra.message}');
          }
          final hint = e.value.first.hint;
          if (hint != null) _line('      → $hint');
        }
        _line('改完再跑一次 doctor；要看全部错误原文：plugin_kernel cli validate $pluginsDir');
        return false;
      }
      _line(wanted == null
          ? '目录 $pluginsDir 里一个插件都没有（每个插件一个子目录，目录里放 plugin.json）。'
          : '没找到插件「$wanted」（目录 $pluginsDir）。');
      if (res.plugins.isNotEmpty) {
        _line('这些可选：');
        for (final p in res.plugins) {
          _line('  · ${p.id}（${p.descriptor.manifest.name}）');
        }
      }
      if (res.broken.isNotEmpty) {
        _line('另外这些声明根本读不出来：${res.broken.keys.join('、')} —— 先跑 validate 看错误原文');
      }
      return false;
    }

    _line('插件体检：${picked.length} 个（目录 $pluginsDir · 本机能力 ${config.hostCapabilityIds.length} 个 · app ${config.appVersion}）');
    _skippedDirs(pluginsDir);
    var blocked = 0;
    var cliSideOnly = 0;
    var pendingSeed = 0;
    for (final p in picked) {
      _line('');
      _reportOne(p, res, enabledIds, seenIds);
      if (_cliSideOnlyGate(p)) {
        cliSideOnly++;
      } else if (p.status == PluginLoadStatus.disabled &&
          p.descriptor.manifest.enabledByDefault &&
          !seenIds.contains(p.id)) {
        // CLI 不模拟首次播种：它在 app 里其实会自动打开 —— 不能算作者的问题。
        pendingSeed++;
      } else if (p.status != PluginLoadStatus.active) {
        blocked++;
      }
    }
    _line('');
    if (pendingSeed > 0) {
      _line('其中 $pendingSeed 个写着 enabledByDefault、还没被 app 扫过 —— 装进 app 第一次扫到会自动打开，不用你动手。');
    }
    // **混合场景**（有的能加载、有的读不出来）以前会把坏声明整个藏起来，收尾还印
    // 「✅ 没有真问题。」—— 第 82 轮修：读不出来的必须点名，而且不许在有坏声明时说那两句好话。
    // （`picked.isEmpty` 那条分支第 75 轮就已经会点名了；漏的是这条。）
    final brokenHere = res.broken.entries
        .where((e) => !picked.any((p) => p.descriptor.location == e.key))
        .toList();
    if (blocked > 0) {
      _line('有 $blocked 个跑不了 —— 照每条最后的「怎么办」做，再跑一次 doctor。');
    } else if (res.broken.isNotEmpty) {
      _line('⚠️ ${res.broken.length} 个声明读不出来 —— 有坏声明的时候不许印"没有真问题 / 全部可运行"。');
    } else if (cliSideOnly > 0) {
      _line('✅ 没有真问题。（$cliSideOnly 个声明式插件在 CLI 里显示"待功能"是正常的：'
          'flow 引擎在 app 里，CLI 进程没有它 —— 装进 app 启用就能跑）');
    } else {
      _line('✅ 全部可运行。');
    }
    if (brokenHere.isNotEmpty) {
      _line('');
      _line('读不出来的东西：');
      for (final e in brokenHere) {
        _line('  ❌ ${e.key}');
        for (final i in e.value.take(3)) {
          _line('       ${i.path}：${i.message}');
        }
        final hint = e.value.isEmpty ? null : e.value.first.hint;
        if (hint != null) _line('       → $hint');
      }
      _line('要看全部错误原文：dart run tool/plugins.dart validate $pluginsDir');
    }
    return blocked == 0 && res.broken.isEmpty;
  }

  /// 被跳过的目录要说出来，而且**必须分类**："我明明放了两份声明怎么一个都没见到"是最高频的一句。
  ///
  /// 三种情况在"目录里没有 plugin.json"这一层长得一模一样，出路却完全不同，
  /// 混成一句就等于没说：
  /// ① 声明其实藏在更里面一层（示例目录常有这种套法）；
  /// ② 那是个 Dart 包 —— 代码级插件的示例，要编进 app 才跑得起来，CLI 本来判不了它；
  /// ③ 真的什么都没有（目录名拼错、忘放文件）。
  void _skippedDirs(String pluginsDir) {
    if (!io.isDir(pluginsDir)) return;
    final nested = <String, String>{};
    final packages = <String>[];
    final bare = <String>[];
    for (final name in io.listDir(pluginsDir)) {
      final dir = '$pluginsDir/$name';
      if (!io.isDir(dir)) continue;
      if (io.exists('$dir/plugin.json')) continue;
      final inner = [for (final sub in io.listDir(dir)) if (io.exists('$dir/$sub/plugin.json')) '$dir/$sub'];
      if (inner.isNotEmpty) {
        // 一个目录可以同时是"Dart 包 + 里面装着声明"（examples/hello_plugin 就这样）——
        // 两件事都要说，只报一件等于让作者猜另一半。
        nested[dir] = inner.join('、') +
            (io.exists('$dir/pubspec.yaml') ? '（它同时是个 Dart 包，dart test 归它自己跑）' : '');
      } else if (io.exists('$dir/pubspec.yaml')) {
        packages.add(dir);
      } else {
        bare.add(dir);
      }
    }
    if (nested.isEmpty && packages.isEmpty && bare.isEmpty) return;
    _line('');
    for (final e in nested.entries) {
      _line('📁 ${e.key}：声明在更里面一层（${e.value}）—— 规矩是"一层目录 = 一个插件"，'
          '要装它就那一层单独指给 --plugins-dir');
    }
    for (final d in packages) {
      _line('📦 $d：代码级插件的 Dart 包（有 pubspec.yaml），要编进 app 才跑得起来 —— '
          'CLI 判不了它（磁盘上的 Dart 代码今天加载不了），跑它自己的 dart test');
    }
    if (bare.isNotEmpty) {
      _line('⬜ 没有 plugin.json 的目录：${bare.join('、')} —— 目录名拼错、忘放文件都会这样；'
          '新插件用 scaffold 生成最省事');
    }
  }

  /// 只因为"CLI 这个进程里没有 flow 引擎"而停下的，不算插件的毛病。
  ///
  /// 声明式插件的实现体由装配根注入（`declarativeFactory`），CLI 本来就没接。
  /// 把这算成"跑不了"，作者就会去改一份本来没问题的 `plugin.json` ——
  /// 工具的每一句判词都必须说清**是谁的问题**。
  bool _cliSideOnlyGate(LoadedPlugin p) =>
      p.status == PluginLoadStatus.gated &&
      p.gatedOn.length == 1 &&
      p.gatedOn.first == 'flow.runner' &&
      p.descriptor.isDeclarative;

  void _reportOne(LoadedPlugin p, LoadResult res, Set<String> enabledIds, Set<String> seenIds) {
    final m = p.descriptor.manifest;
    final cliOnly = _cliSideOnlyGate(p);
    final tag = cliOnly
        ? '📱 只在 app 里跑'
        : switch (p.status) {
            PluginLoadStatus.active => '✅ 可运行',
            PluginLoadStatus.gated => '⏳ 待功能',
            PluginLoadStatus.rejected => '❌ 被拒',
            PluginLoadStatus.disabled => '⬜ 未启用',
          };
    _line('🩺 ${p.id} · ${m.name}　$tag');
    _line('   声明：${p.descriptor.location}');

    // **本机有没有 ≠ 契约认不认**：net.search 是合法 id，但这台机器可能根本没实现它。
    // 这里问的必须是本机（validationCaps 会把"合法但没实现"洗成"全有"，那就白体检了）。
    final missing = [for (final c in m.inject) if (!config.hostCapabilityIds.contains(c)) c];
    _line('   能力：inject ${m.inject.length} 项'
        '${missing.isEmpty ? '，本机全有' : '，本机缺 ${missing.length}：${missing.join('、')}'}');
    _line('   权限：${m.permissions.isEmpty ? '（一个都没声明 —— 取任何能力都会被拒）' : m.permissions.map((e) => e.wireName).join('、')}');

    final jsonBytes = utf8.encode(p.descriptor.rawJson ?? '').length;
    final promptBytes = utf8.encode(p.descriptor.promptText ?? '').length;
    _line('   预算：plugin.json $jsonBytes/$kMaxManifestBytes B · prompt.md $promptBytes/$kMaxPromptBytes B · '
        '参数 ${m.params.length}/12');
    // 「未启用」有三种完全不同的意思，报告必须分得开：默认没开 / 被手动关过 / 声明了默认开但还没被扫过。
    final pendingSeed = p.descriptor.manifest.enabledByDefault && !seenIds.contains(p.id);
    _line('   启用：${enabledIds.contains(p.id) ? '已启用' : pendingSeed ? '未启用，但它写了 enabledByDefault —— app 第一次扫到会自动打开' : '未启用（app 的「设置 → 插件」里打开，或 reset --enabled 清开关重来）'}'
        '；方案档在 app 侧，CLI 看不到');

    final errs = p.descriptor.issues.where((i) => i.isError).toList();
    final warns = p.descriptor.issues.where((i) => !i.isError).toList();
    if (errs.isNotEmpty) _line('   硬问题：${errs.map((e) => '${e.path}：${e.message}').join('；')}');
    if (warns.isNotEmpty) _line('   声明提醒 ${warns.length} 条：${warns.map((e) => '${e.path}：${e.message}').join('；')}');
    final shadow = res.shadowed[p.id];
    if (shadow != null) _line('   同名覆盖：$shadow');

    final how = cliOnly
        ? '不用管它 —— 在 app 的「设置 → 插件」里启用就能跑；CLI 进程没有 flow 引擎，这条是 CLI 的边界'
        : switch (p.status) {
      PluginLoadStatus.active => null,
      PluginLoadStatus.gated =>
        p.gatedHint ?? '本机还缺：${p.gatedOn.join('、')} —— 升级 app、加载对应模型，或在设置里打开相关开关',
      PluginLoadStatus.rejected =>
        (res.broken[p.descriptor.location]?.first.hint) ?? '照上面的硬问题改 plugin.json，然后重新跑 doctor',
      PluginLoadStatus.disabled => pendingSeed
          ? '什么都不用做 —— app 第一次扫到它会按 enabledByDefault 自动打开；要是你在 app 里看到它是关的，说明被手动关过，去面板再打开'
          : p.disabledReason ?? '在 app 的「设置 → 插件」里把它打开',
    };
    if (how != null) _line('   怎么办：$how');
  }

  bool _reset(List<String> args) {
    final flags = _flags(args);
    final dataDir = flags['data-dir'] ?? 'plugin_data';
    final all = flags['enabled'] != 'true' && flags['store'] != 'true';
    var touched = 0;
    void drop(String name, String label) {
      final path = '$dataDir/$name';
      if (!io.exists(path)) {
        _line('（没有 $label，跳过）');
        return;
      }
      if (flags['yes'] != 'true') {
        _line('将删除 $label：$path —— 加 --yes 确认（防止误删用户攒下来的词表）');
        return;
      }
      io.deleteFile(path);
      touched += 1;
      _line('🗑  已删 $label：$path');
    }

    // 开关不能整包删：这个文件里还住着宿主的**首次播种账本** `plugin.seen`。
    // 删了它，所有插件都退回"第一次见到" —— 用户推回手机后会被 `enabledByDefault` 集体重新打开，
    // 那些他亲手关掉的又亮了，而且没人说得清为什么。
    void dropEnabled() {
      final path = '$dataDir/plugin_enabled.json';
      if (!io.exists(path)) {
        _line('（没有 插件开关，跳过）');
        return;
      }
      if (flags['yes'] != 'true') {
        _line('将清空 插件开关：$path —— 加 --yes 确认（同文件的首次播种账本 `plugin.seen` 会留着）');
        return;
      }
      var rest = <String, Object?>{};
      try {
        final decoded = jsonDecode(io.readString(path) ?? '');
        if (decoded is Map) rest = Map<String, Object?>.from(decoded)..remove('plugin.enabled');
      } catch (_) {
        rest = <String, Object?>{}; // 坏文件：没什么要留的
      }
      if (rest.isEmpty) {
        io.deleteFile(path);
      } else {
        io.writeString(path, jsonEncode(rest));
      }
      touched += 1;
      _line('🗑  已清空 插件开关：$path（`plugin.seen` 留着 —— 否则插件会被当成第一次见到而集体自动打开）');
    }

    if (all || flags['enabled'] == 'true') dropEnabled();
    if (all || flags['store'] == 'true') drop('plugin_store.json', '插件数据（所有插件的 KV）');
    if (flags['yes'] != 'true') {
      _line('');
      _line('没动任何东西。');
      return false;
    }
    _line(touched == 0 ? '什么都没要删（目录 $dataDir 是空的？）。' : '完成，删了 $touched 个文件。');
    return true;
  }
}

/// 只为让 loader 判定"本机有这个能力"的最小实现（scan 不做真活儿）。
final class _HostStub with CapabilityBase implements Capability {
  _HostStub(this._id);
  final String _id;

  @override
  ServiceKey get key => ServiceKey(_id);

  @override
  bool get available => true;

  @override
  String? get unavailableReason => null;
}

/// CLI 侧的开关存储（与 app 的 `FileEnabledStore` 同一文件格式，两边口径一致）。
final class _FileEnabledStore implements EnabledStore {
  _FileEnabledStore(this._io, this._dir);
  final PluginCliIo _io;
  final String? _dir;

  String get _path => '${_dir ?? 'plugin_data'}/plugin_enabled.json';

  @override
  Set<String> read() {
    final text = _io.readString(_path);
    if (text == null) return const {};
    try {
      final m = jsonDecode(text);
      if (m is Map && m['plugin.enabled'] is List) {
        return (m['plugin.enabled'] as List).whereType<String>().toSet();
      }
    } catch (_) {
      // 坏文件当没启用（scan 只是给人看的，不影响 app）
    }
    return const {};
  }

  @override
  void write(Set<String> enabledIds) {
    // **读-改-写**：这个文件里不止 `plugin.enabled`，还有宿主的 `plugin.seen`（首次播种账本）。
    // 整包重写会把账本洗掉 —— 用户把 data-dir 里的文件推回手机后，所有插件都变成"第一次见到"，
    // 被 `enabledByDefault` 集体重新打开：用户明明关掉的开关，一次 `reset --enabled` 就全回来了。
    Object? existing;
    try {
      final decoded = jsonDecode(_io.readString(_path) ?? '');
      if (decoded is Map) existing = decoded;
    } catch (_) {
      existing = null; // 坏文件当空的（与读侧同一口径）
    }
    final data = <String, Object?>{
      if (existing is Map) ...Map<String, Object?>.from(existing),
      'plugin.enabled': enabledIds.toList(),
    };
    _io.writeString(_path, jsonEncode(data));
  }

  /// `plugin.seen`（宿主记的"第一次见过"账本）。CLI 用它区分
  /// "**还没被 app 扫过**"（会自动打开，不是作者的问题）与"**开过又被关掉**"（真的关着）。
  Set<String> seen() {
    final text = _io.readString(_path);
    if (text == null) return const {};
    try {
      final m = jsonDecode(text);
      if (m is Map && m['plugin.seen'] is List) {
        return (m['plugin.seen'] as List).whereType<String>().toSet();
      }
    } catch (_) {}
    return const {};
  }
}
