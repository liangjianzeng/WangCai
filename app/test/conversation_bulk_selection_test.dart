import 'package:flutter_test/flutter_test.dart';

// 会话批量选择「反选」核心的回归锚（2026-11-07 用户点单全选/反选）。
// 反选的唯一非显然语义：只取反当前搜索过滤下可见的会话，
// 被过滤掉的已选项保持原样——搜索不该吞掉用户之前勾的选择。
// （全选 = addAll 可见集，无分支逻辑，不在此重复锁。）
import 'package:wangcai/screens/home_screen.dart'
    show invertConversationSelectionWithin;

void main() {
  group('invertConversationSelectionWithin（会话反选核心）', () {
    test('可见项逐个取反：未选→选、已选→取消', () {
      final selected = {'a'};
      invertConversationSelectionWithin(selected, {'a', 'b', 'c'});
      expect(selected, {'b', 'c'}, reason: 'a 被取消，b/c 被选中');
    });

    test('不在可见集里的已选项保持原样（搜索过滤不吞选择）', () {
      final selected = {'a', 'hidden1', 'hidden2'};
      invertConversationSelectionWithin(selected, {'a', 'b'});
      expect(selected, {'hidden1', 'hidden2', 'b'},
          reason: 'a 可见被反掉；hidden* 不可见保持已选');
    });

    test('空可见集 = 无操作（搜索无结果时反选不误伤）', () {
      final selected = {'a', 'b'};
      invertConversationSelectionWithin(selected, {});
      expect(selected, {'a', 'b'});
    });

    test('全选后反选 = 可见项全部退出选择（反选兼作取消全选的路径）', () {
      final selected = {'a', 'b', 'c'}..addAll({'hidden'});
      invertConversationSelectionWithin(selected, {'a', 'b', 'c'});
      expect(selected, {'hidden'});
    });
  });
}
