import 'dart:convert';

import 'package:flutter/material.dart';

import '../agent/session/event.dart';
import '../agent/session/log.dart';
import '../agent/session/store.dart';

/// 轨迹视图 v1（v0.0.4.1 DSH ui-trajectory 对齐，缩放版）：
/// 会话第二个视图——事件台账（每行 = 一条 JSONL 事件）+ 选中行
/// 本地 inspector（原始 JSON + 距上一条的间隔）。
///
/// 数据 = 当前会话 SessionLog 事件流（JSONL 真相源直读，Phase 2 通电
/// 的成果的第一个消费者）。时间轴 Overview（TTFT/解码分段、拖拽区间）
/// 是 v2 的事，先让「发生了什么、花了多久、进了什么」可解释。
class TrajectoryView extends StatefulWidget {
  final String conversationId;

  /// 测试注入：直接给事件日志，跳过真实文件 IO（widget 测试的 FakeAsync
  /// 区里真实 IO/定时器不推进，会把测试吊死到超时）。生产路径恒 null。
  final SessionLog? initialLog;

  const TrajectoryView(
      {super.key, required this.conversationId, this.initialLog});

  @override
  State<TrajectoryView> createState() => _TrajectoryViewState();
}

class _TrajectoryViewState extends State<TrajectoryView> {
  Future<SessionLog>? _future;
  String _query = '';
  int? _selectedSeq;

  @override
  void didUpdateWidget(covariant TrajectoryView old) {
    super.didUpdateWidget(old);
    if (old.conversationId != widget.conversationId) {
      _future = null;
      _selectedSeq = null;
      _query = '';
    }
  }

  void _reload() => setState(() => _future = null);

  String _fmtTime(int ms) {
    final d = DateTime.fromMillisecondsSinceEpoch(ms);
    String two(int v) => v.toString().padLeft(2, '0');
    return '${two(d.hour)}:${two(d.minute)}:${two(d.second)}';
  }

  String _fmtGap(int? deltaMs) {
    if (deltaMs == null) return '';
    if (deltaMs < 1000) return '${deltaMs}ms';
    return '${(deltaMs / 1000).toStringAsFixed(1)}s';
  }

  String _summaryOf(SessionEvent e) {
    final d = e.data;
    final content = d['content'];
    if (content is String && content.trim().isNotEmpty) {
      final oneLine = content.replaceAll(RegExp(r'\s+'), ' ').trim();
      return oneLine.length <= 80
          ? oneLine
          : '${oneLine.substring(0, 80)}…';
    }
    for (final key in ['title', 'name', 'tool', 'cause', 'note']) {
      final v = d[key];
      if (v is String && v.isNotEmpty) return v;
    }
    if (d.isEmpty) return '';
    return d.keys.take(4).join(', ');
  }

  IconData _iconFor(String type) => switch (type) {
        kEventUserMessage => Icons.person,
        kEventAssistantMessage => Icons.auto_awesome,
        kEventToolCall => Icons.build,
        kEventToolResult => Icons.fact_check_outlined,
        kEventTurnStart => Icons.flag,
        kEventTurnEnd => Icons.flag_outlined,
        kEventStepStart => Icons.flag,
        kEventStepEnd => Icons.flag_outlined,
        kEventCompactionSummary => Icons.compress,
        kEventLlmRetry || kEventLlmRetryStarted => Icons.refresh,
        kEventAssistantAttempt => Icons.gavel,
        kEventAssistantFailureNote => Icons.sticky_note_2_outlined,
        kEventSessionTitle => Icons.title,
        kEventImported => Icons.import_export,
        kEventSpillLocate => Icons.data_object,
        _ => Icons.article_outlined,
      };

