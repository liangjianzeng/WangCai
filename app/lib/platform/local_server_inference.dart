// Windows 推理后端（设计 §2.3/§4）：不链 llama.cpp，进程与 token 两条路——
// 引擎生命周期归 EngineRegistry/LlamaServerHost（manifest 驱动），token 走
// llama-server 的 OpenAI 兼容 SSE。provider/agent/plugin 只见 InferenceBackend，
// 与 Android JNI 实现语义对齐（见 inference_backend.dart 顶部约定）。
import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:dio/dio.dart';
import 'package:flutter/foundation.dart'
    show debugPrint, visibleForTesting;

import '../engine/bindings_store.dart';
import '../engine/engine_config.dart';
import '../engine/engine_manifest.dart';
import '../engine/engine_paths.dart';
import '../engine/engine_registry.dart';
import '../engine/engine_status.dart' show EngineLogLine;
import '../engine/engine_store.dart';
import '../engine/llama_server_host.dart';
import '../engine/process_ledger.dart';
import '../engine/routing_policy.dart';
import 'inference_backend.dart';
import 'power_monitor.dart';
import 'wangcai_paths.dart';

/// llama-server SSE chunk → UI 可见 token 流的纯逻辑状态机（可单测）。
/// - chat 模式：content 原样透传；reasoning_content 包 think 开/闭标签，让上层
///   既有的 think 过滤器（chat_provider / AgentStreamProcessor）无感复用；
/// - raw 模式（/completion）：只取顶层 content；
/// - 若 content 流自带 think 标签（模板把思考内联进 content），不再包裹，
///   标签职责交还模型。
class ChatSseDecoder {
  ChatSseDecoder({this.rawMode = false});
  final bool rawMode;

  // think 标签用相邻字面量拼接构造（与 chat_provider/AgentStreamProcessor
  // 的过滤词逐字节一致）；整体标签写进源码易被工具链当标记吞掉。
  static const String openTag = '<' 'think' '>';
  static const String closeTag = '<' '/think' '>';

  bool _inReasoning = false;
  bool _sawInlineTag = false;
  Map<String, dynamic>? timings;
  int tokens = 0;

  List<String> feedChunk(Map<String, dynamic> chunk) {
    final t = chunk['timings'];
    if (t is Map) timings = mapTimings(Map<String, dynamic>.from(t));
    final out = <String>[];
    if (rawMode) {
      final c = chunk['content'];
      if (c is String && c.isNotEmpty) {
        tokens++;
        out.add(c);
      }
      return out;
    }
    final choices = chunk['choices'];
    if (choices is! List || choices.isEmpty) return out;
    final delta = (choices.first as Map)['delta'];
    if (delta is! Map) return out;
    final rc = delta['reasoning_content'];
    if (rc is String && rc.isNotEmpty) {
      if (!_sawInlineTag) {
        if (!_inReasoning) out.add(openTag);
        _inReasoning = true;
      }
      tokens++;
      out.add(rc);
    }
    final c = delta['content'];
    if (c is String && c.isNotEmpty) {
      if (_inReasoning) {
        out.add(closeTag);
        _inReasoning = false;
      }
      if (!_sawInlineTag && (c.contains(openTag) || c.contains(closeTag))) {
        _sawInlineTag = true;
      }
      tokens++;
      out.add(c);
    }
    return out;
  }

  /// 流结束：未闭合的思考补闭标签，消费端不留悬挂 opener。
  List<String> finish() =>
      (_inReasoning && !_sawInlineTag) ? const [closeTag] : const [];

  static Map<String, dynamic> mapTimings(Map<String, dynamic> t) {
    // llama-server timings → {n_gen, t_gen_ms, t_prompt_ms}（native 对齐口径）。
    final out = <String, dynamic>{};
    final n = t['predicted_n'] ?? t['n_gen'];
    final gen = t['predicted_ms'] ?? t['t_gen_ms'];
    final pp = t['prompt_ms'] ?? t['t_prompt_ms'];
    final pn = t['prompt_n'] ?? t['n_prompt'];
    if (n is num) out['n_gen'] = n.toInt();
    if (gen is num) out['t_gen_ms'] = gen.toInt();
    if (pp is num) out['t_prompt_ms'] = pp.toInt();
    if (pn is num) out['n_prompt'] = pn.toInt();
    return out;
  }
}

class LocalServerInference implements InferenceBackend {
  LocalServerInference._();
  static final LocalServerInference instance = LocalServerInference._();

  EngineRegistry? _registry;
  LlamaServerHost? _host;
  EngineConfig? _cfg;
  bool _loaded = false;
  bool _swept = false;

  /// 数据目录（可注入隔离：测试注入临时目录，避免被真实
  /// %APPDATA% 的 routing.json/bindings.db 污染路由决策）。
  EnginePaths? _pathsOverride;
  EnginePaths _enginePaths() => _pathsOverride ?? WangCaiPaths.enginePaths();

  // set* 推送值：server 是独立进程，能落 env/参数的在 loadModel 用，其余随请求体。
  bool _enableThinking = false;

  StreamSubscription<EngineLogLine>? _logSub;
  CancelToken? _cancel;
  Map<String, dynamic> _lastStats = const {};

