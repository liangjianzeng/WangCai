/// 智能体内嵌工作流 UI（主流智能体形态，§12.3 改造）。
///
/// 状态提示不再分散在 AppBar 徽章 / 输入区面板，而是对话内按回合
/// 一步步向下渲染：[思考中…] → [🔧 工具卡片 ×N（逐步）] → [最终回答]。
///
/// - 运行中回合：步骤取 [AgentUiState] 事件流实时数据（参数/结果/状态
///   实时更新）；
/// - 历史回合：步骤解析自存储的 🔧 活动消息（[parseToolActivity]），
///   历史对话可回看每次工具调用。
library;

import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart' show PlatformException;

import '../models/chat_message.dart';
import '../models/turn_trace.dart';
import '../providers/agent_state_provider.dart';
import '../services/device_files_service.dart';
import 'chat_bubble.dart';
import 'turn_clock.dart';
import 'turn_items.dart';

// ---------------------------------------------------------------------------
// 消息分组
// ---------------------------------------------------------------------------

/// 对话展示单元：普通消息保持原样；智能体回合重排为
/// [工具步骤… → 最终回答] 的 [AgentTurnBlock]（内嵌工作流）。
sealed class RenderUnit {
  const RenderUnit();
}

/// 单条用户/普通消息。
class UserUnit extends RenderUnit {
  final ChatMessage message;
  const UserUnit(this.message);
}

/// 一个智能体回合：[tools, answer] 的重排展示单元。
class TurnUnit extends RenderUnit {
  /// 存储顺序中的 🔧 活动消息（新模式 [user, ans, t1..tk]；
  /// 旧模式 [user, t1..tk, ans]）——展示时全部排到回答之前。
  final List<ChatMessage> tools;

  /// 本回合的 assistant 回答（可能为空：中断且未产出答案）。
  final ChatMessage? answer;

  /// 存储的 💭 思考存档消息文本（已去前缀；历史回合过程痕迹回看）。
  final List<String> thinking;

  /// turnTrace UI 信封（2026-10-25 阶段 2）：新回合落库时按 live timeline
  /// 真实交错顺序写入；历史回合渲染**优先走信封**（与 live 同管线），
  /// 旧数据为 null 走散消息重排回退。
  final List<TurnUiItem>? trace;

  /// 信封 tool 项 id → 解析后的卡片数据（优先 toolData 结构化，旧行回退
  /// 前缀解析）。
  final Map<String, ToolActivityUi> traceTools;

  const TurnUnit(this.tools, this.answer,
      {this.thinking = const [], this.trace, this.traceTools = const {}});
}

/// 把原始消息流按回合重排为展示单元。
///
/// 规则：user 消息是分界；user 之后的非 🔧/💭 assistant 消息 = 回答；
/// 🔧 前缀的 assistant 消息 = 工具步骤；💭 前缀 = 思考存档。无论存储顺序
/// 如何，都重排为 [工具… → 回答]，与 [AgentTurnBlock] 的渲染顺序一致。
List<RenderUnit> groupMessages(List<ChatMessage> messages) {
  final units = <RenderUnit>[];
  final pendingTools = <ChatMessage>[];
  final pendingThinking = <String>[];
  final turnMessages = <ChatMessage>[];
  ChatMessage? pendingAnswer;

  void flush() {
    if (pendingTools.isEmpty &&
        pendingThinking.isEmpty &&
        pendingAnswer == null) {
      turnMessages.clear();
      return;
    }
    // 必须拷贝：TurnUnit 保存的列表引用若直接复用 pendingTools，
    // 随后的 pendingTools.clear() 会把已入队的 tools 一并清空。
    final toolList = [...pendingTools];
    final thinkingList = [...pendingThinking];
    // turnTrace 信封优先：本回合消息里找 noticeCode='turnTrace' 的信封，
    // 解码成功 → 历史回合按真实交错顺序渲染（与 live 同管线）。
    List<TurnUiItem>? trace;
    final Map<String, ToolActivityUi> traceTools = {};
    for (final m in turnMessages) {
      if (m.kind == MessageKind.notice && m.noticeCode == 'turnTrace') {
        trace = decodeTurnUiTrace(m.content);
        break;
      }
    }
    if (trace != null) {
      for (final m in turnMessages) {
        if (m.kind != MessageKind.toolActivity) continue;
        final byData = m.toolData != null
            ? ToolActivityUi(
                callId: m.id,
                name: m.toolData!.name,
                arguments: const {},
                status: (m.toolData!.phase == 'failed' || m.toolData!.isError)
                    ? ToolUiStatus.failed
                    : ToolUiStatus.done,
                result: (m.toolData!.resultText?.isNotEmpty ?? false)
                    ? m.toolData!.resultText
                    : m.toolData!.summary,
                isError: m.toolData!.isError || m.toolData!.phase == 'failed',
              )
            : parseToolActivity(m);
        if (byData != null) traceTools[m.id] = byData;
      }
      // 信封引用的工具消息缺失（极端：清理脚本删过）→ 整条回退旧重排。
      final referenced = trace.where((i) => i.type == 'tool').length;
      if (referenced > 0 && traceTools.length < referenced) trace = null;
    }
    units.add(TurnUnit(toolList, pendingAnswer,
        thinking: thinkingList, trace: trace, traceTools: traceTools));
    pendingTools.clear();
    pendingThinking.clear();
    turnMessages.clear();
    pendingAnswer = null;
  }

  for (final m in messages) {
    // 内存构造的消息（测试/临时流）可能未经读取层推断 kind——与
    // ChatMessage.resolveKind 同口径兜底，再按类型分派。
    final k = (m.kind == MessageKind.text && m.toolData == null)
        ? inferLegacyKind(m.content)
        : m.kind;
    if (m.role == MessageRole.user) {
      flush();
      units.add(UserUnit(m));
    } else if (k == MessageKind.toolActivity) {
      pendingTools.add(m);
    } else if (k == MessageKind.thinking) {
      final t = m.content.startsWith('💭 ')
          ? m.content.substring('💭 '.length)
          : m.content.substring('💭'.length);
      if (t.trim().isNotEmpty) pendingThinking.add(t);
    } else if (k == MessageKind.notice || k == MessageKind.error) {
      // 过程信封/错误行：不进渲染序列（阶段 3 的行族负责回看展示）。
      turnMessages.add(m);
    } else {
      pendingAnswer = m;
    }
    if (m.role == MessageRole.assistant) turnMessages.add(m);
  }
  flush();
  return units;
}

