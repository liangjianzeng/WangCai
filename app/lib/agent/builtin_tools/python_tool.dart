/// python_exec 工具 —— 对齐 DSH 的脚本/编程能力（方案见 docs/python_support.md）。
///
/// 通过 MethodChannel（`com.dgxspark.tongyilite/python`）调用 Android 侧
/// Chaquopy（嵌入式 CPython）：`agent_runner.py` 在 app 权限内 exec 脚本，
/// 返回 stdout/stderr/异常。超时（默认 15s）与输出截断与 shell_exec 一致。
/// 无 Python 运行时（未集成 Chaquopy）时返回明确错误，不崩溃（优雅降级）。
library;

import 'dart:async';

import 'package:flutter/services.dart';

import '../sandbox.dart';
import '../tool_definition.dart';

/// Python 脚本执行超时（与 shell 一致）。
const Duration kPythonTimeout = Duration(seconds: 15);

/// 输出截断上限（字符）。
const int kPythonOutputLimit = 4000;

/// MethodChannel：`com.dgxspark.tongyilite/python`（MainActivity 注册）。
const MethodChannel kPythonChannel =
    MethodChannel('com.dgxspark.tongyilite/python');

/// 创建 python_exec 工具。
///
/// 参数：
/// - [script]（必填）：Python 脚本文本；
/// - [timeoutSec]（可选）：超时秒数（默认 15）；
/// - `sandbox_permissions` + `justification`（可选）：请求完整文件系统访问
///   （对照 DSH 升级通道；Python 以 app 权限运行，公共目录需 All-Files-Access）。
ToolDefinition createPythonExecTool() {
  return ToolDefinition(
    isConcurrencySafe: (_) => false, // 副作用工具：独占执行（P2-A）
    name: 'python_exec',
    description:
        '在设备上执行 Python 脚本（嵌入式 CPython，app 权限内）。'
        '可做计算/数据处理/文件/网络。输出截断到 ${kPythonOutputLimit} 字符，超时 ${kPythonTimeout.inSeconds}s。'
        'stdin 不支持交互式输入：它是"一次性喂入并关闭"的批次输入——脚本需要 input() 读取时，'
        '必须用 stdin 参数把输入一并传进来（不传则脚本内 input() 会立即收到 EOF 而退出）。'
        '纯算术运算请直接用 calculator 工具，不要写 Python 去算。'
        '确需访问公共目录时带 sandbox_permissions 请求用户批准。',
    parameters: withEscalationFields({
      'type': 'object',
      'properties': {
        'script': {'type': 'string', 'description': '要执行的 Python 脚本'},
        'stdin': {'type': 'string', 'description': '喂给脚本 stdin 的输入（input() 用；不填则 input() 收 EOF'},
        'timeoutSec': {'type': 'number', 'description': '超时秒数（默认 15）'},
      },
      'required': ['script'],
    }),
    timeout: kPythonTimeout,
    execute: (args) async {
      final script = (args['script'] as String?)?.trim() ?? '';
      if (script.isEmpty) return ToolResult.error('缺少 script 参数');
      final timeoutSec =
          ((args['timeoutSec'] as num?)?.toInt() ?? 15).clamp(1, 60);
      // stdin：仅当非空时传入（空串会让 input() 立即 EOF，故用 null 表示不传）。
      final stdin = (args['stdin'] as String?)?.trim();

      try {
        // isAvailable 返回 String："ok" = 可用；其他为原生透传的具体错误。
        final available = await kPythonChannel
            .invokeMethod<String>('isAvailable')
            .timeout(kPythonTimeout, onTimeout: () => '探测超时');
        if (available != 'ok') {
          return ToolResult.error(
              'Python 运行时不可用${available == null || available.isEmpty ? '' : '：$available'}');
        }
        // runScript 返回处理后的输出文本（原生侧已合并 stdout/stderr、
        // 区分成功/失败；失败走 PlatformException）。stdin 一并透传给 agent_runner。
        final argsMap = <String, dynamic>{'script': script, 'timeoutSec': timeoutSec};
        if (stdin != null && stdin.isNotEmpty) {
          argsMap['stdin'] = stdin;
        }
        final content = await kPythonChannel.invokeMethod<String>(
          'runScript',
          argsMap,
        );
        final output = content?.trim() ?? '';
        final truncated = output.length > kPythonOutputLimit
            ? '${output.substring(0, kPythonOutputLimit)}\n…（已截断）'
            : output;
        return ToolResult(
            content: truncated.isEmpty ? '（脚本执行成功，无输出）' : truncated);
      } on PlatformException catch (e) {
        final code = e.code;
        final message = e.message ?? '';
        if (code == 'SCRIPT_TIMEOUT') {
          return ToolResult.error('脚本执行超时（${timeoutSec}s）');
        }
        if (code == 'PYTHON_UNAVAILABLE' || code == 'PYTHON_ERROR') {
          return ToolResult.error('Python 运行时不可用：$message');
        }
        return ToolResult.error('脚本执行失败：$message');
      } on TimeoutException catch (_) {
        return ToolResult.error('Python 调用超时（${timeoutSec}s）');
      } catch (e) {
        return ToolResult.error('Python 执行失败：$e');
      }
    },
  );
}
