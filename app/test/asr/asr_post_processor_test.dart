// ASR 后处理公共层（T1.4）单测：富转写剥离 / 同音校正幂等 / 指令归一。
// 对应施工计划 §5 test/voice/asr_post_processor_test.dart 的职责（落在
// test/asr/ 与被测文件 lib/asr/ 同树，沿用现有测试布局）。
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:wangcai/asr/asr_post_processor.dart';

void main() {
  group('stripRichTags 富转写标签剥离', () {
    test('尖竖线形态（sense-voice 原始）整对删除', () {
      expect(stripRichTags('<|zh|><|NEUTRAL|>今天天气不错'), '今天天气不错');
      expect(stripRichTags('<|en|><|HAPPY|>hello world'), 'hello world');
    });

    test('竖线夹注形态删除', () {
      expect(stripRichTags('|HAPPY|开饭时间早上9点'), '开饭时间早上9点');
      expect(stripRichTags('|Speech|开会|SAD|了'), '开会了');
    });

    test('未知但形如标签的竖线词也剥离；普通含竖线文本不误伤', () {
      expect(stripRichTags('|FOOBAR|正文'), '正文');
      // 小写裸词不是标签形态（模式要求首字母大写）
      expect(stripRichTags('a|b 选项'), 'a|b 选项');
    });

    test('幂等：二次调用不变', () {
      final once = stripRichTags('<|zh|><|HAPPY|>会议|SPEECH|结束');
      expect(stripRichTags(once), once);
    });

    test('空串与纯标签输入安全', () {
      expect(stripRichTags(''), '');
      expect(stripRichTags('<|zh|><|NEUTRAL|>'), '');
    });
  });

  group('normalizeInstructions 指令归一化', () {
    test('数字与单位间空白收敛（16 k → 16K）', () {
      expect(normalizeInstructions('用 16 k 采样率'), '用 16K 采样率');
      expect(normalizeInstructions('100  Hz 刷新'), '100Hz 刷新');
      expect(normalizeInstructions('带宽 20 M'), '带宽 20M');
    });

    test('285 H → 285H（芯片口径）', () {
      expect(normalizeInstructions('i7-285 H 平台'), 'i7-285H 平台');
    });

    test('单位粘连普通英文词不被吞（后随字母则不动）', () {
      expect(normalizeInstructions('看 3 K 个'), '看 3K 个');
      expect(normalizeInstructions('参数 K 值'), '参数 K 值'); // 前面不是数字，不动
    });

    test('普通语句零改动 + 幂等', () {
      const s = '今天下午三点开会，带上 5 份文档';
      expect(normalizeInstructions(s), s);
      final once = normalizeInstructions('设置 16 k');
      expect(normalizeInstructions(once), once);
    });
  });

  group('AsrPostProcessor.apply 流水线', () {
    test('空热词配置下：剥标签+归一贯通（无词表目录也不抛）', () async {
      final p = AsrPostProcessor();
      await p.configure('${Directory.systemTemp.path}\\no-such-model', const []);
      final out = p.apply('<|zh|><|HAPPY|>把采样率设成 16 k 吧');
      expect(out, '把采样率设成 16K 吧');
      expect(p.lastRawText, contains('<|zh|>'));
    });

    test('同音校正贯通：词表外热词命中（王柴→汪柴）', () async {
      // 临时词表：只放常用字，「汪」刻意不放 → 「汪柴」走同音校正路径。
      final tmp = await Directory.systemTemp.createTemp('asr_vocab');
      File('${tmp.path}\\tokens.txt')
          .writeAsStringSync('王 0\n柴 1\n的 2\n好 3\n');
      final p = AsrPostProcessor();
      await p.configure(tmp.path, const ['汪柴']);
      expect(p.decoderHotwords, isEmpty); // 汪 不在词表 → 不进解码器
      final out = p.apply('王柴的会议纪要');
      expect(out, '汪柴的会议纪要');
      // 幂等
      expect(p.apply(out), out);
      tmp.deleteSync(recursive: true);
    });

    test('词表内热词走解码器路（不吞文本）', () async {
      final tmp = await Directory.systemTemp.createTemp('asr_vocab2');
      File('${tmp.path}\\tokens.txt').writeAsStringSync('王 0\n柴 1\n');
      final p = AsrPostProcessor();
      await p.configure(tmp.path, const ['王柴']);
      expect(p.decoderHotwords, ['王柴']);
      expect(p.apply('王柴你好'), '王柴你好');
      tmp.deleteSync(recursive: true);
    });
  });
}