/// 把 🔧 活动消息内容解析为卡片数据（历史回合步骤回看）。
///
/// 存储约定（新主循环会话层与旧 runAgent 会话共用模板）：
/// - executing：`🔧 正在调用 {name}…`（旧模式多工具为 `🔧 正在调用：A、B…`）；
/// - done/failed：`🔧 {name} ✓/⚠️{summary}`。
ToolActivityUi? parseToolActivity(ChatMessage msg) {
  final c = msg.content.trim();
  if (!c.startsWith('🔧')) return null;
  // 🔧 后通常跟一个空格（"🔧 正在调用 …"）；trim 掉，避免
  // body.startsWith('正在调用') / indexOf 被前置空格干扰。
  final body = c.substring('🔧'.length).trim();

  if (body.startsWith('正在调用')) {
    final name = body
        .substring('正在调用'.length)
        .trim()
        .replaceAll(RegExp(r'^[:：]+'), '')
        .replaceAll(RegExp(r'\…+$'), '')
        .trim();
    return ToolActivityUi(
      callId: '',
      name: name,
      arguments: const {},
      status: ToolUiStatus.executing,
    );
  }

  final done = body.indexOf('✓');
  final fail = body.indexOf('⚠️');
  int idx;
  bool failed;
  if (done != -1 && (fail == -1 || done < fail)) {
    idx = done;
    failed = false;
  } else if (fail != -1) {
    idx = fail;
    failed = true;
  } else {
    return null;
  }
  final name = body.substring(0, idx).trim();
  final summary = body
      .substring(idx + (failed ? '⚠️'.length : '✓'.length))
      .trim();
  return ToolActivityUi(
    callId: '',
    name: name,
    arguments: const {},
    status: failed ? ToolUiStatus.failed : ToolUiStatus.done,
    result: summary.isEmpty ? null : summary,
    isError: failed,
  );
}

/// 🔧 活动消息列表 → 卡片数据（跳过无法解析的异常消息）。
List<ToolActivityUi> parsedToolActivities(List<ChatMessage> tools) =>
    tools.map(parseToolActivity).whereType<ToolActivityUi>().toList();

// ---------------------------------------------------------------------------
// 组件
// ---------------------------------------------------------------------------

/// 「执行中…」占位行（与 ChatBubble 空占位同风格；置于工具卡片之后，
/// 表示智能体正在推进任务下一步/最终答案）。
///
/// 用户定案：这里不是"思考"（真思考走 ThinkingStreamCard），只是任务
/// 执行中的状态过渡，标签必须写「执行中」，否则会误导成模型在空想。
class ThinkingIndicator extends StatefulWidget {
  const ThinkingIndicator({super.key});

  @override
  State<ThinkingIndicator> createState() => _ThinkingIndicatorState();
}

class _ThinkingIndicatorState extends State<ThinkingIndicator> {
  DateTime? _start;
  bool _clockOn = false;

  @override
  void initState() {
    super.initState();
    _start = DateTime.now();
    _clockOn = true;
    TurnClock.instance.acquire();
    TurnClock.instance.tick.addListener(_onTick);
  }

  @override
  void dispose() {
    if (_clockOn) {
      _clockOn = false;
      TurnClock.instance.tick.removeListener(_onTick);
      TurnClock.instance.release();
    }
    super.dispose();
  }

  void _onTick() {
    if (mounted) setState(() {});
  }

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 2),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          const SizedBox(
              width: 12,
              height: 12,
              child: CircularProgressIndicator(strokeWidth: 2)),
          const SizedBox(width: 8),
          Text(
            _elapsed == null || _elapsed! < const Duration(seconds: 15)
                ? '执行中…'
                : '执行中 - 持续了${_fmtDur(_elapsed)}',
            style: const TextStyle(fontSize: 13, fontStyle: FontStyle.italic),
          ),
        ],
      ),
    );
  }

  Duration? get _elapsed =>
      _start == null ? null : DateTime.now().difference(_start!);
}

/// _ToolGenIndicator —— 工具调用参数生成期进度（WP5）。
///
/// 模型正在流式输出工具调用块（如 write_file 的大段 HTML 报告参数）：
/// 可见流与思考流都是空的，此前 UI 只能干转圈"思考中"。这里显示
/// 「🔧 正在生成工具调用参数（已 N 字）」+ 开头预览，让用户看到在做什么。
class _ToolGenIndicator extends StatelessWidget {
  final int chars;
  final String preview;
  const _ToolGenIndicator({required this.chars, required this.preview});

  String get _charsLabel => chars >= 1000
      ? '${(chars / 1000).toStringAsFixed(1)}k 字'
      : '$chars 字';

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 2),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          const SizedBox(
              width: 12,
              height: 12,
              child: CircularProgressIndicator(strokeWidth: 2)),
          const SizedBox(width: 8),
          Expanded(
            child: Text(
              preview.isEmpty
                  ? '🔧 正在生成工具调用参数（已 $_charsLabel）…'
                  : '🔧 正在生成工具调用参数（已 $_charsLabel）：$preview',
              maxLines: 2,
              overflow: TextOverflow.ellipsis,
              style: TextStyle(
                fontSize: 13,
                fontStyle: FontStyle.italic,
                color: theme.colorScheme.onSurfaceVariant,
              ),
            ),
          ),
        ],
      ),
    );
  }
}

/// RetryIndicator —— "重试中…（N）"（llm/retry 事件）。
class RetryIndicator extends StatelessWidget {
  final int attempt;
  const RetryIndicator({super.key, required this.attempt});

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 2),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          SizedBox(
            width: 12,
            height: 12,
            child: CircularProgressIndicator(
                strokeWidth: 2, color: theme.colorScheme.tertiary),
          ),
          const SizedBox(width: 8),
          Text(
            '重试中…（$attempt）',
            style: TextStyle(
              fontSize: 12,
              color: theme.colorScheme.onSurfaceVariant,
              fontStyle: FontStyle.italic,
            ),
          ),
        ],
      ),
    );
  }
}

/// CompactionBanner —— "上下文已压缩"（compaction/summary 事件）。
class CompactionBanner extends StatelessWidget {
  const CompactionBanner({super.key});

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Container(
      margin: const EdgeInsets.symmetric(horizontal: 16, vertical: 2),
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 4),
      decoration: BoxDecoration(
        color: theme.colorScheme.secondaryContainer.withValues(alpha: 0.5),
        borderRadius: BorderRadius.circular(8),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(Icons.compress, size: 13,
              color: theme.colorScheme.onSecondaryContainer),
          const SizedBox(width: 6),
          Text(
            '上下文已压缩',
            style: TextStyle(
              fontSize: 12, color: theme.colorScheme.onSecondaryContainer),
          ),
        ],
      ),
    );
  }
}

/// _ThinkingBlockCard —— 已完成步骤的思考存档（折叠条）。
///
/// 与流式卡的区别：无 spinner、默认折叠、不跟随滚动；点按头部展开静态
/// 文本回看。第 N 步思考按序标注。
class _ThinkingBlockCard extends StatefulWidget {
  final String text;
  final int index;
  final Duration? duration;
  const _ThinkingBlockCard(
      {required this.text, required this.index, this.duration});

  @override
  State<_ThinkingBlockCard> createState() => _ThinkingBlockCardState();
}

