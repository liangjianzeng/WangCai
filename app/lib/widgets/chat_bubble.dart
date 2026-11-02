import 'dart:io';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_markdown/flutter_markdown.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import '../models/chat_message.dart';
import '../providers/settings_provider.dart' show settingsProvider;
import '../services/share_service.dart';
import '../tts/edge_tts_service.dart' show EdgeTtsService;
import 'image_preview.dart';
import 'todo_card.dart';

/// 消息的 TTS 播放按钮是否正控当前这场播报（决定图标显示停止态、点按即停）。
///
/// 播报有两路 key：本按钮/手动试听用 `content.hashCode`，自动播报用会话级
/// `auto-$conversationId`——两者不同。任一命中 = 本按钮正控这场：图标改停止、
/// 点按调用 stop()；否则起播本条。漏判这层就是「自动播报时按钮不变停止态、
/// 点了反而重播」的根因（2026-10 修复）。纯函数，单测钉死。
bool isThisMessagePlaying(String? playing, String messageKey, String? conversationId) {
  if (playing == null) return false;
  if (playing == messageKey) return true;
  return conversationId != null && playing == 'auto-$conversationId';
}

class ChatBubble extends StatelessWidget {
  final String role; // 'user' or 'assistant' or 'system'
  final String content;
  final DateTime timestamp;
  final bool isStreaming;

  /// 页脚（时间/stats/复制/分享/TTS）是否随本气泡渲染。智能体回合把
  /// 页脚集中到回合尾动作区（一条信息一个家，DSH TurnTail 形态），
  /// 传 false 抑制；普通聊天/用户消息保持默认 true。
  final bool showFooter;
  final String? imagePath;
  final List<String>? imagePaths;
  final List<String>? attachments;
  final String? audioPath;
  final InferenceStats? inferenceStats;

  /// 本气泡所属会话 id（普通聊天/用户消息带，智能体回合气泡通常 null）。
  ///
  /// 用于识别「本会话自动播报」：自动播报用 key `auto-$conversationId`，
  /// 与按钮自用的 `content.hashCode` 不同；不带会话 id 时按钮无法判断当前
  /// 出声是不是在播自己，图标就不改停止态、点按也会重新播（二次播放 bug）。
  final String? conversationId;

  const ChatBubble({
    super.key,
    required this.role,
    required this.content,
    required this.timestamp,
    this.isStreaming = false,
    this.showFooter = true,
    this.imagePath,
    this.imagePaths,
    this.attachments,
    this.audioPath,
    this.inferenceStats,
    this.conversationId,
  });

  bool get _isUser => role == 'user';

  /// 工具活动消息（🔧 前缀，智能体模式工具轮）。
  bool get _isToolActivity => !_isUser && content.startsWith('🔧');

  /// 可播报：assistant 普通文本回答（排除工具活动/思考存档/待办卡/计划卡）。
  bool get _canSpeak =>
      !_isUser &&
      !isStreaming &&
      content.length > 1 &&
      !content.startsWith('🔧') &&
      !content.startsWith('💭') &&
      !content.startsWith('☑') &&
      !content.startsWith('📋') &&
      !content.startsWith('🔔');

