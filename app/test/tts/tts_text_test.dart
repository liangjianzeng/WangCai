// TTS 文本预处理单测：markdown 清洗 + 句子分段。
import 'package:flutter_test/flutter_test.dart';
import 'package:tongyi_lite/tts/tts_text.dart';

void main() {
  group('cleanTextForTts markdown 清洗', () {
    test('代码块整体剔除并留提示', () {
      const src = '前面说明\n```python\nprint("hello")\n```\n后面结论';
      final out = cleanTextForTts(src);
      expect(out, contains('（代码略）'));
      expect(out, isNot(contains('print')));
      expect(out, contains('前面说明'));
      expect(out, contains('后面结论'));
    });

    test('链接保留文字、图片与裸 URL 剔除', () {
      const src = '见[官方文档](https://example.com/a)说明\n'
          '![截图](https://img.example.com/x.png)\n'
          '访问 https://example.com/b 了解更多';
      final out = cleanTextForTts(src);
      expect(out, contains('官方文档'));
      expect(out, isNot(contains('example.com/a')));
      expect(out, isNot(contains('截图')));
      expect(out, isNot(contains('https://')));
    });

    test('标题/强调/引用符号剥离', () {
      const src = '# 标题\n**加粗** 与 *斜体*\n> 引用内容';
      final out = cleanTextForTts(src);
      expect(out, contains('标题'));
      expect(out, contains('加粗'));
      expect(out, contains('斜体'));
      expect(out, contains('引用内容'));
      expect(out, isNot(contains('#')));
      expect(out, isNot(contains('**')));
    });

    test('表格与表情清理', () {
      const src = '| a | b |\n|---|---|\n| 1 | 2 |\n😀 完成 🎉';
      final out = cleanTextForTts(src);
      expect(out, isNot(contains('|')));
      expect(out, isNot(contains('😀')));
      expect(out, contains('完成'));
    });

    test('纯文本原样保留', () {
      const src = '你好，这是一段普通回答。包含数字 123 与标点！';
      expect(cleanTextForTts(src), src);
    });
  });

  group('segmentForTts 句子分段', () {
    test('短文本单段', () {
      expect(segmentForTts('你好。'), ['你好。']);
    });

    test('按句子边界合并到段（不超上限）', () {
      final text = List.generate(20, (i) => '这是第$i句话。').join();
      final segs = segmentForTts(text, maxChars: 60);
      expect(segs.length, greaterThan(1));
      for (final s in segs) {
        expect(s.length, lessThanOrEqualTo(60));
      }
      // 内容无损：拼回后逐句都在。
      for (var i = 0; i < 20; i++) {
        expect(segs.join(), contains('这是第$i句话。'));
      }
    });

    test('超长无边界单句硬切', () {
      final text = '长' * 1500;
      final segs = segmentForTts(text, maxChars: 600);
      expect(segs.length, 3); // 600+600+300
      expect(segs.join().length, 1500);
    });

    test('空文本与空白 → 空列表', () {
      expect(segmentForTts(''), isEmpty);
      expect(segmentForTts('   \n  '), isEmpty);
    });
  });
}
