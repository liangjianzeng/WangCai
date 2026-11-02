// M4 打包形态路径解析：安装器引擎目录（engines/wangcai）二级解析。
// dataRoot 用 override 隔离，不碰真实 %APPDATA%。
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:tongyi_lite/platform/wangcai_paths.dart';

void main() {
  late Directory tmp;

  setUp(() {
    tmp = Directory.systemTemp.createTempSync('wc_paths');
    WangCaiPaths.dataRootOverrideForTest = () => tmp;
  });
  tearDown(() {
    WangCaiPaths.dataRootOverrideForTest = null;
    for (var i = 0; i < 10; i++) {
      try {
        if (tmp.existsSync()) tmp.deleteSync(recursive: true);
        return;
      } catch (_) {
        // ignore
      }
    }
  });

  test('bundled 引擎目录存在 → wangcaiServerExe/ovLibsDirs 命中安装位', () {
    final eng = Directory(
        '${WangCaiPaths.dataRoot().path}${Platform.pathSeparator}engines'
        '${Platform.pathSeparator}wangcai')
      ..createSync(recursive: true);
    final exe =
        File('${eng.path}${Platform.pathSeparator}llama-server.exe')
          ..writeAsBytesSync([1]);
    final libs = Directory('${eng.path}${Platform.pathSeparator}ovlibs')
      ..createSync();

    expect(WangCaiPaths.wangcaiServerExe(), exe.path);
    expect(WangCaiPaths.ovLibsDirs(), [libs.path]);
  });

  test('无 bundled 且 env 未设：有 repo 时回退 repo（开发机形态不回归）', () {
    // 本机存在 WangCai 仓库（repoRoot 命中）—— bundled 缺席时回落 repo 产物。
    final exe = WangCaiPaths.wangcaiServerExe();
    if (WangCaiPaths.repoRoot() != null) {
      expect(exe, isNotNull);
      expect(exe, contains('llama-server'));
    }
  });

  test('bundled 优先于 repo（安装器覆盖开发机产物）', () {
    final eng = Directory(
        '${WangCaiPaths.dataRoot().path}${Platform.pathSeparator}engines'
        '${Platform.pathSeparator}wangcai')
      ..createSync(recursive: true);
    final exe =
        File('${eng.path}${Platform.pathSeparator}llama-server.exe')
          ..writeAsBytesSync([1]);
    expect(WangCaiPaths.wangcaiServerExe(), exe.path,
        reason: '安装位存在时必须优先（干净机语义），即便本机有 repo');
  });
}
