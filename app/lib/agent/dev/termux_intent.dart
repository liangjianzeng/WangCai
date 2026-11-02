/// Termux RUN_COMMAND 免 SSH 通道（Dev Agent L2）。
///
/// 链路（对齐 docs/termux_integration_plan_2026-10-04.md §6.2）：
/// Dart 工具层 → DevNativeEnv.runTermux（intent，$PREFIX/bin/sh -c 包装脚本）
/// → Termux 执行并把 输出+退出码 tee 到自家外部交换目录
///   `/sdcard/Android/data/com.termux/files/tongyilite_out/<id>.txt`
///   （Termux 无需存储权限即可写自己的 getExternalFilesDir；本 app 有
///   MANAGE_EXTERNAL_STORAGE 可直接读）
/// → Dart 轮询读到 `__TYL_DONE__` 结束标记，解析退出码。
///
/// 与 SSH 通道的取舍：无网络环回、无密钥、无 PerSourcePenalties；
/// Termux 未装/未开 allow-external-apps 时报可读错误（提示回落 SSH 向导）。
library;

import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'native_env.dart';

/// 交换输出目录（Termux 侧视角；/sdcard 与 /storage/emulated/0 等价）。
///
/// ⚠️ 不能用 `/sdcard/Android/data/com.termux`：那是 Termux 私有外部目录，
/// Termux 能写但本 app 读不到（MANAGE_EXTERNAL_STORAGE 不覆盖其他应用的
/// Android/data，Android 11+ 硬规则）。`/sdcard/TongYiLite/` 两边都可写
/// （本 app 有 MANAGE_EXTERNAL_STORAGE；Termux 需已授予存储权限——
/// 向导配置命令里已含 termux-setup-storage 路径）。
const String kTermuxOutDir = '/sdcard/TongYiLite/termux_out';

/// 结束标记行（脚本在写完 EXIT 后追加）。
const String kTermuxDoneMarker = '__TYL_DONE__';

/// 生成发给 Termux 的包装脚本（纯函数，可测）。
///
/// 语义：**先自建输出目录**（交换目录随首条命令创建，零预置）→ cd 工作目录
/// → 用户命令 → stdout/stderr 全并 + 退出码 → 结束标记。
/// [outFilePath] = Termux 侧视角的交换文件完整路径（`<outDir>/<id>.out`）。
String buildTermuxWrapper({
  required String command,
  required String outFilePath,
  String? cwd,
}) {
  final outDir = outFilePath.contains('/')
      ? outFilePath.substring(0, outFilePath.lastIndexOf('/'))
      : '.';
  final cd = (cwd == null || cwd.isEmpty) ? '' : "cd '$cwd' 2>/dev/null; ";
  final quoted = command.replaceAll("'", r"'\''");
  return "mkdir -p '$outDir'; $cd{ $quoted ; } > '$outFilePath' 2>&1; "
      "echo \"__TYL_EXIT__=\$?\" >> '$outFilePath'; "
      "echo '$kTermuxDoneMarker' >> '$outFilePath'";
}

/// 解析交换文件内容（纯函数，可测）：剥离退出码/结束标记行。
/// 返回 `(exit, output)`；无结束标记视为未完成（exit = null）。
({int? exit, String output}) parseTermuxOutput(String raw) {
  var exitCode = 0;
  final lines = <String>[];
  for (final line in const LineSplitter().convert(raw)) {
    if (line == kTermuxDoneMarker) continue;
    if (line.startsWith('__TYL_EXIT__=')) {
      exitCode = int.tryParse(line.substring('__TYL_EXIT__='.length)) ?? -1;
      continue;
    }
    lines.add(line);
  }
  return (exit: exitCode, output: lines.join('\n').trim());
}

/// 交换文件在 app 侧的可读路径（/sdcard 与 /storage/emulated/0 同一文件系统）。
String termuxOutPathOnApp(String id) =>
    '/storage/emulated/0/TongYiLite/termux_out/$id.out';