  @override
  void Function(String? message)? onLoadingLog;

  final _dio = Dio(BaseOptions(
    connectTimeout: const Duration(seconds: 5),
    receiveTimeout: const Duration(minutes: 10), // 冷编/慢生成期不断流
  ));

  void _log(String? m) {
    try {
      onLoadingLog?.call(m);
    } catch (_) {}
  }

  // ── 引擎装配 ──────────────────────────────────────────────────────────

  Future<EngineRegistry> _ensureRegistry() async {
    final existing = _registry;
    if (existing != null) return existing;
    final paths = _enginePaths();
    final reg = EngineRegistry.dev(
      paths: paths,
      wangcaiServerExe: WangCaiPaths.wangcaiServerExe() ?? 'llama-server.exe',
      ovLibsDirs: WangCaiPaths.ovLibsDirs(),
    );
    await reg.load();
    if (!_swept) {
      _swept = true;
      try {
        // 账本扫孤儿（M0-3 附 实测：杀外壳必留孤儿 llama-server 占端口/内存）。
        for (final o in await ProcessLedger(paths).sweep(killOrphans: true)) {
          debugPrint('[LocalServer] 清理上次崩溃遗留进程 pid=${o.pid} port=${o.port}');
        }
      } catch (e) {
        debugPrint('[LocalServer] ledger sweep failed: $e');
      }
    }
    return _registry = reg;
  }

  // ── M2 路由与绑定表（设计 §7.2/§7.3）──────────────────────────────────

  BindingsStore? _bindings;

  Future<BindingsStore?> _ensureBindings() async {
    final b = _bindings;
    if (b != null) return b;
    try {
      return _bindings = await BindingsStore.open(_enginePaths());
    } catch (e) {
      _log('⚠️ 绑定表不可用（按无实测启发路由）：$e');
      return null;
    }
  }

  Future<List<Binding>> _bindingsFor(String modelId) async =>
      (await _ensureBindings())?.forModel(modelId) ?? const [];

  String? _tierName;

  /// 档位持久化：dataDir/routing.json（UI 档位切换在 M2 设置页接线）。
  Future<String> _tierSetting() async {
    final cached = _tierName;
    if (cached != null) return cached;
    try {
      final f = File('${_enginePaths().dataDir.path}'
          '${Platform.pathSeparator}routing.json');
      if (await f.exists()) {
        final j = jsonDecode(await f.readAsString());
        if (j is Map && j['tier'] is String) return _tierName = j['tier'] as String;
      }
    } catch (_) {}
    return _tierName = 'auto';
  }

  Future<void> setRoutingTier(String tier) async {
    _tierName = routingTierFromName(tier) == RoutingTier.speedFirst
        ? 'speed'
        : routingTierFromName(tier) == RoutingTier.npuFirst
            ? 'npu'
            : 'auto';
    try {
      final j = await _readRoutingJson();
      j['tier'] = _tierName;
      await _writeRoutingJson(j);
    } catch (_) {}
  }

  /// 空闲卸载分钟（0=关闭）；§7.3 调度护栏的 UI 入口。
  Future<void> setIdleUnloadMinutes(int minutes) async {
    try {
      final j = await _readRoutingJson();
      j['idleUnloadMinutes'] = minutes;
      await _writeRoutingJson(j);
      if (minutes <= 0) {
        _idleTimer?.cancel();
        _idleTimer = null;
      }
    } catch (_) {}
  }

  /// 当前档位与空闲配置（设置 UI 初始化读）。
  Future<({String tier, int idleMinutes})> routingSettings() async {
    final j = await _readRoutingJson();
    final tier = await _tierSetting();
    final idle = j['idleUnloadMinutes'];
    return (tier: tier, idleMinutes: idle is num ? idle.toInt() : 0);
  }

  Future<Map<String, dynamic>> _readRoutingJson() async {
    try {
      final f = File('${_enginePaths().dataDir.path}'
          '${Platform.pathSeparator}routing.json');
      if (await f.exists()) {
        final d = jsonDecode(await f.readAsString());
        if (d is Map) return Map<String, dynamic>.from(d);
      }
    } catch (_) {}
    return {};
  }

  Future<void> _writeRoutingJson(Map<String, dynamic> j) async {
    final paths = _enginePaths();
    await paths.ensureDirs();
    await File('${paths.dataDir.path}${Platform.pathSeparator}routing.json')
        .writeAsString(jsonEncode(j), flush: true);
  }

  /// 绑定表实测 t/s（诊断 UI 用）。
  Future<List<Binding>> bindingsForModel(String modelPath) =>
      _bindingsFor(_basename(modelPath));

  /// §7.3「电池机型拔电 → NPU 加权」的输入（M3-b 电源感知）。
  bool _onBattery() {
    final f = _onBatteryForTest;
    if (f != null) return f;
    try {
      return readPowerState().onBattery;
    } catch (_) {
      return false;
    }
  }

