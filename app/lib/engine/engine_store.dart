// 引擎商店（设计 §5.1/§5.2）：官方 llama.cpp Windows release 的获取与探测。
//   下载：GitHub Releases（ghproxy 镜像兜底）→ .tmp → sha256 校验 → 解包到
//         engines/llamacpp-<ver>-{vulkan,cuda}/（D4：各自完整 runtime）。
//   探测：Vulkan `llama-server --list-devices` 枚举；CUDA `nvidia-smi` 存在性
//         + 驱动版本（Blackwell sm_120 需新构建；不满足 UI 置灰退 Vulkan）。
// 网络/进程/时钟全部可注入 —— 单测不联网、不依赖开发机 GPU。
import 'dart:convert';
import 'dart:io';

import 'package:archive/archive_io.dart';
import 'package:crypto/crypto.dart';
import 'package:dio/dio.dart';

import 'engine_paths.dart';

class StoreRelease {
  const StoreRelease({
    required this.version, // 'b12034'
    required this.variant, // 'vulkan' | 'cuda'
    required this.assetName, // 官方资产名（带 cuda 版本段，如
    // 'llama-b12034-bin-win-cuda-12.4-x64.zip'）—— 数据不是模板，官方命名会变。
    required this.sha256, // 官方包实算钉死（白名单数据，不是代码）
  });

  final String version;
  final String variant;
  final String assetName;
  final String sha256;

  String get installDirName => 'llamacpp-$version-$variant';
  String githubUrl({String repo = 'ggml-org/llama.cpp'}) =>
      'https://github.com/$repo/releases/download/$version/$assetName';
  List<String> downloadUrls({List<String> mirrorPrefixes = const []}) => [
        githubUrl(),
        ...mirrorPrefixes.map((m) {
          final base = m.endsWith('/') ? m.substring(0, m.length - 1) : m;
          return '$base/${githubUrl().replaceFirst('https://', '')}';
        }),
      ];
}

/// 版本白名单（设计 §5.1：manifest 钉「已验证版本」，UI 一键装/升/回滚）。
/// 装机验证过的才进表；sha256 为官方 release 包实算（2026-11-03 钉 b12034）。
class StoreCatalog {
  /// 装机验证集（官方 ggml-org/llama.cpp release b12034）。
  static const StoreCatalog verified = StoreCatalog([
    StoreRelease(
      version: 'b12034',
      variant: 'vulkan',
      assetName: 'llama-b12034-bin-win-vulkan-x64.zip',
      sha256: 'df6ab37942d02aeb8ab3de5984711ea866826a94d50f7a9c5960a0d18a9d4269',
    ),
    StoreRelease(
      version: 'b12034',
      variant: 'cuda',
      assetName: 'llama-b12034-bin-win-cuda-12.4-x64.zip',
      sha256: '9ccf4900c6d41e0e27b58d2f6db190918c89c83e26a62565f325ae5f36a3c0d4',
    ),
  ]);

  const StoreCatalog(this.releases);

  final List<StoreRelease> releases;

  factory StoreCatalog.fromJson(dynamic j) {
    final list = (j is Map && j['releases'] is List) ? j['releases'] as List : const [];
    return StoreCatalog([
      for (final e in list.whereType<Map>())
        StoreRelease(
          version: '${e['version']}',
          variant: '${e['variant']}',
          assetName: '${e['assetName'] ?? 'llama-${e['version']}-bin-win-${e['variant']}-x64.zip'}',
          sha256: '${e['sha256']}'.toLowerCase(),
        ),
    ]);
  }

  Map<String, dynamic> toJson() => {
        'releases': [
          for (final r in releases)
            {
              'version': r.version,
              'variant': r.variant,
              'assetName': r.assetName,
              'sha256': r.sha256,
            },
        ],
      };

  StoreRelease? find(String version, String variant) {
    for (final r in releases) {
      if (r.version == version && r.variant == variant) return r;
    }
    return null;
  }

  /// 同 variant 的最新白名单条目（UI「一键升级」目标）。
  StoreRelease? latest(String variant) {
    StoreRelease? best;
    for (final r in releases) {
      if (r.variant != variant) continue;
      if (best == null || _verKey(r.version) > _verKey(best.version)) best = r;
    }
    return best;
  }

  static int _verKey(String v) => int.tryParse(v.replaceFirst('b', '')) ?? 0;
}

