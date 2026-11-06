// 引擎驱动 manifest（设计 §4.1）：差异全是数据，不是代码。
// 加一个引擎 = 加一份 manifest；UI 从 capabilities/参数表自动长出来。
import 'dart:convert';

/// 占位符渲染：`{name}` 必填；`{name?}` 可选（值为 null 时本 token 连同前一个 token
/// 一起删除，用于 `--mmproj {mmproj?}` 这类成对参数）；`{name|default}` 缺省回退。
List<String> renderArgsTemplate(List<String> template, Map<String, String?> values) {
  final out = <String>[];
  for (var i = 0; i < template.length; i++) {
    final token = template[i];
    final m = RegExp(r'^\{([A-Za-z0-9_]+)(\?|=[^}]*)?\}$').firstMatch(token);
    if (m == null) {
      out.add(token);
      continue;
    }
    final name = m.group(1)!;
    final modifier = m.group(2);
    var value = values[name];
    if (value == null && modifier != null && modifier.startsWith('=')) {
      value = modifier.substring(1);
    }
    if (value == null) {
      if (modifier == '?') {
        // 可选成对参数：删前一个 flag token（如 --mmproj）。
        if (out.isNotEmpty) out.removeLast();
        continue;
      }
      throw ArgumentError('manifest 占位符 {$name} 缺值（模板：$template）');
    }
    out.add(value);
  }
  return out;
}

class EngineCapabilities {
  const EngineCapabilities({
    this.nativeToolCall = false,
    this.vision = false,
    this.audio = false,
    this.devices = const [],
  });

  final bool nativeToolCall; // 有 --jinja 的原生 tools/tool_calls
  final bool vision; // --mmproj 可用
  final bool audio; // mtmd 音频理解（NPU 侧 v0.0.2 不承诺）
  final List<String> devices;

  factory EngineCapabilities.fromJson(Map<String, dynamic> j) => EngineCapabilities(
        nativeToolCall: j['nativeToolCall'] == true,
        vision: j['vision'] == true,
        audio: j['audio'] == true,
        devices: (j['devices'] as List?)?.cast<String>() ?? const [],
      );

  Map<String, dynamic> toJson() => {
        'nativeToolCall': nativeToolCall,
        'vision': vision,
        'audio': audio,
        'devices': devices,
      };
}

/// 准入规则（设计 §4.1 admission）：违规在 UI 前置拦截并给改道建议，不等崩。
/// 数据驱动：条件全部满足才触发。世代自适应（2026-11-05）：可选
/// [appliesGenerations]（NpuGeneration.name 集合）把规则限定到某些 NPU
/// 世代；null = 全世代适用（保守默认 —— 一台机器实测到的驱动预算，
/// 未验证世代同样先按它拦）。
class AdmissionRule {
  const AdmissionRule({
    this.ifCtxGt,
    this.ifParamsBAtLeast,
    this.appliesGenerations,
    required this.message,
    required this.suggestion,
  });

  final int? ifCtxGt;
  final double? ifParamsBAtLeast;

  /// 适用世代（'ultra1'/'ultra2'/'ultra3'/'unknown'）；null = 全部。
  final List<String>? appliesGenerations;
  final String message;
  final String suggestion;

  bool triggers({
    required int? ctx,
    required double? paramsB,
    String? generation,
    int? measuredCtx,
  }) {
    if (ifCtxGt != null && (ctx == null || ctx <= ifCtxGt!)) return false;
    if (ifParamsBAtLeast != null && (paramsB == null || paramsB < ifParamsBAtLeast!)) {
      return false;
    }
    // generation=null（非 NPU 引擎/未探测）→ 不做世代过滤，规则照常生效；
    // 已知世代不在适用名单 → 本条豁免。
    if (generation != null &&
        appliesGenerations != null &&
        !appliesGenerations!.contains(generation)) {
      return false;
    }
    // 实测豁免（保守起步+实测上探的另一半）：**ctx 门槛类**规则是某台机器
    // 的先验预算，同 (引擎×模型) 绑定在该 ctx 已成功跑过 = 该先验被本机实测
    // 证伪 → 让位。非 ctx 门槛（纯参数量禁令等）与实测档位无关，不让位。
    if (ifCtxGt != null && measuredCtx != null && ctx != null && ctx <= measuredCtx) {
      return false;
    }
    return ifCtxGt != null || ifParamsBAtLeast != null;
  }

  factory AdmissionRule.fromJson(Map<String, dynamic> j) => AdmissionRule(
        ifCtxGt: (j['ifCtxGt'] as num?)?.toInt(),
        ifParamsBAtLeast: (j['ifParamsBAtLeast'] as num?)?.toDouble(),
        appliesGenerations: (j['appliesGenerations'] as List?)?.cast<String>(),
        message: j['message'] as String? ?? '',
        suggestion: j['suggestion'] as String? ?? '',
      );
}

class TimingHints {
  // 缺省 = 冷编保守上界（2026-11-06 健康检查）：这不只是展示提示——就绪超时
  // 直接用它（llama_server_host.dart:269），36000 的旧缺省会让缺 timingHints
  // 的自定义 manifest 在 NPU 冷编（开发机实测 ~10min）下必超时误杀。宁慢报。
  const TimingHints({this.coldCompileMs = 600000, this.warmMs = 9000});
  final int coldCompileMs;
  final int warmMs;

