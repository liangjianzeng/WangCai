/// run_code 工具（DSH PTC / code-runtime 语义的最小实现，仅 API 档注册）。
///
/// 模型写一段 Python 程序，在**单次工具调用内**编排多次子工具调用
/// （顺序/循环/条件/汇总），省去「每步一个回合」的往返：
/// 脚本内调用 `agent_tool(name, **args)` → 桥目录落请求文件 → Dart 侧
/// 轮询执行注册表中的真实工具 → 结果 JSON 回写 → 脚本继续。
///
/// 安全边界：
/// - 子调用走与主循环同一注册表（workspace-write 沙箱内建在各工具中）；
/// - **禁止嵌套 run_code**（防递归）；子调用次数硬上限 [kMaxSubToolCalls]；
/// - 总超时 [kRunCodeTimeout]，桥目录用后即删。
library;

import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/services.dart';

import '../tool_definition.dart';

/// 单次 run_code 内允许的子工具调用上限。
const int kMaxSubToolCalls = 30;

/// run_code 总超时（脚本 + 全部子调用）。
const Duration kRunCodeTimeout = Duration(seconds: 120);

/// MethodChannel：与 python_exec 同一通道（Chaquopy）。
const MethodChannel _kPythonChannel =
    MethodChannel('com.dgxspark.tongyilite/python');

/// 注入脚本头部的桥接预置代码：定义 `agent_tool(name, **args)`。
/// 请求/响应通过 [bridgeDir] 下的 `<uuid>.req` / `<uuid>.resp` 文件交换。
String _buildPrelude(String bridgeDir) => '''
import json, os, time, uuid as _uuid

TOOL_BRIDGE_DIR = r"""$bridgeDir"""

class AgentToolError(RuntimeError):
    pass

def agent_tool(name, **args):
    """调用智能体工具并返回结果文本；失败抛 AgentToolError。"""
    rid = _uuid.uuid4().hex
    req = os.path.join(TOOL_BRIDGE_DIR, rid + '.req')
    resp = os.path.join(TOOL_BRIDGE_DIR, rid + '.resp')
    with open(req, 'w', encoding='utf-8') as f:
        json.dump({'id': rid, 'name': name, 'args': args}, f, ensure_ascii=False)
    deadline = time.time() + 90
    while not os.path.exists(resp):
        if time.time() > deadline:
            raise AgentToolError('agent_tool 超时：' + name)
        time.sleep(0.05)
    with open(resp, 'r', encoding='utf-8') as f:
        r = json.load(f)
    try:
        os.remove(resp)
    except OSError:
        pass
    if r.get('isError'):
        raise AgentToolError('工具 ' + name + ' 失败：' + str(r.get('content')))
    return r.get('content')
''';