  /// 路由决策（§7.3）：候选=已启用本地实例；binary 缺失=未装不作候选；
  /// admission 违例=blocked（带建议改道，不去拉必崩的 server）。
  /// [engineId] 非空 = 模型级引擎钉选（LocalModelConfig.engineId）：命中即
  /// 直通（跳过打分，但仍受 admission 约束）；未命中留痕回落 Auto 打分。
  Future<RoutingDecision> _route({
    required EngineRegistry reg,
    required String path,
    required int? nCtx,
    String? engineId,
  }) async {
    if (engineId != null && engineId.isNotEmpty) {
      final inst = reg.instance(engineId);
      final m = inst == null ? null : reg.manifestOf(inst.id);
      final bin = inst?.binaryPath ?? m?.binary;
      final hit = inst != null &&
          inst.enabled &&
          m != null &&
          m.kind != 'remote' &&
          bin != null &&
          bin.isNotEmpty &&
          File(bin).existsSync();
      if (hit) {
        final p = _matchPreset(m, path);
        final requested = nCtx ?? inst.defaultConfig?.ctx ?? (p?.ctx ?? 1024);
        final ceil = p?.ctx;
        final tentative = (ceil != null && requested > ceil) ? ceil : requested;
        final v = m.checkAdmission(ctx: tentative, paramsB: p?.paramsB);
        if (v.isNotEmpty) {
          return RoutingDecision.none('指定引擎拒绝（$engineId）：${v.join('；')}',
              '改用 Auto 路由，或调小上下文后重试');
        }
        return RoutingDecision(
            instanceId: engineId, reason: '指定引擎（钉选）：$engineId');
      }
      _log('⚠️ 指定引擎 $engineId 不可用（未安装/未启用/不存在），回落 Auto 路由');
    }
    final bindingsForModel = await _bindingsFor(_basename(path));
    final cands = <EngineCandidate>[];
    final blocked = <String, String>{};
    for (final inst in reg.instances) {
      final m = reg.manifestOf(inst.id);
      if (m.kind == 'remote') continue; // loadModel 是本地意图；远端走请求路由
      final bin = inst.binaryPath ?? m.binary;
      final installed = bin != null && bin.isNotEmpty && File(bin).existsSync();
      cands.add(EngineCandidate(
        instanceId: inst.id,
        kind: m.kind,
        devices: m.capabilities.devices,
        enabled: inst.enabled,
        installed: installed,
      ));
      final p = _matchPreset(m, path);
      final requested =
          nCtx ?? inst.defaultConfig?.ctx ?? (p?.ctx ?? 1024);
      final ceil = p?.ctx;
      final tentative = (ceil != null && requested > ceil) ? ceil : requested;
      final v = m.checkAdmission(ctx: tentative, paramsB: p?.paramsB);
      if (v.isNotEmpty) blocked[inst.id] = v.join('；');
    }
    return chooseEngine(RoutingRequest(
      tier: routingTierFromName(await _tierSetting()),
      candidates: cands,
      bindings: bindingsForModel,
      blocked: blocked,
      onBattery: _onBattery(),
    ));
  }

  // ── 按需下载闭环（Phase 3c，设计 §5.1）────────────────────────────────
  // 路由选不出本地引擎但存在「已启用未装」的 cuda/vulkan 实例时，决策带
  // needInstall；loadModel 记下它，UI（模型管理页加载弹层）读取后弹
  // 「下载引擎」→ installEngine（EngineStore 进度）→ 装完重试 loadModel。

  /// 最近一次加载失败的下载建议（'cuda'|'vulkan'；null = 无建议）。
  String? lastInstallSuggestion;

  /// @visibleForTesting：installEngine 的 EngineStore 工厂注入（假下载器）。
  @visibleForTesting
  EngineStore Function(EnginePaths paths, Directory? enginesDir)?
      engineStoreForTest;

  /// 下载并装配官方 llama.cpp 引擎：whitelist 版本 → EngineStore.install
  /// （镜像兜底 + sha256）→ 实例 binaryPath 落位 + enabled=true → engines.json。
  /// 返回 null = 成功；非 null = 错误文案（UI 弹层直接展示）。
  /// [enginesDir] = settings.enginesDir 用户自选目录（空 = 数据区默认）。
  Future<String?> installEngine(
    String variant, {
    String? enginesDir,
    List<String> mirrors = const [],
    void Function(int received, int total)? onProgress,
  }) async {
    final reg = await _ensureRegistry();
    final rel = StoreCatalog.verified.latest(variant);
    if (rel == null) return '版本白名单里没有 $variant 包（检查网络清单）';
    final dir = (enginesDir == null || enginesDir.trim().isEmpty)
        ? null
        : Directory(enginesDir.trim());
    final store = engineStoreForTest?.call(reg.paths, dir) ??
        EngineStore(reg.paths, enginesDirOverride: dir);
    _log('⬇️ 下载引擎 $variant（官方 ${rel.version}）…');
    final res =
        await store.install(rel, mirrorPrefixes: mirrors, onProgress: onProgress);
    if (!res.ok) {
      _log('❌ 引擎安装失败：${res.error}');
      return res.error ?? '安装失败';
    }
    final instId = 'llamacpp-$variant';
    final inst = reg.instance(instId);
    if (inst != null) {
      inst
        ..binaryPath = res.serverExe
        ..enabled = true;
    } else {
      reg.upsert(EngineInstance(
          id: instId,
          manifestId: instId,
          binaryPath: res.serverExe,
          enabled: true));
    }
    await reg.save();
    lastInstallSuggestion = null;
    _log('✅ 引擎就绪：${res.serverExe}');
    return null;
  }