class _ThinkingBlockCardState extends State<_ThinkingBlockCard> {
  bool _expanded = false;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final tail = widget.text.length > 2000
        ? '…${widget.text.substring(widget.text.length - 2000)}'
        : widget.text;
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 1),
      child: Container(
        decoration: BoxDecoration(
          color:
              theme.colorScheme.surfaceContainerHighest.withValues(alpha: 0.35),
          borderRadius: BorderRadius.circular(8),
        ),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          mainAxisSize: MainAxisSize.min,
          children: [
            InkWell(
              borderRadius: BorderRadius.circular(8),
              onTap: () => setState(() => _expanded = !_expanded),
              child: Padding(
                padding:
                    const EdgeInsets.symmetric(horizontal: 10, vertical: 3),
                child: Row(
                  // max 宽度：Spacer 生效，箭头对齐右缘（min 时跟标题飘）。
                  children: [
                    Icon(Icons.psychology,
                        size: 14,
                        color: theme.colorScheme.tertiary
                            .withValues(alpha: 0.7)),
                    const SizedBox(width: 6),
                    // 序号去掉（用户定案「思考 1/2/3 难看」），但**「思考」
                    // 二字保留**（2026-10-25 澄清：没字用户不知道这行是啥）；
                    // 有耗时显示耗时。
                    Text(
                      widget.duration == null
                          ? '思考'
                          : '思考 - 持续了${_fmtDur(widget.duration)}',
                      style: TextStyle(
                          fontSize: 12,
                          color:
                              theme.colorScheme.tertiary.withValues(alpha: 0.8)),
                    ),
                    // 折叠态摘要 = 思考首行（DSH ReasoningRow firstLine）：
                    // 收起时用户概知里面想了啥。
                    if (!_expanded) ...[
                      const SizedBox(width: 6),
                      Expanded(
                        child: Text(
                          _ThinkingStreamCardState._firstLine(widget.text),
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: TextStyle(
                              fontSize: 11,
                              color: theme.colorScheme.onSurfaceVariant,
                              fontStyle: FontStyle.italic),
                        ),
                      ),
                    ] else
                      const Spacer(),
                    Icon(
                      _expanded ? Icons.expand_less : Icons.expand_more,
                      size: 15,
                      color: theme.colorScheme.onSurfaceVariant,
                    ),
                  ],
                ),
              ),
            ),
            if (_expanded)
              Padding(
                padding: const EdgeInsets.fromLTRB(10, 0, 10, 5),
                child: ConstrainedBox(
                  constraints: const BoxConstraints(maxHeight: 150),
                  child: SingleChildScrollView(
                    child: Text(
                      tail,
                      style: TextStyle(
                        fontSize: 11,
                        fontFamily: 'monospace',
                        color: theme.colorScheme.onSurfaceVariant,
                      ),
                    ),
                  ),
                ),
              ),
          ],
        ),
      ),
    );
  }
}

/// ToolActivityCard —— tool/call + tool/result 结构化卡片。
///
/// 折叠态压到**最低可见文字高度**（单行 ~22px）：状态图标 + 工具名 +
/// 参数摘要；点按行内展开完整参数 JSON + 结果。
/// export_file 工具结果 → 打开目标（content URI/绝对路径 + 源文件回退）。
/// 顶层函数：工具卡「打开」按钮与回合产物汇总卡共用同一提取规则。
({String primary, String? fallback})? exportTargetOf({
  required String toolName,
  String? result,
  Map<String, dynamic> arguments = const {},
}) {
  if (toolName != 'export_file') return null;
  final candidates = [result ?? '', arguments['name']?.toString() ?? ''];
  for (final s in candidates) {
    final m = RegExp(r'(content://\S+|/storage/emulated/\S+)').firstMatch(s);
    if (m == null) continue;
    return (
      primary: m.group(1)!,
      fallback: RegExp(r'源文件：(\S+)').firstMatch(s)?.group(1),
    );
  }
  return null;
}

class ToolActivityCard extends StatefulWidget {
  final ToolActivityUi activity;
  const ToolActivityCard({super.key, required this.activity});

  @override
  State<ToolActivityCard> createState() => _ToolActivityCardState();
}

class _ToolActivityCardState extends State<ToolActivityCard> {
  bool _expanded = false;

  /// 执行起点（首次以 executing 状态入树时记录）；null = 未知（历史回合）。
  DateTime? _execStart;
  Duration? _total;

  /// 秒级刷新走全 app 单时钟 [TurnClock]（阶段 4 计时器收敛：替代每卡
  /// 一个 Ticker；实际耗时用 DateTime 差值，重建不丢）。
  bool _clockOn = false;

  /// 折叠行摘要（2026-10-25 阶段 2）：variant 键优先级取参数首行（DSH
  /// toolRowModel 同构）；无命中回退参数 JSON 60 字旧口径。
  String get _argsSummary {
    final a = widget.activity;
    final variant = toolVariantOf(a.name);
    final byVariant = toolVariantSummary(variant, a.arguments);
    if (byVariant != null) return byVariant;
    if (a.arguments.isEmpty) return '';
    try {
      final s = jsonEncode(a.arguments);
      return s.length > 60 ? '${s.substring(0, 60)}…' : s;
    } catch (_) {
      return '';
    }
  }

  /// 失败态折叠摘要 = 失败结果首行（DSH errorSummary：错误顶进折叠行，
  /// 不是靠 ⚠️ 后缀传达）。
  String? get _errorSummary {
    final a = widget.activity;
    if (a.status != ToolUiStatus.failed) return null;
    final r = a.result?.trim();
    if (r == null || r.isEmpty) return null;
    final line = r.split('\n').first.trim();
    return line.isEmpty ? null : line;
  }

  /// 折叠态摘要（用户定案 2026-10-25）：收起时用户要知道**里面输出是啥**，
  /// 不能只有工具名+参数——
  /// 失败 → 错误首行；完成 → **结果首行**（输出概知，DSH resultSummary
  /// 同语义）；无结果/执行中 → 回退参数摘要（执行中看的就是要干啥）。
  String get _collapsedSummary {
    final err = _errorSummary;
    if (err != null) return err;
    final a = widget.activity;
    if (a.status == ToolUiStatus.done) {
      final r = a.result?.trim();
      if (r != null && r.isNotEmpty) {
        for (final raw in r.split('\n')) {
          final line = raw.trim();
          if (line.isNotEmpty) return line;
        }
      }
    }
    return _argsSummary;
  }

  /// WP6：export_file 产物打开目标（复用顶层 [exportTargetOf]）。
  /// live 取 result（工具真实输出），历史取解析后的 summary（落库 🔧 消息）。
  ({String primary, String? fallback})? get _exportTargetInfo =>
      exportTargetOf(
        toolName: widget.activity.name,
        result: widget.activity.result,
        arguments: widget.activity.arguments,
      );

