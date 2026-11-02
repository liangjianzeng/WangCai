import 'package:plugin_sdk/plugin_sdk.dart';
import 'package:test/test.dart';

/// 抽取容错是**平台唯一的一份**（声明式 flow 与手写插件共用），所以这里钉死的是
/// "同一个模型、同一份脏输出，任何插件得到同样的结果"。
void main() {
  test('标准 {"items":[…]}', () {
    final r = extractItems('{"items":[{"text":"apple","note":"苹果","unit":"Unit 1"}]}');
    expect(r.single.text, 'apple');
    expect(r.single.note, '苹果');
    expect(r.single.unit, 'Unit 1');
  });

  test('围栏 + 前后寒暄', () {
    final r = extractItems('好的：\n```json\n{"items":[{"text":"apple"}]}\n```\n希望有帮助');
    expect(r.map((e) => e.text), ['apple']);
  });

  test('裸数组 + 单引号 + 尾逗号', () {
    final r = extractItems("[{'text':'apple','note':'苹果'},{'text':'pear'},]");
    expect(r.map((e) => e.text), ['apple', 'pear']);
    expect(r.first.note, '苹果');
  });

  test('键名漂移（word/zh/释义）与大小写都认', () {
    final r = extractItems('{"Words":[{"Word":"dog","释义":"狗"}]}');
    expect(r.single.text, 'dog');
    expect(r.single.note, '狗');
  });

  test('多余字段进 extra，不丢信息也不猜', () {
    final r = extractItems('{"items":[{"text":"run","pos":"v."}]}');
    expect(r.single.extra['pos'], 'v.');
  });

  test('单个对象也算一条', () {
    expect(extractItems('{"text":"apple","note":"苹果"}').single.text, 'apple');
  });

  test('纯文本按行兜底（≥2 条短行）', () {
    final r = extractItems('apple\nbanana\ncherry');
    expect(r.map((e) => e.text), ['apple', 'banana', 'cherry']);
  });

  test('认不出来 → 空表，绝不把散文当条目端给用户', () {
    expect(extractItems('抱歉，这张图我看不太清，请重新拍摄。'), isEmpty);
    expect(extractItems(''), isEmpty);
    expect(extractItems('{"items":[]}'), isEmpty);
    expect(extractItems('apple\nbanana', allowLineFallback: false), isEmpty);
  });

  test('条目里的花括号不会把切片带偏（取最外层）', () {
    final r = extractItems('前缀 {"items":[{"text":"a{b}c"}]} 后缀');
    expect(r.single.text, 'a{b}c');
  });
}