  /// 推理结束回写绑定表（§7.2「实测由每次会话后回写」）；失败静默。
  void _recordTpsBestEffort() {
    final h = _host;
    final c = _cfg;
    final s = _lastStats;
    if (h == null || c == null || s.isEmpty) return;
    final gen = s['n_gen'];
    final tgen = s['t_gen_ms'];
    final pn = s['n_prompt'];
    final tp = s['t_prompt_ms'];
    if (gen is! int || tgen is! int || gen <= 0 || tgen <= 0) return;
    unawaited(() async {
      try {
        final b = await _ensureBindings();
        await b?.recordRun(
          engineId: h.instanceId,
          modelId: _basename(c.modelPath),
          device: c.device,
          presetJson: c.presetName,
          decodeTps: gen * 1000 / tgen,
          prefillTps: (pn is int && tp is int && tp > 0) ? pn * 1000 / tp : null,
          ctx: c.ctx,
        );
      } catch (_) {}
    }());
  }

  Preset? _matchPreset(EngineManifest manifest, String modelPath) {
    final base = _basename(modelPath);
    for (final p in manifest.presets) {
      final glob = p.modelGlob;
      if (glob == null) continue;
      final pattern = glob
          .split('')
          .map((c) => c == '*' ? '.*' : (c == '?' ? '.' : RegExp.escape(c)))
          .join();
      if (RegExp('^$pattern\$', caseSensitive: false).hasMatch(base)) return p;
    }
    return null;
  }

  @override
  Future<void> initialize() async {
    await _ensureRegistry(); // 幂等；仅装配 registry + 清孤儿，不拉进程
  }

  @override
  Future<bool> loadModel(
    String path, {
    int? nCtx,
    int? chunk,
    int? gpuLayers,
    String? mmprojPath,
    String? draftPath,
    List<String>? customArgs,
    String? engineId,
  }) async {
    try {
      await stopGeneration(); // 换载前掐掉在飞生成
      final reg = await _ensureRegistry();
      final decision = await _route(
          reg: reg, path: path, nCtx: nCtx, engineId: engineId);
      final instId = decision.instanceId;
      if (instId == null) {
        lastInstallSuggestion = decision.needInstall;
        _log('⛔ ${decision.reason}'
            '${decision.suggestion != null ? '（${decision.suggestion}）' : ''}');
        return false;
      }
      _log('🧭 ${decision.reason}'
          '${decision.suggestion != null ? ' · ${decision.suggestion}' : ''}');
      final manifest = reg.manifestOf(instId);
      await _stopOtherHosts(reg, instId); // §7.3 单 active 互斥
      final host = reg.hostOf(instId) as LlamaServerHost;
      _host = host; // 失败也要可取证（debugHost / UI 读状态与日志）

      // ── 参数优先级链（Phase 3）：模型级（本层调用参数，来自
      // LocalModelConfig）> 引擎实例 defaultConfig（引擎管理页配置）>
      // manifest preset（出厂档）。null / 未配置 = 让位下一档。
      final preset = _matchPreset(manifest, path);
      final dc = reg.instance(instId)?.defaultConfig;
      // ctx 收敛纪律（对两档显式值都生效）：preset.ctx 是**实测安全上限**
      // （status.md 缺陷5：4B@c>512 OUT_OF_HOST_MEMORY）。显式值可抬高、
      // 但顶不过实测上限——顶穿=admission 硬拒或执行期崩，宁可收敛留痕。
      final requestedCtx = nCtx ?? dc?.ctx ?? (preset?.ctx ?? 1024);
      final ctxCeiling = preset?.ctx;
      final ctx =
          (ctxCeiling != null && requestedCtx > ctxCeiling) ? ctxCeiling : requestedCtx;
      if (ctx != requestedCtx) {
        _log('ℹ️ ctx $requestedCtx → 收敛到预设上限 $ctx（${preset!.name} 实测上限；'
            '更大上下文请改用 CUDA/Vulkan 引擎）');
      }
      // 自定义尾参：模型级 customArgs 整档赢过引擎 defaultConfig.args（计划
      // 定案，非合并语义）。草稿头经 --model-draft 尾参入场（桌面侧
      // manifest 模板没有 draft 占位符；尾参追加是 llama.cpp「后者覆盖
      // 前者」，用户尾参始终排在最后 → 天然赢）。
      final tailArgs = <String>[
        if (draftPath != null && draftPath.isNotEmpty) ...['--model-draft', draftPath],
        ...((customArgs != null && customArgs.isNotEmpty)
            ? customArgs
            : (dc?.args ?? const <String>[])),
      ];
      if (draftPath != null && draftPath.isNotEmpty) {
        _log('⚡ 投机草稿: $draftPath（--model-draft 尾参入场）');
      }
      final cfg = EngineConfig(
        engineId: instId,
        modelPath: path,
        mmprojPath: mmprojPath,
        ctx: ctx,
        chunk: chunk ?? dc?.chunk ?? preset?.chunk,
        // device 只对 OV 设备族有意义；llamacpp 驱动由 server 自己挑
        // （--list-devices 枚举），不伪造 'NPU' 误导日志/指纹。
        device: dc?.device ??
            preset?.device ??
            (manifest.capabilities.devices
                    .any((d) => d.toUpperCase().contains('NPU'))
                ? 'NPU'
                : null),
        gpuLayers: gpuLayers ?? dc?.gpuLayers ?? preset?.gpuLayers,
        presetName: preset?.name,
        paramsB: preset?.paramsB,
        // preset 附加 env（如 Spark/Omni 的 DISABLE_DECODE_LEVELS=1，
        // spark-npu-accept.ps1 实测必需）+ 引擎 defaultConfig.extraEnv
        // （同键覆盖 preset）；host 侧在 envTemplate 之后合并，且已计入
        // profileId 指纹（D6：换 env = 换编译缓存目录）。
        extraEnv: <String, String>{
          ...?preset?.extraEnv,
          ...?dc?.extraEnv,
        },
        extraArgs: tailArgs,
      );
      final violations = manifest.checkAdmission(ctx: cfg.ctx, paramsB: cfg.paramsB);
      if (violations.isNotEmpty) {
        for (final v in violations) {
          _log('⛔ $v');
        }
        return false; // 前置拦截（设计 §4.1），不等 server 崩
      }

      _log('引擎: ${manifest.display} · ${_basename(path)} · '
          'ctx=${cfg.ctx} chunk=${cfg.chunk ?? '默认'} device=${cfg.device} '
          'cache=${reg.paths.cacheDirFor(cfg.profileId).path}');
      await _logSub?.cancel();
      _logSub = host.logs.listen((l) => _log(l.text), onError: (_) {});

      await host.start(cfg);
      // mmproj（视觉塔）入场时首编预算远超纯文本（实测 Omni-2B+c4096 ≈310s），
      // slack 加到 7 分钟；纯文本维持 +120s。
      final ok = await host.waitReady(Duration(
          milliseconds: manifest.timingHints.coldCompileMs +
              (cfg.mmprojPath != null ? 420000 : 120000)));
      if (!ok) {
        _loaded = false;
        _log('❌ 引擎未就绪: ${host.status.error ?? host.status.phase.name}');
        unawaited(host.stop());
        return false;
      }
      _cfg = cfg;
      _loaded = true;
      lastInstallSuggestion = null; // 加载成功即销掉下载建议
      reg.instance(instId)!.lastConfig = cfg;
      unawaited(reg.save().catchError((Object _) {}));
      _log('✅ 引擎就绪: ${host.baseUrl}');
      _touchIdle(); // §7.3 空闲卸载计时启动
      return true;
    } catch (e) {
      _log('❌ 模型加载异常: $e');
      _loaded = false;
      return false;
    }
  }