  Future<void> _openExport() async {
    final info = _exportTargetInfo;
    if (info == null) return;
    try {
      await DeviceFilesService.instance
          .openFile(info.primary, fallbackPath: info.fallback);
    } catch (e) {
      if (context.mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('打开失败：$e')),
        );
      }
    }
  }

  /// 另存默认文件名：源文件 basename > export_file 的 name 参数 >
  /// path basename > artifact。
  String get _saveAsName {
    final info = _exportTargetInfo;
    final fb = info?.fallback;
    if (fb != null && fb.isNotEmpty) return fb.split('/').last;
    final name = widget.activity.arguments['name'];
    if (name is String && name.trim().isNotEmpty) return name.trim();
    final path = widget.activity.arguments['path'];
    if (path is String && path.trim().isNotEmpty) {
      return path.trim().split('/').last;
    }
    return 'artifact';
  }

  Future<void> _saveAsExport() async {
    final info = _exportTargetInfo;
    if (info == null) return;
    try {
      final uri = await DeviceFilesService.instance.saveAs(
        srcUri: info.primary.startsWith('content:') ? info.primary : null,
        srcPath: info.fallback,
        name: _saveAsName,
      );
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text('已另存：$uri'),
            duration: const Duration(seconds: 2),
          ),
        );
      }
    } on PlatformException catch (e) {
      if (e.code == 'CANCELLED') return;
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('另存失败：${e.message ?? e.code}')),
        );
      }
    }
  }

  @override
  void initState() {
    super.initState();
    _syncClock();
  }

  @override
  void didUpdateWidget(covariant ToolActivityCard old) {
    super.didUpdateWidget(old);
    _syncClock();
  }

  @override
  void dispose() {
    if (_clockOn) {
      _clockOn = false;
      TurnClock.instance.tick.removeListener(_onTick);
      TurnClock.instance.release();
    }
    super.dispose();
  }

  /// 计时归零/冻结：executing 且无起点 → 记录起点并开秒级 Ticker；
  /// 离开 executing → 冻结总耗时、停 Ticker。
  void _syncClock() {
    final st = widget.activity.status;
    if (st == ToolUiStatus.executing) {
      if (_execStart == null) {
        _execStart = DateTime.now();
        if (!_clockOn) {
          _clockOn = true;
          TurnClock.instance.acquire();
          TurnClock.instance.tick.addListener(_onTick);
        }
      }
    } else if (_execStart != null && _total == null) {
      _total = DateTime.now().difference(_execStart!);
      if (_clockOn) {
        _clockOn = false;
        TurnClock.instance.tick.removeListener(_onTick);
        TurnClock.instance.release();
      }
    }
  }

  void _onTick() {
    if (mounted) setState(() {});
  }

  /// 当前/最终耗时（未知为 null）。
  Duration? get _elapsed {
    if (_total != null) return _total;
    if (_execStart == null) return null;
    return DateTime.now().difference(_execStart!);
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final activity = widget.activity;
    final (IconData icon, Color color, bool busy) = switch (activity.status) {
      ToolUiStatus.executing => (
          Icons.hourglass_top,
          theme.colorScheme.tertiary,
          true
        ),
      ToolUiStatus.done => (Icons.check_circle, Colors.green.shade600, false),
      ToolUiStatus.failed =>
        (Icons.error, theme.colorScheme.error, false),
    };
    final summary = _collapsedSummary;
    // running 态 = 扫光动画（DSH 同款），不再用小转圈——"最多一个 spinner"
    // 由结构保证：工具行跑起来是光带，不是转圈。
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 1),
      child: SweepHighlight(
        active: busy,
        child: Material(
        color:
            theme.colorScheme.surfaceContainerHighest.withValues(alpha: 0.6),
        borderRadius: BorderRadius.circular(6),
          child: InkWell(
          borderRadius: BorderRadius.circular(6),
          onTap: () => setState(() => _expanded = !_expanded),
          child: Padding(
            // 单行高度贴死文字：vertical 2 + fontSize 12 ≈ 22px。
            // horizontal 10：与思考行/执行过程区的行内距一致——展开箭头
            // 与图标落在同一条 x 线上（此前 8，箭头右缘差 2px 不对齐）。
            padding:
                const EdgeInsets.symmetric(horizontal: 10, vertical: 2),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              mainAxisSize: MainAxisSize.min,
              children: [
                Row(
                  children: [
                    Icon(icon, size: 13, color: color),
                    const SizedBox(width: 6),
                    Flexible(
                      child: Text(
                        '🔧 ${activity.name}',
                        overflow: TextOverflow.ellipsis,
                        style: const TextStyle(fontSize: 12),
                      ),
                    ),
                    if (summary.isNotEmpty) ...[
                      const SizedBox(width: 6),
                      Expanded(
                        child: Text(
                          summary,
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: TextStyle(
                              fontSize: 11,
                              color: _errorSummary != null
                                  ? theme.colorScheme.error
                                  : theme.colorScheme.outline),
                        ),
                      ),
                    ],
                    if (activity.status == ToolUiStatus.executing) ...[
                      const SizedBox(width: 4),
                      Text(
                        _execStart == null ? '执行中…' : '执行中 - 持续了${_fmtDur(_elapsed)}',
                        style: TextStyle(
                            fontSize: 10,
                            color: theme.colorScheme.onSurfaceVariant,
                            fontStyle: FontStyle.italic),
                      ),
                    ] else if (_total != null) ...[
                      const SizedBox(width: 4),
                      Text('持续了${_fmtDur(_total)}',
                          style: TextStyle(
                              fontSize: 10,
                              color: theme.colorScheme.outline,
                              fontStyle: FontStyle.italic)),
                    ],
                    // WP6：export_file 完成后给「打开」按钮（系统查看器
                    // 直接查阅 html/png/pdf/md 等产物）。
                    if (activity.status != ToolUiStatus.executing &&
                        _exportTargetInfo != null) ...[
                      const SizedBox(width: 6),
                      InkWell(
                        onTap: _openExport,
                        borderRadius: BorderRadius.circular(4),
                        child: Padding(
                          padding: const EdgeInsets.symmetric(
                              horizontal: 4, vertical: 2),
                          child: Row(
                            mainAxisSize: MainAxisSize.min,
                            children: [
                              Icon(Icons.open_in_new,
                                  size: 12, color: theme.colorScheme.primary),
                              const SizedBox(width: 2),
                              Text('打开',
                                  style: TextStyle(
                                      fontSize: 11,
                                      fontWeight: FontWeight.w600,
                                      color: theme.colorScheme.primary)),
                            ],
                          ),
                        ),
                      ),
                      const SizedBox(width: 2),
                      InkWell(
                        onTap: _saveAsExport,
                        borderRadius: BorderRadius.circular(4),
                        child: Padding(
                          padding: const EdgeInsets.symmetric(
                              horizontal: 4, vertical: 2),
                          child: Row(
                            mainAxisSize: MainAxisSize.min,
                            children: [
                              Icon(Icons.save_alt,
                                  size: 12, color: theme.colorScheme.primary),
                              const SizedBox(width: 2),
                              Text('另存',
                                  style: TextStyle(
                                      fontSize: 11,
                                      fontWeight: FontWeight.w600,
                                      color: theme.colorScheme.primary)),
                            ],
                          ),
                        ),
                      ),
                    ],
                    Icon(
                      _expanded ? Icons.expand_less : Icons.expand_more,
                      size: 14,
                      color: theme.colorScheme.onSurfaceVariant,
                    ),
                  ],
                ),
                if (_expanded) ...[
                  if (activity.arguments.isNotEmpty)
                    Padding(
                      padding: const EdgeInsets.only(top: 3),
                      child: Align(
                        alignment: Alignment.centerLeft,
                        child: Text(
                          '参数：\n${_prettyArgs()}',
                          style: const TextStyle(
                              fontSize: 11, fontFamily: 'monospace'),
                        ),
                      ),
                    ),
                  if (activity.result != null && activity.result!.isNotEmpty)
                    Padding(
                      padding: const EdgeInsets.only(top: 3),
                      child: Align(
                        alignment: Alignment.centerLeft,
                        child: ConstrainedBox(
                          constraints: const BoxConstraints(maxHeight: 150),
                          child: SingleChildScrollView(
                            child: Text(
                              activity.result!.length > 800
                                  ? '${activity.result!.substring(0, 800)}…'
                                  : activity.result!,
                              style: TextStyle(
                                fontSize: 11,
                                fontFamily: 'monospace',
                                color: activity.isError
                                    ? theme.colorScheme.error
                                    : theme.colorScheme.onSurfaceVariant,
                              ),
                            ),
                          ),
                        ),
                      ),
                    ),
                ],
              ],
            ),
          ),
        ),
        ),
      ),
    );
  }

  String _prettyArgs() {
    try {
      return const JsonEncoder.withIndent('  ')
          .convert(widget.activity.arguments);
    } catch (_) {
      return widget.activity.arguments.toString();
    }
  }
}

