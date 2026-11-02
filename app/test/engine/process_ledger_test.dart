import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:tongyi_lite/engine/engine_paths.dart';
import 'package:tongyi_lite/engine/process_ledger.dart';

void main() {
  late Directory tmp;
  late EnginePaths paths;
  LedgerEntry entry(String id, int pid) => LedgerEntry(
      instanceId: id, pid: pid, port: 8100 + pid % 100, startedAt: DateTime.now());

  setUp(() {
    tmp = Directory.systemTemp.createTempSync('m1_ledger');
    paths = EnginePaths.root(tmp);
  });
  tearDown(() => tmp.deleteSync(recursive: true));

  test('write/readAll/clear', () async {
    final ledger = ProcessLedger(paths, pidAlive: (_) async => false);
    await ledger.write(entry('a', 111));
    await ledger.write(entry('b', 222));
    final all = await ledger.readAll();
    expect(all.map((e) => e.instanceId), containsAll(['a', 'b']));
    await ledger.clear('a');
    expect(await ledger.readAll(), hasLength(1));
  });

  test('坏账本自愈删除', () async {
    await paths.ensureDirs();
    await paths.ledgerFile('bad').writeAsString('{not json');
    final ledger = ProcessLedger(paths, pidAlive: (_) async => false);
    expect(await ledger.readAll(), isEmpty);
    expect(await paths.ledgerFile('bad').exists(), isFalse);
  });

  test('sweep：死进程账本清理；活孤儿被杀（真进程验证 kill 路径）', () async {
    // 起一个真长命进程当"孤儿"：ping 60 次 ≈ 一分钟
    final orphan = await Process.start('ping', ['/n', '60', '127.0.0.1'],
        mode: ProcessStartMode.detachedWithStdio);
    final ledger = ProcessLedger(paths); // 真 tasklist 探活
    await ledger.write(entry('orphan', orphan.pid));
    expect(await tasklistPidAlive(orphan.pid), isTrue);

    final swept = await ledger.sweep();
    expect(swept.single.instanceId, 'orphan');
    await Future<void>.delayed(const Duration(milliseconds: 500));
    expect(await tasklistPidAlive(orphan.pid), isFalse,
        reason: 'sweep 应杀掉存活孤儿（M0-3 附 实测场景）');
    expect(await ledger.readAll(), isEmpty);
  });
}
