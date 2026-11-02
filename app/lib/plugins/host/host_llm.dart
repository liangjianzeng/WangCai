/// 宿主接缝：把既有的模型调用路线（本地 llama.cpp / OpenAI 兼容 API）适配成
/// 平台的 `llm.complete` 与 `llm.vision` 能力。
///
/// 三条不能让步的地方：
/// 1. **不进会话 KV**（§5.4）：抽词这种一次性补全绝不能污染用户正在聊的上下文。
///    本地路线走 `completionWithMessages`（原生按 messagesJson 重建上下文），
///    并在 `finally` 里 `resetContext()` —— 代价是聊天下一轮重新 prefill，
///    **正确性优先于省那点算力**；
/// 2. **不与聊天抢引擎**：本地引擎同时只有一个生成流（`_currentTokenSubscription`
///    会被后来者抢走），聊天正在生成时插件直接拿 `busy`，排队不是办法（用户会以为卡死）；
/// 3. **一次性补全 ≠ 智能体回合**：不注入系统提示词、不带工具、不进事件日志。
library;

import 'dart:async';
import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:plugin_kernel/plugin_kernel.dart';

import '../../agent/llm/openai_adapter.dart' show attachWireImages;
import '../../providers/chat_provider.dart' show isGeneratingProvider, planGenerationRoute;
import '../../providers/model_provider.dart' show modelManagerProvider;
import '../../providers/settings_provider.dart';
import '../../providers/shared_providers.dart';
import '../../services/inference_service.dart';
import '../../services/openai_service.dart';

/// 聊天正在生成（本地引擎只能有一个生成流）。
class PluginEngineBusyException implements Exception {
  @override
  String toString() => 'busy';
}

/// 当前没有任何可用模型。
class PluginNoModelException implements Exception {
  PluginNoModelException(this.reason);
  final String reason;
  @override
  String toString() => reason;
}

/// 模型没准备好（本地档没加载起来）。带着"该对用户说什么"的失败体，
/// 由 [explain] 原样端出去 —— 别让这种可预料的状况落到 catch-all 那句"没能从图里提取内容"上。
class PluginModelNotReadyException implements Exception {
  PluginModelNotReadyException(this.failure);
  final PluginFailure failure;
  @override
  String toString() => failure.message;
}

/// 本地路线在**要结果之前**把模型准备好（可注入，好让这条路径能在纯 Dart 测试里跑）。
///
/// 为什么要有这一步：插件的一次性补全是**独立入口** —— 用户可能刚打开 app 就直接点听写图标，
/// 那时模型根本没加载（只有发消息才会加载）。以前这里直接问原生要结果，原生抛错，
/// 界面只剩一句"没能从图里提取内容"（2026-10-24 真机：用户"一直报"却没有任何线索）。
final class LocalModelGate {
  const LocalModelGate({required this.isLoaded, required this.load});

  final bool Function() isLoaded;
  final Future<bool> Function(String modelId) load;

  /// null = 可以继续问模型；否则是要对用户说的话。
  Future<PluginFailure?> ensure(String modelId) async {
    if (modelId.isEmpty) {
      return PluginFailure(
        code: PluginFailureKind.missingCapability,
        message: '没指定用哪个模型',
        hint: '在 设置→模型管理 勾选默认模型，或在 设置→API 接入 配好接口',
        cause: 'route 没给出 modelId',
      );
    }
    if (isLoaded()) return null;
    final ok = await load(modelId);
    if (ok) return null;
    return PluginFailure(
      code: PluginFailureKind.missingCapability,
      message: '模型还没加载起来',
      hint: '在 设置→模型管理 里加载它；要看图还得给该模型开启视觉（需要 mmproj 投影器），'
          '或改用支持视觉的模型',
      cause: 'loadModel($modelId) 返回 false',
    );
  }
}

/// 一次补全的路由结果。
final class PluginLlmRoute {
  const PluginLlmRoute({required this.useApi, this.modelId, this.error, this.visionCapable = false});
  final bool useApi;
  final String? modelId;
  final String? error;
  final bool visionCapable;
}

/// 文本/图文补全端口（测试注入用；真机走 [AppLlmPort]）。
abstract interface class LlmTextPort {
  Future<PluginLlmRoute> route();
  Future<String> complete({
    required String system,
    required String user,
    List<String> imagePaths,
    int? maxTokens,
    double temperature,
    PluginCancelToken? cancelToken,
  });
}