  @override
  Future<void> unloadModel() async {
    _idleTimer?.cancel();
    _idleTimer = null;
    await stopGeneration();
    await _logSub?.cancel();
    _logSub = null;
    await _host?.stop();
    _loaded = false;
  }

  // ── M2-e 调度护栏（设计 §7.3）：单 active 互斥 + 空闲超时卸载 ──────────

  /// 空闲卸载时长（routing.json `idleUnloadMinutes`，0=关闭）；≤0 视为关闭。
  Timer? _idleTimer;

  /// 测试注入的空闲时长（非 null 时优先于配置文件）。
  Duration? _idleUnloadForTest;

  /// 测试注入的电源状态（null = 读真实系统）。缺省走真系统的意义在于
  /// 「拔电 NPU 加权」是真行为；但单测必须注入定值 —— 开发机插没插电
  /// 会翻转路由档位，让 speed 启发类断言随机翻转（2026-11-04 实案：
  /// 单 active 互斥测试在拔电状态下选中 NPU 而非 CUDA）。
  bool? _onBatteryForTest;

  void _armIdleTimer(Duration d) {
    _idleTimer?.cancel();
    if (!_loaded || d <= Duration.zero) return;
    _idleTimer = Timer(d, () {
      if (!_loaded) return;
      _log('💤 空闲超时，卸载模型释放显存/NPU 预算（§7.3 调度护栏）');
      unawaited(unloadModel());
    });
  }

  void _touchIdle() {
    if (!_loaded) return;
    final d = _idleUnloadForTest;
    if (d != null) {
      _armIdleTimer(d);
      return;
    }
    // 配置文件值重读成本可忽略（几百字节），直接同步到下次触发。
    unawaited(() async {
      var minutes = 0;
      try {
        final f = File('${_enginePaths().dataDir.path}'
            '${Platform.pathSeparator}routing.json');
        if (await f.exists()) {
          final j = jsonDecode(await f.readAsString());
          if (j is Map && j['idleUnloadMinutes'] is num) {
            minutes = (j['idleUnloadMinutes'] as num).toInt();
          }
        }
      } catch (_) {}
      if (minutes > 0) {
        _armIdleTimer(Duration(minutes: minutes));
      } else {
        _idleTimer?.cancel();
        _idleTimer = null;
      }
    }());
  }

