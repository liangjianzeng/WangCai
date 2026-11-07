// 引擎驱动注册表（设计 §1）：实例 = manifest + 二进制路径 + 最近配置，持久化 JSON。
// 加一个引擎 = instances 里加一条 + manifest；UI/调度只认这里。
import 'dart:convert';
import 'dart:io';

import 'bundled_manifests.dart';
import 'engine_config.dart';
import 'engine_host.dart';
import 'engine_manifest.dart';
import 'engine_paths.dart';
import 'llama_server_host.dart';
import 'remote_openai_host.dart';

/// 引擎实例的「默认启动参数」（Phase 3 参数体系，设计 §3）：
/// 用户在引擎管理页编辑、落 engines.json。优先级链中间档：
/// 模型 customArgs > 引擎 defaultConfig > manifest 模板/preset。
/// 与 lastConfig 分工：lastConfig 仅是最近一次启动的诊断快照，不参与决策。
class EngineDefaults {
  const EngineDefaults({
    this.ctx,
    this.chunk,
    this.gpuLayers,
    this.device,
    this.extraEnv = const {},
    this.args = const [],
  });

  final int? ctx;
  final int? chunk;
  final int? gpuLayers;
  final String? device;
  final Map<String, String> extraEnv;

  /// 自定义尾参（追加在 argsTemplate 之后；llama.cpp 后者覆盖前者）。
  final List<String> args;

  bool get isEmpty =>
      ctx == null &&
      chunk == null &&
      gpuLayers == null &&
      device == null &&
      extraEnv.isEmpty &&
      args.isEmpty;

  Map<String, dynamic> toJson() => {
        if (ctx != null) 'ctx': ctx,
        if (chunk != null) 'chunk': chunk,
        if (gpuLayers != null) 'gpuLayers': gpuLayers,
        if (device != null) 'device': device,
        if (extraEnv.isNotEmpty) 'extraEnv': extraEnv,
        if (args.isNotEmpty) 'args': args,
      };

  /// 防御式解析：坏条目逐键丢弃（老 engines.json 无此键 → null）。
  static EngineDefaults? fromJson(Object? raw) {
    if (raw is! Map) return null;
    int? i(String k) => raw[k] is num ? (raw[k] as num).toInt() : null;
    final env = (raw['extraEnv'] as Map?)?.map(
          (k, v) => MapEntry('$k', '$v'),
        ) ??
        const <String, String>{};
    final args = (raw['args'] as List?)
            ?.whereType<String>()
            .where((a) => a.trim().isNotEmpty)
            .toList() ??
        const <String>[];
    final d = EngineDefaults(
      ctx: i('ctx'),
      chunk: i('chunk'),
      gpuLayers: i('gpuLayers'),
      device: raw['device'] is String && (raw['device'] as String).isNotEmpty
          ? raw['device'] as String
          : null,
      extraEnv: env,
      args: args,
    );
    return d.isEmpty ? null : d;
  }
}

class EngineInstance {
  EngineInstance({
    required this.id,
    required this.manifestId,
    this.binaryPath,
    this.pathPrefixes,
    this.enabled = true,
    this.lastConfig,
    this.defaultConfig,
    this.lastNpuInfo,
  });

  final String id;
  final String manifestId;
  String? binaryPath; // 空 = 用 manifest.binary / 引擎商店目录（M2）
  List<String>? pathPrefixes; // 覆盖 manifest 的 PATH 前置（开发机指向 repo 构建产物）
  bool enabled;
  EngineConfig? lastConfig;

  /// 用户配置的默认启动参数（null = 未配置 → 走 manifest preset）。
  EngineDefaults? defaultConfig;

  /// 最近一次 NPU 探测摘要（NpuDeviceInfo.toSummary()：devArg/型号/世代/
  /// 驱动）。诊断与引擎管理页展示用，不参与决策；可选字段不 bump 版本
  /// （DSH 纪律），老 engines.json 无此键 → null。
  Map<String, dynamic>? lastNpuInfo;

  Map<String, dynamic> toJson() => {
        'id': id,
        'manifestId': manifestId,
        'binaryPath': binaryPath,
        'pathPrefixes': pathPrefixes,
        'enabled': enabled,
        'lastConfig': lastConfig == null
            ? null
            : {
                'engineId': lastConfig!.engineId,
                'modelPath': lastConfig!.modelPath,
                'mmprojPath': lastConfig!.mmprojPath,
                'ctx': lastConfig!.ctx,
                'chunk': lastConfig!.chunk,
                'threads': lastConfig!.threads,
                'device': lastConfig!.device,
                'gpuLayers': lastConfig!.gpuLayers,
                'presetName': lastConfig!.presetName,
                'extraEnv': lastConfig!.extraEnv,
                'paramsB': lastConfig!.paramsB,
                'remoteBaseUrl': lastConfig!.remoteBaseUrl,
                'remoteModel': lastConfig!.remoteModel,
                // api key 不入库（flutter_secure_storage 管，设计 §6.1）
              },
        'defaultConfig':
            defaultConfig == null ? null : defaultConfig!.toJson(),
        if (lastNpuInfo?.isNotEmpty == true) 'lastNpuInfo': lastNpuInfo,
      };

