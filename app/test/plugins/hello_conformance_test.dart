// 内置冒烟件的 conformance（§4.15：每个插件都要过同一套六组检查，内置也不例外）。
//
// 用 `flutter test test/plugins` 跑（它 import 了 Flutter 负载，跑不了纯 dart test）。
import 'package:flutter_test/flutter_test.dart';
import 'package:plugin_sdk/testing.dart';
import 'package:tongyi_lite/plugins/builtin/hello/hello_plugin.dart';

void main() {
  test('hello-note 过 conformance 六组', () async {
    // 夹具要给齐它 inject 的能力：conformance 会分别跑「能力齐备」与「能力缺失」两种局面，
    // 少了 fakes 只会验到后一半（前面就被踩到过）。
    final h = FakeCapabilityHarness()
      ..register(FakeStore())
      ..register(FakeInteract(numbers: [3]));
    final results = await runConformance(HelloBuiltinPlugin.new, harness: h);
    final failed = results.where((r) => !r.passed).toList();
    expect(
      failed.map((f) => '${f.group}/${f.name}：${f.detail}').toList(),
      isEmpty,
      reason: '内置插件违反作者纪律，等于平台违反自己的契约',
    );
    expect(results.map((r) => r.group), containsAll(<String>['契约', '生命周期', '回收', '状态与错误', '槽', '预算']));
  });
}