  /// 单 active 互斥：除 [keepId] 外，把处于启动/就绪态的本地 host 全部停掉。
  /// （显存与 NPU 共享内存预算表：同一时刻至多一个 loaded 引擎。）
  Future<void> _stopOtherHosts(EngineRegistry reg, String keepId) async {
    for (final inst in reg.instances) {
      if (inst.id == keepId) continue;
      if (reg.manifestOf(inst.id).kind == 'remote') continue;
      if (reg.existingHostOf(inst.id) == null) continue; // 未拉起过的不碰
      final h = reg.hostOf(inst.id);
      if (h.baseUrl != null || h.status.isStarting || h.status.isUsable) {
        _log('🛑 单 active 互斥：停止 ${inst.id}');
        await h.stop();
      }
    }
  }

  /// 测试注入 registry（绕过 dev 工厂；注入方须自配 fake runner/probe）。
  @visibleForTesting
  void attachRegistryForTest(EngineRegistry reg, {EnginePaths? paths}) {
    _registry = reg;
    _pathsOverride = paths;
    _swept = true;
  }

  /// 测试注入空闲卸载时长（非 null 时优先于 routing.json）。
  @visibleForTesting
  set idleUnloadForTest(Duration? d) => _idleUnloadForTest = d;

  @visibleForTesting
  set onBatteryForTest(bool? v) => _onBatteryForTest = v;

  // ── 设置推送（server 侧语义：加载参数在 start 落，请求参数随 body）────
  // OOM 守卫 = manifest admission；KV 精度/FA = 引擎参数链（NPU 硬约束 -fa 1）。
  // 手机端 JNI 推送三件套 setOomGuard/setKvCacheType/setFlashAttn 已随 Phase 4 删除。
  @override
  Future<void> setEnableThinking(bool enable) async => _enableThinking = enable;

  @override
  Future<void> resetContext() async {
    // llama-server 每次请求重建上下文（无追加式 KV 复用），无需清缓存。
  }

  @override
  Future<bool> isLoaded() async => _loaded && _isReady();

  @override
  Future<bool> isModelLoaded() async => _loaded && _isReady();

  bool _isReady() {
    final h = _host;
    return h != null && h.baseUrl != null;
  }

  /// 诊断与 M1-b UI：当前绑定的引擎宿主（未加载/失败后仍可读状态、日志、spawn 现场）。
  LlamaServerHost? debugHost() => _host;

  /// 诊断：引擎注册表（M1-b 引擎管理页用）。
  Future<EngineRegistry> registry() => _ensureRegistry();

  @override
  Future<Map<String, dynamic>> getModelInfo() async => {
        'path': _cfg?.modelPath ?? '',
        'n_ctx': _cfg?.ctx ?? 0,
        'engine': _cfg?.engineId ?? '',
        'device': _cfg?.device ?? '',
      };

  @override
  Future<Map<String, int>> getMemoryInfo() async {
    // M1 暂缺 Windows 内存快照（面板对空 Map 容错）；M2 用 GlobalMemoryStatusEx FFI。
    return const {};
  }

  @override
  Future<Map<String, dynamic>> getInferenceStats() async => _lastStats;

  // getDeviceInfo（SoC 硬件信息）已随 Phase 4 删除：唯一消费者是天玑芯片
  // 禁用 OpenCL 后端的手机端判定。

  // ── 生成 ──────────────────────────────────────────────────────────────

  @override
  Stream<String> completionWithMessages({
    required String prompt,
    required String messagesJson,
    String? imagePath,
    List<String>? imagePaths,
    String? audioPath,
    int maxTokens = 2048,
    double temperature = 0.7,
    double topP = 0.9,
  }) {
    if (!_isReady()) {
      return Stream.error(StateError('模型未加载，请先在模型管理页加载模型'));
    }
    final List<Map<String, dynamic>> msgs;
    try {
      msgs = _decodeMessages(messagesJson);
    } catch (e) {
      return Stream.error(e);
    }
    if (prompt.trim().isNotEmpty) {
      msgs.add({'role': 'user', 'content': prompt});
    }
    if (audioPath != null) {
      _log('⚠️ Windows 语音输入未接入（M3），本条忽略音频');
    }
    final images = <String>[
      if (imagePath != null) imagePath,
      ...?imagePaths,
    ];
    return _postChat(msgs,
        images: images,
        maxTokens: maxTokens,
        temperature: temperature,
        topP: topP);
  }

  @override
  Stream<String> completion({
    required String prompt,
    int maxTokens = 2048,
    double temperature = 0.7,
    double topP = 0.9,
  }) {
    if (!_isReady()) return Stream.error(StateError('模型未加载'));
    return _postRawCompletion(prompt,
        maxTokens: maxTokens, temperature: temperature, topP: topP);
  }

  @override
  Future<String> complete({
    required String prompt,
    int maxTokens = 2048,
    double temperature = 0.7,
    double topP = 0.9,
  }) async {
    if (!_isReady()) throw StateError('模型未加载');
    final res = await _dio.post<Map<String, dynamic>>(
      '${_host!.baseUrl}/completion',
      data: {
        'prompt': prompt,
        'n_predict': maxTokens,
        'temperature': temperature,
        'top_p': topP,
        'stream': false,
      },
    );
    final content = res.data?['content'];
    return content is String ? content : '';
  }

