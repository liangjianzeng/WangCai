// `agent_handoff` 在宿主这一侧的行为。
//
// 这个动词最容易写出两种假货：
// ① 真的另开一个会话 —— 用户丢了上文、不知道去哪儿看结果（所以定案"交接进当前会话"，测试钉住）；
// ② 火后不管 —— 无论能不能受理都回 Ok(1)，flow 显示"已交接"而对话页什么都没发生。
// 这里两头都钉：**受理前**的失败必须如实报错并给出路，**受理后**不等智能体答完。

import 'package:flutter_test/flutter_test.dart';
import 'package:plugin_kernel/plugin_kernel.dart';
import 'package:tongyi_lite/plugins/host/host_agent.dart';

class _FakePort implements AgentHandoffPort {
  _FakePort({
    this.conversationId = 'c-1',
    this.agentEnabled = true,
    this.conversationBusy = false,
    this.thrown,
    this.acceptDelay = Duration.zero,
  });

  String? conversationId;
  bool agentEnabled;
  bool conversationBusy;
  Object? thrown;
  Duration acceptDelay;

  final List<(String, String)> sent = [];

  @override
  Future<void> accept(String conversationId, String text) async {
    if (acceptDelay > Duration.zero) await Future<void>.delayed(acceptDelay);
    if (thrown != null) throw thrown!;
    sent.add((conversationId, text));
  }
}

Future<Outcome<int>> handoff(_FakePort port, {String sessionId = 'root', String context = ''}) =>
    startAgentHandoff(port,
        pluginName: '英语听写',
        pluginId: 'en-dictation',
        sessionId: sessionId,
        prompt: '把这批词按错得最多的排个序，明天再听写',
        context: context);

void main() {
  group('agent_handoff 交接进当前会话', () {
    test('正常一条：发到当前会话，文本带插件署名、要求与材料', () async {
      final port = _FakePort();
      final r = await handoff(port, context: 'apple 苹果\nbanana 香蕉');
      expect(r.isOk, isTrue);
      expect(r.valueOrNull, 1, reason: '返回的是"启动了几个子任务"，不是答案文本');
      expect(port.sent.single.$1, 'c-1');
      final text = port.sent.single.$2;
      expect(text, contains('英语听写'), reason: '要看得是谁交来的');
      expect(text, contains('en-dictation'));
      expect(text, contains('把这批词按错得最多的排个序'));
      expect(text, contains('banana 香蕉'), reason: 'flow 攒出来的材料得一起交过去');
    });

    test('插件自己带了 sessionId 就用它的（不抢 app 的当前会话）', () async {
      final port = _FakePort(conversationId: 'c-1');
      await handoff(port, sessionId: 'c-9');
      expect(port.sent.single.$1, 'c-9');
    });

    test('没打开对话：如实报错并说清"回到对话页再点"，而且一条都没发', () async {
      final port = _FakePort(conversationId: null);
      final r = await handoff(port);
      expect(r.isErr, isTrue);
      expect(r.failureOrNull!.code, PluginFailureKind.missingCapability);
      expect(r.failureOrNull!.hint, contains('回到对话页'));
      expect(port.sent, isEmpty, reason: '没交成就别说交成了');
    });

    test('智能体总开关关着：说清"交过去也不会执行"并指到设置', () async {
      final port = _FakePort(agentEnabled: false);
      final r = await handoff(port);
      expect(r.isErr, isTrue);
      expect(r.failureOrNull!.message, contains('智能体模式没打开'));
      expect(r.failureOrNull!.hint, contains('打开智能体模式'),
        reason: '两字「设置」指不到是哪个开关；产品那句直接说要打开智能体模式，还带「再点一次」');
      expect(port.sent, isEmpty);
    });

    test('这个会话正在回答：不硬塞第二条打断它', () async {
      final port = _FakePort(conversationBusy: true);
      final r = await handoff(port);
      expect(r.isErr, isTrue);
      expect(r.failureOrNull!.message, contains('这个对话正在回答中'),
        reason: '「正在回答」四字什么都能套；要说破是【这个对话】在回答，用户才知道该去点哪条的停止');
      expect(r.failureOrNull!.hint, contains('或先按停止'),
        reason: '出路要连「按哪个键」一起说：等它答完，或先按停止，免得两条互相打断');
      expect(port.sent, isEmpty);
    });

    test('受理是 await 的：受理阶段就失败时不许回 Ok（火后不管是最坏的假货）', () async {
      final port = _FakePort(thrown: StateError('存储没就绪'));
      final r = await handoff(port);
      expect(r.isErr, isTrue, reason: '受理失败必须让 flow 步骤失败，而不是显示"已交接"');
      expect(r.failureOrNull!.message, '交回智能体没成功');
      // 参谋保留：cause 只断「有原始异常」是对的：异常原文按契约只进诊断树不进 UI，钉成具体文案反而会诱有人把堆栈搬进 message。
      expect(r.failureOrNull!.cause, isNotNull, reason: '异常原文进诊断，不进 message');
      expect(r.failureOrNull!.hint, contains('模型没加载就先在'),
        reason: '两字「模型」等于没指路；真话是「先去设置→推理引擎把模型加载起来」');
    });

    test('受理慢也照常等它（等的是受理，不是整回合）', () async {
      final port = _FakePort(acceptDelay: const Duration(milliseconds: 30));
      final r = await handoff(port);
      expect(r.isOk, isTrue);
      expect(port.sent, hasLength(1));
    });

    test('材料超长要截断：整场清单挤进用户消息就是挤爆上下文', () async {
      final port = _FakePort();
      await handoff(port, context: '单词 释义\n' * 4000);
      final text = port.sent.single.$2;
      expect(text.length, lessThanOrEqualTo(kAgentHandoffMaxChars + 200));
      expect(text, contains('已截断'), reason: '截了要说明，否则模型以为材料就这么多');
    });
  });
}
