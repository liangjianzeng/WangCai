// 进程账本 port.json（设计 §3 / M0-3 附 实测：杀外壳必留孤儿 llama-server）。
// 壳启动时 scanOrphans + sweep：账本里有 pid 还活着 → 收编或杀掉，防"上次崩了
// 留下三个 server 抢显存"。
import 'dart:convert';
import 'dart:io';

import 'engine_paths.dart';

class LedgerEntry {
  const LedgerEntry({
    required this.instanceId,
    required this.pid,
    required this.port,
    required this.startedAt,
  });

  final String instanceId;
  final int pid;
  final int port;
  final DateTime startedAt;

  Map<String, dynamic> toJson() => {
        'instanceId': instanceId,
        'pid': pid,
        'port': port,
        'startedAt': startedAt.toIso8601String(),
      };

  factory LedgerEntry.fromJson(Map<String, dynamic> j) => LedgerEntry(
        instanceId: j['instanceId'] as String,
        pid: j['pid'] as int,
        port: j['port'] as int,
        startedAt: DateTime.parse(j['startedAt'] as String),
      );
}

/// pid 探活（注入以便测试；生产实现走 tasklist）。
typedef PidAlive = Future<bool> Function(int pid);

Future<bool> tasklistPidAlive(int pid) async {
  try {
    final r = await Process.run(
        'tasklist', ['/FI', 'PID eq $pid', '/NH'],
        stdoutEncoding: utf8, stderrEncoding: utf8);
    // 注意：raw string 不插值，必须用普通字符串 + 转义 \b。
    return (r.stdout as String).contains(RegExp('\\b$pid\\b'));
  } catch (_) {
    return false;
  }
}

class ProcessLedger {
  ProcessLedger(this.paths, {PidAlive? pidAlive})
      : pidAlive = pidAlive ?? tasklistPidAlive;

  final EnginePaths paths;
  final PidAlive pidAlive;

  Future<void> write(LedgerEntry e) async {
    await paths.ensureDirs();
    await paths.ledgerFile(e.instanceId)
        .writeAsString(jsonEncode(e.toJson()), flush: true);
  }

  Future<void> clear(String instanceId) async {
    final f = paths.ledgerFile(instanceId);
    if (await f.exists()) await f.delete();
  }

  Future<List<LedgerEntry>> readAll() async {
    if (!await paths.ledgerDir.exists()) return [];
    final out = <LedgerEntry>[];
    await for (final e in paths.ledgerDir.list()) {
      if (e is! File || !e.path.endsWith('.port.json')) continue;
      try {
        out.add(LedgerEntry.fromJson(
            jsonDecode(await e.readAsString()) as Map<String, dynamic>));
      } catch (_) {
        try {
          await e.delete(); // 坏账本直接清
        } catch (_) {}
      }
    }
    return out;
  }

  /// 返回扫到的账本条目。[killOrphans]=true 时把仍存活的孤儿进程杀掉。
  Future<List<LedgerEntry>> sweep({bool killOrphans = true}) async {
    final entries = await readAll();
    for (final e in entries) {
      final alive = await pidAlive(e.pid);
      if (alive && killOrphans) {
        Process.killPid(e.pid); // 账本孤儿无主，直接终止
      }
      try {
        await paths.ledgerFile(e.instanceId).delete();
      } catch (_) {}
    }
    return entries;
  }
}