/// 下载器抽象（测试注入假实现）。
typedef Downloader = Future<void> Function(String url, String destPath);

/// 命令执行抽象（探测用；测试注入假输出）。
class CmdResult {
  const CmdResult(this.exitCode, this.stdout, this.stderr);
  final int exitCode;
  final String stdout;
  final String stderr;
  bool get ok => exitCode == 0;
  String get all => '$stdout\n$stderr';
}

typedef CmdRunner = Future<CmdResult?> Function(String exe, List<String> args);

class InstallResult {
  const InstallResult({required this.serverExe, required this.dir, this.error});
  final String? serverExe;
  final String dir;
  final String? error;
  bool get ok => serverExe != null && error == null;
}

class EngineStore {
  EngineStore(
    this.paths, {
    Dio? dio,
    Downloader? downloader,
    CmdRunner? runner,
    Directory? enginesDirOverride,
  })  : _dio = dio ?? Dio(BaseOptions(connectTimeout: const Duration(seconds: 8))),
        _downloader = downloader,
        _runner = runner ?? _realRunner,
        _enginesDirOverride = enginesDirOverride;

  final EnginePaths paths;
  final Dio _dio;
  final Downloader? _downloader;
  final CmdRunner _runner;

  /// 安装根目录覆写（Phase 3c）：settings `enginesDir` 用户自选目录；
  /// null = 默认 paths.enginesDir（数据区之下）。
  final Directory? _enginesDirOverride;
  Directory get enginesRoot => _enginesDirOverride ?? paths.enginesDir;

  Directory dirFor(StoreRelease r) => Directory(
      '${enginesRoot.path}${Platform.pathSeparator}${r.installDirName}');

  /// 扫描目录识别现成 llama.cpp 引擎（v0.0.3 用户反馈：用户自选目录里的
  /// 引擎要能被自动认出来，而不是只有商店装的才算数）。
  /// 在 [root] 下 ≤[maxDepth] 层找 llama-server.exe，按**所在目录名**推断
  /// 变体（含 'cuda'→cuda、'vulkan'→vulkan，大小写不敏感）；同名变体取
  /// 先遇到的；识别不了的目录跳过（商店目录名 llamacpp-<ver>-<variant>
  /// 天然命中）。返回 变体 id → exe 绝对路径。
  static Map<String, String> discoverEngineExes(Directory root,
      {int maxDepth = 2}) {
    final out = <String, String>{};
    if (!root.existsSync()) return out;
    void walk(Directory dir, int depth) {
      if (depth > maxDepth) return;
      for (final e in dir.listSync(followLinks: false)) {
        if (e is File && e.path.endsWith('llama-server.exe')) {
          final segs = dir.path.split(Platform.pathSeparator);
          final name = segs.isEmpty ? '' : segs.last.toLowerCase();
          final variant = name.contains('cuda')
              ? 'cuda'
              : name.contains('vulkan')
                  ? 'vulkan'
                  : null;
          if (variant != null && !out.containsKey(variant)) {
            out[variant] = e.path;
          }
        } else if (e is Directory) {
          walk(e, depth + 1);
        }
      }
    }

    walk(root, 0);
    return out;
  }

  /// llama-server.exe 在解包目录里（官方 zip 顶层平铺 exe+dll；防变体递归找）。
  String? findServerExe(Directory dir) {
    if (!dir.existsSync()) return null;
    for (final candidate in [
      '${dir.path}${Platform.pathSeparator}llama-server.exe',
      '${dir.path}${Platform.pathSeparator}bin${Platform.pathSeparator}llama-server.exe',
    ]) {
      if (File(candidate).existsSync()) return candidate;
    }
    try {
      for (final e in dir.listSync(recursive: true).whereType<File>()) {
        if (e.path.toLowerCase().endsWith('llama-server.exe')) return e.path;
      }
    } catch (_) {}
    return null;
  }

