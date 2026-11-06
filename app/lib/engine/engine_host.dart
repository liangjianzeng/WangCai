// EngineHost 抽象（设计 §2.3）：进程与模型生命周期归它；token 流不归它
// （那是既有 LlmAdapter/OpenAiService 的事，D2 一个契约）。
import 'dart:async';
import 'dart:convert';
import 'dart:io' as io;

import 'engine_config.dart';
import 'engine_manifest.dart';
import 'engine_status.dart';

abstract class EngineHost {
  EngineManifest get manifest;
  EngineStatus get status;
  Stream<EngineStatus> get onStatus;
  Stream<EngineLogLine> get logs;
  /// 就绪后的 OpenAI 兼容基址（含 /v1）；未就绪为 null。
  String? get baseUrl;

  Future<void> start(EngineConfig cfg);
  Future<void> stop();
  Future<EngineCapabilities> probe();
  Future<void> dispose();
}

// ── 可注入的进程/健康探测原语（host_test 用假实现驱动全状态机）────────────────

abstract class EngineProcess {
  Stream<List<int>> get stdout;
  Stream<List<int>> get stderr;
  Future<int> get exitCode;
  int get pid;
  bool kill();
}

class _IoProcess implements EngineProcess {
  _IoProcess(this._p);
  final io.Process _p;
  @override
  Stream<List<int>> get stdout => _p.stdout;
  @override
  Stream<List<int>> get stderr => _p.stderr;
  @override
  Future<int> get exitCode => _p.exitCode;
  @override
  int get pid => _p.pid;
  @override
  bool kill() => _p.kill();
}

typedef ProcessRunner = Future<EngineProcess> Function(
    String executable, List<String> arguments, Map<String, String> environment);

Future<EngineProcess> defaultProcessRunner(
    String executable, List<String> arguments, Map<String, String> environment) async {
  final p = await io.Process.start(executable, arguments,
      environment: environment, includeParentEnvironment: false);
  return _IoProcess(p);
}

typedef HealthProbe = Future<bool> Function(String host, int port);

Future<bool> defaultHealthProbe(String host, int port) async {
  final client = io.HttpClient();
  try {
    final req = await client
        .getUrl(Uri.parse('http://$host:$port/health'))
        .timeout(const Duration(seconds: 3));
    final res = await req.close().timeout(const Duration(seconds: 3));
    await res.drain<void>();
    return res.statusCode == 200;
  } catch (_) {
    return false;
  } finally {
    client.close(force: true);
  }
}

/// 加载期预热探针：对 llama-server 发一条真 completion，把 prefill/decode
/// 懒编译吸收进加载阶段（2026-11-06 用户指令：预热要在模型加载时做完）。
typedef PrewarmCompletion = Future<void> Function(int port);

/// 默认实现：prompt 灌过一个 prefill chunk 满桶（~140 字 ≥ chunk128 满桶）
/// + 8 token 小尾段逼出首个 decode 级别图；temp 0 贪心，走原生 /completion。
Future<void> defaultPrewarmCompletion(int port) async {
  final client = io.HttpClient()
    ..connectionTimeout = const Duration(seconds: 5);
  try {
    final req = await client.postUrl(
        Uri.parse('http://127.0.0.1:$port/completion'));
    req.headers.contentType = io.ContentType.json;
    req.write('{"prompt":"${'预热。' * 60}",'
        '"n_predict":8,"temp":0.0,"cache_prompt":false}');
    final res = await req.close();
    await res.drain<void>();
    if (res.statusCode != 200) {
      throw io.HttpException('prewarm http=${res.statusCode}');
    }
  } finally {
    client.close(force: true);
  }
}

typedef PortAllocator = Future<int> Function();

Future<int> defaultPortAllocator() async {
  final s = await io.ServerSocket.bind(io.InternetAddress.loopbackIPv4, 0);
  final port = s.port;
  await s.close();
  return port;
}

typedef Sleeper = Future<void> Function(Duration);
Future<void> realSleeper(Duration d) => Future<void>.delayed(d);

/// 子进程 stdout/stderr → EngineLogLine 流 + 喂状态机。
void pipeProcessStream(
  Stream<List<int>> stream, {
  required void Function(String line) onLine,
}) {
  stream
      .transform(const Utf8Decoder(allowMalformed: true))
      .transform(const LineSplitter())
      .listen(onLine, onError: (Object _) {});
}