/// 真机端口：路由规则与聊天/智能体**同源**（`planGenerationRoute`），不另立一套。
final class AppLlmPort implements LlmTextPort {
  AppLlmPort(this._ref,
      {InferenceService? inference, OpenAiService? openAi, LocalModelGate? modelGate})
      : _inference = inference,
        _openAi = openAi,
        _modelGate = modelGate;

  final Ref _ref;
  final InferenceService? _inference;
  final OpenAiService? _openAi;
  final LocalModelGate? _modelGate;

  /// 真值取自模型管理器（与聊天同一份真相）；测试里由构造函数注入。
  LocalModelGate get _gate => _modelGate ?? LocalModelGate(
        isLoaded: () => _ref.read(modelManagerProvider).isLoaded,
        load: (id) => _ref.read(modelManagerProvider.notifier).loadModel(id),
      );

  InferenceService get _inf => _inference ?? _ref.read(inferenceServiceProvider);
  OpenAiService get _api => _openAi ?? _ref.read(openAiServiceProvider);

  @override
  Future<PluginLlmRoute> route() async {
    final settings = _ref.read(settingsProvider);
    if (_ref.read(isGeneratingProvider)) {
      // 生成中：本地引擎的 token 流是单槽的，硬挤进去会让聊天半路断流。
      throw PluginEngineBusyException();
    }
    // 加载态取 modelManagerProvider（与聊天同一份真相，不去问原生）。
    final manager = _ref.read(modelManagerProvider);
    final plan = planGenerationRoute(
      settings: settings,
      localLoaded: manager.isLoaded,
      loadedModelId: manager.modelId,
      fallbackModelId: settings.defaultModelId ?? '',
    );
    if (plan.useApi) {
      final api = settings.activeApiModel();
      return PluginLlmRoute(
        useApi: true,
        modelId: api?.model,
        error: api == null ? 'API 接入未配置' : null,
        visionCapable: api?.visionCapable ?? false,
      );
    }
    final id = plan.localModelId ?? '';
    if (id.isEmpty) {
      return PluginLlmRoute(useApi: false, error: plan.error ?? '没有加载或勾选任何模型');
    }
    return PluginLlmRoute(
      useApi: false,
      modelId: id,
      // 本地能不能看图，取决于该模型是否按视觉模型启用（mmproj 在加载时决定）。
      visionCapable: settings.visionEnabled(id),
    );
  }

  @override
  Future<String> complete({
    required String system,
    required String user,
    List<String> imagePaths = const [],
    int? maxTokens,
    double temperature = 0,
    PluginCancelToken? cancelToken,
  }) async {
    final r = await route();
    if (r.error != null) throw PluginNoModelException(r.error!);
    return r.useApi
        ? _viaApi(r, system: system, user: user, imagePaths: imagePaths, maxTokens: maxTokens, temperature: temperature, cancelToken: cancelToken)
        : _viaLocal(modelId: r.modelId ?? '', system: system, user: user, imagePaths: imagePaths, maxTokens: maxTokens, temperature: temperature, cancelToken: cancelToken);
  }

  Future<String> _viaApi(
    PluginLlmRoute r, {
    required String system,
    required String user,
    required List<String> imagePaths,
    required int? maxTokens,
    required double temperature,
    PluginCancelToken? cancelToken,
  }) async {
    final config = _ref.read(settingsProvider).activeApiModel();
    if (config == null) throw PluginNoModelException('API 接入未配置');
    final logical = <Map<String, dynamic>>[
      if (system.isNotEmpty) {'role': 'system', 'content': system},
      {'role': 'user', 'content': user, if (imagePaths.isNotEmpty) 'imagePaths': imagePaths},
    ];
    // 图片转 base64 走适配器同一个函数（缓存、条数上限、失败降级口径与聊天一致）。
    final wire = await attachWireImages(
      logical.map((m) => Map<String, dynamic>.of(m)).toList(),
      logical,
    );
    final sb = StringBuffer();
    final stream = _api.chatCompletion(config: config, messages: wire, temperature: temperature, maxTokens: maxTokens);
    await for (final chunk in stream) {
      if (cancelToken?.isCancelled ?? false) break;
      sb.write(chunk);
    }
    return sb.toString();
  }

