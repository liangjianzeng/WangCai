// LlamaServerHost：spawn/守护/kill llama-server（设计 §4.2/§4.3）。
// - 状态机由日志+/health 驱动；start() 不等就绪（UI 不卡），waitReady() 供网关等待。
// - 崩溃走重启预算 3 次（1s/4s/16s 退避），耗尽置 error（M1-d DoD：看门狗复活）。
// - env 纪律（run-npu.ps1 等价）：清 GGML_OPENVINO_*/NPUW_*、PATH 前置、独立编译缓存目录。
import 'dart:async';

import 'engine_config.dart';
import 'engine_host.dart';
import 'engine_manifest.dart';
import 'engine_paths.dart';
import 'engine_status.dart';
import 'process_ledger.dart';
import 'runtime_env.dart';

class LlamaServerHost implements EngineHost {
  LlamaServerHost({
    required this.instanceId,
    required this.manifest,
    required this.binaryPath,
    required this.paths,
    List<String>? pathPrefixes,
    ProcessRunner? processRunner,
    HealthProbe? healthProbe,
    PortAllocator? portAllocator,
    Sleeper? sleeper,
    ProcessLedger? ledger,
    int maxRestartAttempts = 3,
    Map<String, String>? parentEnv,
    Duration healthPollInterval = const Duration(seconds: 1),
    Duration readyTimeoutSlack = const Duration(seconds: 45),
  })  : _prefixes = pathPrefixes ?? manifest.pathPrefixes,
        _runner = processRunner ?? defaultProcessRunner,
        _health = healthProbe ?? defaultHealthProbe,
        _portAlloc = portAllocator ?? defaultPortAllocator,
        _sleep = sleeper ?? realSleeper,
        _ledger = ledger ?? ProcessLedger(paths),
        _maxRestarts = maxRestartAttempts,
        _parentEnv = parentEnv,
        _pollEvery = healthPollInterval,
        _readySlack = readyTimeoutSlack;

  final String instanceId;
  @override
  final EngineManifest manifest;
  final String binaryPath;
  final EnginePaths paths;

  final List<String> _prefixes;
  final ProcessRunner _runner;
  final HealthProbe _health;
  final PortAllocator _portAlloc;
  final Sleeper _sleep;
  final ProcessLedger _ledger;
  final int _maxRestarts;
  final Map<String, String>? _parentEnv;
  final Duration _pollEvery;
  final Duration _readySlack;

  final _machine = EngineStateMachine();
  final _statusCtl = StreamController<EngineStatus>.broadcast();
  final _logsCtl = StreamController<EngineLogLine>.broadcast();
  final _logHistory = <EngineLogLine>[];
  static const _logHistoryCap = 2000;

  EngineConfig? _cfg;
  EngineProcess? _proc;
  int _gen = 0;
  int _attempts = 0;
  bool _stopping = false;
  int? _port;
  String? _stderrTail;

  EngineConfig? get lastConfig => _cfg;

  @override
  EngineStatus get status => _machine.state;
  @override
  Stream<EngineStatus> get onStatus => _statusCtl.stream;
  @override
  Stream<EngineLogLine> get logs => _logsCtl.stream;
  List<EngineLogLine> get logHistory => List.unmodifiable(_logHistory);

  @override
  String? get baseUrl =>
      _machine.state.phase == EnginePhase.ready && _port != null
          ? 'http://127.0.0.1:$_port/v1'
          : null;

  /// spawn 并异步推进状态机（不等就绪）。已在跑则先停（= applyPreset 语义，D5）。
  @override
  Future<void> start(EngineConfig cfg) async {
    if (_machine.wantRunning || _proc != null) {
      await stop();
    }
    _cfg = cfg;
    _attempts = 0;
    await _launch();
  }

  /// 应用即重启（D5）。
  Future<void> applyPreset(EngineConfig cfg) => start(cfg);

  Future<bool> waitReady(Duration timeout) async {
    final deadline = DateTime.now().add(timeout);
    while (DateTime.now().isBefore(deadline)) {
      if (_machine.state.phase == EnginePhase.ready) return true;
      if (_machine.state.phase == EnginePhase.error ||
          _machine.state.phase == EnginePhase.stopped) {
        return false;
      }
      await _sleep(const Duration(milliseconds: 200));
    }
    return false;
  }

  @override
  Future<void> stop() async {
    _stopping = true;
    _gen++; // 作废在飞的 poller/exit 回调
    final proc = _proc;
    _proc = null;
    _emit(_machine.handle(StopRequested()));
    if (proc != null) {
      proc.kill();
      try {
        await proc.exitCode.timeout(const Duration(seconds: 5));
      } catch (_) {}
    }
    await _ledger.clear(instanceId).catchError((_) {});
    _emit(_machine.handle(ProcessExitedEvent(0)));
  }

  @override
  Future<EngineCapabilities> probe() async => manifest.capabilities;

  @override
  Future<void> dispose() async {
    await stop();
    await _statusCtl.close();
    await _logsCtl.close();
  }

  // ── 内部 ────────────────────────────────────────────────────────────────