/// 构造 run_code 工具。
///
/// [callTool]：执行注册表中的真实工具（接入层注入；应拒绝 run_code 自身）。
/// [bridgeRoot]：桥目录父目录（测试注入；默认系统临时目录）。
ToolDefinition createRunCodeTool({
  required Future<ToolResult> Function(String name, Map<String, dynamic> args)
      callTool,
  Directory? bridgeRoot,
}) {
  return ToolDefinition(
    isConcurrencySafe: (_) => false, // 副作用工具：独占执行（P2-A）
    name: 'run_code',
    description:
        '把多步数据加工/批量工具编排写成一段 Python 程序，一次调用内完成'
        '（替代"每步一个回合"的多次往返）。脚本内用 agent_tool(name, **args) '
        '调用其他工具（如 read_file/web_search/calculator），支持循环、条件、'
        '汇总统计；子调用最多 $kMaxSubToolCalls 次。适合：批量处理多个文件、'
        '搜索结果聚合分析、多步计算流水线。纯算术直接用 calculator，'
        '单次工具调用能完成的不要用本工具。',
    parameters: {
      'type': 'object',
      'properties': {
        'script': {
          'type': 'string',
          'description': 'Python 脚本（预置了 agent_tool 函数，勿自行定义）',
        },
      },
      'required': ['script'],
    },
    timeout: kRunCodeTimeout,
    execute: (args) async {
      final script = (args['script'] as String?)?.trim() ?? '';
      if (script.isEmpty) return ToolResult.error('缺少 script 参数');
      if (script.contains('def agent_tool')) {
        return ToolResult.error('不要自定义 agent_tool，直接使用预置的即可');
      }

      // 桥目录：用后即删。
      final Directory dir;
      try {
        dir = await (bridgeRoot ?? Directory.systemTemp)
            .createTemp('agent_ptc_');
      } catch (e) {
        return ToolResult.error('无法创建桥目录：$e');
      }

      try {
        // Python 可用性（同 python_exec 的探测口径）。
        final available = await _kPythonChannel
                .invokeMethod<String>('isAvailable')
                .timeout(const Duration(seconds: 15), onTimeout: () => '探测超时') ??
            '';
        if (available != 'ok') {
          return ToolResult.error(available.isEmpty
              ? 'Python 运行时不可用'
              : 'Python 运行时不可用：$available');
        }

        final fullScript =
            '${_buildPrelude(dir.path)}\n\n# ---- 模型脚本 ----\n$script';
        // 不 await：脚本运行期间 Dart 侧轮询桥目录服务子调用。
        final done = _kPythonChannel.invokeMethod<String>('runScript', {
          'script': fullScript,
          'timeoutSec': (kRunCodeTimeout.inSeconds - 10).clamp(10, 180),
        });

        var subCalls = 0;
        var pumpError = '';
        // 脚本运行期间 Dart 侧轮询桥目录服务子调用；脚本结束（或泵错误）即停。
        var scriptDone = false;
        unawaited(done.whenComplete(() => scriptDone = true));
        while (!scriptDone && pumpError.isEmpty) {
          await _serviceBridgeRequests(dir, callTool, () {
            subCalls++;
            return subCalls > kMaxSubToolCalls;
          }, (msg) => pumpError = msg);
          if (scriptDone || pumpError.isNotEmpty) break;
          await Future<void>.delayed(const Duration(milliseconds: 80));
        }

        final output = (await done.asStream().first ?? '').trim();
        if (pumpError.isNotEmpty) {
          return ToolResult.error(pumpError);
        }
        final truncated = output.length > kPythonOutputLimit
            ? '${output.substring(0, 4000)}\n…（已截断）'
            : output;
        return ToolResult(
            content: truncated.isEmpty ? '（脚本执行成功，无输出）' : truncated);
      } on PlatformException catch (e) {
        if (e.code == 'SCRIPT_TIMEOUT') {
          return ToolResult.error('脚本执行超时（${kRunCodeTimeout.inSeconds}s）');
        }
        return ToolResult.error('run_code 执行失败：${e.message ?? e.code}');
      } on TimeoutException {
        return ToolResult.error('run_code 超时（${kRunCodeTimeout.inSeconds}s）');
      } catch (e) {
        return ToolResult.error('run_code 执行失败：$e');
      } finally {
        try {
          await dir.delete(recursive: true);
        } catch (_) {}
      }
    },
  );
}

const int kPythonOutputLimit = 4000;

/// 扫描桥目录，顺序服务全部待处理子调用请求。
/// [overBudget] 返回 true 时停止服务并写回预算错误；[onError] 收集致命错误。
Future<void> _serviceBridgeRequests(
  Directory dir,
  Future<ToolResult> Function(String, Map<String, dynamic>) callTool,
  bool Function() overBudget,
  void Function(String) onError,
) async {
  final List<FileSystemEntity> entries;
  try {
    entries = await dir.list().toList();
  } catch (_) {
    return;
  }
  for (final e in entries) {
    if (!e.path.endsWith('.req')) continue;
    Map<String, dynamic>? req;
    try {
      req = (jsonDecode(await File(e.path).readAsString())
          as Map<String, dynamic>);
    } catch (_) {
      await _writeResp(e.path, ToolResult.error('请求格式非法'), dir.path);
      continue;
    }
    if (overBudget()) {
      onError('run_code 子调用超过上限 $kMaxSubToolCalls 次，已中止。'
          '请拆分任务或减少编排规模。');
      return;
    }
    final name = req['name']?.toString() ?? '';
    final args = (req['args'] as Map<String, dynamic>?) ?? const {};
    ToolResult result;
    if (name == 'run_code') {
      result = ToolResult.error('run_code 不能嵌套调用自身');
    } else {
      try {
        result = await callTool(name, args);
      } catch (ex) {
        result = ToolResult.error('工具 "$name" 执行异常: $ex');
      }
    }
    await _writeResp(e.path, result, dir.path);
  }
}

/// 把结果写到 `<reqPath 去掉 .req>.resp`（拒绝符号链接逃逸由临时目录隔离兜底）。
Future<void> _writeResp(String reqPath, ToolResult result, String dirPath) async {
  final respPath =
      '${reqPath.substring(0, reqPath.length - '.req'.length)}.resp';
  final name = reqPath.split(Platform.pathSeparator).last;
  final expectedDir = File(respPath).parent.path;
  if (expectedDir != dirPath || !name.endsWith('.req')) {
    return; // 路径异常（不应发生）：拒服务而非写出去。
  }
  final payload = jsonEncode({
    'content': result.content,
    'isError': result.isError,
  });
  await File(respPath).writeAsString(payload, flush: true);
  try {
    await File(reqPath).delete();
  } catch (_) {}
}