  @override
  Future<void> stopGeneration() async {
    final c = _cancel;
    _cancel = null;
    if (c != null && !c.isCancelled) {
      c.cancel('user_stop'); // dio 5 CancelToken.cancel 同步返回；连接断开即打断生成
    }
  }

  // ── 语音（M3）──────────────────────────────────────────────────────────
  @override
  Future<bool> supportsAudio() async => false;
  @override
  Future<bool> startRecording() async => false;
  @override
  Future<String?> stopRecording() async => null;

  @override
  Future<Map<String, double>> benchmark({
    String prompt = 'List 5 common fruits.',
    int nRepeats = 3,
  }) async {
    var tpsSum = 0.0;
    for (var i = 0; i < nRepeats; i++) {
      final t0 = DateTime.now();
      final out = await complete(prompt: prompt, maxTokens: 64);
      final secs = DateTime.now().difference(t0).inMilliseconds / 1000.0;
      if (secs > 0) tpsSum += (out.length / 4) / secs; // 粗估 token 数
    }
    return {'tg': tpsSum / (nRepeats <= 0 ? 1 : nRepeats), 'pp': 0};
  }

  @override
  void dispose() {
    unawaited(_logSub?.cancel());
    unawaited(_registry?.dispose().catchError((Object _) {}));
    _registry = null;
    _host = null;
    _loaded = false;
  }

  // ── SSE 内部 ──────────────────────────────────────────────────────────

  List<Map<String, dynamic>> _decodeMessages(String messagesJson) {
    final decoded = jsonDecode(messagesJson);
    if (decoded is! List) throw FormatException('messagesJson 不是数组');
    return decoded
        .map((e) => Map<String, dynamic>.from(e as Map))
        .toList();
  }

  Stream<String> _postChat(List<Map<String, dynamic>> msgs,
          {required List<String> images,
          required int maxTokens,
          required double temperature,
          required double topP}) =>
      _streamRequest(
        url: '${_host!.baseUrl}/chat/completions',
        buildBody: () async => {
          'messages': await _attachImages(msgs, images),
          'max_tokens': maxTokens,
          'temperature': temperature,
          'top_p': topP,
          'stream': true,
          // --jinja 下 Qwen3 类模型思考开关；LFM3 等忽略未知 kwargs。
          'chat_template_kwargs': {'enable_thinking': _enableThinking},
        },
        rawMode: false,
      );

  Stream<String> _postRawCompletion(String prompt,
          {required int maxTokens,
          required double temperature,
          required double topP}) =>
      _streamRequest(
        url: '${_host!.baseUrl}/completion',
        buildBody: () async => {
          'prompt': prompt,
          'n_predict': maxTokens,
          'temperature': temperature,
          'top_p': topP,
          'stream': true,
        },
        rawMode: true,
      );

  Future<List<Map<String, dynamic>>> _attachImages(
      List<Map<String, dynamic>> msgs, List<String> images) async {
    if (images.isEmpty) return msgs;
    if (msgs.isEmpty) msgs.add({'role': 'user', 'content': ''});
    final last = msgs.last;
    final content = last['content'];
    final parts = <Map<String, dynamic>>[
      if (content is String && content.isNotEmpty)
        {'type': 'text', 'text': content}
      else if (content is List)
        for (final p in content) Map<String, dynamic>.from(p as Map),
    ];
    for (final path in images) {
      final f = File(path);
      if (!await f.exists()) {
        _log('⚠️ 图片不存在，已跳过: $path');
        continue;
      }
      final b64 = base64Encode(await f.readAsBytes());
      parts.add({
        'type': 'image_url',
        'image_url': {'url': 'data:${_mimeOf(path)};base64,$b64'},
      });
    }
    last['content'] = parts;
    return msgs;
  }

  Stream<String> _streamRequest({
    required String url,
    required Future<Map<String, dynamic>> Function() buildBody,
    required bool rawMode,
  }) {
    final ctl = StreamController<String>();
    unawaited(_runStream(ctl, url, buildBody, rawMode));
    return ctl.stream;
  }

