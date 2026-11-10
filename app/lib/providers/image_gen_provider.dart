/// 生图任务进行中状态（入口①的**临时占位**，convId → 任务）。
///
/// 评审定案（2026-11-09）：占位**不落库**——生成中杀 App 不留「正在生成」
/// 脏消息（ThinkingStreamCard 等既有占位全部是临时 state，同一纪律）。
/// 成功/失败才写最终 assistant 消息（messagesProvider 500ms 轮询自动上屏）。
library;

import 'package:flutter_riverpod/flutter_riverpod.dart';

class ImageGenJob {
  final String conversationId;
  final String prompt;

  /// 本任务的尺寸（来自设置默认档，占位卡展示用）。
  final String size;
  final DateTime startedAt;
  const ImageGenJob({
    required this.conversationId,
    required this.prompt,
    required this.size,
    required this.startedAt,
  });

  /// 已进行秒数（占位卡实时刷新）。
  int elapsedSecs(DateTime now) => now.difference(startedAt).inSeconds;
}

class ImageGenJobsNotifier extends StateNotifier<Map<String, ImageGenJob>> {
  ImageGenJobsNotifier() : super(const {});

  void start(ImageGenJob job) {
    state = {...state, job.conversationId: job};
  }

  void finish(String conversationId) {
    if (!state.containsKey(conversationId)) return;
    state = {...state}..remove(conversationId);
  }
}

final imageGenJobsProvider =
    StateNotifierProvider<ImageGenJobsNotifier, Map<String, ImageGenJob>>(
        (ref) => ImageGenJobsNotifier());
