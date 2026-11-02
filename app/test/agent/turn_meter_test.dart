import 'package:flutter_test/flutter_test.dart';

import 'package:tongyi_lite/agent/observability/turn_meter.dart';

void main() {
  group('token 估算口径', () {
    test('中文按字、英文按 4 字符折 1，空白不计', () {
      expect(estimateTokens(''), 0);
      expect(estimateTokens('一二三四五六七八九十'), 10);
      expect(estimateTokens('a' * 80), 20);
      expect(estimateTokens('a' * 81), 21); // 向上取整
      expect(estimateTokens('   \n\t  '), 0);
      // 混合：9 汉字（按字）+ 40 字母（4 字符折 1）= 9 + 10
      expect(estimateTokens('一二三四五六七八九${'a' * 40}'), 19);
    });

    test('全角标点与假名按字计（不能掉进 4 字符折算里）', () {
      expect(estimateTokens('，。！？；：'), 6);
      expect(estimateTokens('こんにちは'), 5);
    });
  });

  group('回合读数（用户要看得懂在干什么）', () {
    test('产出包含工具参数——工具参数也是模型烧出来的 token', () {
      final m = TurnMeter(
        step: 2,
        stepBudget: 1024,
        answer: '好的',
        toolArgumentJson: ['{"path":"/data/x.txt","content":"${'a' * 400}"}'],
        toolCount: 1,
      );
      expect(m.producedTokens, greaterThanOrEqualTo(100));
      expect(m.label, contains('工具 1'));
      // 「第 X 步」计数已删（2026-10-25 用户指令）：细条不再显示步序号。
      expect(m.label, isNot(contains('第 2 步')));
      expect(m.label, contains('/1024'));
    });

    test('工具参数生成中（answer 与思考都空）也要计进产出，不能显示 0 产出', () {
      final m = TurnMeter(step: 1, toolGenChars: 800);
      expect(m.producedTokens, 200);
      expect(m.looksWasteful, isFalse, reason: '正在生成工具参数 ≠ 空转');
    });

    test('服务端 usage 到位时以服务端为准并标明非估算', () {
      final est = TurnMeter(answer: '你好');
      final srv = TurnMeter(
          answer: '你好', fromServerUsage: true, serverCompletionTokens: 4321);
      expect(est.totalTokens, lessThan(10));
      expect(srv.totalTokens, 4321);
      expect(srv.label, contains('4321 tok'));
      expect(srv.label, isNot(contains('约')), reason: '服务端数不该再标"约"');
      expect(est.label, contains('约'));
    });

    test('无用功判据：思考狂涨而正文零产出 = 只想不写', () {
      final burn = TurnMeter(
        step: 1,
        liveThinking: '让我想一想' * 300, // 1500 字 ≈ 1500 tok
        answer: '',
      );
      expect(burn.thinkingTokens, greaterThan(600));
      expect(burn.producedTokens, 0);
      expect(burn.looksWasteful, isTrue);
      expect(burn.label, contains('只想不写'));
      expect(burn.label, contains('思考 1500 字'));
    });

    test('有产出就不算空转；重试中也不误报（重试本身是可见状态）', () {
      final ok = TurnMeter(
          liveThinking: '让我想一想' * 300, answer: '结论是这样做：' * 30);
      expect(ok.looksWasteful, isFalse);
      final retrying = TurnMeter(
          liveThinking: '让我想一想' * 300, answer: '', retryAttempt: 1);
      expect(retrying.looksWasteful, isFalse);
      expect(retrying.label, contains('重试 1'));
    });

    test('刚开始想（思考还不够多）不报空转，避免每次开局都闪警告', () {
      expect(TurnMeter(liveThinking: '嗯', answer: '').looksWasteful, isFalse);
    });

    test('累计 = 产出 + 思考（估算口径），思考字数与守卫阈值同用「字」', () {
      final m = TurnMeter(
        answer: '结论' * 40,
        liveThinking: '推理' * 100,
        archivedThinking: ['前一步的思考' * 50],
      );
      expect(m.totalTokens, m.producedTokens + m.thinkingTokens);
      // 200 字（推理×100）+ 300 字（前一步的思考×50，每遍 6 字）
      expect(m.thinkingChars, 500);
    });
  });
}