  factory TimingHints.fromJson(Map<String, dynamic> j) => TimingHints(
        coldCompileMs: (j['coldCompileMs'] as num?)?.toInt() ?? 600000,
        warmMs: (j['warmMs'] as num?)?.toInt() ?? 9000,
      );
}

class Preset {
  const Preset({
    required this.name,
    this.modelGlob,
    this.ctx,
    this.chunk,
    this.paramsB,
    this.device,
    this.gpuLayers,
    this.extraEnv = const {},
    this.note,
  });

  final String name;
  final String? modelGlob;
  final int? ctx;
  final int? chunk; // GGML_OPENVINO_PREFILL_CHUNK_SIZE
  final double? paramsB;
  final String? device; // OPENVINO0..3 / CPU
  final int? gpuLayers; // llama.cpp -ngl
  final Map<String, String> extraEnv;
  final String? note;

  factory Preset.fromJson(Map<String, dynamic> j) => Preset(
        name: j['name'] as String,
        modelGlob: j['modelGlob'] as String?,
        ctx: (j['ctx'] as num?)?.toInt(),
        chunk: (j['chunk'] as num?)?.toInt(),
        paramsB: (j['paramsB'] as num?)?.toDouble(),
        device: j['device'] as String?,
        gpuLayers: (j['gpuLayers'] as num?)?.toInt(),
        extraEnv: ((j['extraEnv'] as Map?) ?? {}).map(
          (k, v) => MapEntry(k as String, v as String),
        ),
        note: j['note'] as String?,
      );
}

/// kind：llamaServer（子进程）| remote（纯 HTTP，无进程）。
class EngineManifest {
  const EngineManifest({
    required this.id,
    required this.display,
    required this.kind,
    this.binary,
    this.pathPrefixes = const [],
    this.argsTemplate = const [],
    this.envTemplate = const {},
    this.capabilities = const EngineCapabilities(),
    this.presets = const [],
    this.admission = const [],
    this.timingHints = const TimingHints(),
    this.hardFlagsHint = '',
  });

  final String id;
  final String display;
  final String kind;
  final String? binary;
  final List<String> pathPrefixes; // 追加到 PATH 的运行时目录（相对 engineRoot 或绝对）
  final List<String> argsTemplate;
  final Map<String, String> envTemplate; // 值支持占位符
  final EngineCapabilities capabilities;
  final List<Preset> presets;
  final List<AdmissionRule> admission;
  final TimingHints timingHints;
  final String hardFlagsHint; // 展示用：硬约束说明，UI 不进可编辑区

  factory EngineManifest.fromJson(Map<String, dynamic> j) => EngineManifest(
        id: j['id'] as String,
        display: j['display'] as String,
        kind: j['kind'] as String? ?? 'llamaServer',
        binary: j['binary'] as String?,
        pathPrefixes: (j['pathPrefixes'] as List?)?.cast<String>() ?? const [],
        argsTemplate: (j['argsTemplate'] as List?)?.cast<String>() ?? const [],
        envTemplate: ((j['envTemplate'] as Map?) ?? {}).map(
          (k, v) => MapEntry(k as String, v as String),
        ),
        capabilities: EngineCapabilities.fromJson(
            (j['capabilities'] as Map?)?.cast<String, dynamic>() ?? {}),
        presets: ((j['presets'] as List?) ?? [])
            .map((e) => Preset.fromJson((e as Map).cast<String, dynamic>()))
            .toList(),
        admission: ((j['admission'] as List?) ?? [])
            .map((e) => AdmissionRule.fromJson((e as Map).cast<String, dynamic>()))
            .toList(),
        timingHints: TimingHints.fromJson(
            (j['timingHints'] as Map?)?.cast<String, dynamic>() ?? {}),
        hardFlagsHint: j['hardFlagsHint'] as String? ?? '',
      );

  factory EngineManifest.parse(String source) =>
      EngineManifest.fromJson(jsonDecode(source) as Map<String, dynamic>);

  Preset? presetByName(String? name) {
    if (name == null) return null;
    for (final p in presets) {
      if (p.name == name) return p;
    }
    return null;
  }

  /// 返回违规说明列表（空 = 放行）。UI 据此弹改道建议（设计 §4.1）。
  /// [generation] = NpuGeneration.name（NPU 引擎的探测世代）；null = 不做
  /// 世代过滤（非 NPU 引擎/未探测，规则全量生效）。
  /// [measuredCtx] = 同 (引擎×模型) 绑定的实测稳定 ctx（ctx 门槛类规则的
  /// 豁免依据，见 AdmissionRule.triggers）。
  List<String> checkAdmission({
    required int? ctx,
    required double? paramsB,
    String? generation,
    int? measuredCtx,
  }) {
    return [
      for (final r in admission)
        if (r.triggers(
            ctx: ctx,
            paramsB: paramsB,
            generation: generation,
            measuredCtx: measuredCtx))
          '${r.message}（建议：${r.suggestion}）',
    ];
  }
}
