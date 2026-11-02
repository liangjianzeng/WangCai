/// 离线评分入口（P0-C）：`dart run eval/score_traces.dart <轨迹目录> [任务集]`
///
/// 前置：真机设置 → 智能体 → 开启「回合轨迹落盘」，跑完基线任务后
/// `adb pull` 拉取 `ApplicationSupport/traces/*.jsonl`。
/// 匹配规则：轨迹首条 user 消息包含任务 prompt 前 40 字符。
/// 退出码：0 全过 / 1 有挂项 / 2 有任务未匹配到轨迹。
library;

import 'dart:io';

import 'scoring.dart';

void main(List<String> args) {
  final traceDir = args.isNotEmpty ? args[0] : 'traces';
  final tasksFile = args.length > 1 ? args[1] : 'eval/tasks.json';
  final tasks = EvalTask.listFromFile(tasksFile);
  stdout.writeln('基线任务 ${tasks.length} 个；轨迹目录：$traceDir');
  exitCode = scoreTracesDir(tasksFile, traceDir);
}
