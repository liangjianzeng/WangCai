// 引擎测试共享的假子进程（2026-11-06 健康检查收编）：此前 5 个套件各抄一份
// 逐字相同的实现（llama_server_host/engine_defaults_chain/npu_generation_adapt/
// on_demand_install/single_active_and_idle），改 EngineProcess 接口要改 5 处——
// 同 test/helpers/fake_llm.dart 的 P0-3 教训，抽到唯一出处。
import 'dart:async';
import 'dart:convert';

import 'package:wangcai/engine/engine_host.dart' show EngineProcess;

/// 假 [EngineProcess]：stdout/stderr 手动投喂，退出码手动触发，kill 记标志。
class FakeProcess implements EngineProcess {
  final stdoutCtl = StreamController<List<int>>();
  final stderrCtl = StreamController<List<int>>();
  final _exit = Completer<int>();
  bool killed = false;

  @override
  final int pid = 4242;
  @override
  Stream<List<int>> get stdout => stdoutCtl.stream;
  @override
  Stream<List<int>> get stderr => stderrCtl.stream;
  @override
  Future<int> get exitCode => _exit.future;
  @override
  bool kill() {
    killed = true;
    if (!_exit.isCompleted) _exit.complete(0);
    return true;
  }

  /// 投喂一行 stdout（UTF-8）。
  void emitOut(String s) => stdoutCtl.add(utf8.encode(s));

  /// 投喂一行 stderr（UTF-8）。
  void emitErr(String s) => stderrCtl.add(utf8.encode(s));

  /// 手动结束进程（幂等）。
  void exitWith(int code) {
    if (!_exit.isCompleted) _exit.complete(code);
  }
}