/// ThinkingStreamCard —— 思考流式卡片（独立模块，不与正文混杂）。
///
/// 用户定案：思考卡主信息是**耗时**（"思考 - 持续了X秒"）。流式输出时
/// **自动展开**并跟随列表滚动（否则用户不知道智能体在干什么）；流式输出
/// 完成（答案开始/回合结束）自动闭合；点按头部可手动展开/收起。
/// 思考文本来自 adapter onThinking 全量快照。
class ThinkingStreamCard extends StatefulWidget {
  final AgentUiState ui;

  /// 正文回答是否已开始输出（保留：答案开始后不展开内容，头部仅剩耗时）。
  final bool answerVisible;

  /// 直播态（2026-10-25）：简单聊天没有 ui.running（非智能体回合），
  /// 由调用方传 true——头部显示「思考中…」+ 自动展开，回合结束收起。
  final bool live;
  const ThinkingStreamCard({
    super.key,
    required this.ui,
    this.answerVisible = false,
    this.live = false,
  });

  @override
  State<ThinkingStreamCard> createState() => _ThinkingStreamCardState();
}

class _ThinkingStreamCardState extends State<ThinkingStreamCard> {
  /// null = 默认收起；非 null = 用户手动覆盖。
  bool? _override;
  DateTime? _start;
  bool _clockOn = false;

  /// 流式长内容自动跟随：内容变长时滚到可见区底部，直到用户手动上滑。
  final ScrollController _scroll = ScrollController();
  bool _userScrolledUp = false;

  @override
  void initState() {
    super.initState();
    _scroll.addListener(_onScroll);
  }

  @override
  void dispose() {
    if (_clockOn) {
      _clockOn = false;
      TurnClock.instance.tick.removeListener(_onTick);
      TurnClock.instance.release();
    }
    _scroll.dispose();
    super.dispose();
  }

  /// 用户滚动时判定是否离开了底部：离开 = 暂停跟随；滚回底部 = 恢复。
  void _onScroll() {
    if (!_scroll.hasClients) return;
    final pos = _scroll.position;
    final atBottom = pos.maxScrollExtent == 0 ||
        pos.pixels >= pos.maxScrollExtent - 4;
    if (_userScrolledUp == atBottom) {
      _userScrolledUp = !atBottom;
    }
  }

  /// 流式中把最新内容滚进可见区（仅当仍在跟随状态）。
  void _followStream() {
    if (!mounted || _userScrolledUp || !_scroll.hasClients) return;
    final pos = _scroll.position;
    if (pos.maxScrollExtent > 0 && pos.pixels < pos.maxScrollExtent) {
      _scroll.jumpTo(pos.maxScrollExtent);
    }
  }

  @override
  void didUpdateWidget(ThinkingStreamCard old) {
    super.didUpdateWidget(old);
    // 内容变长（流式推进）时跟随底部；同一内容仅头部耗时刷新的重建
    // 不触发（length 相同），避免无谓跳转。
    if (widget.ui.thinking.length != old.ui.thinking.length) {
      WidgetsBinding.instance.addPostFrameCallback((_) => _followStream());
    }
    // 回合结束 / 答案开始 → 自动闭合；下次再流式时恢复跟随。
    if (!widget.ui.running || widget.answerVisible) {
      _userScrolledUp = false;
    }
  }

  /// 思考开始时记录起点并挂全 app 单时钟（秒级 setState）。
  void _syncClock() {
    final s = widget.ui;
    if (_start == null && s.hasThinking && s.running) {
      _start = DateTime.now();
      if (!_clockOn) {
        _clockOn = true;
        TurnClock.instance.acquire();
        TurnClock.instance.tick.addListener(_onTick);
      }
    }
  }

  void _onTick() {
    if (mounted) setState(() {});
  }

  Duration? get _elapsed =>
      _start == null ? null : DateTime.now().difference(_start!);

