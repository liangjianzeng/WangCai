// 引擎商店（§5.1/§5.2）离线单测：假下载器 + 真 zip 解包 + 假命令输出。
// 全程不联网、不依赖 GPU。
import 'dart:convert';
import 'dart:io';

import 'package:archive/archive_io.dart';
import 'package:crypto/crypto.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:wangcai/engine/engine_paths.dart';
import 'package:wangcai/engine/engine_store.dart';

List<int> _zipWithServer() {
  final arch = Archive()
    ..addFile(ArchiveFile('llama-server.exe', 4, utf8.encode('FAKE')))
    ..addFile(ArchiveFile('ggml-cuda.dll', 3, utf8.encode('DLL')))
    ..addFile(ArchiveFile('README.md', 2, utf8.encode('RM')));
  return ZipEncoder().encode(arch)!;
}

Future<void> _rm(Directory d) async {
  for (var i = 0; i < 10; i++) {
    try {
      if (d.existsSync()) d.deleteSync(recursive: true);
      return;
    } catch (_) {
      await Future<void>.delayed(const Duration(milliseconds: 50));
    }
  }
}

void main() {
  late Directory tmp;
  late EnginePaths paths;

  setUp(() {
    tmp = Directory.systemTemp.createTempSync('wc_store');
    paths = EnginePaths.root(tmp);
  });
  tearDown(() => _rm(tmp));

  group('StoreCatalog / URL', () {
    test('find/latest 与镜像 URL 拼接（assetName 显式数据，含缺省推导）', () {
      final cat = StoreCatalog.fromJson({
        'releases': [
          {'version': 'b6010', 'variant': 'vulkan', 'sha256': 'aa'}, // 无 assetName → 推导
          {'version': 'b6100', 'variant': 'vulkan', 'sha256': 'bb'},
          {
            'version': 'b6100',
            'variant': 'cuda',
            'assetName': 'llama-b6100-bin-win-cuda-12.4-x64.zip',
            'sha256': 'cc',
          },
        ],
      });
      expect(cat.find('b6010', 'vulkan')!.sha256, 'aa');
      expect(cat.find('b6010', 'vulkan')!.assetName, 'llama-b6010-bin-win-vulkan-x64.zip');
      expect(cat.latest('vulkan')!.version, 'b6100');
      expect(cat.latest('cuda')!.version, 'b6100');
      final r = cat.find('b6100', 'cuda')!;
      expect(r.assetName, 'llama-b6100-bin-win-cuda-12.4-x64.zip');
      final urls = r.downloadUrls(mirrorPrefixes: ['https://ghproxy.example/']);
      expect(urls.first,
          'https://github.com/ggml-org/llama.cpp/releases/download/b6100/llama-b6100-bin-win-cuda-12.4-x64.zip');
      expect(urls[1],
          'https://ghproxy.example/github.com/ggml-org/llama.cpp/releases/download/b6100/llama-b6100-bin-win-cuda-12.4-x64.zip');
    });
  });

  group('install：下载→校验→解包', () {
    test('sha256 正确：解包出 llama-server.exe，dll 同落', () async {
      final zip = _zipWithServer();
      final good = sha256.convert(zip).toString();
      final store = EngineStore(paths, downloader: (url, dest) async {
        await File(dest).writeAsBytes(zip);
      });
      final res = await store
          .install(StoreRelease(version: 'b1', variant: 'vulkan', assetName: 'llama-b1-bin-win-vulkan-x64.zip', sha256: good));
      expect(res.ok, isTrue, reason: res.error);
      expect(File(res.serverExe!).existsSync(), isTrue);
      expect(
          File('${res.dir}${Platform.pathSeparator}ggml-cuda.dll').existsSync(),
          isTrue);
      expect(await File('${res.dir}.zip.tmp').exists(), isFalse,
          reason: '成功路径不留 tmp');
    });

    test('sha256 不符：拒绝并清 tmp', () async {
      final zip = _zipWithServer();
      final store = EngineStore(paths, downloader: (url, dest) async {
        await File(dest).writeAsBytes(zip);
      });
      final res = await store.install(
          StoreRelease(version: 'b1', variant: 'vulkan', assetName: 'llama-b1-bin-win-vulkan-x64.zip', sha256: 'deadbeef'));
      expect(res.ok, isFalse);
      expect(res.error, contains('sha256'));
      expect(await File('${res.dir}.zip.tmp').exists(), isFalse);
    });

    test('镜像回退：首个 URL 失败 → 镜像成功', () async {
      final zip = _zipWithServer();
      final good = sha256.convert(zip).toString();
      final tried = <String>[];
      final store = EngineStore(paths, downloader: (url, dest) async {
        tried.add(url);
        if (tried.length == 1) throw Exception('github 不通');
        await File(dest).writeAsBytes(zip);
      });
      final res = await store.install(
          StoreRelease(version: 'b1', variant: 'vulkan', assetName: 'llama-b1-bin-win-vulkan-x64.zip', sha256: good),
          mirrorPrefixes: ['https://mirror.example']);
      expect(res.ok, isTrue, reason: res.error);
      expect(tried, hasLength(2));
    });

    test('全部失败：error 报告、无残留', () async {
      final store = EngineStore(paths, downloader: (url, dest) async {
        throw Exception('网络不可达');
      });
      final res = await store
          .install(StoreRelease(version: 'b1', variant: 'cuda', assetName: 'llama-b1-bin-win-cuda-x64.zip', sha256: 'x'));
      expect(res.ok, isFalse);
      expect(res.error, contains('镜像'));
    });
  });

  group('探测解析（§5.2）', () {
    test('--list-devices 行 → 设备名列表（新旧两种官方措辞）', () {
      const legacy = '''
Available devices:
  Device 0: "NVIDIA GeForce RTX 5060 Ti"
  Device 1: "Intel(R) UHD Graphics"
''';
      expect(EngineStore.parseListDevices(legacy), [
        'NVIDIA GeForce RTX 5060 Ti',
        'Intel(R) UHD Graphics',
      ]);
      // b12034 实测格式（含显存标注尾巴）。
      const modern = '''
Available devices:
  Vulkan0: Intel(R) Graphics (27651 MiB, 27651 MiB free)
  Vulkan1: NVIDIA GeForce RTX 5060 Ti (16050 MiB, 15282 MiB free)
''';
      expect(EngineStore.parseListDevices(modern), [
        'Intel(R) Graphics',
        'NVIDIA GeForce RTX 5060 Ti',
      ]);
      expect(EngineStore.parseListDevices('no devices here'), isEmpty);
    });

    test('nvidia-smi csv → CudaInfo + Blackwell 驱动门槛', () {
      final a = EngineStore.parseNvidiaSmi('NVIDIA GeForce RTX 5060 Ti, 572.16')!;
      expect(a.name, contains('5060 Ti'));
      expect(a.blackwellReady, isTrue);
      final b = EngineStore.parseNvidiaSmi('RTX 3060, 550.90')!;
      expect(b.blackwellReady, isFalse);
      expect(EngineStore.parseNvidiaSmi('garbage'), isNull);
    });

    test('注入 runner：cuda()/vulkanDevices() 走假命令', () async {
      final store = EngineStore(paths, runner: (exe, args) async {
        if (exe == 'nvidia-smi') {
          return const CmdResult(0, 'NVIDIA GeForce RTX 5060 Ti, 572.62\n', '');
        }
        return const CmdResult(
            0, 'Available devices:\n  Device 0: "Intel UHD"\n', '');
      });
      final cuda = await store.cuda();
      expect(cuda!.blackwellReady, isTrue);
      expect(await store.vulkanDevices('X:/fake/llama-server.exe'), ['Intel UHD']);
    });

    test('runner 返回 null（命令不存在）→ 不可用', () async {
      final store = EngineStore(paths, runner: (exe, args) async => null);
      expect(await store.cuda(), isNull);
      expect(await store.vulkanDevices('x'), isEmpty);
    });

    test('npuDriverVersion（世代自适应 2026-11-05）：输出裁决', () async {
      final ok = EngineStore(paths, runner: (exe, args) async {
        expect(exe, 'powershell.exe');
        // CIM 查询命令必须同时覆盖两代枚举名。
        expect(args.join(' '), contains('AI Boost'));
        expect(args.join(' '), contains(r'\(R\) NPU'));
        return const CmdResult(0, ' 32.0.100.3800 \n', '');
      });
      expect(await ok.npuDriverVersion(), '32.0.100.3800');
      final fail = EngineStore(
          paths, runner: (exe, args) async => const CmdResult(1, '', 'nope'));
      expect(await fail.npuDriverVersion(), isNull);
      final nul = EngineStore(
          paths, runner: (exe, args) async => const CmdResult(0, 'null\n', ''));
      expect(await nul.npuDriverVersion(), isNull, reason: 'CIM 无设备输出字面 null');
      final gone = EngineStore(paths, runner: (exe, args) async => null);
      expect(await gone.npuDriverVersion(), isNull);
    }, skip: !Platform.isWindows);
  });

  test('sha256File 与 crypto 直算一致', () async {
    final f = File('${tmp.path}${Platform.pathSeparator}x.bin')
      ..writeAsBytesSync(List.generate(100000, (i) => i % 251));
    expect(await EngineStore.sha256File(f),
        sha256.convert(f.readAsBytesSync()).toString());
  });
}
