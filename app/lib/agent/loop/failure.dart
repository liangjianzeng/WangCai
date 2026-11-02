/// llm-retry 插件 + 失败瀑布决策（Phase 1）。
///
/// 对照 DSH Part 9.9：有界重试 + 指数退避。
/// 主循环失败瀑布：
///   模型失败 → 落 assistant/attempt → 跑瀑布：
///     1. compaction（CONTEXT_WINDOW_EXCEEDED）→ success 则 {kind:retry}
///     2. llm-retry（retryPolicy 允许该 code）→ 退避后 {kind:retry}
///     3. 默认 → 终态失败（turn/end {reason:error}）
library;

import 'dart:async';
import 'dart:math' as math;

import '../llm/adapter.dart';
import '../session/session.dart' show SessionLog;

/// 失败处理决策。
enum FailureDecisionKind {
  retry,     // 同一 step 重试（compaction 成功 / llm-retry 允许）
  giveUp,    // 终态失败（turn/end {reason:error}）
}

final class FailureDecision {
  final FailureDecisionKind kind;
  final String? detail;

  const FailureDecision(this.kind, {this.detail});
}

/// 失败处理插件（compaction seam，Phase 2 实现确定性裁剪/摘要）。
///
/// [decide] 返回 success 表示已推进 generation（可安全 retry）；
/// failure 表示无法推进（避免死循环）。
enum CompactionResultKind {
  success,
  failure,
}

final class CompactionResult {
  final CompactionResultKind kind;

  /// 压缩统计（success 时由插件填写；failure 为 null）。
  /// 查询/呈现压缩状态的数据源：推理日志、可观测面板据此回答
  /// "压没压、从多少压到多少、谁压的"。
  final CompactionStats? stats;
  const CompactionResult(this.kind, [this.stats]);
}

/// 一次压缩的量化结果。
final class CompactionStats {
  /// 被遮蔽的事件数（影子区宽度）。
  final int maskedEvents;

  /// 压缩前/后上下文估算 token（estimateContextTokens 口径）。
  final int beforeTokens;
  final int afterTokens;

  /// 摘要来源：deterministic-prune / llm。
  final String provider;

  /// 摘要文本长度（字符）。
  final int summaryChars;
  const CompactionStats({
    required this.maskedEvents,
    required this.beforeTokens,
    required this.afterTokens,
    required this.provider,
    required this.summaryChars,
  });

  /// 净省下的估算 token（可为负——旧区本就小时摘要可能不省）。
  int get savedTokens => beforeTokens - afterTokens;
}

abstract class CompactionPlugin {
  /// 给定上下文溢出，尝试压缩。success 才允许 retry（前进性证明）。
  Future<CompactionResult> decide({
    required SessionRef ref,
    required int turn,
    required int step,
    required String? reason,
  });
}

/// Phase 1 占位：不压缩，返回 failure（Phase 2 用确定性裁剪/摘要替代）。
final class NoCompactionPlugin implements CompactionPlugin {
  const NoCompactionPlugin();

  @override
  Future<CompactionResult> decide({
    required SessionRef ref,
    required int turn,
    required int step,
    required String? reason,
  }) async {
    return const CompactionResult(CompactionResultKind.failure);
  }
}

/// 轻量会话引用（loop 内部用；避免循环依赖，直接持有 SessionLog）。
final class SessionRef {
  final SessionLog _log;
  const SessionRef(this._log);
  SessionLog get log => _log;
}

/// llm-retry 插件：有界 + 指数退避。
final class LlmRetry {
  final int maxRetries;
  final Duration initialDelay;
  final Duration maxDelay;
  final double backoffFactor;

  /// 空响应是否计入可重试档（API 路线开：思考型模型推理耗尽 max_tokens
  /// 时 content 为空，属设计文档 §5.4 的 EMPTY_RESPONSE 可重试码）。
  final bool retryEmptyResponse;

  /// 思考失控是否允许「换条件重试」一次（默认开）。
  ///
  /// 旧行为：thinkingOverflow 永不重试 → 整轮判死，用户只看到"本轮执行失败"。
  /// 新行为：允许重试**一次**，且该次请求强制关思考（见 [takeForceNoThinking]）——
  /// 同一模型同一配置原样重发必然再次失控，只有换条件重采样才有救。
  final bool retryThinkingOverflow;

  /// 每步思考失控重试上限（默认 1；防"失控→关思考重试→又失控"循环烧 token）。
  final int maxThinkingRetries;

  int _retries;
  int _thinkingRetries = 0;
  bool _forceNoThinkingNext = false;

  LlmRetry({
    this.maxRetries = 3,
    this.initialDelay = const Duration(milliseconds: 500),
    this.maxDelay = const Duration(seconds: 10),
    this.backoffFactor = 2.0,
    this.retryEmptyResponse = false,
    this.retryThinkingOverflow = true,
    this.maxThinkingRetries = 1,
  }) :
    _retries = 0;

  void reset() {
    _retries = 0;
    _thinkingRetries = 0;
    _forceNoThinkingNext = false;
  }

  int get retries => _retries;

  /// 取走「下一次请求请强制不思考」标志（读后即清）。
  bool takeForceNoThinking() {
    final v = _forceNoThinkingNext;
    _forceNoThinkingNext = false;
    return v;
  }

  /// 该失败是否允许 llm-retry（compaction 不在此判定，由瀑布分开处理）。
  bool isRetryable(LlmFailure f) {
    // 无适配器 / 上下文溢出 → 不靠 retry 解决。
    if (f.code == LlmFailureCode.noAdapter) return false;
    if (f.code == LlmFailureCode.contextWindowExceeded) return false;
    // 4xx（参数/鉴权/路由）是确定性错误，重试同样失败，只浪费时间。
    if (f.code == LlmFailureCode.invalidRequest) return false;
    // 模型未加载：isLoaded=false 是原生层的权威状态，重试只会再撞同一堵墙。
    if (f.code == LlmFailureCode.modelNotReady) return false;
    // 空响应默认不重试；API 路线按 EMPTY_RESPONSE 计入可重试档。
    if (f.code == LlmFailureCode.emptyResponse && !retryEmptyResponse) {
      return false;
    }
    // 思考失控：只许一次，且那次必须关思考重试（见 maybeBackoff）；用尽即止损。
    if (f.code == LlmFailureCode.thinkingOverflow) {
      return retryThinkingOverflow && _thinkingRetries < maxThinkingRetries;
    }
    // 其余失败（含 toolCallTruncated：采样可能产出更短的完整调用）走
    // 统一的 maxRetries 预算——连续截断说明 token 预算真不够，及时止损。
    return _retries < maxRetries;
  }

  /// 记录一次重试并返回退避时长；首次无退避。
  /// 返回 null 表示不应重试（超出 maxRetries）。
  Future<Duration?> maybeBackoff(LlmFailure f) async {
    if (!isRetryable(f)) return null;
    if (f.code == LlmFailureCode.thinkingOverflow) {
      _thinkingRetries++;
      // 关键：重试必须换条件（关思考），否则同一模型同一配置必然再次失控。
      _forceNoThinkingNext = true;
      return const Duration(milliseconds: 0);
    }
    _retries++;
    if (_retries == 1) return const Duration(milliseconds: 0);
    final rawMs = (initialDelay.inMilliseconds *
        math.pow(backoffFactor, _retries - 1)).round();
    final ms = math.min(rawMs, maxDelay.inMilliseconds);
    if (ms > 0) {
      await Future.delayed(Duration(milliseconds: ms));
    }
    return const Duration(milliseconds: 0);
  }
}
