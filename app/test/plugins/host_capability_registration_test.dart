// 宿主注册能力这条链的诚实性。
//
// `CapabilityRegistry.register` 返回 `Outcome`：同 id 同 priority 的第二次注册会被拒（先到先得）。
// 以前五个调用点把返回值整个丢掉 —— 于是"我明明注册了离线实现，怎么还走在线"在日志里
// 一个字都没有，属于"受理了但没干活"里最难查的那种。现在被拒必须留下声音。
import 'package:flutter_test/flutter_test.dart';
import 'package:plugin_kernel/plugin_kernel.dart';
import 'package:plugin_sdk/testing.dart';
import 'package:tongyi_lite/plugins/host/host_wiring.dart';

void main() {
  group('宿主注册能力：被拒必须留下声音', () {
    test('同 id 同 priority 撞车：返回 false，日志说清被谁占了、怎么办', () {
      final caps = CapabilityRegistry();
      final log = <String>[];

      expect(
          registerHostCapability(caps, FakeCapability(ServiceKeys.store),
              ownerPluginId: 'app', log: log.add),
          isTrue);
      expect(
          registerHostCapability(caps, FakeCapability(ServiceKeys.store),
              ownerPluginId: 'offline-pack', log: log.add),
          isFalse,
          reason: '静默 false 就是"注册了但没进去"，调用方连知道的机会都没有');

      expect(log, hasLength(1));
      expect(log.single, contains('注册被拒'));
      expect(log.single, contains('app.store'), reason: '要说清是哪个能力');
      expect(log.single, contains('offline-pack'), reason: '要说清是谁没注册上');
      expect(log.single, contains('priority'), reason: '出路（换 priority）要写在日志里，别让人去猜');
      expect(caps.list('app.store'), hasLength(1), reason: '被拒的注册不许留下半个条目');
    });

    test('用更小 priority 压上去是合法的：成功、且不产生噪音日志', () {
      final caps = CapabilityRegistry();
      final log = <String>[];

      expect(registerHostCapability(caps, FakeCapability(ServiceKeys.store), ownerPluginId: 'app'), isTrue);
      expect(
          registerHostCapability(caps, FakeCapability(ServiceKeys.store),
              ownerPluginId: 'offline-pack', priority: -1, log: log.add),
          isTrue);

      expect(log, isEmpty, reason: '正常路径不许往日志里泼水');
      final sorted = caps.list('app.store');
      expect(sorted, hasLength(2));
      expect(sorted.first.priority, -1, reason: '排序按 priority：小的在前，resolve 取第一个可用的');
    });
  });
}