  Future<void> _runStream(
    StreamController<String> ctl,
    String url,
    Future<Map<String, dynamic>> Function() buildBody,
    bool rawMode,
  ) async {
    final cancel = CancelToken();
    _cancel = cancel;
    final t0 = DateTime.now();
    _lastStats = const {}; // 上一请求的 timings 不得串台
    final dec = ChatSseDecoder(rawMode: rawMode);
    try {
      var body = await buildBody();
      for (var trimTry = 0;; trimTry++) {
        final res = await _dio.post<ResponseBody>(
          url,
          data: body,
          cancelToken: cancel,
          options: Options(
            responseType: ResponseType.stream,
            headers: const {'Accept': 'text/event-stream'},
            // stream 响应 dio 解析不了 body，4xx 正文只能自己抽干流取证
            // （M1-d 实案：http=400 只剩 dio 模板文案，无从定位）。
            validateStatus: (_) => true,
          ),
        );
        final status = res.statusCode ?? 0;
        if (status >= 400) {
          final text = await _drainBody(res.data);
          final short = text.length > 300 ? '${text.substring(0, 300)}…' : text;
          if (_isContextOverflow(text) && trimTry < 3 && _trimOldestHistory(body)) {
            // 真机实案：设置页把 ctx 调小后，续跑的会话历史超新 ctx → server 400。
            // 丢最旧的非 system 轮重试，而不是把死局抛给用户。
            _log('✂️ 上下文超限：丢弃最旧历史重试 ${trimTry + 1}/3');
            continue;
          }
          ctl.addError(StateError('引擎请求失败(http=$status): '
              '${short.isEmpty ? (res.statusMessage ?? '') : short}'));
          await ctl.close();
          return;
        }
        await for (final data in sseDataLines(res.data!.stream)) {
          if (data == '[DONE]') break;
          Map<String, dynamic> chunk;
          try {
            chunk = jsonDecode(data) as Map<String, dynamic>;
          } catch (_) {
            continue; // 容忍半行/坏行：SSE 断线重连与分块边界的常态
          }
          for (final piece in dec.feedChunk(chunk)) {
            ctl.add(piece);
          }
        }
        break;
      }
      for (final piece in dec.finish()) {
        ctl.add(piece);
      }
      _lastStats = dec.timings ??
          {
            // server 未给 timings 时 Dart 侧兜底（口径：SSE 增量计数/挂钟）。
            'n_gen': dec.tokens,
            't_gen_ms': DateTime.now().difference(t0).inMilliseconds,
            't_prompt_ms': 0,
          };
      _recordTpsBestEffort(); // 实测 t/s 回写绑定表（路由真源）
      _touchIdle(); // §7.3 空闲卸载计时重置
      await ctl.close();
    } on DioException catch (e) {
      if (CancelToken.isCancel(e)) {
        await ctl.close(); // 用户主动停止：静默收尾（与 Android 语义一致）
      } else {
        ctl.addError(_describeDio(e));
        await ctl.close();
      }
    } catch (e) {
      ctl.addError(e);
      await ctl.close();
    } finally {
      if (identical(_cancel, cancel)) _cancel = null;
    }
  }

  /// SSE `data:` 行流（容忍非 utf8 字节与断行）。公开以便单测直接喂字节。
  static Stream<String> sseDataLines(Stream<List<int>> raw) async* {
    final lines = const Utf8Decoder(allowMalformed: true)
        .bind(raw)
        .transform(const LineSplitter());
    await for (final line in lines) {
      final t = line.trim();
      if (t.startsWith('data:')) yield t.substring(5).trim();
    }
  }

  Future<String> _drainBody(ResponseBody? rb) async {
    if (rb == null) return '';
    try {
      final bytes = <int>[];
      await for (final c in rb.stream) {
        bytes.addAll(c);
        if (bytes.length > 8192) break; // 取证够用即止
      }
      return const Utf8Decoder(allowMalformed: true).convert(bytes);
    } catch (_) {
      return '';
    }
  }

  /// server 因提示超出 n_ctx 报 400 的正文特征（llama-server 措辞族）。
  static bool isContextOverflowText(String text) {
    final t = text.toLowerCase();
    return t.contains('exceed') ||
        t.contains('n_ctx') ||
        t.contains('context size') ||
        t.contains('prompt is too long') ||
        t.contains('too many tokens');
  }

  bool _isContextOverflow(String text) => isContextOverflowText(text);

  /// 丢最旧的非 system 消息（保留 system 前缀与末位 user），原地改 body。
  /// 可裁到只剩 system+末位 user 为止；再裁返回 false。公开静态便于单测。
  static bool trimOldestHistory(Map<String, dynamic> body) {
    final msgs = body['messages'];
    if (msgs is! List || msgs.length < 3) return false;
    var head = 0;
    if (msgs.first is Map && msgs.first['role'] == 'system') head = 1;
    if (msgs.length - head <= 2) return false; // 剩 system+user+1 以下不再裁
    msgs.removeAt(head);
    return true;
  }

  bool _trimOldestHistory(Map<String, dynamic> body) => trimOldestHistory(body);

  StateError _describeDio(DioException e) {
    final code = e.response?.statusCode;
    // SSE 流式请求里 dio 不会把 body 解析成 Map——400 的 server 报错 JSON
    // 就是 String。取证必须带出正文，否则只有 http=400 无法定位（M1-d 实案）。
    final raw = e.response?.data;
    final detail = raw is Map
        ? (raw['error'] ?? raw['message'])?.toString()
        : raw is String
            ? (raw.length > 300 ? '${raw.substring(0, 300)}…' : raw)
            : raw is List<int>
                ? String.fromCharCodes(raw.take(300))
                : null;
    return StateError('引擎请求失败(${e.type.name}${code != null ? ' http=$code' : ''}): '
        '${(detail == null || detail.isEmpty) ? e.message : detail}');
  }
}

String _basename(String path) {
  final i = path.replaceAll('\\', '/').lastIndexOf('/');
  return i < 0 ? path : path.substring(i + 1);
}

String _mimeOf(String path) {
  final p = path.toLowerCase();
  if (p.endsWith('.png')) return 'image/png';
  if (p.endsWith('.webp')) return 'image/webp';
  if (p.endsWith('.gif')) return 'image/gif';
  if (p.endsWith('.bmp')) return 'image/bmp';
  return 'image/jpeg';
}