  @override
  Widget build(BuildContext context) {
    final s = widget.ui;
    if (!s.hasThinking) return const SizedBox.shrink();
    _syncClock();
    final theme = Theme.of(context);
    // 流式输出中（running 且答案未开始）自动展开跟随滚动；答案开始/回合
    // 结束自动闭合。用户手动点按优先（_override 非 null 即覆盖）。
    final live = widget.live || s.running;
    final expanded = _override ?? (live && !widget.answerVisible);
    // 只显示尾部（长思考时头部早已滚出视野，截断省内存与布局开销）。
    final tail = s.thinking.length > 2000
        ? '…${s.thinking.substring(s.thinking.length - 2000)}'
        : s.thinking;
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 1),
      child: SweepHighlight(
        active: s.running && expanded,
        child: Container(
        decoration: BoxDecoration(
          color:
              theme.colorScheme.surfaceContainerHighest.withValues(alpha: 0.5),
          borderRadius: BorderRadius.circular(8),
        ),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          mainAxisSize: MainAxisSize.min,
          children: [
            InkWell(
              borderRadius: BorderRadius.circular(8),
              onTap: () => setState(() => _override = !expanded),
              child: Padding(
                padding:
                    const EdgeInsets.symmetric(horizontal: 10, vertical: 3),
                child: Row(
                  // max 宽度：Spacer 才生效，展开箭头对齐右缘（min 时箭头
                  // 跟在标题后面飘，与工具行/执行过程区的箭头不在一条线）。
                  children: [
                    Icon(Icons.psychology,
                        size: 14, color: theme.colorScheme.tertiary),
                    const SizedBox(width: 6),
                    Text(
                      _elapsed == null
                          ? (live ? '思考中…' : '思考')
                          : '思考 - 持续了${_fmtDur(_elapsed)}',
                      style: TextStyle(
                          fontSize: 12, color: theme.colorScheme.tertiary),
                    ),
                    // 折叠态摘要（DSH ReasoningRow 同构）：running =
                    // 最后一行（跟随刷新）；落档 = 首行（内容概知）。
                    // 用户收起时看到的不是空洞的「思考」两个字。
                    if (!expanded) ...[
                      const SizedBox(width: 6),
                      Expanded(
                        child: Text(
                          live
                              ? _latestLine(s.thinking)
                              : _firstLine(s.thinking),
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: TextStyle(
                              fontSize: 11,
                              color: theme.colorScheme.onSurfaceVariant,
                              fontStyle: FontStyle.italic),
                        ),
                      ),
                    ] else
                      // 折叠态摘要的 Expanded 已把箭头顶到右缘；展开态
                      // 没有摘要，用 Spacer 补位——两种态箭头都在右缘。
                      const Spacer(),
                    Icon(
                      expanded ? Icons.expand_less : Icons.expand_more,
                      size: 15,
                      color: theme.colorScheme.onSurfaceVariant,
                    ),
                  ],
                ),
              ),
            ),
            if (expanded)
              Padding(
                padding: const EdgeInsets.fromLTRB(10, 0, 10, 5),
                child: ConstrainedBox(
                  constraints: const BoxConstraints(maxHeight: 150),
                  child: SingleChildScrollView(
                    controller: _scroll,
                    child: Text(
                      tail,
                      style: TextStyle(
                        fontSize: 11,
                        fontFamily: 'monospace',
                        color: theme.colorScheme.onSurfaceVariant,
                      ),
                    ),
                  ),
                ),
              ),
          ],
        ),
        ),
      ),
    );
  }

  /// 思考最后一行（折叠摘要跟随刷新，DSH latestLine 口径）。
  static String _latestLine(String text) {
    final visible = text.trimRight();
    if (visible.isEmpty) return '…';
    final i = visible.lastIndexOf('\n');
    final line = i == -1 ? visible : visible.substring(i + 1);
    return line.trim().isEmpty ? '…' : line.trim();
  }

  /// DSH ReasoningRow firstLine：落档收起态摘要 = 思考首行（内容概知，
  /// 用户收起时不该只看到「思考」两个字）。
  static String _firstLine(String text) {
    final visible = text.trimRight();
    if (visible.isEmpty) return '…';
    final i = visible.indexOf('\n');
    final line = i == -1 ? visible : visible.substring(0, i);
    return line.trim().isEmpty ? '…' : line.trim();
  }
}

/// 智能体回合内嵌工作流块（对话内一步步向下渲染）：
///
/// 运行中回合（inline）：
/// [重试/压缩横幅] → [思考流/工具卡按执行次序交错] → [思考中…] → [最终回答]。
///
/// 已完成回合（折叠）：工具调用 + 思考存档全部收进**总折叠区**
/// [执行过程 · N 工具 · M 思考]（默认收起，点按展开回看），回答直接可见
/// ——过程痕迹保留但不再占屏（用户定案：完成即折叠、可点开）。
class AgentTurnBlock extends StatelessWidget {
  final List<ToolActivityUi> steps;
  final ChatMessage? answer;
  final AgentUiState ui;
  /// 是否当前运行中回合（决定横幅/思考行/流式点是否显示）。
  final bool isLive;

  /// 历史回合的思考存档文本（解析自存储 💭 消息；仅已完成回合折叠区使用）。
  final List<String> thinking;

  const AgentTurnBlock({
    super.key,
    required this.steps,
    required this.answer,
    required this.ui,
    required this.isLive,
    this.thinking = const [],
    this.trace,
    this.traceTools = const {},
  });

  /// 历史回合 turnTrace 信封（null = 旧数据，走散消息重排回退）。
  final List<TurnUiItem>? trace;
  final Map<String, ToolActivityUi> traceTools;

  /// 答案占位中：live 智能体回合、答案还没有任何文本。
  bool get _answerPending =>
      isLive && ui.running && (answer == null || answer!.content.trim().isEmpty);

  /// WP-C：本轮产物汇总（export_file 成功项，按 primary 去重）。
  /// live 取事件流工具卡，历史取落库 🔧 消息解析结果（steps 已统一类型）。
  List<ArtifactEntry> get _artifacts {
    final out = <ArtifactEntry>[];
    final seen = <String>{};
    for (final a in [...steps, if (isLive) ...ui.tools]) {
      final t = exportTargetOf(
        toolName: a.name,
        result: a.result,
        arguments: a.arguments,
      );
      if (t == null || !seen.add(t.primary)) continue;
      // 文件名优先取「（name，size」格式；否则 URI 尾段。
      final m = RegExp(r'（([^（]+)，').firstMatch(a.result ?? '');
      final label = m != null
          ? m.group(1)!
          : Uri.tryParse(t.primary)?.pathSegments.lastWhere(
              (s) => s.isNotEmpty,
              orElse: () => 'export_file 产物',
            ) ??
              'export_file 产物';
      out.add(ArtifactEntry(
          label: label, primary: t.primary, fallback: t.fallback));
    }
    return out;
  }

  /// 「执行中…」占位行只在「智能体确实在推进、答案未开始、且没有工具正在
  /// 执行」时显示（用户定案：这不是"思考"，是任务执行状态过渡，标签写
  /// 执行中）。工具执行中不显示——工具卡片自带「执行中 - 持续了Xs」；
  /// 重试中已有 RetryIndicator，同理。
  /// **有真思考流（思考卡）时不显示**——思考卡自带「思考 - 持续了Xs」转圈，
  /// 占位行不是真思考、纯属重复（用户定案：界面上同时最多一个 spinner）。
  bool get _thinking =>
      _answerPending &&
      !ui.hasThinking &&
      ui.toolGen == null &&
      ui.retryAttempt == 0 &&
      !steps.any((s) => s.status == ToolUiStatus.executing);

  /// live 回合按**执行顺序**交错渲染思考存档与工具卡。
  ///
  /// 时间线标记由归约器按事件到达次序生成（思考落档 / 工具卡加入时追加），
  /// 渲染时依序取对应数据——工具调用与思考不再"一律思考在前、工具在后"。
  List<Widget> _timelineWidgets() {
    final widgets = <Widget>[];
    for (final m in ui.timeline) {
      switch (m) {
        case UiTimelineThinking(:final index):
          if (index < ui.thinkingHistory.length)
            widgets.add(_ThinkingBlockCard(
              text: ui.thinkingHistory[index],
              index: index + 1,
              duration: index < ui.thinkingDurations.length
                  ? ui.thinkingDurations[index]
                  : null,
            ));
        case UiTimelineTool(:final index):
          if (index < ui.tools.length)
            widgets.add(ToolActivityCard(activity: ui.tools[index]));
      }
    }
    return widgets;
  }