  Future<void> _launch() async {
    final cfg = _cfg!;
    final gen = ++_gen;
    _stopping = false;
    _emit(_machine.handle(StartRequested()));
    try {
      final port = await _portAlloc();
      _port = port;
      final cacheDir = paths.cacheDirFor(cfg.profileId);
      await cacheDir.create(recursive: true);

      final values = <String, String>{
        'model': cfg.modelPath,
        'port': '$port',
        'ctx': '${cfg.ctx ?? 1024}',
        'devArg': _devArgFor(cfg.device),
        if (cfg.mmprojPath != null) 'mmproj': cfg.mmprojPath!,
        if (cfg.device != null) 'device': cfg.device!,
        if (cfg.chunk != null) 'chunk': '${cfg.chunk}',
        if (cfg.gpuLayers != null) 'gpuLayers': '${cfg.gpuLayers}',
        if (cfg.threads != null) 'threads': '${cfg.threads}',
        'cacheDir': cacheDir.path,
      };
      final args = renderArgsTemplate(manifest.argsTemplate, values);
      final engineEnv = <String, String>{};
      manifest.envTemplate.forEach((k, tpl) {
        final v = renderEnvValue(tpl, values);
        if (v != null) engineEnv[k] = v;
      });
      engineEnv.addAll(cfg.extraEnv);
      final env = buildServerEnv(
        parentEnv: _parentEnv ?? const {},
        pathPrefixes: [
          _dirOf(binaryPath),
          ..._prefixes.map((p) => _isAbsolute(p) ? p : _join(_dirOf(binaryPath), p)),
        ],
        engineEnv: engineEnv,
      );

      final proc = await _runner(binaryPath, args, env);
      _proc = proc;
      await _ledger.write(LedgerEntry(
          instanceId: instanceId,
          pid: proc.pid,
          port: port,
          startedAt: DateTime.now()));
      pipeProcessStream(proc.stdout, onLine: (l) => _onLog(l, gen));
      pipeProcessStream(proc.stderr, onLine: (l) => _onLog(l, gen));
      unawaited(proc.exitCode
          .then((code) => _onExit(code, gen))
          .catchError((Object _) {}));
      unawaited(_waitReady(gen));
    } catch (e) {
      _emit(_machine.handle(CrashDetectedEvent('无法启动引擎：$e')));
    }
  }

  void _onLog(String line, int gen) {
    if (gen != _gen) return;
    _logHistory.add(EngineLogLine.now(line));
    if (_logHistory.length > _logHistoryCap) {
      _logHistory.removeRange(0, _logHistory.length - _logHistoryCap);
    }
    _logsCtl.add(EngineLogLine.now(line));
    final next = _machine.handle(LogLineEvent(line));
    if (next != _machine.state) _emit(next);
    if (next.phase == EnginePhase.error) _stderrTail = line;
  }

  Future<void> _waitReady(int gen) async {
    final deadline = DateTime.now().add(
        Duration(milliseconds: manifest.timingHints.coldCompileMs) + _readySlack);
    var timedOut = false;
    while (gen == _gen && !_stopping) {
      final st = _machine.state.phase;
      if (st == EnginePhase.ready || st == EnginePhase.error) return;
      if (DateTime.now().isAfter(deadline)) {
        timedOut = true;
        break;
      }
      if (await _health('127.0.0.1', _port ?? 0)) {
        if (gen != _gen) return;
        _emit(_machine.handle(HealthOkEvent()));
        return;
      }
      await _sleep(_pollEvery);
    }
    if (timedOut &&
        gen == _gen &&
        _machine.state.phase != EnginePhase.ready &&
        _machine.state.phase != EnginePhase.stopped &&
        _machine.state.phase != EnginePhase.error) {
      _emit(_machine.handle(CrashDetectedEvent(
          '启动超时（${manifest.timingHints.coldCompileMs}ms+slack 未就绪）${_stderrTail != null ? '：$_stderrTail' : ''}')));
    }
  }

  Future<void> _onExit(int code, int gen) async {
    if (gen != _gen) return;
    if (_stopping || !_machine.wantRunning) {
      _emit(_machine.handle(ProcessExitedEvent(code)));
      return;
    }
    if (_attempts < _maxRestarts) {
      _attempts++;
      _logsCtl.add(EngineLogLine.now(
          'engine exited code=$code，重启 $_attempts/$_maxRestarts（指数退避）'));
      await _sleep(Duration(seconds: [1, 4, 16][_attempts - 1]));
      if (gen != _gen || !_machine.wantRunning) return;
      await _launch();
    } else {
      _emit(_machine.handle(
          ProcessExitedEvent(code))); // wantRunning → error：重启预算耗尽
    }
  }

  void _emit(EngineStatus s) {
    if (!_statusCtl.isClosed) _statusCtl.add(s);
  }

  static String _devArgFor(String? device) {
    switch (device) {
      case 'CPU':
        return 'OPENVINO0';
      case 'GPU':
      case 'GPU.0':
        return 'OPENVINO1';
      case 'NPU':
        return 'OPENVINO3';
      default:
        return device ?? 'OPENVINO3'; // 允许直接写 OPENVINO0..3
    }
  }
}

String _dirOf(String path) {
  final i = path.replaceAll('\\', '/').lastIndexOf('/');
  return i <= 0 ? '.' : path.substring(0, i);
}

bool _isAbsolute(String p) =>
    RegExp(r'^([A-Za-z]:[\\/]|/)').hasMatch(p) || p.startsWith(r'\\');

String _join(String a, String b) {
  if (a.isEmpty || a.endsWith('/') || a.endsWith(r'\')) return '$a$b';
  final sep = a.contains('\\') ? '\\' : '/';
  return '$a$sep$b';
}

/// envTemplate 值渲染：`{name}` / `{name=default}`；缺值且无默认 → null（删除该 env）。
String? renderEnvValue(String template, Map<String, String> values) {
  final m = RegExp(r'^\{([A-Za-z0-9_]+)(=[^}]*)?\}$').firstMatch(template);
  if (m == null) return template;
  final v = values[m.group(1)!];
  if (v != null) return v;
  return m.group(2)?.substring(1);
}