  factory EngineInstance.fromJson(Map<String, dynamic> j) => EngineInstance(
        id: j['id'] as String,
        manifestId: j['manifestId'] as String,
        binaryPath: j['binaryPath'] as String?,
        pathPrefixes: (j['pathPrefixes'] as List?)?.cast<String>(),
        enabled: j['enabled'] != false,
        defaultConfig: EngineDefaults.fromJson(j['defaultConfig']),
        lastNpuInfo: j['lastNpuInfo'] is Map
            ? Map<String, dynamic>.from(j['lastNpuInfo'] as Map)
            : null,
        lastConfig: j['lastConfig'] == null
            ? null
            : EngineConfig(
                engineId: j['lastConfig']['engineId'] as String,
                modelPath: j['lastConfig']['modelPath'] as String? ?? '',
                mmprojPath: j['lastConfig']['mmprojPath'] as String?,
                ctx: (j['lastConfig']['ctx'] as num?)?.toInt(),
                chunk: (j['lastConfig']['chunk'] as num?)?.toInt(),
                threads: (j['lastConfig']['threads'] as num?)?.toInt(),
                device: j['lastConfig']['device'] as String?,
                gpuLayers: (j['lastConfig']['gpuLayers'] as num?)?.toInt(),
                presetName: j['lastConfig']['presetName'] as String?,
                extraEnv:
                    ((j['lastConfig']['extraEnv'] as Map?) ?? {}).map(
                        (k, v) => MapEntry(k as String, v as String)),
                paramsB: (j['lastConfig']['paramsB'] as num?)?.toDouble(),
                remoteBaseUrl: j['lastConfig']['remoteBaseUrl'] as String?,
                remoteModel: j['lastConfig']['remoteModel'] as String?,
              ),
      );
}

class EngineRegistry {
  EngineRegistry({
    required this.paths,
    Map<String, EngineManifest>? manifests,
    required List<EngineInstance> instances,
    this.processRunner,
    this.healthProbe,
    this.portAllocator,
    this.sleeper,
    this.parentEnv,
    this.prewarmCompletion,
  })  : manifests = manifests ?? bundledManifests(),
        _instances = {for (final i in instances) i.id: i};

  /// 开发机默认：汪柴引擎直接指向 repo 的构建产物（装机形态由 M2 商店接管）。
  factory EngineRegistry.dev({
    required EnginePaths paths,
    required String wangcaiServerExe,
    required List<String> ovLibsDirs,
    List<EngineInstance>? extraInstances,
  }) {
    return EngineRegistry(
      paths: paths,
      instances: [
        EngineInstance(
          id: 'wangcai-npu',
          manifestId: 'wangcai-npu',
          binaryPath: wangcaiServerExe,
          pathPrefixes: ovLibsDirs,
        ),
        EngineInstance(id: 'llamacpp-vulkan', manifestId: 'llamacpp-vulkan', enabled: false),
        EngineInstance(id: 'llamacpp-cuda', manifestId: 'llamacpp-cuda', enabled: false),
        EngineInstance(id: 'openai-remote', manifestId: 'openai-remote'),
        ...?extraInstances,
      ],
    );
  }

  final EnginePaths paths;
  final Map<String, EngineManifest> manifests;
  final Map<String, EngineInstance> _instances;
  final Map<String, EngineHost> _hosts = {};

  final ProcessRunner? processRunner;
  final HealthProbe? healthProbe;
  final PortAllocator? portAllocator;
  final Sleeper? sleeper;
  final Map<String, String>? parentEnv;
  /// 加载期预热探针（null=host 默认：真 completion；测试注入桩免碰真 socket，
  /// 2026-11-06 平台套件实锤：不注入会 5s 连接超时×每引擎拖死回归）。
  final PrewarmCompletion? prewarmCompletion;

  List<EngineInstance> get instances => _instances.values.toList()
    ..sort((a, b) => a.id.compareTo(b.id));

  EngineInstance? instance(String id) => _instances[id];
  EngineManifest manifestOf(String id) => manifests[_instances[id]!.manifestId]!;

  void upsert(EngineInstance inst) => _instances[inst.id] = inst;
  Future<void> remove(String id) async {
    await _hosts.remove(id)?.dispose();
    _instances.remove(id);
  }

  File get _storeFile =>
      File('${paths.dataDir.path}${Platform.pathSeparator}engines.json');