  Future<String> _viaLocal({
    required String modelId,
    required String system,
    required String user,
    required List<String> imagePaths,
    required int? maxTokens,
    required double temperature,
    PluginCancelToken? cancelToken,
  }) async {
    // 模型不在内存里就直接问原生 = 必然抛错，然后被 catch-all 说成"没能从图里提取内容"。
    // 先加载（与聊天同一个 loadModel），加载不动就说清"模型还没加载起来 + 去哪儿加载"。
    final notReady = await _gate.ensure(modelId);
    if (notReady != null) throw PluginModelNotReadyException(notReady);
    final msgs = <Map<String, dynamic>>[
      if (system.isNotEmpty) {'role': 'system', 'content': system},
      {'role': 'user', 'content': user, if (imagePaths.isNotEmpty) 'imagePaths': imagePaths},
    ];
    final sb = StringBuffer();
    try {
      final stream = _inf.completionWithMessages(
        prompt: user,
        messagesJson: jsonEncode(msgs),
        imagePaths: imagePaths.isEmpty ? null : imagePaths,
        maxTokens: maxTokens ?? 1024,
        temperature: temperature,
      );
      await for (final chunk in stream) {
        if (cancelToken?.isCancelled ?? false) {
          await _inf.stopGeneration();
          break;
        }
        sb.write(chunk);
      }
      return sb.toString();
    } finally {
      // 见文件头第 1 条：一次性补全用完就把 KV 归零，聊天下一轮自行重建。
      try {
        await _inf.resetContext();
      } catch (_) {}
    }
  }
}

/// `llm.complete` 的宿主实现（一次性文本补全，不带工具、不进会话）。
final class HostLlmComplete with CapabilityBase implements LlmComplete {
  HostLlmComplete(this._port);
  final LlmTextPort _port;

  @override
  final ServiceKey<LlmComplete> key = ServiceKeys.llmComplete;

  @override
  bool get available => true; // 路由是运行期的事；缺模型时说人话（见 _explain）。

  @override
  String? get unavailableReason => null;

  @override
  Future<Outcome<String>> complete({
    required String systemPrompt,
    required String userText,
    int? maxTokens,
    double temperature = 0,
    PluginCancelToken? cancelToken,
  }) async {
    try {
      final text = await _port.complete(
        system: systemPrompt,
        user: userText,
        maxTokens: maxTokens,
        temperature: temperature,
        cancelToken: cancelToken,
      );
      if (text.trim().isEmpty) {
        return Outcome.err<String>(
          code: PluginFailureKind.badContent,
          message: '模型没给出内容',
          hint: '换个模型或把要求写得更具体些',
        );
      }
      return Ok<String>(text);
    } catch (e) {
      return Err<String>(explain(e, '没能完成补全'));
    }
  }
}

/// `llm.vision` 的宿主实现（抽词主路径）。
final class HostLlmVision with CapabilityBase implements LlmVision {
  HostLlmVision(this._port);
  final LlmTextPort _port;

  @override
  final ServiceKey<LlmVision> key = ServiceKeys.llmVision;

  @override
  bool get available => true;

  @override
  String? get unavailableReason => null;

  @override
  Future<Outcome<String>> completeWithImage({
    required String systemPrompt,
    required String userText,
    required List<String> imagePaths,
    int? maxTokens,
    double temperature = 0,
    PluginCancelToken? cancelToken,
  }) async {
    if (imagePaths.isEmpty) {
      return Outcome.err<String>(
        code: PluginFailureKind.badContent,
        message: '没有图片可看',
        hint: '先拍照或从相册选一张',
      );
    }
    // 分阶段记一步：出错时能说清是"路由/加载"死的还是"生成"死的。
    // 2026-10-24 真机"一直报没能从图里提取内容"就是因为这两段共用一句 catch-all，
    // 模型没加载、mmproj 缺失、图片解码失败、断网在界面上长得一模一样。
    var stage = '准备模型';
    try {
      final r = await _port.route();
      if (r.error != null) return Err<String>(_noModel(r.error!));
      if (!r.visionCapable) {
        return Outcome.err<String>(
          code: PluginFailureKind.missingCapability,
          message: '当前模型看不了图',
          hint: r.useApi
              ? '在 设置→API 接入 把这个模型勾成支持视觉'
              : '在 设置 里为该模型开启视觉（需要 mmproj 投影器），或改用支持视觉的模型',
        );
      }
      stage = '看图生成';
      final text = await _port.complete(
        system: systemPrompt,
        user: userText,
        imagePaths: imagePaths,
        maxTokens: maxTokens,
        temperature: temperature,
        cancelToken: cancelToken,
      );
      if (text.trim().isEmpty) {
        return Outcome.err<String>(
          code: PluginFailureKind.badContent,
          message: '模型没从图里读出内容',
          hint: '拍清楚一些再试（对齐课本条目、别逆光）',
        );
      }
      return Ok<String>(text);
    } catch (e) {
      return Err<String>(explain(e, '没能从图里提取内容', stage: stage));
    }
  }
}