  /// 思考中占位（内容为空 + 流式中 → 显示「思考中…」指示器）。
  bool get _isThinkingPlaceholder => !_isUser && isStreaming && content.isEmpty;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    // 用户气泡定值（设计稿）：不随 M3 明暗档漂移——浅色饱和紫+白字，
    // 暗色亮紫+深字（primary 在暗色档是浅淡紫，和设计稿差一截）。
    final bool dark = theme.brightness == Brightness.dark;
    final Color userBubbleColor =
        dark ? const Color(0xFF9B8CFF) : const Color(0xFF6D4FE0);
    final Color userBubbleFg = dark ? Colors.black87 : Colors.white;
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 6),
      child: Row(
        mainAxisAlignment:
            _isUser ? MainAxisAlignment.end : MainAxisAlignment.start,
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Flexible(
            child: Column(
              crossAxisAlignment:
                  _isUser ? CrossAxisAlignment.end : CrossAxisAlignment.start,
              children: [
                // DSH 参考形态（2026-10-25）：助手消息**无气泡**——markdown
                // 直接铺在画布上（去头像同时去掉灰底框，阅读面不缩水）；
                // 用户消息右对齐圆角 22 气泡（DSH bubble r22）。工具活动
                // 消息保留浅色卡（在 TurnUnit 里已是紧凑行，此处是兜底）。
                Container(
                  constraints: _isUser
                      ? const BoxConstraints(maxWidth: 600)
                      : null,
                  padding: EdgeInsets.symmetric(
                    // 助手无气泡：正文与下方时间/动作行同左缘（都落在
                    // 外层 16px 消息列轴上）——内衬是去气泡时的遗留，
                    // 留着就出现「时间贴边、正文缩进 16」的错位。
                    horizontal: _isToolActivity || _isUser ? 16 : 0,
                    vertical: _isToolActivity
                        ? 8
                        : _isUser
                            ? 10
                            : 0,
                  ),
                  margin: const EdgeInsets.symmetric(vertical: 2),
                  decoration: _isUser
                      ? BoxDecoration(
                          // 用户气泡定值：浅色饱和紫+白字，暗色亮紫+深字
                          //（primary 在暗色档是浅淡紫，和设计稿差一截）。
                          color: userBubbleColor,
                          borderRadius: BorderRadius.circular(22),
                        )
                      : _isToolActivity
                          ? BoxDecoration(
                              color: theme.colorScheme.tertiaryContainer
                                  .withValues(alpha: 0.5),
                              borderRadius: BorderRadius.circular(14),
                            )
                          : null,
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      // 语音消息标记（端侧语音理解）
                      if (audioPath != null && audioPath!.isNotEmpty) ...[
                        Row(
                          mainAxisSize: MainAxisSize.min,
                          children: [
                            Icon(Icons.mic,
                                size: 14,
                                color: _isUser
                                    ? userBubbleFg
                                    : theme.colorScheme.onSurfaceVariant),
                            const SizedBox(width: 4),
                            Text(
                              '语音',
                              style: TextStyle(
                                color: _isUser
                                    ? userBubbleFg
                                    : theme.colorScheme.onSurfaceVariant,
                                fontSize: 12,
                              ),
                            ),
                          ],
                        ),
                        const SizedBox(height: 6),
                      ],
                      // Show image if present (user messages only)；多图 ≤10 依次展示。
                      // 点任意缩略图 → 全屏预览（可缩放/翻页）。
                      if (imagePath != null && imagePath!.isNotEmpty) ...[
                        GestureDetector(
                          onTap: () => showImagePreview(
                            context,
                            imagePaths:
                                imagePaths != null && imagePaths!.isNotEmpty
                                    ? imagePaths!
                                    : [imagePath!],
                            initialIndex: 0,
                          ),
                          child: ClipRRect(
                            borderRadius: BorderRadius.circular(8),
                            child: ConstrainedBox(
                              constraints: const BoxConstraints(
                                  maxWidth: 300, maxHeight: 300),
                              child: Image.file(
                                File(imagePath!),
                                fit: BoxFit.cover,
                              ),
                            ),
                          ),
                        ),
                        const SizedBox(height: 8),
                      ],
                      if (imagePaths != null && imagePaths!.length > 1) ...[
                        SizedBox(
                          height: 110,
                          child: ListView(
                            scrollDirection: Axis.horizontal,
                            children: [
                              for (var i = 1; i < imagePaths!.length; i++)
                                Padding(
                                  padding: const EdgeInsets.only(right: 8),
                                  child: GestureDetector(
                                    onTap: () => showImagePreview(
                                      context,
                                      imagePaths: imagePaths!,
                                      initialIndex: i,
                                    ),
                                    child: ClipRRect(
                                      borderRadius: BorderRadius.circular(8),
                                      child: Image.file(
                                        File(imagePaths![i]),
                                        height: 100,
                                        width: 100,
                                        fit: BoxFit.cover,
                                      ),
                                    ),
                                  ),
                                ),
                            ],
                          ),
                        ),
                        const SizedBox(height: 8),
                      ],
                      // 智能体附件（WP-A）：文件名 chips 展示。
                      if (attachments != null && attachments!.isNotEmpty) ...[
                        Wrap(
                          spacing: 6,
                          runSpacing: 4,
                          children: [
                            for (final name in attachments!)
                              Chip(
                                visualDensity: VisualDensity.compact,
                                avatar: const Icon(Icons.description, size: 16),
                                label: Text(
                                  name,
                                  style: const TextStyle(fontSize: 12),
                                ),
                              ),
                          ],
                        ),
                        const SizedBox(height: 8),
                      ],
                      // 工具活动消息：紧凑文本 + 工具图标（不暴露原始 JSON）。
                      if (_isToolActivity) ...[
                        Row(
                          mainAxisSize: MainAxisSize.min,
                          crossAxisAlignment: CrossAxisAlignment.center,
                          children: [
                            Icon(
                              Icons.construction,
                              size: 13,
                              color: theme.colorScheme.onTertiaryContainer,
                            ),
                            const SizedBox(width: 6),
                            Flexible(
                              child: Text(
                                content,
                                style: TextStyle(
                                  color: theme.colorScheme.onTertiaryContainer,
                                  fontSize: 13,
                                  height: 1.4,
                                  fontWeight: FontWeight.w500,
                                ),
                              ),
                            ),
                          ],
                        ),
                      ] else ...[
                        // 思考中占位：空内容 + 流式 → 显示「思考中…」。
                        if (_isThinkingPlaceholder) ...[
                          Row(
                            mainAxisSize: MainAxisSize.min,
                            children: [
                              const SizedBox(
                                width: 12,
                                height: 12,
                                child: CircularProgressIndicator(
                                  strokeWidth: 2,
                                ),
                              ),
                              const SizedBox(width: 8),
                              Text(
                                '思考中…',
                                style: TextStyle(
                                  color: theme.colorScheme.onSurfaceVariant,
                                  fontSize: 13,
                                  fontStyle: FontStyle.italic,
                                ),
                              ),
                            ],
                          ),
                        ] else if (content.isNotEmpty) ...[
                          if (_isUser)
                            Text(
                              content,
                              style: TextStyle(
                                color: userBubbleFg,
                                fontSize: 15,
                                height: 1.5,
                              ),
                            )
                          else if (content.startsWith('☑ 任务清单'))
                            // 任务清单活卡（todo_write upsert）：结构化清单
                            // 视图（状态图标/完成删除线/进行中高亮），不走 MD。
                            TodoChecklistCard(content: content)
                          else if (isStreaming)
                            // finalize swap（DSH 同构，2026-10-25 阶段 4）：
                            // 流式期间平文本渲染（每帧重排一张 Text），落档
                            // 后一次性换完整 markdown（标题/代码块/表格）。
                            // 长回复滚动性能的关键：流式中 MarkdownBody 每帧
                            // 全量重排是卡顿大头。
                            Text(
                              content,
                              style: TextStyle(
                                color: theme.colorScheme.onSurface,
                                fontSize: 15,
                                height: 1.5,
                              ),
                            )
                          else
                            // 智能体回答 markdown 美化渲染（WP-B）：标题/列表/
                            // 代码块/表格/加粗等结构化排版。流式期间部分 MD
                            // 也能渐进渲染；纯文本行不受影响。
                            MarkdownBody(
                              data: content,
                              selectable: true,
                              softLineBreak: true,
                              styleSheet: MarkdownStyleSheet.fromTheme(
                                theme,
                              ).copyWith(
                                // 无气泡形态（DSH 参考）：正文铺在画布上，
                                // 用 onSurface 主文字色（原 onSurfaceVariant
                                // 是给灰底气泡配的次级色，直接铺开偏灰淡）。
                                p: TextStyle(
                                  color: theme.colorScheme.onSurface,
                                  fontSize: 15,
                                  height: 1.5,
                                ),
                                // 引用块（> …）：flutter_markdown 默认底色写死
                                // Colors.blue.shade100，深色模式下浅色文字+浅蓝底
                                // 几乎不可读——改为跟随主题的中性底 + onSurface 文字。
                                blockquote: TextStyle(
                                  color: theme.colorScheme.onSurface,
                                  fontSize: 15,
                                  height: 1.5,
                                ),
                                blockquoteDecoration: BoxDecoration(
                                  color: theme.colorScheme.onSurfaceVariant
                                      .withValues(alpha: 0.12),
                                  borderRadius: BorderRadius.circular(8),
                                  border: Border(
                                    left: BorderSide(
                                      width: 3,
                                      color: theme.colorScheme.primary,
                                    ),
                                  ),
                                ),
                                h1: theme.textTheme.titleLarge
                                    ?.copyWith(fontWeight: FontWeight.w700),
                                h2: theme.textTheme.titleMedium
                                    ?.copyWith(fontWeight: FontWeight.w700),
                                h3: theme.textTheme.titleSmall
                                    ?.copyWith(fontWeight: FontWeight.w700),
                                codeblockDecoration: BoxDecoration(
                                  color: theme
                                      .colorScheme.surfaceContainerHighest
                                      .withValues(alpha: 0.7),
                                  borderRadius: BorderRadius.circular(8),
                                ),
                                code: TextStyle(
                                  fontSize: 13,
                                  fontFamily: 'monospace',
                                  backgroundColor: theme
                                      .colorScheme.surfaceContainerHighest
                                      .withValues(alpha: 0.7),
                                ),
                                tableBorder: TableBorder.all(
                                  color: theme.dividerColor,
                                ),
                              ),
                            ),
                        ],
                        if (isStreaming && !_isThinkingPlaceholder) ...[
                          const SizedBox(height: 4),
                          SizedBox(
                            width: 16,
                            height: 16,
                            child: CircularProgressIndicator(
                              strokeWidth: 2,
                              color: _isUser
                                  ? userBubbleFg
                                  : theme.colorScheme.primary,
                            ),
                          ),
                        ],
                      ],
                    ],
                  ),
                ),
                if (showFooter)
                  MessageActionsRow(
                    content: content,
                    timestamp: timestamp,
                    stats: inferenceStats,
                    isUser: _isUser,
                    canSpeak: _canSpeak,
                    conversationId: conversationId,
                  ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}

/// 消息动作行（2026-10-25 阶段 3，DSH MessageIconActions 同位）：
/// `[时间] · [耗时 X · N tok/s] · [复制] [分享] [TTS]`。
/// 从 ChatBubble 页脚抽出——智能体回合把它放在**回合尾**渲染一次
/// （showFooter:false 抑制气泡内页脚），普通聊天/用户消息仍随气泡。
class MessageActionsRow extends StatelessWidget {
  final String content;
  final DateTime timestamp;
  final InferenceStats? stats;
  final bool isUser;

  /// TTS 播报按钮可见性（调用方按消息类型判定，工具/思考/卡片不给）。
  final bool canSpeak;

  /// 本消息所属会话 id（用于识别本会话自动播报，见 [MessageActionsRow] 的
  /// TTS 播放按钮）。普通聊天/用户消息带，智能体回合气泡通常 null。
  final String? conversationId;

  const MessageActionsRow({
    super.key,
    required this.content,
    required this.timestamp,
    this.stats,
    required this.isUser,
    this.canSpeak = false,
    this.conversationId,
  });

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Padding(
      // 水平缩进由调用方负责：ChatBubble 页脚走外层 16px 消息列；
      // agent_workflow 的独立调用点自带 Padding(16)。此处只管行距。
      padding: const EdgeInsets.only(top: 2),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Text(
            _formatTime(timestamp),
            style: TextStyle(fontSize: 11, color: Colors.grey.shade500),
          ),
          if (!isUser && stats != null) ...[
            const SizedBox(width: 8),
            Flexible(
              child: Text(
                _formatStats(stats!),
                overflow: TextOverflow.ellipsis,
                style: TextStyle(
                  fontSize: 11,
                  color: Colors.grey.shade500,
                  fontFeatures: const [FontFeature.tabularFigures()],
                ),
              ),
            ),
          ],
          if (content.isNotEmpty) ...[
            const SizedBox(width: 6),
            InkWell(
              borderRadius: BorderRadius.circular(12),
              onTap: () async {
                await Clipboard.setData(ClipboardData(text: content));
                if (context.mounted) {
                  ScaffoldMessenger.of(context).showSnackBar(
                    SnackBar(
                      content: Text(isUser ? '已复制消息内容' : '已复制回复内容'),
                      duration: const Duration(seconds: 1),
                    ),
                  );
                }
              },
              child: Padding(
                padding: const EdgeInsets.all(2),
                child: Icon(
                  Icons.content_copy,
                  size: 15,
                  color: Colors.grey.shade400,
                ),
              ),
            ),
          ],
          if (!isUser && content.isNotEmpty) ...[
            const SizedBox(width: 6),
            InkWell(
              borderRadius: BorderRadius.circular(12),
              onTap: () async {
                final ok = await ShareService.instance
                    .shareText(content, title: '分享回复');
                if (context.mounted && !ok) {
                  ScaffoldMessenger.of(context).showSnackBar(
                    const SnackBar(
                      content: Text('未找到可用的分享入口'),
                      duration: Duration(seconds: 1),
                    ),
                  );
                }
              },
              child: Padding(
                padding: const EdgeInsets.all(2),
                child: Icon(
                  Icons.share,
                  size: 15,
                  color: Colors.grey.shade400,
                ),
              ),
            ),
            if (canSpeak) ...[
              const SizedBox(width: 6),
              _buildSpeakButton(context, theme),
            ],
          ],
        ],
      ),
    );
  }

  /// TTS 播报按钮：Consumer 自取设置与播放状态；播报中变停止键。
  Widget _buildSpeakButton(BuildContext context, ThemeData theme) {
    try {
      ProviderScope.containerOf(context);
    } catch (_) {
      return const SizedBox.shrink();
    }
    return Consumer(
      builder: (context, ref, _) {
        final settings = ref.watch(settingsProvider);
        final tts = EdgeTtsService.instance;
        return ValueListenableBuilder<String?>(
          valueListenable: tts.playingKey,
          builder: (context, playing, _) {
            final isThis = isThisMessagePlaying(
              playing,
              content.hashCode.toString(),
              conversationId,
            );
            return InkWell(
              borderRadius: BorderRadius.circular(12),
              onTap: () async {
                // 正在播本条（手动或自动）= 点按停止；否则起播本条。
                if (isThis) {
                  await tts.stop();
                  return;
                }
                final ok = await tts.speak(
                  content,
                  key: content.hashCode.toString(),
                  voice: settings.edgeTtsVoice,
                  rate: settings.edgeTtsRate,
                  pitch: settings.edgeTtsPitch,
                  volume: settings.edgeTtsVolume,
                );
                if (ok || !context.mounted) return;
                final err = tts.lastError;
                if (err == null) return;
                ScaffoldMessenger.of(context)
                  ..hideCurrentSnackBar()
                  ..showSnackBar(SnackBar(
                    content: Text('🔊 没能播报：$err'),
                    duration: const Duration(seconds: 4),
                  ));
              },
              child: Padding(
                padding: const EdgeInsets.all(2),
                child: Icon(
                  isThis ? Icons.stop_circle : Icons.volume_up,
                  size: 15,
                  color:
                      isThis ? theme.colorScheme.primary : Colors.grey.shade400,
                ),
              ),
            );
          },
        );
      },
    );
  }

  String _formatTime(DateTime dt) {
    final now = DateTime.now();
    if (dt.year == now.year && dt.month == now.month && dt.day == now.day) {
      return '${dt.hour.toString().padLeft(2, '0')}:${dt.minute.toString().padLeft(2, '0')}';
    }
    return '${dt.month}/${dt.day} ${dt.hour.toString().padLeft(2, '0')}:${dt.minute.toString().padLeft(2, '0')}';
  }

  String _formatStats(InferenceStats s) {
    final first = s.firstTokenMs > 0
        ? (s.firstTokenMs >= 1000
            ? '首Tok ${(s.firstTokenMs / 1000).toStringAsFixed(1)}s · '
            : '首Tok ${s.firstTokenMs}ms · ')
        : '';
    final total = s.totalMs >= 1000
        ? '${(s.totalMs / 1000).toStringAsFixed(1)}s'
        : '${s.totalMs}ms';
    final rate = s.tokPerSec.toStringAsFixed(1);
    final vision = s.visionMs > 0
        ? (s.visionMs >= 1000
            ? ' · 视觉 ${(s.visionMs / 1000).toStringAsFixed(1)}s'
            : ' · 视觉 ${s.visionMs}ms')
        : '';
    final audio = s.audioMs > 0
        ? (s.audioMs >= 1000
            ? ' · 听音 ${(s.audioMs / 1000).toStringAsFixed(1)}s'
            : ' · 听音 ${s.audioMs}ms')
        : '';
    return '$first$vision$audio · 耗时 $total · $rate tok/s';
  }
}