  /// 下载（镜像逐个试）→ sha256 校验 → 解包。任何一步失败清场并返回 error。
  Future<InstallResult> install(StoreRelease release,
      {List<String> mirrorPrefixes = const [],
      void Function(int received, int total)? onProgress}) async {
    final dir = dirFor(release);
    final tmpZip = File('${dir.path}.zip.tmp');
    try {
      await dir.delete(recursive: true);
    } catch (_) {}
    try {
      await tmpZip.parent.create(recursive: true);
      if (await tmpZip.exists()) await tmpZip.delete();
      var downloaded = false;
      for (final url in release.downloadUrls(mirrorPrefixes: mirrorPrefixes)) {
        try {
          if (_downloader != null) {
            await _downloader(url, tmpZip.path);
          } else {
            await _dio.download(url, tmpZip.path,
                onReceiveProgress: onProgress == null
                    ? null
                    : (r, t) => onProgress(r, t));
          }
          downloaded = true;
          break;
        } catch (_) {
          continue; // 下一个镜像
        }
      }
      if (!downloaded) return InstallResult(serverExe: null, dir: dir.path, error: '所有镜像下载失败');
      return _verifyAndExtract(release, tmpZip);
    } catch (e) {
      try {
        if (await tmpZip.exists()) await tmpZip.delete();
      } catch (_) {}
      return InstallResult(serverExe: null, dir: dir.path, error: '$e');
    }
  }

  /// 离线安装：用户/脚本已下好的 zip（校验+解包与在线共用一套）。
  Future<InstallResult> installFromLocal(
      StoreRelease release, String zipPath) async {
    final zip = File(zipPath);
    if (!await zip.exists()) {
      return InstallResult(
          serverExe: null, dir: dirFor(release).path, error: '安装包不存在：$zipPath');
    }
    final tmp = File('${dirFor(release).path}.zip.tmp');
    try {
      await tmp.parent.create(recursive: true);
      if (await tmp.exists()) await tmp.delete();
      await zip.copy(tmp.path);
      return await _verifyAndExtract(release, tmp);
    } catch (e) {
      return InstallResult(serverExe: null, dir: dirFor(release).path, error: '$e');
    } finally {
      try {
        if (await tmp.exists()) await tmp.delete();
      } catch (_) {}
    }
  }

  /// sha256 校验 + 解包 + 定位 llama-server.exe（在线/离线安装共用）。
  Future<InstallResult> _verifyAndExtract(
      StoreRelease release, File tmpZip) async {
    final dir = dirFor(release);
    try {
      final actual = await sha256File(tmpZip);
      if (actual != release.sha256.toLowerCase()) {
        await tmpZip.delete();
        return InstallResult(
            serverExe: null,
            dir: dir.path,
            error: 'sha256 不符（期望 ${release.sha256} 实得 $actual）');
      }

      await dir.create(recursive: true);
      // 流式解包：decodeBuffer(InputFileStream) 让每个条目持有文件流上的切片，
      // 解压发生在写盘那一刻 —— CUDA 包 800MB+，decodeBytes 全量进内存会在
      // 32GB 机器上也吃掉数 GB（2026-11-05 用户实报"下载完成后崩溃"的根因）。
      final input = InputFileStream(tmpZip.path);
      try {
        final archive = ZipDecoder().decodeBuffer(input);
        await extractArchiveToDisk(archive, dir.path); // 异步！漏 await = 空目录
      } finally {
        await input.close();
      }
      await tmpZip.delete();

      final exe = findServerExe(dir);
      if (exe == null) {
        return InstallResult(serverExe: null, dir: dir.path, error: '包内未找到 llama-server.exe');
      }
      return InstallResult(serverExe: exe, dir: dir.path);
    } catch (e) {
      try {
        if (await tmpZip.exists()) await tmpZip.delete();
      } catch (_) {}
      return InstallResult(serverExe: null, dir: dir.path, error: '$e');
    }
  }

  Future<void> uninstall(StoreRelease release) async {
    try {
      await dirFor(release).delete(recursive: true);
    } catch (_) {}
  }

  /// sha256 流式摘要（避免整包进内存；cuda 包数百 MB）。
  /// 捕获式 sink 口径与 download_service._computeSha256OfFile 一致。
  static Future<String> sha256File(File f) async {
    var value = Digest(const <int>[]);
    final sink = _CaptureSink((d) => value = d);
    final input = sha256.startChunkedConversion(sink);
    await for (final chunk in f.openRead()) {
      input.add(chunk);
    }
    input.close();
    return value.toString();
  }

  // ── 探测（§5.2）───────────────────────────────────────────────────────

