// flow 的 `export` 动词在宿主这一侧的行为。
//
// 平台侧只保证"内容成形"，交付是宿主的事 —— 所以这里必须钉死三件事：
// ① 作者给的文件名**不能穿越**出自己的目录（今天是我们的例子，将来是第三方插件的 plugin.json）；
// ② 撞名不覆盖用户上一次导出的东西；
// ③ 只写进 app 私有目录**不算交付**（文件管理器看不见），必须如实报错并说清文件在哪儿。
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:plugin_kernel/plugin_kernel.dart';
import 'package:path/path.dart' as p;
import 'package:tongyi_lite/plugins/host/host_export.dart';

void main() {
  late Directory docs;
  late List<(String src, String? name)> downloaded;
  Object? downloadError;
  String? downloadUri; // null = 用默认的 content://download/<name>

  setUp(() {
    docs = Directory.systemTemp.createTempSync('plugin_export');
    downloaded = [];
    downloadError = null;
    downloadUri = null;
  });
  tearDown(() {
    if (docs.existsSync()) docs.deleteSync(recursive: true);
  });

  Future<Outcome<ExportReceipt>> run(String filename, String content, {String pluginId = 'en-dictation'}) =>
      exportPluginText(
        pluginId: pluginId,
        filename: filename,
        content: content,
        docsDir: () async => docs,
        exportToDownloads: (src, name) async {
          if (downloadError != null) throw downloadError!;
          downloaded.add((src, name));
          return downloadUri ?? 'content://download/$name';
        },
      );

  group('导出交付', () {

    test('导出通道返回空串 = 没交付，必须报错（不许"已导出："后面什么都没有）', () async {
      // Kotlin 侧 MediaStore insert 失败会返回 null；服务层以前折算成 ''，两层都当成功用了出去。
      downloadUri = '';
      final r = await run('生字练习单.txt', 'apple\t苹果\n');
      expect(r.isErr, isTrue, reason: '空 URI 不是交付证明');
      expect(r.failureOrNull!.message, contains('没能导出到下载目录'));
      expect(r.failureOrNull!.hint, contains('plugin_exports/en-dictation'), reason: '私有副本要能指路，排障靠它');
      expect(
        File(p.join(docs.path, 'plugin_exports', 'en-dictation', '生字练习单.txt')).existsSync(),
        isTrue,
        reason: '取证副本仍然落下 —— 报错不许顺手删证据',
      );
    });

    test('正常一条：私有副本 + 下载目录都到位，返回下载 URI', () async {
      final r = await run('生字练习单.txt', 'apple\t苹果\nbanana\t香蕉\n');
      expect(r.isOk, isTrue);
      expect(r.valueOrNull!.uri, 'content://download/生字练习单.txt');
      expect(r.valueOrNull!.fileName, '生字练习单.txt', reason: '凭据里要有真名，引擎拿它去写回执');
      expect(r.valueOrNull!.renamedFrom, isNull, reason: '没改写过就别谎称改写过');
      expect(downloaded.single.$2, '生字练习单.txt');

      final f = File(downloaded.single.$1);
      expect(f.existsSync(), isTrue);
      expect(f.readAsStringSync(), contains('apple\t苹果'));
      expect(p_containsDir(f.path, 'plugin_exports/en-dictation'), isTrue,
          reason: '副本必须落在插件自己的命名空间里，别互相盖文件');
    });

    test('宿主改写过的名字必须交回真名（引擎才不会拿作者要的名去报）', () async {
      final r = await run('第三单元:生字/练习单?.txt', 'apple\t苹果');
      expect(r.isOk, isTrue);
      final receipt = r.valueOrNull!;
      expect(receipt.fileName, isNot(contains(':')), reason: '非法字符要换掉');
      expect(receipt.fileName, isNot(contains('/')), reason: '带斜杠的"文件名"其实是路径，只能取最后一段');
      expect(receipt.renamedFrom, '第三单元:生字/练习单?.txt', reason: '原名要说破');
      expect(File('${docs.path}/plugin_exports/en-dictation/${receipt.fileName}').existsSync(), isTrue,
          reason: '报的这个名字必须真在盘上');
    });

    test('两个插件同名各留一份，互不覆盖', () async {
      await run('练习单.txt', 'A', pluginId: 'en-dictation');
      await run('练习单.txt', 'B', pluginId: 'zh-cards');
      final a = File('${docs.path}/plugin_exports/en-dictation/练习单.txt').readAsStringSync();
      final b = File('${docs.path}/plugin_exports/zh-cards/练习单.txt').readAsStringSync();
      expect(a, 'A');
      expect(b, 'B');
    });

    test('撞名不覆盖：第二次自动加 -1，用户上一次的东西还在', () async {
      await run('练习单.txt', '第一次');
      final second = await run('练习单.txt', '第二次');
      expect(second.valueOrNull!.fileName, '练习单-1.txt',
          reason: '撞名后真正落盘的是 -1 那份；回执还报「练习单.txt」就是给用户指一个不是它的文件');
      expect(second.valueOrNull!.renamedFrom, '练习单.txt', reason: '改名要说破，交给引擎写进回执');
      final dir = Directory('${docs.path}/plugin_exports/en-dictation');
      final names = dir.listSync().whereType<File>().map((e) => e.uri.pathSegments.last).toList()..sort();
      expect(names, ['练习单-1.txt', '练习单.txt']);
      expect(File('${dir.path}/练习单.txt').readAsStringSync(), '第一次',
          reason: '悄悄吃掉用户上一份导出，是插件平台最招恨的行为');
    });

    test('导出到下载目录失败 = 如实报错，并且说清文件已经在哪', () async {
      downloadError = FileSystemException('MediaStore 拒绝写入');
      final r = await run('练习单.txt', '内容');
      expect(r.isErr, isTrue, reason: '只在私有目录里躺着不算交付，不许报喜');
      final f = r.failureOrNull!;
      expect(f.code, PluginFailureKind.runtimeError);
      expect(f.hint, contains('plugin_exports/en-dictation/练习单.txt'), reason: '出路要具体到文件');
      expect(f.cause, isNotNull, reason: '异常原文进诊断，不进 message');
      expect(f.message.length, lessThanOrEqualTo(120), reason: 'message 是 UI 上的一句话，契约限 120 字');
      expect(f.message, isNot(contains('Exception')), reason: '技术细节不许渗进给用户看的那句');
    });

    test('没内容就直说，不落一个空文件骗人', () async {
      final r = await run('练习单.txt', '   \n  ');
      expect(r.isErr, isTrue);
      expect(r.failureOrNull!.code, PluginFailureKind.badContent);
      expect(Directory('${docs.path}/plugin_exports').existsSync(), isFalse);
    });
  });

  group('文件名消毒（作者写的 filename 不许穿越）', () {
    test('相对穿越与绝对路径都被按在自家目录里', () {
      expect(safeExportFileName('../../../../sdcard/下载/x.txt', fallback: 'f.txt'), 'x.txt');
      expect(safeExportFileName('/etc/passwd', fallback: 'f.txt'), 'passwd.txt');
      expect(safeExportFileName(r'C:\windows\evil.dll', fallback: 'f.txt'), 'evil.dll');
      expect(safeExportFileName('a/b/中文名.txt', fallback: 'f.txt'), '中文名.txt');
    });

    test('怪名字修成能用的，不返回空串', () {
      expect(safeExportFileName('', fallback: 'f.txt'), 'f.txt');
      expect(safeExportFileName('...', fallback: 'f.txt'), 'f.txt');
      expect(safeExportFileName('apple', fallback: 'f.txt'), 'apple.txt', reason: '没扩展名就补一个');
      expect(safeExportFileName('a<b>:c?.txt', fallback: 'f.txt'), 'a_b__c_.txt',
          reason: '每个非法字符换一个下划线，扩展名点号要留着');
      final long = safeExportFileName('${'x' * 300}.txt', fallback: 'f.txt');
      expect(long.length, lessThanOrEqualTo(80));
      expect(long, endsWith('.txt'));
    });

    test('穿越名走完整流程后，目录里只会有那一个文件', () async {
      await run('../../../../etc/passwd', 'pwn');
      final files = Directory('${docs.path}/plugin_exports/en-dictation').listSync().whereType<File>().toList();
      expect(files.length, 1);
      expect(p_basename(files.single.path), 'passwd.txt');
      expect(Directory('${docs.path}/etc').existsSync(), isFalse);
    });
  });
}

bool p_containsDir(String path, String needle) => path.replaceAll('\\', '/').contains(needle);
String p_basename(String path) => path.replaceAll('\\', '/').split('/').last;