  @override
  Widget build(BuildContext context) {
    final running = isLive && ui.running;
    // live 回合：思考存档与工具卡按**执行顺序**交错渲染（timeline 由归约器
    // 按事件到达次序生成）——不再"思考一律在前、工具一律在后"。流式思考卡
    // = 当前正在进行的思考，位于时间线末尾。
    // 历史/普通聊天回合（timeline 恒空）：按存储 🔧 消息顺序渲染工具卡。
    final stepWidgets = (isLive && ui.timeline.isNotEmpty)
        ? _timelineWidgets()
        : steps.map((s) => ToolActivityCard(activity: s)).toList();

    // ---- 已完成回合：过程痕迹（工具卡 + 思考存档）收进总折叠区 ----
    if (!running) {
      // turnTrace 信封优先：按落库时的真实交错顺序渲染（与 live 同管线）。
      List<Widget>? traceChildren;
      if (trace != null) {
        traceChildren = <Widget>[];
        var thinkN = 0;
        for (final item in trace!) {
          switch (item.type) {
            case 'tool':
              final t = traceTools[item.toolId];
              if (t != null) traceChildren.add(ToolActivityCard(activity: t));
            case 'think':
              traceChildren.add(_ThinkingBlockCard(
                  text: item.text ?? '', index: ++thinkN));
          }
        }
        if (traceChildren.isEmpty) traceChildren = null;
      }
      final historyThinkingWidgets = <Widget>[
        for (var i = 0; i < thinking.length; i++)
          _ThinkingBlockCard(text: thinking[i], index: i + 1),
      ];
      final processChildren = traceChildren ??
          [...stepWidgets, ...historyThinkingWidgets];
      return Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          if (processChildren.isNotEmpty)
            _TurnProcessSection(
              toolCount: steps.length,
              thinkingCount: thinking.length,
              children: processChildren,
            ),
          if (answer != null)
            ChatBubble(
              role: 'assistant',
              content: answer!.content,
              timestamp: answer!.timestamp,
              imagePath: answer!.imagePath,
              audioPath: answer!.audioPath,
              inferenceStats: answer!.inferenceStats,
              // 页脚集中到回合尾动作区（一条信息一个家）。
              showFooter: false,
            ),
          // 回合尾动作区：时间/耗时·tok/s/复制/分享/TTS 每回合一次。
          // 独立进列表流（无 ChatBubble 外层），自补 16px 消息列轴。
          if (answer != null)
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: 16),
              child: MessageActionsRow(
                content: answer!.content,
                timestamp: answer!.timestamp,
                stats: answer!.inferenceStats,
                isUser: false,
                canSpeak:
                    answer!.kind == MessageKind.text && !_answerPending,
                conversationId: answer!.conversationId,
              ),
            ),
          // WP-C：本轮产物汇总（export_file 成功项去重）——快捷打开链接。
          if (answer != null && _artifacts.isNotEmpty)
            _ArtifactSummaryCard(artifacts: _artifacts),
        ],
      );
    }

    // ---- 运行中回合：过程全部内联展开（结束即自动折叠为总折叠区） ----
    return Column(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        // 横幅/思考行必须属于「正在跑的这一个回合」：retry/compacted 残留
        // 状态要等下一次 attach 才清，加 ui.running 防串台到普通聊天。
        if (running && ui.retryAttempt > 0) RetryIndicator(attempt: ui.retryAttempt),
        if (running && ui.compacted) const CompactionBanner(),
        ...stepWidgets,
        if (isLive && ui.hasThinking)
          ThinkingStreamCard(
            ui: ui,
            answerVisible: answer != null && !_answerPending,
          ),
        // WP5：工具调用参数生成期反馈（大 HTML/长文本写文件时思考与可见
        // 流都为空，此前只能干转圈）——显示已生成字数 + 开头预览。
        if (running && ui.toolGen != null)
          _ToolGenIndicator(
            chars: ui.toolGen!.chars,
            preview: ui.toolGen!.preview,
          ),
        if (_thinking) const ThinkingIndicator(),
        // 回合错误行（2026-10-25 阶段 3）：AgentUiState.lastError 此前只写
        // 不渲染——红点行给出"该回合失败了"的显式落点（DSH TurnErrorItem）。
        if (isLive && !running && (ui.lastError?.isNotEmpty ?? false))
          _TurnErrorRow(message: ui.lastError!),
        // 智能体回合里答案还是空占位 → 不渲染回答气泡：ChatBubble 自带的
        // 「思考中…」占位会和上面的思考行/工具卡转圈叠成第二个 spinner。
        if (answer != null && !_answerPending)
          ChatBubble(
            role: 'assistant',
            content: answer!.content,
            timestamp: answer!.timestamp,
            isStreaming: isLive && answer!.isStreaming,
            imagePath: answer!.imagePath,
            audioPath: answer!.audioPath,
            inferenceStats: answer!.inferenceStats,
            // 页脚集中到回合尾动作区（一条信息一个家）。
            showFooter: false,
          ),
        // 回合尾动作区：答案流式结束才出现（DSH 规则：IconActions 仅在
        // turn 结束后出现）。独立进列表流，自补 16px 消息列轴。
        if (answer != null &&
            !_answerPending &&
            !(isLive && answer!.isStreaming))
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 16),
            child: MessageActionsRow(
              content: answer!.content,
              timestamp: answer!.timestamp,
              stats: answer!.inferenceStats,
              isUser: false,
              canSpeak: answer!.kind == MessageKind.text,
              conversationId: answer!.conversationId,
            ),
          ),
        // WP-C：本轮产物汇总（export_file 成功项去重）——快捷打开链接。
        if (answer != null && !_answerPending && _artifacts.isNotEmpty)
          _ArtifactSummaryCard(artifacts: _artifacts),
      ],
    );
  }
}

/// _TurnErrorRow —— 回合错误行（红点 + 文案，DSH TurnErrorItem 形态）。
class _TurnErrorRow extends StatelessWidget {
  final String message;
  const _TurnErrorRow({required this.message});

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 2, 16, 2),
      child: Row(
        children: [
          Icon(Icons.error, size: 13, color: theme.colorScheme.error),
          const SizedBox(width: 6),
          Expanded(
            child: Text(message,
                maxLines: 2,
                overflow: TextOverflow.ellipsis,
                style: TextStyle(fontSize: 12, color: theme.colorScheme.error)),
          ),
        ],
      ),
    );
  }
}

/// _TurnProcessSection —— 已完成回合的过程痕迹总折叠区（用户定案）。///
/// 回合完成后，工具调用卡与思考存档卡**自动折叠**进这个总区域：
/// 默认只显示一行摘要头（步骤数），点按展开再呈现各工具/思考块——
/// 过程可回看、但不再占屏。
class _TurnProcessSection extends StatefulWidget {
  final int toolCount;
  final int thinkingCount;
  final List<Widget> children;

  const _TurnProcessSection({
    required this.toolCount,
    required this.thinkingCount,
    required this.children,
  });

  @override
  State<_TurnProcessSection> createState() => _TurnProcessSectionState();
}

