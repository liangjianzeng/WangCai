/// shell 执行工具 —— 对齐 DSH 的 pwsh/shell 能力。
///
/// 通过 dart:io Process 在应用进程内执行 `sh -c`，命令以 app 权限运行
/// （可访问沙盒工作区与普通用户命令），输出截断 + 超时保护。
/// 默认不注册（设置开启后挂载），避免端侧模型误用危险命令。
library;

import 'dart:convert';
import 'dart:io';

import '../sandbox.dart';
import '../tool_definition.dart';

/// 命令超时。
const Duration kShellTimeout = Duration(seconds: 10);

/// 输出截断上限（字符）。
const int kShellOutputLimit = 4000;

ToolDefinition createShellExecTool() {
  return ToolDefinition(
    isConcurrencySafe: (_) => false, // 副作用工具：独占执行（P2-A）
    name: 'shell_exec',
    description:
        '在设备上执行 shell 命令（sh -c，app 权限内）。'
        '可访问工作区文件、运行普通命令（如 cat/free/ps/top/df、查看 /proc 信息等）。'
        '输出截断到 ${kShellOutputLimit} 字符，超时 ${kShellTimeout.inSeconds}s。'
        'stdin 不支持交互：它是"一次性喂入并关闭"的批次输入——命令需要读取输入时用 stdin 参数一并传进来（不传则命令读不到输入）。'
        '命令以 app 权限运行，不依赖 root；需要完整文件系统访问时带 sandbox_permissions 请求用户批准。',
    parameters: withEscalationFields({
      'type': 'object',
      'properties': {
        'command': {'type': 'string', 'description': '要执行的 shell 命令'},
        'stdin': {'type': 'string', 'description': '喂给命令 stdin 的输入（一次性批次，喂完即关闭；不填则不写）'},
      },
      'required': ['command'],
    }),
    timeout: kShellTimeout,
    execute: (args) async {
      final command = (args['command'] as String?)?.trim() ?? '';
      if (command.isEmpty) return ToolResult.error('缺少 command 参数');
      // 沙箱模式（workspace-write 默认；danger-full-access 为审批后生效）——
      // Android 上 sh 进程始终以 app 权限运行，完整访问依赖 All-Files-Access。
      final mode = effectiveModeOf(args);
      try {
        // stdin：一次性批次输入（对齐 DSH）。喂入后关闭；不传则不写。
        final stdinInput = (args['stdin'] as String?)?.trim();
        final process = await Process.start('sh', ['-c', command]);
        // 先同时拉取 stdout/stderr 流，避免单向等待导致标准错误缓冲区写满而死锁。
        // Process.start 无 stdoutEncoding 参数，需手动用 utf8.decoder 解码字节流。
        final stdoutFuture = process.stdout.transform(utf8.decoder).join();
        final stderrFuture = process.stderr.transform(utf8.decoder).join();
        final exitFuture = process.exitCode;
        if (stdinInput != null && stdinInput.isNotEmpty) {
          process.stdin.write(stdinInput);
          await process.stdin.close();
        }
        final stdout = await stdoutFuture;
        final stderr = await stderrFuture;
        final exitCode = await exitFuture;

        final buffer = StringBuffer();
        if (stdout.isNotEmpty) buffer.write(stdout);
        if (stderr.isNotEmpty) {
          if (buffer.isNotEmpty && !buffer.toString().endsWith('\n')) buffer.write('\n');
          buffer.write('[stderr] $stderr');
        }
        final output = buffer.toString().trim();
        final truncated = output.length > kShellOutputLimit
            ? '${output.substring(0, kShellOutputLimit)}\n…（已截断）'
            : output;

        // 注意：不输出 [sandbox: ...] 标记——模型常误读为"被沙箱拒绝"而
        // 放弃执行；实际 sh 命令始终以 app 权限运行，成功/失败只看 exit code。
        return ToolResult(
          content: 'exit=${exitCode}${truncated.isNotEmpty ? '\n$truncated' : '（无输出）'}',
        );
      } on ProcessException catch (e) {
        return ToolResult.error('命令执行失败：${e.message}');
      } catch (e) {
        return ToolResult.error('命令执行失败：$e');
      }
    },
  );
}