  /// 读取 engines.json 覆盖内置实例。返回人类可读摘要（调用方落日志）：
  /// null = 文件不存在；'loaded N entries …'；'parse-failed: …'（坏文件回退内置）。
  ///
  /// 覆盖语义（2026-11-07 装机排障定案）：存储的 binaryPath 是**上次运行时
  /// 的缓存**，不是命令——内置实例在本次启动已做过新鲜解析（wangcai-npu =
  /// 装机位探测），新鲜解析有效时存储值不夺权；存储值本身指向不存在文件时
  /// 丢弃（回退 manifest.binary）。实战实锤：开发机 engines.json 残留
  /// `E:/DTXY/src/llama/…`（junction 指向 D 盘，existsSync 间歇性假阴），
  /// 覆盖掉装机位正确路径 → 装机 App「NPU 引擎不可用（未安装或未启用）」。
  Future<String?> load() async {
    if (!await _storeFile.exists()) return null;
    try {
      final j = jsonDecode(await _storeFile.readAsString());
      if (j is List) {
        var kept = 0;
        final notes = <String>[];
        for (final e in j) {
          final inst = EngineInstance.fromJson((e as Map).cast<String, dynamic>());
          // PATH 前置：存储条目剔除不存在目录后若为空 → **回退内置新鲜解析**
          // （装机 ovlibs）。2026-11-07 两连实锤：engines.json 里开发机残留
          // '/DTXY/…' 垃圾前缀本就该丢，但丢光后置 null 会把内置实例的
          // ovlibs 一起冲掉——装机位不是自包含布局（tbb/NPU 插件在 ovlibs
          // 子目录），PATH 一丢 server 即 c0000142 起进程死。
          final storedPrefixes =
              inst.pathPrefixes?.where((p) => Directory(p).existsSync()).toList();
          if (storedPrefixes == null || storedPrefixes.isEmpty) {
            inst.pathPrefixes = _instances[inst.id]?.pathPrefixes;
          } else {
            inst.pathPrefixes = storedPrefixes;
          }
          final fresh = _instances[inst.id]?.binaryPath;
          if (fresh != null && fresh.isNotEmpty && File(fresh).existsSync()) {
            // 新鲜解析有效 → 存储的 binaryPath 只是缓存，不夺权。
            if (inst.binaryPath != fresh) {
              notes.add('${inst.id}: stored-path 让位新鲜解析'
                  '（stored=${inst.binaryPath}）');
            }
            inst.binaryPath = fresh;
          } else if (inst.binaryPath != null &&
              inst.binaryPath!.isNotEmpty &&
              !File(inst.binaryPath!).existsSync()) {
            // 新鲜解析无效且存储值也指向不存在文件 → 陈旧缓存丢弃。
            notes.add('${inst.id}: stored-path 指向不存在文件，丢弃'
                '（${inst.binaryPath}）');
            inst.binaryPath = null;
          }
          _instances[inst.id] = inst;
          kept++;
        }
        return ['loaded $kept entries', ...notes].join('\n');
      }
      return 'unexpected shape: ${j.runtimeType}';
    } catch (e) {
      return 'parse-failed: $e';
    }
  }

  Future<void> save() async {
    await paths.ensureDirs();
    await _storeFile.writeAsString(
        const JsonEncoder.withIndent('  ').convert(
            _instances.values.map((e) => e.toJson()).toList()),
        flush: true);
  }

  /// 已存在的宿主（不惰性创建；单 active 互斥扫描用）。
  EngineHost? existingHostOf(String instanceId) => _hosts[instanceId];

  /// 同 id 单例宿主（聊天与设置页共享同一进程视图）。
  EngineHost hostOf(String instanceId) {
    final existing = _hosts[instanceId];
    if (existing != null) return existing;
    final inst = _instances[instanceId];
    if (inst == null) {
      throw ArgumentError('未注册的引擎实例：$instanceId');
    }
    final manifest = manifestOf(instanceId);
    final host = manifest.kind == 'remote'
        ? RemoteOpenAiHost(instanceId: instanceId, manifest: manifest)
        : LlamaServerHost(
            instanceId: instanceId,
            manifest: manifest,
            binaryPath: inst.binaryPath ?? manifest.binary ?? '',
            paths: paths,
            pathPrefixes: inst.pathPrefixes,
            processRunner: processRunner,
            healthProbe: healthProbe,
            portAllocator: portAllocator,
            sleeper: sleeper,
            parentEnv: parentEnv ?? Platform.environment,
            prewarmCompletion: prewarmCompletion,
          );
    return _hosts[instanceId] = host;
  }

  Future<void> dispose() async {
    for (final h in _hosts.values) {
      await h.dispose();
    }
    _hosts.clear();
  }
}
