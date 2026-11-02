// 契约表与解释器不许各说各话（P1/P5 的方向约束）。
//
// `FlowStepOp.knownParamKeys` 是"这个原语到底读哪些步骤参数"的唯一真源，validate 拿它拦拼错的键。
// 一旦它与 `flow_runner` 的实际读取漂移，就会出现两种坏结果：
// ① 表里有、runner 不读 → 装饰品键被当成合法写法（示例里就出现过 `"gapSeconds": "{{config.gapSeconds}}"`）；
// ② runner 读、表里没有 → 作者写对了却被 validate 提醒，从此没人信这个工具。
// 所以这里**双向**钉住：表里的键必须在 runner 源码里真被读到；runner 读的键必须在表里（或开放原语的豁免集里）。
import 'dart:io';

import 'package:plugin_kernel/plugin_kernel.dart';
import 'package:plugin_sdk/plugin_sdk.dart';
import 'package:test/test.dart';

String? _findRepoFile(String relative) {
  var d = Directory.current;
  for (var i = 0; i < 6; i++) {
    final f = File('${d.path}/$relative');
    if (f.existsSync()) return f.path;
    final parent = d.parent;
    if (parent.path == d.path) break;
    d = parent;
  }
  return null;
}

/// 开放原语（`knownParamKeys == null`）额外允许的键：`llm_extract` 的多余键是 `prompt.md` 的变量，
/// `promptFile` 由装载器读、`system` 是提示词内部键 —— 都不是"拼错的键"。
const _openExtra = {
  'allowLineFallback',
  'instruction',
  'maxTokens',
  'noteKeys',
  'promptFile',
  'textKeys',
  'unitKeys',
  'system',
};

void main() {
  final runnerPath = _findRepoFile('packages/plugin_kernel/lib/src/flow_runner.dart');

  test('找得到 flow_runner.dart（这组测试靠读它来对齐契约）', () {
    expect(runnerPath, isNotNull);
  });

  test('表里的每个键，runner 源码里必须真的读它', () {
    final src = File(runnerPath!).readAsStringSync();
    for (final op in FlowStepOp.values) {
      for (final key in op.knownParamKeys ?? const <String>{}) {
        final read = src.contains("p['$key']") || src.contains("params['$key']");
        expect(read, isTrue, reason: '$op 的表里列了 "$key"，但 flow_runner 里没人读它 —— 那是装饰品键，必须从表里删');
      }
    }
  });

  test('runner 读的每个键，表里必须有（开放原语按豁免集算）', () {
    final src = File(runnerPath!).readAsStringSync();
    final read = RegExp(r"(?:p|params)\['([A-Za-z]+)'\]").allMatches(src).map((m) => m.group(1)!).toSet();
    expect(read, isNotEmpty, reason: '正则没抓到东西，说明 runner 写法变了，这组测试要跟着改');

    final tabled = <String>{
      for (final op in FlowStepOp.values) ...?op.knownParamKeys,
    };
    // 开放原语（llm_extract）的键只对它自己合法；这里按"出现在豁免集"放行。
    for (final key in read) {
      expect(tabled.contains(key) || _openExtra.contains(key), isTrue,
          reason: 'runner 读了 "$key" 但契约表没列：作者写它会被 validate 误报，必须补进 knownParamKeys');
    }
  });

  test('开放集只给 llm_extract（别的原语都必须闭集，否则拼错键抓不住）', () {
    final openOps = FlowStepOp.values.where((o) => o.knownParamKeys == null).toList();
    expect(openOps, [FlowStepOp.llmExtract], reason: '多开一个开放原语 = 那原语的拼错键从此无人管');
  });

  test('原语集合是冻结件 —— 8 个，一个都不许多（加原语必须走契约评审）', () {
    expect(
      FlowStepOp.values.map((o) => o.name).toSet(),
      {
        'capture',
        'llmExtract',
        'review',
        'askParams',
        'speakSequence',
        'store',
        'export',
        'agentHandoff',
      },
      reason: 'flow 原语是平台预算：多一个就多一份校验、一份 runner 分支、一份文档；'
          '少一个就是作者手上的 API 凭空蒸发。两头都必须走契约评审（§11-A 第 30 条）。',
    );
  });
}