  Color _colorFor(String type) {
    if (isStructural(type)) return Colors.blueGrey;
    if (isLogOnly(type)) return Colors.grey;
    return switch (type) {
      kEventUserMessage => const Color(0xFF6D4FE0),
      kEventAssistantMessage => const Color(0xFF1976D2),
      kEventToolCall || kEventToolResult => const Color(0xFFEF6C00),
      kEventCompactionSummary => const Color(0xFF00897B),
      _ => Colors.black87,
    };
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    return FutureBuilder<SessionLog>(
      future: _future ??= widget.initialLog != null
          ? Future<SessionLog>.value(widget.initialLog)
          : JsonlSessionStore.shared.load(widget.conversationId),
      builder: (context, snap) {
        if (snap.connectionState != ConnectionState.done) {
          return const Center(child: CircularProgressIndicator());
        }
        if (snap.hasError) {
          return Center(
              child: Text('读取事件日志失败：${snap.error}',
                  style: const TextStyle(color: Colors.red)));
        }
        final all = snap.data?.rawEvents ?? const <SessionEvent>[];
        final q = _query.trim().toLowerCase();
        final rows = q.isEmpty
            ? all
            : all
                .where((e) =>
                    e.type.toLowerCase().contains(q) ||
                    _summaryOf(e).toLowerCase().contains(q))
                .toList();
        final toolCalls = all.where((e) => e.type == kEventToolCall).length;
        final llmCalls =
            all.where((e) => e.type == kEventAssistantMessage).length;
        final totalMs = all.length >= 2
            ? all.last.timeMs - all.first.timeMs
            : 0;

        return Column(
          children: [
            // 顶栏：统计 + 搜索 + 刷新。
            Padding(
              padding: const EdgeInsets.fromLTRB(12, 6, 12, 4),
              child: Row(children: [
                Text('${all.length} 事件',
                    style: theme.textTheme.bodySmall
                        ?.copyWith(color: scheme.onSurfaceVariant)),
                const SizedBox(width: 10),
                Text('LLM $llmCalls',
                    style: theme.textTheme.bodySmall
                        ?.copyWith(color: scheme.onSurfaceVariant)),
                const SizedBox(width: 10),
                Text('工具 $toolCalls',
                    style: theme.textTheme.bodySmall
                        ?.copyWith(color: scheme.onSurfaceVariant)),
                const SizedBox(width: 10),
                Text(totalMs > 0 ? '跨度 ${_fmtGap(totalMs)}' : '',
                    style: theme.textTheme.bodySmall
                        ?.copyWith(color: scheme.onSurfaceVariant)),
                const Spacer(),
                SizedBox(
                  width: 180,
                  child: TextField(
                    style: const TextStyle(fontSize: 12),
                    decoration: const InputDecoration(
                      hintText: '过滤类型/内容…',
                      isDense: true,
                      prefixIcon: Icon(Icons.search, size: 15),
                      contentPadding: EdgeInsets.symmetric(vertical: 6),
                    ),
                    onChanged: (v) => setState(() => _query = v),
                  ),
                ),
                IconButton(
                    visualDensity: VisualDensity.compact,
                    tooltip: '重新读取',
                    icon: const Icon(Icons.refresh, size: 18),
                    onPressed: _reload),
              ]),
            ),
            Divider(height: 1, color: scheme.outlineVariant),
            // 台账。
            Expanded(
              child: rows.isEmpty
                  ? Center(
                      child: Text(
                          all.isEmpty ? '该会话还没有事件记录' : '无匹配事件',
                          style: TextStyle(color: Colors.grey.shade600)))
                  : ListView.builder(
                      itemCount: rows.length,
                      itemBuilder: (context, i) {
                        final e = rows[i];
                        // 过滤态下相邻行可能跨事件，间隔会误导 → 只在
                        // 无过滤时展示「距上一条」。
                        final gap = (q.isEmpty && i > 0)
                            ? e.timeMs - rows[i - 1].timeMs
                            : null;
                        final selected = _selectedSeq == e.seq;
                        return InkWell(
                          onTap: () => setState(
                              () => _selectedSeq = selected ? null : e.seq),
                          child: Container(
                            color: selected
                                ? scheme.primaryContainer.withValues(alpha: .35)
                                : null,
                            padding: const EdgeInsets.symmetric(
                                horizontal: 12, vertical: 5),
                            child: Row(children: [
                              SizedBox(
                                  width: 62,
                                  child: Text(_fmtTime(e.timeMs),
                                      style: theme.textTheme.bodySmall
                                          ?.copyWith(
                                              fontFeatures: const [
                                                FontFeature.tabularFigures()
                                              ],
                                              color: Colors.grey.shade600))),
                              SizedBox(
                                  width: 46,
                                  child: Text(
                                      gap == null ? '' : _fmtGap(gap),
                                      textAlign: TextAlign.end,
                                      style: theme.textTheme.bodySmall
                                          ?.copyWith(
                                              color: Colors.grey.shade500))),
                              const SizedBox(width: 8),
                              Icon(_iconFor(e.type),
                                  size: 15, color: _colorFor(e.type)),
                              const SizedBox(width: 6),
                              SizedBox(
                                width: 132,
                                child: Text(e.type,
                                    maxLines: 1,
                                    overflow: TextOverflow.ellipsis,
                                    style: theme.textTheme.bodySmall
                                        ?.copyWith(
                                            color: _colorFor(e.type),
                                            fontWeight: FontWeight.w600)),
                              ),
                              const SizedBox(width: 8),
                              Expanded(
                                child: Text(_summaryOf(e),
                                    maxLines: 1,
                                    overflow: TextOverflow.ellipsis,
                                    style: theme.textTheme.bodyMedium),
                              ),
                              const SizedBox(width: 6),
                              Text('#${e.seq}',
                                  style: theme.textTheme.bodySmall
                                      ?.copyWith(color: Colors.grey.shade500)),
                            ]),
                          ),
                        );
                      },
                    ),
            ),
            // 本地 inspector：选中事件的原始 JSON（DSH TrajectoryTable
            // 选中行开本地 inspector 的同位件）。
            if (_selectedSeq != null &&
                all.any((e) => e.seq == _selectedSeq)) ...[
              Divider(height: 1, color: scheme.outlineVariant),
              SizedBox(
                height: 210,
                child: _Inspector(
                    event: all.firstWhere((e) => e.seq == _selectedSeq)),
              ),
            ],
          ],
        );
      },
    );
  }
}

class _Inspector extends StatelessWidget {
  final SessionEvent event;
  const _Inspector({required this.event});

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final body = const JsonEncoder.withIndent('  ').convert({
      'type': event.type,
      'seq': event.seq,
      'time': event.timeMs,
      if (event.source != null) 'source': event.source,
      if (event.surfaceOp != null) 'surfaceOp': event.surfaceOp,
      if (event.shadowsEndSeq != null) 'shadowsEndSeq': event.shadowsEndSeq,
      'data': event.data,
    });
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Padding(
          padding: const EdgeInsets.fromLTRB(12, 6, 12, 2),
          child: Text('事件 #${event.seq} · ${event.type} · '
              '${event.isIgnorable ? 'ignorable' : '语义帧'}',
              style: theme.textTheme.bodySmall
                  ?.copyWith(color: theme.colorScheme.onSurfaceVariant)),
        ),
        Expanded(
          child: SingleChildScrollView(
            padding: const EdgeInsets.fromLTRB(12, 2, 12, 10),
            child: SelectableText(
              body,
              style: const TextStyle(
                  fontFamily: 'Consolas', fontFamilyFallback: ['monospace'],
                  fontSize: 11.5,
                  height: 1.45),
            ),
          ),
        ),
      ],
    );
  }
}
