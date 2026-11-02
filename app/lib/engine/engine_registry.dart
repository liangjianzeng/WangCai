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

class EngineInstance {
  EngineInstance({
    required this.id,
    required this.manifestId,
    this.binaryPath,
    this.pathPrefixes,
    this.enabled = true,
    this.lastConfig,
  });

  final String id;
  final String manifestId;
  String? binaryPath; // 空 = 用 manifest.binary / 引擎商店目录（M2）
  List<String>? pathPrefixes; // 覆盖 manifest 的 PATH 前置（开发机指向 repo 构建产物）
  bool enabled;
  EngineConfig? lastConfig;

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
      };

  factory EngineInstance.fromJson(Map<String, dynamic> j) => EngineInstance(
        id: j['id'] as String,
        manifestId: j['manifestId'] as String,
        binaryPath: j['binaryPath'] as String?,
        pathPrefixes: (j['pathPrefixes'] as List?)?.cast<String>(),
        enabled: j['enabled'] != false,
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

  Future<void> load() async {
    if (!await _storeFile.exists()) return;
    try {
      final j = jsonDecode(await _storeFile.readAsString());
      if (j is List) {
        for (final e in j) {
          final inst = EngineInstance.fromJson((e as Map).cast<String, dynamic>());
          _instances[inst.id] = inst;
        }
      }
    } catch (_) {/* 坏文件回退内置 */}
  }

  Future<void> save() async {
    await paths.ensureDirs();
    await _storeFile.writeAsString(
        const JsonEncoder.withIndent('  ').convert(
            _instances.values.map((e) => e.toJson()).toList()),
        flush: true);
  }

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
