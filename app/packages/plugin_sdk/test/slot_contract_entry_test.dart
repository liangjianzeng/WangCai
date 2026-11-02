/// 独立入口冒烟：作者只 import `package:plugin_sdk/slot_contract.dart` 也应该能用
/// （不必为了"看看有哪些位置可填"而拖进整个 SDK）。
library;

import 'package:plugin_sdk/slot_contract.dart';
import 'package:test/test.dart';

void main() {
  test('单入口可独立使用', () {
    expect(allHostSlots, isNotEmpty);
    expect(hostSlotDef('app.tool.view'), isNotNull);
    expect(hostSlotDef('app.nope'), isNull);
  });
}
