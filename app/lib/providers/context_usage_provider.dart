import 'package:flutter_riverpod/flutter_riverpod.dart';

/// 单个会话的上下文占用快照。
///
/// - [usedTokens]：当前发送给模型的上下文 token 数（API `usage.prompt_tokens`）；
/// - [windowTokens]：上下文槽位大小（优先 API `/v1/models` 的 `n_ctx`，
///   回退 API 配置 [ApiModelConfig.contextWindow]）；
/// - [windowSource]：槽位来源，用于 UI 区分「实测 / 配置估算」。
class ContextUsage {
  final int? usedTokens;
  final int? windowTokens;
  final String windowSource;

  /// 数据域（2026-10-25）：true = 本地引擎 KV（kv_used/kv_ctx，单实例，
  /// 切会话即失效）；false = API usage（按会话有效，不随本地轮次失效）。
  /// 清理策略按域走：本地轮次只清本地域快照，API 会话数据不被抹掉。
  final bool isLocal;

  const ContextUsage({
    this.usedTokens,
    this.windowTokens,
    this.windowSource = '',
    this.isLocal = false,
  });

  /// 占用比例（0..1）。任一项缺失 → null（无数据不显示）。
  double? get fraction {
    final used = usedTokens;
    final win = windowTokens;
    if (used == null || win == null || win <= 0) return null;
    return (used / win).clamp(0.0, 1.0);
  }

  bool get hasData => fraction != null;
}

/// 按会话 id 跟踪 API 接入模型的上下文占用，供输入框上下文占用圈展示。
///
/// 仅记录 API 接入模型的占用；本地模型不更新（UI 侧也不显示）。
class ContextUsageNotifier extends StateNotifier<Map<String, ContextUsage>> {
  ContextUsageNotifier() : super(const {});

  /// 更新某会话的上下文占用。
  ///
  /// [windowTokens] 为 null 且 [windowSource] 非空时表示「无槽位数据」，
  /// 此时仍记录 used，但 fraction 因窗口缺失为 null（UI 不显示）。
  void update(
    String conversationId, {
    int? usedTokens,
    int? windowTokens,
    String windowSource = '',
    bool isLocal = false,
  }) {
    final next = Map<String, ContextUsage>.from(state);
    next[conversationId] = ContextUsage(
      usedTokens: usedTokens,
      windowTokens: windowTokens,
      windowSource: windowSource,
      isLocal: isLocal,
    );
    state = next;
  }

  /// 只清本地域快照（本地 KV 单实例，resetContext 后全部失效）；
  /// API 会话的 usage 快照不受影响（2026-10-25：此前 clear() 把 API
  /// 会话的占用一并抹掉——用户实测 API 的 KV 管理丢失的根因）。
  void clearLocal() {
    final next = <String, ContextUsage>{
      for (final e in state.entries)
        if (!e.value.isLocal) e.key: e.value,
    };
    if (next.length != state.length) state = next;
  }

  /// 保留 keep 会话，其余**本地域**快照清除（本地轮次结束时调用）。
  void clearLocalExcept(String? keepConversationId) {
    final next = <String, ContextUsage>{
      for (final e in state.entries)
        if (e.key == keepConversationId || !e.value.isLocal) e.key: e.value,
    };
    if (next.length != state.length) state = next;
  }

  /// 清空全部快照（本地 resetContext 后：KV 归零，旧快照全部失效）。
  void clear() {
    if (state.isNotEmpty) state = const {};
  }

  /// 清除除 [keepConversationId] 外的全部占用快照。
  ///
  /// 本地引擎 KV 是**单实例**：切会话/切模式 resetContext 后，其它会话的
  /// 快照已成陈旧值（KV 里装的是当前会话的 token），细条继续显示会误导。
  void clearExcept(String? keepConversationId) {
    if (keepConversationId == null) {
      if (state.isNotEmpty) state = const {};
      return;
    }
    final next = <String, ContextUsage>{
      for (final e in state.entries)
        if (e.key == keepConversationId) e.key: e.value,
    };
    if (next.length != state.length) state = next;
  }

  /// 读取某会话的占用快照（无记录返回 null）。
  ContextUsage? usageFor(String? conversationId) =>
      conversationId == null ? null : state[conversationId];

  /// 某会话是否已有可显示的占用数据。
  bool hasUsage(String? conversationId) =>
      usageFor(conversationId)?.hasData ?? false;
}

final contextUsageProvider =
    StateNotifierProvider<ContextUsageNotifier, Map<String, ContextUsage>>(
        (ref) => ContextUsageNotifier());
