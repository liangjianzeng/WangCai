import 'package:plugin_sdk/plugin_sdk.dart';
import 'package:test/test.dart';

/// **这份表就是契约本身**（P0 冻结件）。
///
/// 改动规则：允许**新增**槽；**不许**改已有槽的 id / kind / scope / maxEntries ——
/// 那会让已经写好 plugin.json 的用户和已发布插件静默失效。真要改，就新增一个并把旧的走弃用流程。
const _frozenHostSlots = <String, (SlotKind, SlotScope, int?)>{
  'app.input.left': (SlotKind.list, SlotScope.sessionMaybe, null),
  'app.input.right': (SlotKind.list, SlotScope.sessionMaybe, null),
  'app.input.activity': (SlotKind.list, SlotScope.session, null),
  'app.input.attachments': (SlotKind.list, SlotScope.session, null),
  'app.composer.dock': (SlotKind.list, SlotScope.session, null),
  'app.input.dock': (SlotKind.single, SlotScope.session, 4),
  'app.input.overlay': (SlotKind.single, SlotScope.session, null),
  'app.composer.takeover': (SlotKind.chain, SlotScope.session, null),
  'app.chat.node': (SlotKind.keyed, SlotScope.session, null),
  'app.tool.view': (SlotKind.keyed, SlotScope.session, null),
  'app.settings.section': (SlotKind.list, SlotScope.root, null),
};

void main() {
  group('宿主 11 槽契约（冻结）', () {
    test('恰好 11 个宿主槽，id/kind/scope/maxEntries 一字不差', () {
      expect(kHostSlotContract.length, 11);
      final actual = {for (final d in kHostSlotContract) d.id: (d.kind, d.scope, d.maxEntries)};
      expect(actual.keys.toSet(), _frozenHostSlots.keys.toSet(),
          reason: '槽被增删了：新增可以，删除/改名要走弃用流程');
      for (final e in _frozenHostSlots.entries) {
        expect(actual[e.key], e.value, reason: '槽 ${e.key} 的语义被改了（契约只加不改）');
      }
    });

    test('每个槽都写了评审必读的 description（≥20 字，说清保证什么）', () {
      for (final d in kHostSlotContract) {
        expect(d.description.length, greaterThan(20), reason: '${d.id} 的 description 太敷衍');
        expect(d.ownerPluginId, 'app');
        expect(isValidSlotId(d.id), isTrue, reason: '${d.id} 不合命名规范');
      }
    });

    test('id 唯一且都在 app 命名空间下', () {
      final ids = allHostSlots.map((d) => d.id).toList();
      expect(ids.toSet().length, ids.length);
      expect(ids.every((i) => i.startsWith('app.')), isTrue);
    });

    test('四种基数语义各有代表（防"只会做 list"这种偏科平台）', () {
      final kinds = kHostSlotContract.map((d) => d.kind).toSet();
      expect(kinds, containsAll(<SlotKind>[SlotKind.list, SlotKind.single, SlotKind.keyed, SlotKind.chain]));
    });

    test('查不存在的槽返回 null（宿主渲染层据此什么都不画）', () {
      expect(hostSlotDef('app.input.rigth'), isNull, reason: 'typo 的槽名不许悄悄命中别的槽');
      expect(hostSlotDef('app.input.right')!.kind, SlotKind.list);
    });

    test('插件面板的槽也已冻结（实现虽在 P6，契约不欠债）', () {
      expect(kPanelSlotContract.map((d) => d.id), ['app.plugins.tab', 'app.plugins.detail.action']);
    });
  });
}