/// 一次性执行结果。
final class TermuxRunResult {
  final int exit;
  final String output;
  const TermuxRunResult({required this.exit, required this.output});

  bool get ok => exit == 0;
}

/// Termux intent 通道服务（单例；sender/reader 可注入测试）。
class TermuxIntentService {
  TermuxIntentService._();

  static final TermuxIntentService instance = TermuxIntentService._();

  /// 发送器注入点：默认走 DevNativeEnv.runTermux。返回错误信息（null=已投递）。
  Future<String?> Function(String wrapper, String? cwd)? sender;

  /// 交换文件读取器注入点：默认读 app 侧共享路径。null = 文件未就绪。
  Future<String?> Function(String id)? reader;

  /// 单次轮询间隔与总超时。
  static const _pollInterval = Duration(milliseconds: 300);
  static const _defaultTimeout = Duration(seconds: 30);

  /// 单次 shell 命令轮询等待上限（文件工具给长一点）。
  Future<TermuxRunResult> run(
    String command, {
    String? cwd,
    Duration timeout = _defaultTimeout,
  }) async {
    final id = 'tyl_${DateTime.now().millisecondsSinceEpoch}'
        '_${DateTime.now().microsecondsSinceEpoch % 1000}';
    final wrapper = buildTermuxWrapper(
        command: command, outFilePath: '$kTermuxOutDir/$id.out', cwd: cwd);
    final send = sender ?? _defaultSender;
    final err = await send(wrapper, null);
    if (err != null) {
      throw StateError('Termux 通道不可用：$err。'
          '请确认已安装 Termux 并在 Termux 内执行过配置命令'
          '（allow-external-apps）');
    }
    final read = reader ?? _defaultReader;
    final deadline = DateTime.now().add(timeout);
    while (DateTime.now().isBefore(deadline)) {
      final raw = await read(id);
      if (raw != null && raw.contains(kTermuxDoneMarker)) {
        final parsed = parseTermuxOutput(raw);
        return TermuxRunResult(exit: parsed.exit ?? -1, output: parsed.output);
      }
      await Future<void>.delayed(_pollInterval);
    }
    throw StateError('Termux 命令超时（${timeout.inSeconds}s）：未收到执行结果。'
        '可能 Termux 被系统杀后台，请重新打开 Termux 后重试');
  }

  /// 远端读文件（base64 传输，免换行/二进制截断）。
  Future<String?> readFile(String path, {Duration? timeout}) async {
    final res = await run("base64 < '$path'",
        timeout: timeout ?? const Duration(seconds: 30));
    if (!res.ok) return null;
    try {
      return utf8.decode(base64.decode(res.output.replaceAll('\n', '')),
          allowMalformed: true);
    } catch (_) {
      return null;
    }
  }

  /// 远端写文件（base64 经命令行传入；单次 ≤ 64KB，与 ssh_write_file 对齐）。
  Future<bool> writeFile(String path, String content,
      {Duration? timeout}) async {
    if (content.length > 65536) return false;
    final b64 = base64.encode(utf8.encode(content));
    // 目录可能不存在：mkdir -p 兜底（path 的父目录由 shell 展开）。
    final dir = path.contains('/')
        ? path.substring(0, path.lastIndexOf('/'))
        : '.';
    final res = await run(
        "mkdir -p '$dir' && printf %s '$b64' | base64 -d > '$path'",
        timeout: timeout ?? const Duration(seconds: 30));
    return res.ok;
  }

  Future<String?> _defaultSender(String wrapper, String? cwd) {
    return DevNativeEnv.runTermux(
      executablePath: '/data/data/com.termux/files/usr/bin/sh',
      arguments: ['-c', wrapper],
    );
  }

  Future<String?> _defaultReader(String id) async {
    try {
      final f = File(termuxOutPathOnApp(id));
      if (!await f.exists()) return null;
      return await f.readAsString();
    } catch (_) {
      return null;
    }
  }
}