  /// Vulkan：`llama-server --list-devices` 输出解析出设备名列表。
  Future<List<String>> vulkanDevices(String serverExe) async {
    final r = await _runner(serverExe, ['--list-devices']);
    if (r == null) return const [];
    return parseListDevices(r.all);
  }

  /// CUDA：nvidia-smi 存在 + 驱动版本串。返回 null = 无 N 卡/无驱动。
  Future<CudaInfo?> cuda() async {
    final r = await _runner('nvidia-smi',
        ['--query-gpu=name,driver_version', '--format=csv,noheader']);
    if (r == null || !r.ok || r.stdout.trim().isEmpty) return null;
    return parseNvidiaSmi(r.stdout);
  }

  /// Intel NPU 驱动版本（世代自适应 2026-11-05，仿 cuda() 的注入先例）：
  /// best-effort 查 Win32_PnPSignedDriver，命中 `AI Boost`（一/二代枚举名）
  /// 或 `(R) NPU`（Panther Lake 可能的新枚举名，未实机核证故两种都收）。
  /// null = 非 Windows / 查询失败 / 无设备 —— 调用方对驱动提示静默跳过。
  /// 该值仅诊断与 UI 提示，不参与任何预算决策。
  Future<String?> npuDriverVersion() async {
    if (!Platform.isWindows) return null;
    final r = await _runner('powershell.exe', [
      '-NoProfile',
      '-NonInteractive',
      '-Command',
      "(Get-CimInstance Win32_PnPSignedDriver | "
          "Where-Object { \$_.DeviceName -match 'AI Boost|\\(R\\) NPU' } | "
          "Select-Object -First 1 -ExpandProperty DriverVersion)",
    ]);
    if (r == null || !r.ok) return null;
    final v = r.stdout.trim();
    if (v.isEmpty || v.toLowerCase() == 'null') return null;
    return v;
  }

  /// `--list-devices` 行解析：官方措辞两种都收（2026-11-03 b12034 实测：
  /// `Vulkan0: Intel(R) Graphics (27651 MiB, ...)`；旧版 `Device 0: "name"`）。
  static List<String> parseListDevices(String out) {
    final names = <String>[];
    for (final line in const LineSplitter().convert(out)) {
      final t = line.trim();
      final m = RegExp(r'^(?:Vulkan|Device)\s*(\d+):\s*(.+)$').firstMatch(t);
      if (m == null) continue;
      var name = m.group(2)!.trim();
      // 去掉尾部显存标注与引号：`Name (16050 MiB, 15282 MiB free)` → `Name`
      final parens = name.indexOf(' (');
      if (parens > 0 && name.endsWith(')')) name = name.substring(0, parens);
      name = name.replaceAll('"', '').trim();
      if (name.isNotEmpty) names.add(name);
    }
    return names;
  }

  static CudaInfo? parseNvidiaSmi(String csv) {
    final first = csv.trim().split(RegExp(r'\r?\n')).first.split(',');
    if (first.length < 2) return null;
    return CudaInfo(name: first[0].trim(), driverVersion: first[1].trim());
  }
}

class CudaInfo {
  const CudaInfo({required this.name, required this.driverVersion});
  final String name;
  final String driverVersion;

  /// 驱动主版本 ≥570 视为 Blackwell(sm_120) 可用下限（570 分支起带 sm_120
  //  内核态支持；发行包自带 cudart，故瓶颈在驱动）。低于则 UI 置灰 CUDA。
  bool get blackwellReady => (int.tryParse(driverVersion.split('.').first) ?? 0) >= 570;
}

class _CaptureSink implements Sink<Digest> {
  _CaptureSink(this.onValue);
  final void Function(Digest) onValue;
  @override
  void add(Digest data) => onValue(data);
  @override
  void close() {}
}

Future<CmdResult?> _realRunner(String exe, List<String> args) async {
  try {
    // cwd = exe 所在目录：引擎 exe 依赖同目录 DLL/运行时（2026-11-03 实测：
    // flutter_tester cwd 下 --list-devices 的 Vulkan 枚举空手而归）。
    final pr = await Process.run(exe, args,
            workingDirectory: File(exe).parent.path)
        .timeout(const Duration(seconds: 20));
    return CmdResult(pr.exitCode, '${pr.stdout}', '${pr.stderr}');
  } catch (_) {
    return null; // 命令不存在/超时 = 探测失败（调用方按不可用处理）
  }
}
