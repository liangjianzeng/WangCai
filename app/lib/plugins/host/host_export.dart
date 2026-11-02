/// 宿主接缝：flow 的 `export` 动词 —— 把插件产出的文本**交付成用户真能打开的文件**。
///
/// 内核的分工是"平台不落盘，交给宿主渲染"（`FlowHost.renderExport`）：平台只保证内容成形，
/// 落在哪儿、怎么让用户看得见，是宿主与系统的事。这里做两件事：
///
/// 1. 先在 app 私有目录留一份**插件命名空间内**的副本（`文档/plugin_exports/<插件 id>/`）——
///    排障时能取证（"我明明生成了，用户说没有"这种案子只能靠落盘事实说话）；
/// 2. 再经 `DeviceFilesService` 导出到系统 `Download/TongYi-Lite/`（MediaStore），
///    这才是**交付**：Android 上私有目录文件管理器看不到，只有下载目录里的才算交到用户手里。
///
/// 三条纪律：
/// * **文件名一律消毒**：`params.filename` 来自插件作者写的 `plugin.json`（将来是第三方给的），
///   `../../` 或绝对路径必须被按在自家目录里，不许穿越；
/// * **同名不覆盖**：撞名就加 `-1`、`-2`，用户上次导的练习单不该被下一次悄悄吃掉；
/// * **导出失败要如实报错**：只写进私有目录**不算交付**（用户看不见），此时返回 `runtimeError`
///   并在 message 里说清两份文件各在哪儿 —— 让流程失败、让用户知道，胜过假装成功。
library;

import 'dart:io';

import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';
import 'package:plugin_kernel/plugin_kernel.dart';

import '../../services/device_files_service.dart';

/// 落盘 + 导出。依赖全部可注入，测试不必起 path_provider 与 MediaStore。
/// [FlowHost.renderExport] 的接法（薄壳：真实逻辑在 [exportPluginText]，方便不起 ctx 就能测）。
Future<Outcome<ExportReceipt>> hostRenderExport(
  PluginCtx ctx,
  String filename,
  String content, {
  Future<Directory> Function()? docsDir,
  Future<String> Function(String src, String? name)? exportToDownloads,
}) =>
    exportPluginText(
      pluginId: ctx.manifest.id,
      filename: filename,
      content: content,
      docsDir: docsDir,
      exportToDownloads: exportToDownloads,
    );

/// 落一份 + 导出到下载目录。`pluginId` 决定私有目录，防两个插件互相盖文件。
Future<Outcome<ExportReceipt>> exportPluginText({
  required String pluginId,
  required String filename,
  required String content,
  Future<Directory> Function()? docsDir,
  Future<String> Function(String src, String? name)? exportToDownloads,
}) async {
  if (content.trim().isEmpty) {
    return Outcome.err<ExportReceipt>(
      code: PluginFailureKind.badContent,
      message: '没有可导出的内容',
      hint: '把 export 排在能产出内容的步骤之后',
      pluginId: pluginId,
    );
  }

  final name = safeExportFileName(filename, fallback: '$pluginId-练习单.txt');
  try {
    final docs = await (docsDir ?? getApplicationDocumentsDirectory)();
    final dir = Directory(p.join(docs.path, 'plugin_exports', pluginId));
    if (!await dir.exists()) await dir.create(recursive: true);

    // 撞名不覆盖用户上一次的东西。
    var target = File(p.join(dir.path, name));
    if (await target.exists()) {
      final base = p.basenameWithoutExtension(name);
      final ext = p.extension(name);
      var n = 1;
      while (await target.exists() && n < 100) {
        target = File(p.join(dir.path, '$base-$n$ext'));
        n++;
      }
    }
    await target.writeAsString(content, flush: true);

    final toDownloads = exportToDownloads ?? (src, n) => DeviceFilesService.instance.exportFile(src: src, name: n);
    try {
      final uri = await toDownloads(target.path, p.basename(target.path));
      if (uri.trim().isEmpty) {
        // 通道说"成功了"却给不出位置 = 没交付（平台纪律：什么都没做成就不许报成功）。
        // 私有副本还在，所以 hint 里继续指路 —— 排障时"我明明生成了"要靠它。
        return Outcome.err<ExportReceipt>(
          code: PluginFailureKind.runtimeError,
          message: '练习单已经生成，但没能导出到下载目录',
          hint: '文件在 app 里：plugin_exports/$pluginId/${p.basename(target.path)}；'
              '检查本应用的存储权限，或换个文件名再试',
          pluginId: pluginId,
        );
      }
      final delivered = p.basename(target.path);
      return Ok<ExportReceipt>(ExportReceipt(
        uri: uri,
        fileName: delivered,
        // 宿主确实动过名字（非法字符、补扩展名、撞名加 `-1`）才给原名：
        // 让引擎在回执里说破，而不是让用户拿着一个不存在的文件名去找。
        renamedFrom: delivered == filename.trim() ? null : filename.trim(),
      ));
    } catch (e) {
      // 只落进私有目录**不算交付**：文件管理器看不见，用户拿到的是"什么都没有"。
      return Outcome.err<ExportReceipt>(
        code: PluginFailureKind.runtimeError,
        // message 是给 UI 看的一句话（契约里限死 120 字且不许带异常原文）；
        // 路径与异常原文走 hint / cause —— 混进 message 就是把技术细节甩到用户脸上。
        message: '练习单已经生成，但没能导出到下载目录',
        hint: '文件在 app 里：plugin_exports/$pluginId/${p.basename(target.path)}；'
            '检查本应用的存储权限，或换个文件名再试',
        pluginId: pluginId,
        cause: e,
      );
    }
  } catch (e) {
    return Outcome.err<ExportReceipt>(
      code: PluginFailureKind.runtimeError,
      message: '导出没成功',
      hint: '看看磁盘是否可写，或换个文件名（原因已记进诊断日志）',
      pluginId: pluginId,
      cause: e,
    );
  }
}

/// 把作者给的文件名按在自家目录里。
///
/// 不是洁癖：`filename` 来自 `plugin.json`（今天是我们的例子，将来是第三方插件），
/// `../../sdcard/x` 或 `/system/x` 一旦被当真，插件就拿到了任意路径写权限。
String safeExportFileName(String raw, {required String fallback}) {
  var name = raw.trim();
  if (name.isEmpty) return fallback;
  // 只认最后一段：绝对路径、`a/b`、反斜杠、URL 片段统统剥掉目录。
  name = name.replaceAll('\\', '/').split('/').last.trim();
  // 去掉穿越与非法字符（Windows/Android 都禁的那批 + 控制字符）。
  name = name.replaceAll(RegExp(r'[<>:"|?*\x00-\x1F]'), '_').replaceAll(RegExp(r'^\.+'), '').trim();
  if (name.isEmpty) return fallback;
  if (!name.contains('.')) name = '$name.txt';
  if (name.length > 80) {
    final ext = p.extension(name);
    name = '${name.substring(0, 80 - ext.length)}$ext';
  }
  return name;
}
