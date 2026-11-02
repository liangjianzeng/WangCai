/// 本地引擎 adapter —— 包裹 [InferenceService]（llama.cpp）。
///
/// 路由：仅 local。工具调用走文本协议（由 [ToolProtocol] 注入 +
/// [AgentStreamProcessor] 从 response 文本解析）。
///
/// 取消（DSH Part 14.6）：`generate` 接受 cancel，与流完成竞跑；
/// cancel 先行则抛 [AgentCancelledException]。`cancel()` 另作安全网。
library;

import 'dart:async';
import 'dart:convert';

import 'package:flutter/foundation.dart';

import '../../providers/agent_stream_processor.dart';
import '../../services/inference_service.dart';
import 'adapter.dart';
import 'base_engine_adapter.dart';
import '../capability.dart';
import '../protocol/tool_protocol.dart';

class LocalEngineAdapter extends BaseEngineAdapter {
  final InferenceService _inference;

  /// 思考失控守卫阈值（设置可调；默认 [kMaxThinkingChars]）。
  final int _maxThinkingChars;

  /// 用户的全局思考开关（本步是否需要"恢复思考"的判据）。
  ///
  /// [GenerateOptions.forceNoThinking] 为真时临时把原生 enableThinking 关掉，
  /// 生成结束必须按这个值恢复，否则会把用户的设置悄悄改掉。
  final bool _thinkingEnabled;

  LocalEngineAdapter({
    required InferenceService inference,
    required ToolProtocol protocol,
    EngineCapabilities? capabilities,
    int maxThinkingChars = kMaxThinkingChars,
    bool thinkingEnabled = false,
  })  : _inference = inference,
        _maxThinkingChars = maxThinkingChars,
        _thinkingEnabled = thinkingEnabled,
        super(protocol: protocol, capabilities: capabilities);

  /// 取消：先中止 Dart 侧流（基类），再通知 native 引擎停生成。
  @override
  void cancel() {
    super.cancel();
    _inference.stopGeneration();
  }

