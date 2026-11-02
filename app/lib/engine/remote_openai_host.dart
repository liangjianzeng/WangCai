// RemoteOpenAiHost（设计 §6）：无进程的 EngineHost——start/stop 只管"配置生效"，
// probe 打 /v1/models。路由上与本地引擎同权（第 5 类引擎，兜底位）。
import 'dart:async';
import 'dart:convert';
import 'dart:io' as io;

import 'engine_config.dart';
import 'engine_host.dart';
import 'engine_manifest.dart';
import 'engine_status.dart';

class RemoteOpenAiHost implements EngineHost {
  RemoteOpenAiHost({required this.instanceId, required this.manifest});

  final String instanceId;
  @override
  final EngineManifest manifest;

  final _machine = EngineStateMachine();
  final _statusCtl = StreamController<EngineStatus>.broadcast();
  final _logsCtl = StreamController<EngineLogLine>.broadcast();
  String? _base;
  String? _apiKey;
  String? _model;

  @override
  EngineStatus get status => _machine.state;
  @override
  Stream<EngineStatus> get onStatus => _statusCtl.stream;
  @override
  Stream<EngineLogLine> get logs => _logsCtl.stream;
  @override
  String? get baseUrl => _machine.state.phase == EnginePhase.ready ? _base : null;
  String? get modelId => _model;

  @override
  Future<void> start(EngineConfig cfg) async {
    final base = cfg.remoteBaseUrl;
    if (base == null || base.isEmpty) {
      _emit(_machine
          .handle(CrashDetectedEvent('远端引擎缺少 baseUrl（设置页 API 接入配置）')));
      return;
    }
    _base = base.endsWith('/v1') ? base : '${base.replaceAll(RegExp(r'/$'), '')}/v1';
    _apiKey = cfg.remoteApiKey;
    _model = cfg.remoteModel;
    _emit(_machine.handle(StartRequested()));
    _emit(_machine.handle(HealthOkEvent()));
  }

  @override
  Future<void> stop() async {
    _emit(_machine.handle(StopRequested()));
    _emit(_machine.handle(ProcessExitedEvent(0)));
  }

  @override
  Future<EngineCapabilities> probe() async {
    if (_base == null) return manifest.capabilities;
    try {
      final client = io.HttpClient();
      try {
        final req = await client
            .getUrl(Uri.parse('$_base/models'))
            .timeout(const Duration(seconds: 8));
        if (_apiKey != null && _apiKey!.isNotEmpty) {
          req.headers.set('Authorization', 'Bearer $_apiKey');
        }
        final res = await req.close().timeout(const Duration(seconds: 8));
        final body = await res.transform(utf8.decoder).join();
        if (res.statusCode != 200) {
          return manifest.capabilities;
        }
        final j = jsonDecode(body);
        final n = (j is Map && j['data'] is List) ? (j['data'] as List).length : -1;
        _logsCtl.add(EngineLogLine.now('/v1/models → $n 个模型'));
        return EngineCapabilities(
          nativeToolCall: true,
          vision: true,
          audio: false,
          devices: const ['remote'],
        );
      } finally {
        client.close(force: true);
      }
    } catch (_) {
      return manifest.capabilities;
    }
  }

  @override
  Future<void> dispose() async {
    await _statusCtl.close();
    await _logsCtl.close();
  }

  void _emit(EngineStatus s) {
    if (!_statusCtl.isClosed) _statusCtl.add(s);
  }
}
