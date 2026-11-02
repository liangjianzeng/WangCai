/// 宿主接缝：flow 的 `agent_handoff` 动词 —— 把手头结果**交回智能体续跑**。
///
/// 定案（写死，免得以后有人改成"新开一个会话"却不说明白）：
/// **交接进当前会话**，不新开。理由很实在 ——
/// 用户是在这串对话里点的插件（"听写完帮我总结一下"），
/// 突然冒出一个新会话，他既不知道去哪儿看结果，也丢了上文；
/// 而"新会话"唯一的好处只是隔离，可隔离在插件平台上早有自己的位置（`app.store` 命名空间、独立能力），
/// 不该由一个 flow 动词顺手决定。
///
/// 三条纪律：
/// * **不 await 完整回合**。flow 步骤有自己的超时（内核 `_withTimeout`），
///   等智能体答完会被误判成"步骤超时失败"；而且用户就在对话页看着它跑，flow 没必要卡在那儿。
///   所以端口只保证"**受理成功**"（会话在、没在忙、开关开着），受理完立刻记 `agentsStarted = 1`。
/// * **受理前的失败一律如实报错并给出路**：没打开对话 / 这个会话正在回答 / 智能体模式没开 ——
///   这三种都是"用户一动手就能修"的，绝不返回 Ok 假装交接了。
/// * **上下文有长度上限**：一个 flow 攒出来的清单可能很长，整段塞进用户消息会把上下文挤爆
///   （和 `prompt.md ≤ 32KB` 是同一类坑），超了截断并在文本里注明。
library;

import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:plugin_kernel/plugin_kernel.dart';

import '../../providers/chat_provider.dart';
import '../../providers/settings_provider.dart';

/// 交给智能体的文本上限（字符）。超了截断 —— 这条不是优化，是防"整场清单挤爆上下文"。
const int kAgentHandoffMaxChars = 4000;

/// 交接端口（真机接 `chat_provider`；测试里换成假件，不必起 Riverpod）。
abstract interface class AgentHandoffPort {
  /// 当前打开的会话 id；没在对话页就是 null。
  String? get conversationId;

  /// 智能体总开关（关了交过去也不会执行，得先说清楚）。
  bool get agentEnabled;

  /// 这个会话是不是正在回答（正在回答时再塞一条只会打断它）。
  bool get conversationBusy;

  /// **受理**一条交回智能体的消息（不等它答完）。受理失败请抛异常，由 [hostStartAgent] 折算成人话。
  Future<void> accept(String conversationId, String text);
}

/// 真机端口：当前会话 = home_screen 打开的那一个；发送 = `chatProvider.sendMessage`。
final class ChatAgentHandoffPort implements AgentHandoffPort {
  ChatAgentHandoffPort(this._ref);

  final Ref _ref;

  @override
  String? get conversationId => _ref.read(currentConversationIdProvider);

  @override
  bool get agentEnabled => _ref.read(settingsProvider).agentEnabled;

  @override
  bool get conversationBusy {
    final id = conversationId;
    if (id == null) return false;
    return _ref.read(runningTurnsProvider).containsKey(id);
  }

  @override
  Future<void> accept(String conversationId, String text) async {
    // 不 await 整回合：只把它发出去，失败在后台记日志（对话页自己会显示失败原因）。
    unawaited(_ref
        .read(chatNotifierProvider.notifier)
        .sendMessage(conversationId, text)
        .catchError((Object e) {
      debugPrint('[plugin-handoff] 交回智能体这条没跑成：$e');
      return '';
    }));
  }
}

/// [FlowHost.startAgent] 的接法（薄壳，真身在 [startAgentHandoff]，不起 ctx 就能测）。
Future<Outcome<int>> hostStartAgent(
  AgentHandoffPort port,
  PluginCtx ctx,
  String prompt,
  String context,
) =>
    startAgentHandoff(
      port,
      pluginName: ctx.manifest.name,
      pluginId: ctx.manifest.id,
      sessionId: ctx.sessionId,
      prompt: prompt,
      context: context,
    );

/// 组文本 + 受理 + 计数。失败一律折算成带出路的人话（受理前那三种都是用户一动手就能修的）。
Future<Outcome<int>> startAgentHandoff(
  AgentHandoffPort port, {
  required String pluginName,
  required String pluginId,
  required String sessionId,
  required String prompt,
  required String context,
}) async {
  bool ok(String? value) => value != null && value.trim().isNotEmpty;

  if (!port.agentEnabled) {
    return Outcome.err<int>(
      code: PluginFailureKind.missingCapability,
      message: '智能体模式没打开，交过去也不会执行',
      hint: '到「设置 → 智能体」打开智能体模式，再点一次',
      pluginId: pluginId,
    );
  }

  // 插件自己知道会话（比如从某个会话里唤起的）就用它的；否则用 app 当前打开的那一个。
  final conversationId = sessionId != 'root' && ok(sessionId) ? sessionId : port.conversationId;
  if (!ok(conversationId)) {
    return Outcome.err<int>(
      code: PluginFailureKind.missingCapability,
      message: '现在没有可交接的对话',
      hint: '回到对话页再点它（交接是接着这串聊，不是另开一个）',
      pluginId: pluginId,
    );
  }
  if (port.conversationBusy) {
    return Outcome.err<int>(
      code: PluginFailureKind.runtimeError,
      message: '这个对话正在回答中',
      hint: '等它答完（或先按停止）再交接，免得两条互相打断',
      pluginId: pluginId,
    );
  }

  final body = ok(context) ? '\n手头的材料：\n${_clip(context)}' : '';
  final text = '【插件交接】$pluginName（$pluginId）\n$prompt$body';
  try {
    await port.accept(conversationId!, text);
  } catch (e) {
    return Outcome.err<int>(
      code: PluginFailureKind.runtimeError,
      message: '交回智能体没成功',
      hint: '看看对话页那条的失败原因；模型没加载就先在「设置 → 推理引擎」加载',
      pluginId: pluginId,
      cause: e,
    );
  }
  debugPrint('[plugin-handoff] $pluginId → 会话 $conversationId（${text.length} 字）');
  return const Ok<int>(1);
}

String _clip(String s) {
  final t = s.trim();
  if (t.length <= kAgentHandoffMaxChars) return t;
  return '${t.substring(0, kAgentHandoffMaxChars)}\n…（材料太长，已截断；需要更多请让我再取）';
}