  @override
  Future<LlmResult> generate(
    GenerateOptions options, {
    StreamController<String>? onToken,
    StreamController<String>? onThinking,
    Completer<void>? cancel,
  }) async {
    // 本地引擎：生成前确认模型已加载（查询原生 isLoaded，权威状态）。
    // 未加载 → 立即抛非重试失败（modelNotReady），避免 native 把
    // COMPLETION_ERROR 归一化成可重试的 transport 导致 agent 空转重试。
    final ready = await _inference.isModelLoaded();
    if (!ready) {
      throw LlmFailure(
        code: LlmFailureCode.modelNotReady,
        message: '本地模型未加载（模型加载失败），请在模型管理页重新加载模型',
      );
    }

    // 本步强制不思考（工具决策步 / 思考失控后的重试）：临时关原生思考开关，
    // finally 里按用户设置恢复。端侧思考失控的止损主力——工具步根本不需要思考。
    final suppressThinking = options.forceNoThinking && _thinkingEnabled;
    if (suppressThinking) {
      await _inference.setEnableThinking(false);
    }

    final messagesJson = jsonEncode(convertEngineMessages(options.messages));
    final rawBuffer = StringBuffer();
    final processor = AgentStreamProcessor();
    final error = StringBuffer();
    final done = Completer<void>();
    StreamSubscription<String>? sub;
    var _streamFinished = false;
    // 思考失控守卫（口径唯一真源：AgentStreamProcessor.thinkingRunaway）：
    // **跨块累计**思考超预算且本步还没有有用产出 → 主动 stopGeneration 止损。
    // 旧口径只量「当前块长」，模型 think…response 反复横跳时每块归零 →
    // 4 万字独白畅通无阻（用户报的"思考超 32k"），已在实测中复现。
    var _thinkingOverflow = false;
    var _thinkingCharsAtTrigger = 0;
    // WP5：工具调用块生成中标记（status 流只在状态翻转/持续时推）。
    var _toolGenActive = false;
    void _finish() {
      if (_streamFinished) return;
      _streamFinished = true;
      done.complete();
    }
    try {
      final sourceStream = _inference.completionWithMessages(
        prompt: '',
        messagesJson: messagesJson,
        imagePath: options.imagePath,
        // 多图全量送原生（长图切块序列）：mtmd 按序逐张编码。
        imagePaths: options.imagePaths,
        audioPath: options.audioPath,
        maxTokens: options.maxTokens ?? 512,
        temperature: options.temperature,
        topP: 0.9,
      );
      sub = sourceStream.listen(
        (token) {
          if (token.isEmpty) return;
          rawBuffer.write(token);
          processor.add(token);
          if (onToken != null) {
            onToken!.add(processor.visibleText);
          }
          if (onThinking != null) {
            onThinking!.add(processor.thinkingText);
          }
          if (!_thinkingOverflow &&
              processor.thinkingRunaway(_maxThinkingChars)) {
            _thinkingOverflow = true;
            _thinkingCharsAtTrigger = processor.thinkingCharsSoFar;
            _inference.stopGeneration();
          }
          // WP5：工具调用参数生成期反馈（大 HTML/长文本写文件时
          // 可见流为空、思考为空，UI 只能干转圈——把隐藏缓冲长度推给 UI）。
          if (options.onStatus != null) {
            final gen = processor.toolGenActive;
            if (gen && !_toolGenActive) {
              _toolGenActive = true;
            }
            if (gen) {
              options.onStatus!.add(
                  'toolgen|${processor.toolGenChars}|${processor.toolGenPreview}');
            } else if (_toolGenActive) {
              _toolGenActive = false;
              options.onStatus!.add('toolgen|0|');
            }
          }
        },
        onError: (Object e, [StackTrace? s]) {
          error.write('$e\n');
          _finish();
        },
        onDone: _finish,
      );
      currentSub = sub;
      // 与 cancel 竞跑：cancel 先行则取消。
      if (await race(done.future, cancel)) {
        throw const AgentCancelledException();
      }
      if (error.length > 0) {
        throw LlmFailure(
          code: mapEngineError(error.toString()),
          message: error.toString(),
        );
      }
      if (_thinkingOverflow) {
        // 先抢救，再判死：止损前已产出的工具调用/答案照样有效。
        // 旧行为是直接丢弃整步产出并抛错 → 端侧用户白等几分钟还整轮失败。
        if (processor.hasToolCalls ||
            processor.visibleText.trim().length >=
                AgentStreamProcessor.kMinUsefulChars) {
          debugPrint('[AgentLlm] 思考失控已止损（累计 $_thinkingCharsAtTrigger 字），'
              '但已有产出可交付 → 照常返回结果');
          return parseAndReturn(rawBuffer, processor);
        }
        throw LlmFailure(
          code: LlmFailureCode.thinkingOverflow,
          message: '思考失控：已累计思考 $_thinkingCharsAtTrigger 字仍无任何产出，'
              '已主动中止（阈值 $_maxThinkingChars 字）。'
              '本次自动改用「不思考」重试一次；若频繁出现，'
              '请在 设置→智能体 调大「思考失控守卫阈值」或关闭该模型思考模式',
        );
      }
      return parseAndReturn(rawBuffer, processor);
    } on AgentCancelledException catch (e) {
      rethrow;
    } on LlmFailure catch (e) {
      rethrow;
    } catch (e) {
      throw LlmFailure(
        code: mapEngineError(error.toString()),
        message: '本地引擎调用失败: $e',
      );
    } finally {
      sub?.cancel();
      if (identical(sub, currentSub)) {
        currentSub = null;
      }
      // 恢复用户的思考开关（本步曾为止损临时关掉）。失败不改变本步结论。
      if (suppressThinking) {
        try {
          await _inference.setEnableThinking(true);
        } catch (_) {}
      }
    }
  }
}