/// 把端口异常翻成"一句人话 + 下一步做什么"（技术原文进 hint 与 cause）。
///
/// 2026-10-24 真机教训：用户"一直报没能从图里提取内容"却无从下手 —— 原来所有异常都落到
/// 最后那句 catch-all，真凶（模型没加载 / 没开视觉 / 图片解码失败 / 断网 / 超时）只进 `cause`，
/// 而界面上连 `cause` 都不显示。所以这里：**分类说人话、hint 带下一步也带技术原文、并且打日志**
/// （`[plugin-llm]`，抓得到 logcat 时一眼定位）。
PluginFailure explain(Object e, String fallbackMessage, {String stage = ''}) {
  final raw = '$e';
  final kind = e.runtimeType.toString();
  final where = stage.isEmpty ? '' : '（$stage）';
  // 不 import dio/services：按类型名认（假异常也能测）。`kind` 与原文两处都看 ——
  // 上层有时把真凶包在 `Exception('SocketException: …')` 里，只看 runtimeType 会漏掉。
  final hay = '$kind $raw';
  String? cls(String name) => hay.contains(name) ? name : null;
  final klass = cls('PlatformException') ??
      cls('TimeoutException') ??
      cls('DioException') ??
      cls('SocketException') ??
      cls('HandshakeException');
  debugPrint('[plugin-llm] ${stage.isEmpty ? '失败' : stage}：$kind $raw');
  if (e is PluginEngineBusyException) {
    return PluginFailure(
      code: PluginFailureKind.busy,
      message: '模型正在回答上一条消息',
      hint: '等它说完再试，或先点停止',
    );
  }
  if (e is PluginNoModelException) return _noModel(e.reason);
  if (e is PluginModelNotReadyException) return e.failure;
  if (klass == 'PlatformException') {
    // 本地引擎那条线：原生层报错（模型没加载、mmproj 缺失、图片读不进、显存不够被拒）。
    return PluginFailure(
      code: PluginFailureKind.runtimeError,
      message: '本地模型看图这一步没跑通$where',
      hint: '多半是该模型没加载或没开视觉（需要 mmproj 投影器）：'
          '去 设置→模型管理 加载并开启视觉再试。引擎原话：$raw',
      cause: raw,
    );
  }
  if (klass == 'TimeoutException') {
    return PluginFailure(
      code: PluginFailureKind.timeout,
      message: '等模型回话超时$where',
      hint: '图拍小一点（别一整页）、或换快一档的模型再试。原文：$raw',
      cause: raw,
    );
  }
  if (klass != null) {
    return PluginFailure(
      code: PluginFailureKind.runtimeError,
      message: '接口没连上$where',
      hint: '检查 设置→API 接入 的地址、密钥与手机网络（走 API 时才需要网）。原文：$raw',
      cause: raw,
    );
  }
  return PluginFailure(
    code: PluginFailureKind.runtimeError,
    message: '$fallbackMessage$where',
    hint: '检查模型与网络设置后再试一次。原文：$raw',
    cause: raw,
  );
}

PluginFailure _noModel(String reason) => PluginFailure(
      code: PluginFailureKind.missingCapability,
      message: '没有可用的模型',
      hint: '在 设置→模型管理 勾选默认模型，或在 设置→API 接入 配好接口',
      cause: reason,
    );
