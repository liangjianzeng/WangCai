// 并发会话槽位门控纯函数（checkTurnAdmission）单测。
//
// 规则：① 本地引擎（权重+KV）单实例 → 本地回合彼此互斥，与槽位无关；
// ② 总活跃回合数不得超过并发会话槽位（API 会话可真正并行）。
import 'package:flutter_test/flutter_test.dart';

import 'package:tongyi_lite/providers/chat_provider.dart'
    show checkTurnAdmission;

void main() {
  group('checkTurnAdmission 并发会话槽位门控', () {
    test('无活跃回合 → 任何路线都允许', () {
      expect(
          checkTurnAdmission(
              activeCount: 0, activeHasLocal: false, newIsLocal: true, slots: 1),
          isNull);
      expect(
          checkTurnAdmission(
              activeCount: 0, activeHasLocal: false, newIsLocal: false, slots: 1),
          isNull);
    });

    test('槽位=1：已有任一回活在跑（含 API）→ 拒绝（默认行为与旧版一致）', () {
      final api = checkTurnAdmission(
          activeCount: 1, activeHasLocal: false, newIsLocal: false, slots: 1);
      expect(api, isNotNull);
      expect(api, contains('槽位已满'));

      final local = checkTurnAdmission(
          activeCount: 1, activeHasLocal: false, newIsLocal: true, slots: 1);
      expect(local, isNotNull);
      expect(local, contains('槽位已满'));
    });

    test('槽位>1：API 回合可并行到槽位上限', () {
      expect(
          checkTurnAdmission(
              activeCount: 1, activeHasLocal: false, newIsLocal: false, slots: 3),
          isNull);
      expect(
          checkTurnAdmission(
              activeCount: 2, activeHasLocal: false, newIsLocal: false, slots: 3),
          isNull);
      // 第 4 个 → 满。
      final full = checkTurnAdmission(
          activeCount: 3, activeHasLocal: false, newIsLocal: false, slots: 3);
      expect(full, isNotNull);
      expect(full, contains('3/3'));
    });

    test('本地回合互斥：槽位未满也不允许第二个本地回合', () {
      final rejected = checkTurnAdmission(
          activeCount: 1, activeHasLocal: true, newIsLocal: true, slots: 4);
      expect(rejected, isNotNull);
      expect(rejected, contains('本地模型同一时间只能执行一个会话'));
    });

    test('本地回合与 API 回合可共存（API 不占本地引擎）', () {
      expect(
          checkTurnAdmission(
              activeCount: 1, activeHasLocal: true, newIsLocal: false, slots: 2),
          isNull);
    });
  });
}