class _TurnProcessSectionState extends State<_TurnProcessSection> {
  bool _expanded = false;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final labelParts = <String>[
      if (widget.toolCount > 0) '${widget.toolCount} 工具',
      if (widget.thinkingCount > 0) '${widget.thinkingCount} 思考',
    ];
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 2),
      child: Container(
        decoration: BoxDecoration(
          color: theme.colorScheme.surfaceContainerHighest.withValues(alpha: 0.3),
          borderRadius: BorderRadius.circular(8),
          border: Border.all(
            color: theme.colorScheme.outlineVariant.withValues(alpha: 0.4),
          ),
        ),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          mainAxisSize: MainAxisSize.min,
          children: [
            InkWell(
              borderRadius: BorderRadius.circular(8),
              onTap: () => setState(() => _expanded = !_expanded),
              child: Padding(
                padding:
                    const EdgeInsets.symmetric(horizontal: 10, vertical: 5),
                child: Row(
                  children: [
                    Icon(Icons.account_tree_outlined,
                        size: 14,
                        color: theme.colorScheme.primary.withValues(alpha: 0.8)),
                    const SizedBox(width: 6),
                    Text(
                      '执行过程'
                      '${labelParts.isEmpty ? '' : ' · ${labelParts.join(' · ')}'}',
                      style: TextStyle(
                        fontSize: 12,
                        color: theme.colorScheme.onSurfaceVariant,
                      ),
                    ),
                    const Spacer(),
                    Text(
                      _expanded ? '收起' : '展开',
                      style: TextStyle(
                        fontSize: 11,
                        color: theme.colorScheme.primary,
                      ),
                    ),
                    Icon(
                      _expanded ? Icons.expand_less : Icons.expand_more,
                      size: 15,
                      color: theme.colorScheme.onSurfaceVariant,
                    ),
                  ],
                ),
              ),
            ),
            if (_expanded)
              Padding(
                padding: const EdgeInsets.only(bottom: 4),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  mainAxisSize: MainAxisSize.min,
                  children: widget.children,
                ),
              ),
          ],
        ),
      ),
    );
  }
}

/// 产物汇总条目。
class ArtifactEntry {
  final String label;
  final String primary;
  final String? fallback;
  const ArtifactEntry(
      {required this.label, required this.primary, this.fallback});
}

/// WP-C：回合最终产物汇总卡——本回合 export_file 交付的文件一屏列出，
/// 点「打开」直接调系统查看器（openFile 分层回退，见 DeviceFilesService）。
class _ArtifactSummaryCard extends StatelessWidget {
  final List<ArtifactEntry> artifacts;
  const _ArtifactSummaryCard({required this.artifacts});

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 4),
      child: Material(
        color: theme.colorScheme.primaryContainer.withValues(alpha: 0.35),
        borderRadius: BorderRadius.circular(10),
        child: Padding(
          padding: const EdgeInsets.all(10),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Row(
                children: [
                  const Icon(Icons.inventory_2, size: 14),
                  const SizedBox(width: 6),
                  Text('本轮产物（${artifacts.length}）',
                      style: const TextStyle(
                          fontSize: 12, fontWeight: FontWeight.w700)),
                ],
              ),
              const SizedBox(height: 6),
              for (final a in artifacts)
                Padding(
                  padding: const EdgeInsets.symmetric(vertical: 2),
                  child: Row(
                    children: [
                      Icon(_iconFor(a.label).icon,
                          size: 14, color: theme.colorScheme.primary),
                      const SizedBox(width: 6),
                      Expanded(
                        child: Text(a.label,
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                            style: const TextStyle(fontSize: 12)),
                      ),
                      const SizedBox(width: 8),
                      InkWell(
                        borderRadius: BorderRadius.circular(6),
                        onTap: () async {
                          try {
                            await DeviceFilesService.instance
                                .openFile(a.primary, fallbackPath: a.fallback);
                          } catch (e) {
                            if (context.mounted) {
                              ScaffoldMessenger.of(context).showSnackBar(
                                SnackBar(content: Text('打开失败：$e')),
                              );
                            }
                          }
                        },
                        child: Padding(
                          padding: const EdgeInsets.symmetric(
                              horizontal: 8, vertical: 3),
                          child: Row(
                            mainAxisSize: MainAxisSize.min,
                            children: [
                              Icon(Icons.open_in_new,
                                  size: 12, color: theme.colorScheme.primary),
                              const SizedBox(width: 3),
                              Text('打开',
                                  style: TextStyle(
                                      fontSize: 12,
                                      fontWeight: FontWeight.w600,
                                      color: theme.colorScheme.primary)),
                            ],
                          ),
                        ),
                      ),
                      const SizedBox(width: 4),
                      InkWell(
                        borderRadius: BorderRadius.circular(6),
                        onTap: () => _saveAsArtifact(context, a),
                        child: Padding(
                          padding: const EdgeInsets.symmetric(
                              horizontal: 8, vertical: 3),
                          child: Row(
                            mainAxisSize: MainAxisSize.min,
                            children: [
                              Icon(Icons.save_alt,
                                  size: 12, color: theme.colorScheme.primary),
                              const SizedBox(width: 3),
                              Text('另存',
                                  style: TextStyle(
                                      fontSize: 12,
                                      fontWeight: FontWeight.w600,
                                      color: theme.colorScheme.primary)),
                            ],
                          ),
                        ),
                      ),
                    ],
                  ),
                ),
            ],
          ),
        ),
      ),
    );
  }

  static Future<void> _saveAsArtifact(
      BuildContext context, ArtifactEntry a) async {
    final name = a.label.contains('.') ? a.label : 'artifact';
    try {
      final uri = await DeviceFilesService.instance.saveAs(
        srcUri: a.primary.startsWith('content:') ? a.primary : null,
        srcPath: a.fallback,
        name: name,
      );
      if (context.mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text('已另存：$uri'),
            duration: const Duration(seconds: 2),
          ),
        );
      }
    } on PlatformException catch (e) {
      if (e.code == 'CANCELLED') return;
      if (context.mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('另存失败：${e.message ?? e.code}')),
        );
      }
    }
  }

  Icon _iconFor(String label) {
    final ext = label.contains('.')
        ? label.substring(label.lastIndexOf('.')).toLowerCase()
        : '';
    switch (ext) {
      case '.html':
      case '.htm':
        return const Icon(Icons.language, size: 14);
      case '.png':
      case '.jpg':
      case '.jpeg':
      case '.svg':
        return const Icon(Icons.image, size: 14);
      case '.pdf':
        return const Icon(Icons.picture_as_pdf, size: 14);
      case '.csv':
      case '.xlsx':
        return const Icon(Icons.table_chart, size: 14);
      default:
        return const Icon(Icons.description, size: 14);
    }
  }
}

/// 时长渲染："持续了X秒"（<60s）/"X分Y秒"。null → 空串（历史回合无起点）。
String _fmtDur(Duration? d) {
  if (d == null) return '';
  if (d.inSeconds < 60) return '${d.inSeconds}秒';
  return '${d.inMinutes}分${d.inSeconds % 60}秒';
}
