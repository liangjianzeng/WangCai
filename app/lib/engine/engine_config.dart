// 引擎实例配置：一次 start(cfg) 的全部输入。profileId 决定独立编译缓存目录
// （D6：任一影响静态图的参数变 → 换目录，杜绝旧编译图无声胜出）。
import 'dart:convert';

import 'package:crypto/crypto.dart';

class EngineConfig {
  const EngineConfig({
    required this.engineId,
    required this.modelPath,
    this.mmprojPath,
    this.ctx,
    this.chunk,
    this.threads,
    this.device, // OPENVINO0..3 / CPU / GPU.x
    this.gpuLayers, // llama.cpp -ngl
    this.presetName,
    this.extraEnv = const {},
    this.paramsB,
    this.remoteBaseUrl, // kind=remote
    this.remoteApiKey,
    this.remoteModel,
  });

  final String engineId;
  final String modelPath;
  final String? mmprojPath;
  final int? ctx;
  final int? chunk;
  final int? threads;
  final String? device;
  final int? gpuLayers;
  final String? presetName;
  final Map<String, String> extraEnv;
  final double? paramsB;
  final String? remoteBaseUrl;
  final String? remoteApiKey;
  final String? remoteModel;

  /// 影响编译图/加载的参数指纹 → per-profile 缓存目录（D6）。
  String get profileId {
    final key = jsonEncode({
      'e': engineId,
      'm': modelPath,
      'p': mmprojPath,
      'c': ctx,
      'k': chunk,
      'd': device,
      'g': gpuLayers,
      'x': (extraEnv.entries.toList()
            ..sort((a, b) => a.key.compareTo(b.key)))
          .map((e) => '${e.key}=${e.value}')
          .toList(),
    });
    return sha1.convert(utf8.encode(key)).toString().substring(0, 16);
  }

  EngineConfig copyWith({
    String? modelPath,
    String? mmprojPath,
    int? ctx,
    int? chunk,
    int? threads,
    String? device,
    int? gpuLayers,
    String? presetName,
    Map<String, String>? extraEnv,
    double? paramsB,
  }) =>
      EngineConfig(
        engineId: engineId,
        modelPath: modelPath ?? this.modelPath,
        mmprojPath: mmprojPath ?? this.mmprojPath,
        ctx: ctx ?? this.ctx,
        chunk: chunk ?? this.chunk,
        threads: threads ?? this.threads,
        device: device ?? this.device,
        gpuLayers: gpuLayers ?? this.gpuLayers,
        presetName: presetName ?? this.presetName,
        extraEnv: extraEnv ?? this.extraEnv,
        paramsB: paramsB ?? this.paramsB,
        remoteBaseUrl: remoteBaseUrl,
        remoteApiKey: remoteApiKey,
        remoteModel: remoteModel,
      );
}
