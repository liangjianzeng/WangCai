/// 声明式 flow 引擎（P5）—— 把 `plugin.json` 的 `steps` 跑成一次真实流程。
///
/// 放在内核（而不是 app 里）的理由：解释器是**平台的核心资产**，必须能离线全量测试
/// （本文件配套 `test/flow_runner_test.dart` 用假能力跑完 8 个原语）。app 只负责
/// 把真能力注进来。
///
/// 四条解释纪律：
/// 1. **步骤白名单**：`declarative` 插件只能调 8 个原语，引擎不认识任何别的东西；
/// 2. **每一步之后复查取消**（引擎替作者守住，作者忘了也不会失控）；
/// 3. **失败策略是闭集**：`abort` / `skipWithWarning` / `cancel`，没有"静默跳过当成功"；
/// 4. **终局三态**（completed / cancelled / error）+ 已完成/跳过步骤清单 ——
///    "迭代两下就停却显示完成"这类事故在这里被结构上堵死。
library;

import 'dart:async';
import 'dart:convert';

import 'package:plugin_sdk/plugin_sdk.dart';

import 'loader.dart';

/// 需要宿主帮忙的两件事（内核不碰 UI、不碰智能体实现）。
///
/// 没提供时引擎**不硬编**：`agent_handoff` 走 `skipWithWarning` 并在面板说明"本机没接线"。
/// 宿主交付导出件时**必须**给回的凭据。
///
/// 为什么不能由引擎拿"作者要的文件名"去报：宿主会改写它 —— 非法字符换成 `_`、
/// 没扩展名补 `.txt`、撞名加 `-1`。报告里说一个用户手上没有的文件名，
/// 与"空 URI 也算导出成功"是同族的谎：跑成功了，但功能是坏的。
final class ExportReceipt {
  const ExportReceipt({required this.uri, required this.fileName, this.renamedFrom});

  /// 内容提供者给回的位置；空串 = 没交付（runner 会复查，见 export 步）。
  final String uri;

  /// **真正**落到下载目录的文件名（含撞名后缀），不是作者要的那个。
  final String fileName;

  /// 宿主改写过名字时给原名；没改写过为 null。
  final String? renamedFrom;
}

final class FlowHost {
  const FlowHost({this.startAgent, this.renderExport});

  /// 交回智能体续跑，返回启动的子任务数（进 `FlowResult.agentsStarted`）。
  final Future<Outcome<int>> Function(PluginCtx ctx, String prompt, String context)? startAgent;

  /// 导出产物：平台**不自己落盘**，交给宿主渲染成可分享卡片/文件。
  /// 没接（null）时引擎不硬编，把内容留在 `payloads` 里由 UI 决定怎么呈现。
  /// 接了就必须交回 [ExportReceipt]（真名 + 位置）：空 URI、空文件名都按失败处理。
  final Future<Outcome<ExportReceipt>> Function(PluginCtx ctx, String filename, String content)? renderExport;
}

/// 声明式插件的实现体（loader 通过 `declarativeFactory` 给每条声明配一个）。
final class DeclarativePlugin implements AppPlugin {
  DeclarativePlugin(this.descriptor, {required this.runner});

  final PluginDescriptor descriptor;
  final FlowRunner runner;

  @override
  PluginManifest get manifest => descriptor.manifest;

  @override
  Outcome<Disposable?> apply(PluginCtx ctx) {
    final ready = ensureDeclaredCapabilities(ctx);
    if (ready.isErr) return Err<Disposable?>(ready.failureOrNull!);

    final flow = manifest.flow;
    if (flow == null || flow.steps.isEmpty) {
      return Outcome.err<Disposable?>(
        code: PluginFailureKind.configInvalid,
        message: '没有可执行的步骤',
        hint: '在 plugin.json 的 flow.steps 里至少写一步',
        pluginId: ctx.manifest.id,
      );
    }

    // 图标位：声明式插件没有 Dart，可以完全不给图标（作者写了 icon 才占位）。
    if (manifest.icon == null) return const Ok<Disposable?>(null);
    final chip = ctx.slots.register(SlotContribution<Object?>(
      slotId: 'app.input.right',
      pluginId: ctx.manifest.id,
      id: 'chip',
      label: ctx.manifest.name,
      payload: ctx.manifest.name,
    ));
    if (chip.isErr) return Err<Disposable?>(chip.failureOrNull!);
    ctx.effect(chip.valueOrNull!);
    return const Ok<Disposable?>(null);
  }

  @override
  Future<Outcome<PluginRunResult>> run(PluginCtx ctx, PluginInput input) =>
      runner.run(ctx, input, flow: manifest.flow!, promptText: descriptor.promptText);
}

/// 步骤之间的共享状态（引擎内部，作者看不见）。
class _State {
  List<String> images = [];
  List<ExtractedItem> items = [];
  List<String> lines = [];
  Map<String, Object?> values = {};
  final List<Object?> payloads = [];
  final List<ExportReceipt> exported = [];
}

final class FlowRunner {
  const FlowRunner({this.host = const FlowHost()});

  final FlowHost host;

  Future<Outcome<PluginRunResult>> run(
    PluginCtx ctx,
    PluginInput input, {
    required FlowMeta flow,
    String? promptText,
  }) async {
    final st = _State()..images = List<String>.of(input.imagePaths);
    final completed = <String>[];
    final skipped = <String>[];
    var agents = 0;
    // 入口带的文字（用户输入框内容）算一条附加要求，提示词里用 {{userInstruction}} 引用。
    var userInstruction = input.text.trim();

    for (var i = 0; i < flow.steps.length; i++) {
      final step = flow.steps[i];
      final label = 'step:${step.id}';
      if (ctx.cancelToken.isCancelled) {
        return Ok<PluginRunResult>(PluginRunResult(
          summary: '已取消（走到第 ${i + 1} 步「${step.op.wireName}」）',
          data: {'flow': flow.name, 'completedSteps': completed, 'skippedSteps': skipped, 'cancelled': true},
          userVisible: false,
        ));
      }

      final outcome = await _withTimeout(step, () => _execute(ctx, input, step, st, userInstruction, promptText));
      if (outcome.isErr) {
        final f = outcome.failureOrNull!.scoped(pluginId: ctx.manifest.id, step: label);
        // 用户主动放弃（review 选"算了"、没选图）= 终局 `cancelled`，**不是 error**；
        // 三态闭集的意义就在这：三件事必须能被面板区分开。
        if (f.code == PluginFailureKind.cancelled) {
          return Ok<PluginRunResult>(PluginRunResult(
            summary: f.message,
            data: {'flow': flow.name, 'completedSteps': completed, 'skippedSteps': skipped, 'cancelled': true},
            userVisible: false,
          ));
        }
        switch (step.onFailure) {
          case FlowStepFailure.abort:
            return Err<PluginRunResult>(f);
          case FlowStepFailure.skipWithWarning:
            skipped.add('${step.id}（${f.message}）');
            ctx.log.warn('步骤 ${step.id} 跳过：${f.message}');
            continue;
          case FlowStepFailure.cancel:
            return Ok<PluginRunResult>(
              PluginRunResult(
                summary: '已取消',
                data: {'flow': flow.name, 'completedSteps': completed, 'skippedSteps': skipped, 'cancelled': true},
                userVisible: false,
              ),
            );
        }
      }
      final r = outcome.valueOrNull!;
      completed.add(step.id);
      if (r.agentsStartedDelta > 0) agents += r.agentsStartedDelta;
    }

    final summary = _summary(flow, st, completed.length, skipped.length);
    return Ok<PluginRunResult>(PluginRunResult(
      summary: summary,
      data: {
        'flow': flow.name,
        'completedSteps': completed,
        'skippedSteps': skipped,
        'count': st.items.length,
        'agentsStarted': agents,
      },
      payloads: List<Object?>.unmodifiable(st.payloads),
    ));
  }

    Future<Outcome<_StepResult>> _withTimeout(FlowStep step, Future<Outcome<_StepResult>> Function() body) async {
    final seconds = step.timeoutSeconds;
    if (seconds == null) return body();
    try {
      return await body().timeout(Duration(seconds: seconds));
    } on TimeoutException {
      return Outcome.err<_StepResult>(
        code: PluginFailureKind.timeout,
        message: '「${step.op.wireName}」等了 ${seconds} 秒没结果',
        hint: '再试一次；网络慢就换个时间或缩短内容',
      );
    }
  }

  Future<Outcome<_StepResult>> _execute(
    PluginCtx ctx,
    PluginInput input,
    FlowStep step,
    _State st,
    String userInstruction,
    String? promptText,
  ) async {
    final p = step.params;
    switch (step.op) {
      // —— 取材 ——
      case FlowStepOp.capture:
        if (st.images.isNotEmpty && p['alwaysAsk'] != true) return Ok<_StepResult>(_StepResult());
        final cap = ctx.capabilities.require<Capture>(ServiceKeys.capture);
        if (cap.isErr) return Err<_StepResult>(cap.failureOrNull!);
        final picked = await cap.valueOrNull!.pickImages(
          maxCount: (p['maxCount'] as num?)?.toInt() ?? 3,
          preferCamera: p['preferCamera'] != false,
        );
        if (picked.isErr) return Err<_StepResult>(picked.failureOrNull!);
        final got = picked.valueOrNull!;
        if (got.isEmpty) {
          return Outcome.err<_StepResult>(
            code: PluginFailureKind.cancelled,
            message: '没选图片',
            hint: '拍一张课本单词表，或从相册选',
          );
        }
        st.images = got;
        return Ok<_StepResult>(_StepResult());

      // —— 抽取 ——
      case FlowStepOp.llmExtract:
        final system = _renderPrompt(promptText, userInstruction, p, st.values);
        final userText = (p['instruction'] as String?) ??
            (userInstruction.isEmpty ? '请按规则抽取内容条目。' : userInstruction);
        final maxTokens = (p['maxTokens'] as num?)?.toInt();
        // 走哪条路由两件事说了算：用户真给了图 **且** 插件声明了 llm:vision。
        // 只声明 llm:chat 的纯文本插件即使被塞了一张图，也不会被推着去调视觉模型。
        final wantsVision = st.images.isNotEmpty && ctx.hasPermission(PluginPermission.llmVision);
        if (st.images.isNotEmpty && !wantsVision) {
          ctx.log.warn('收到 ${st.images.length} 张图，但插件没声明 llm:vision 权限，按文本补全处理');
        }
        final raw = wantsVision
            ? await _completeVision(ctx, system, userText, st.images, maxTokens)
            : await _completeText(ctx, system, userText, maxTokens);
        if (raw.isErr) return Err<_StepResult>(raw.failureOrNull!);
        final items = extractItems(
          raw.valueOrNull!,
          textKeys: _stringList(p['textKeys']) ?? kTextKeys,
          noteKeys: _stringList(p['noteKeys']) ?? kNoteKeys,
          unitKeys: _stringList(p['unitKeys']) ?? kUnitKeys,
          allowLineFallback: p['allowLineFallback'] != false,
        );
        if (items.isEmpty) {
          return Outcome.err<_StepResult>(
            code: PluginFailureKind.badContent,
            message: '没认出内容',
            hint: st.images.isEmpty ? '把要抽取的文字写清楚' : '拍正、拍全，别逆光或只拍半页',
          );
        }
        st.items = items;
        st.lines = _linesOf(st.items, p, ctx);
        return Ok<_StepResult>(_StepResult());

      // —— 校对 ——
      case FlowStepOp.review:
        if (st.items.isEmpty) {
          return Outcome.err<_StepResult>(
            code: PluginFailureKind.badContent,
            message: '还没有可校对的内容',
            hint: '把 review 步排在 llm_extract 之后',
          );
        }
        final interact = ctx.capabilities.require<Interact>(ServiceKeys.interact);
        if (interact.isErr) return Err<_StepResult>(interact.failureOrNull!);
        final preview = st.items.take(8).map((e) => e.toString()).join('、');
        final authorTitle = (p['title'] as String?)?.trim();
        // 作者写的 `title` 必须真的出现在用户面前：以前它被丢掉，用户在"共 12 条：…"里
        // 完全看不出这一步在让他确认什么 —— 声明里写"点掉不对的"就这么蒸发了。
        final answer = await interact.valueOrNull!.askChoice(
          question: [
            if (authorTitle != null && authorTitle.isNotEmpty) authorTitle,
            '共 ${st.items.length} 条：$preview${st.items.length > 8 ? ' …' : ''}',
          ].join('｜'),
          options: const ['继续', '算了'],
        );
        if (answer.isErr) return Err<_StepResult>(answer.failureOrNull!);
        final a = answer.valueOrNull;
        if (a == null || a == '算了') {
          return Outcome.err<_StepResult>(
            code: PluginFailureKind.cancelled,
            message: '用户放弃了这次流程',
            hint: null,
          );
        }
        return Ok<_StepResult>(_StepResult());

      // —— 要参数 ——
      case FlowStepOp.askParams:
        final names = _stringList(p['names']) ??
            ctx.manifest.params.where((x) => x.askAtStart).map((x) => x.name).toList();
        final interact = ctx.capabilities.require<Interact>(ServiceKeys.interact);
        if (interact.isErr) return Err<_StepResult>(interact.failureOrNull!);
        for (final name in names) {
          final param = ctx.manifest.params.where((x) => x.name == name).firstOrNull;
          if (param == null) {
            return Outcome.err<_StepResult>(
              code: PluginFailureKind.configInvalid,
              message: '要问的参数「$name」没在 params 里定义',
              hint: '在 plugin.json 的 params 里补上它',
            );
          }
          switch (param.type) {
            case PluginParamType.number:
              final v = await interact.valueOrNull!.askNumber(
                question: param.label,
                defaultValue: (ctx.numberConfig(name, param.defaultValue is num ? (param.defaultValue as num).toDouble() : 0) * 100).roundToDouble() / 100,
                min: param.min ?? 0,
                max: param.max ?? 100000,
              );
              if (v.isErr) return Err<_StepResult>(v.failureOrNull!);
              final got = v.valueOrNull;
              if (got != null) {
                final lo = param.min ?? 0;
                final hi = param.max ?? 100000;
                // 区间是**插件在 manifest 里声明**的，宿主实现给了越界值 = 实现违约，
                // 不是用户填错。默默采纳会变成"5 秒变 500 秒"这种查不出来的玄学故障，
                // 所以当场判失败，并且说清是谁的问题（冻结清单：判词必须指到该改的那个人）。
                if (got < lo || got > hi) {
                  return Outcome.err<_StepResult>(
                    code: PluginFailureKind.runtimeError,
                    message: '「${param.label}」的输入返回了 $got，超出插件声明的 $lo–$hi',
                    hint: '这是提供 app.interact 的宿主实现违约（它必须自己钳制或拒收），不是插件写错、也不是用户填错',
                  );
                }
                // 落整就存整：否则提示词里"只做 8.0 张卡"、总结里"每条 5.0 秒"。
                st.values[name] = num.parse(formatCount(got));
              }
            case PluginParamType.choice:
              final v = await interact.valueOrNull!.askChoice(
                question: param.label,
                options: param.options.isEmpty ? [param.defaultValue?.toString() ?? ''] : param.options,
              );
              if (v.isErr) return Err<_StepResult>(v.failureOrNull!);
              if (v.valueOrNull != null) st.values[name] = v.valueOrNull;
            case PluginParamType.boolean:
            case PluginParamType.text:
              // 布尔/文本用配置值即可（弹窗问"是/否"体验更差，交给设置页）。
              break;
          }
        }
        return Ok<_StepResult>(_StepResult());

      // —— 朗读 ——
      case FlowStepOp.speakSequence:
        final lines = st.lines.isEmpty ? _linesOf(st.items, p, ctx) : st.lines;
        if (lines.isEmpty) {
          return Outcome.err<_StepResult>(
            code: PluginFailureKind.badContent,
            message: '没有可朗读的内容',
            hint: '先跑 llm_extract，或在 steps 里给 items',
          );
        }
        final speak = ctx.capabilities.require<Speak>(ServiceKeys.speak);
        if (speak.isErr) return Err<_StepResult>(speak.failureOrNull!);
        final gapKey = (p['gapParam'] as String?) ?? 'gapSeconds';
        final gapSeconds = (st.values[gapKey] as num?)?.toDouble() ?? ctx.numberConfig(gapKey, 5);
        var played = 0;
        final failed = <String>[];
        final toSpeak = _stringList(p['items']) ?? lines;
        final voice = (p['voice'] as String?) ?? ctx.stringConfig('voice', '');
        // 第一条照常立刻播，其余**后台预热**：`Speak.prewarm` 是契约里就有、宿主也真做了
        // 预合成的口子，以前却没有任何调用者 —— 于是每条都要现合成，用户等的是
        // "下载音频的时间"而不是插件声明的间隔。预热只该影响性能：false 与异常都不许惊动用户。
        if (toSpeak.length > 1) {
          speak.valueOrNull!.prewarm(toSpeak.sublist(1), voice).catchError((_) => false);
        }
        final stream = speak.valueOrNull!.speak(
          SpeakRequest(
            items: toSpeak,
            voice: voice,
            gap: Duration(seconds: gapSeconds.round()),
            repeatPerItem: (p['repeatPerItem'] as num?)?.toInt() ?? 1,
          ),
          ctx.cancelToken,
        );
        await for (final ev in stream) {
          if (ctx.cancelToken.isCancelled) break;
          if (ev.phase == SpeakPhase.playing) played += 1;
          if (ev.phase == SpeakPhase.skipped) failed.add(ev.text);
        }
        st.values['played'] = played;
        st.values['failed'] = failed;
        return Ok<_StepResult>(_StepResult());

      // —— 存储 ——
      case FlowStepOp.store:
        final store = ctx.capabilities.require<Store>(ServiceKeys.store);
        if (store.isErr) return Err<_StepResult>(store.failureOrNull!);
        if (p['value'] == null && st.items.isEmpty && st.values.isEmpty) {
          // 存一个空壳却返回成功 = 用户以为"记住了上次那批"，下次却什么都没有。
          return Outcome.err<_StepResult>(
            code: PluginFailureKind.badContent,
            message: '没东西可存',
            hint: '把 store 排在 llm_extract 之后，或在 params.value 里直接给要存的文本',
          );
        }
        final key = (p['key'] as String?) ?? 'lastRun';
        final value = (p['value'] as String?) ??
            (st.items.isEmpty ? jsonEncode(st.values) : st.items.map((e) => e.toString()).join('、'));
        final w = await store.valueOrNull!.write(key, value);
        if (w.isErr) return Err<_StepResult>(w.failureOrNull!);
        return Ok<_StepResult>(_StepResult());

      // —— 导出 ——
      case FlowStepOp.export:
        final filename = (p['filename'] as String?) ?? '${ctx.manifest.id}-练习单.txt';
        final content = st.items.isEmpty
            ? (p['content'] as String? ?? '')
            : st.items.map((e) => p['withNote'] == false ? e.text : '${e.text}\t${e.note}').join('\n');
        if (content.trim().isEmpty) {
          return Outcome.err<_StepResult>(
            code: PluginFailureKind.badContent,
            message: '没有可导出的内容',
            hint: '把 export 排在 llm_extract 之后',
          );
        }
        st.payloads.add({'filename': filename, 'content': content});
        if (host.renderExport != null) {
          final r = await host.renderExport!(ctx, filename, content);
          if (r.isErr) return Err<_StepResult>(r.failureOrNull!);
          final receipt = r.valueOrNull;
          // 交付必须由位置与真名证明（与"空 URI 不算导出"同族）：宿主说成功了，
          // 就得说得出文件落在哪、最后叫什么 —— 给不出就等于用户手上什么都没有。
          if (receipt == null || receipt.uri.trim().isEmpty || receipt.fileName.trim().isEmpty) {
            return Outcome.err<_StepResult>(
              code: PluginFailureKind.runtimeError,
              message: '导出没拿到凭据：宿主没给回文件名与位置',
              hint: '内容可能已在 app 里：plugin_exports/${ctx.manifest.id}/；'
                  '检查导出通道（下载目录是否可用、存储权限是否给了）',
              pluginId: ctx.manifest.id,
              step: step.id,
            );
          }
          st.exported.add(receipt);
        }
        return Ok<_StepResult>(_StepResult());

      // —— 交给智能体 ——
      case FlowStepOp.agentHandoff:
        if (host.startAgent == null) {
          return Outcome.err<_StepResult>(
            code: PluginFailureKind.missingCapability,
            message: '这台机器还没接通智能体交接',
            hint: '宿主未提供 FlowHost.startAgent；把该步的 onFailure 设成 skipWithWarning 可跳过',
          );
        }
        final prompt = (p['prompt'] as String?) ?? ctx.manifest.whenToUse;
        final context = st.items.isEmpty ? userInstruction : st.items.map((e) => e.toString()).join('、');
        final started = await host.startAgent!(ctx, prompt, context);
        if (started.isErr) return Err<_StepResult>(started.failureOrNull!);
        if ((started.valueOrNull ?? 0) <= 0) {
          // 宿主说"受理了"却一个回合都没起：用户看到的是流程成功、智能体压根没动。
          // 返回 0 就等于没受理，必须按失败处理（三态闭集：不许"看起来成功"）。
          return Outcome.err<_StepResult>(
            code: PluginFailureKind.runtimeError,
            message: '交接给智能体了，但它一个回合都没开始',
            hint: '这是宿主 startAgent 的实现问题（受理了就必须起回合）；先确认对话页没被占用',
          );
        }
        return Ok<_StepResult>(_StepResult(agentsStartedDelta: started.valueOrNull!));
    }
  }

  /// 提示词由声明给（`promptFile` → descriptor.promptText），占位符按语义替换。
  ///
  /// 替换来源三层（后者覆盖前者）：步骤 `params` → `ask_params` 当场问到的值 → 用户输入。
  /// 有了第二层，`prompt.md` 里才能写 `{{count}}` 这种"运行时才知道"的东西
  /// （实例 C 中英默写卡就是这么用"要几张卡"的）。
  String _renderPrompt(
    String? promptText,
    String userInstruction,
    Map<String, dynamic> params, [
    Map<String, Object?> asked = const {},
  ]) {
    var s = promptText ?? (params['system'] as String?) ?? '';
    s = s.replaceAll('{{userInstruction}}', userInstruction.isEmpty ? '无' : userInstruction);
    for (final e in params.entries) {
      if (e.key == 'promptFile') continue;
      s = s.replaceAll('{{${e.key}}}', '${e.value}');
    }
    for (final e in asked.entries) {
      final v = e.value;
      s = s.replaceAll('{{${e.key}}}', v is num ? formatCount(v) : '$v');
    }
    return s;
  }

  Future<Outcome<String>> _completeText(PluginCtx ctx, String system, String user, int? maxTokens) async {
    final c = ctx.capabilities.require<LlmComplete>(ServiceKeys.llmComplete);
    if (c.isErr) {
      // 作者最容易踩的坑：没图时引擎走纯文本补全，但插件只声明了 llm:vision。
      final f = c.failureOrNull!;
      return Err<String>(PluginFailure(
        code: f.code,
        message: f.message,
        hint: '这一步没有图片，要用文本补全：在 manifest.permissions 里加 "llm:chat"，'
            '或把 capture 步排在它前面',
        pluginId: ctx.manifest.id,
        cause: f.cause,
      ));
    }
    return c.valueOrNull!.complete(systemPrompt: system, userText: user, maxTokens: maxTokens, cancelToken: ctx.cancelToken);
  }

  Future<Outcome<String>> _completeVision(
      PluginCtx ctx, String system, String user, List<String> images, int? maxTokens) async {
    final c = ctx.capabilities.require<LlmVision>(ServiceKeys.llmVision);
    if (c.isErr) return Err<String>(c.failureOrNull!);
    return c.valueOrNull!
        .completeWithImage(systemPrompt: system, userText: user, imagePaths: images, maxTokens: maxTokens, cancelToken: ctx.cancelToken);
  }

  List<String> _linesOf(List<ExtractedItem> items, Map<String, dynamic> params, PluginCtx ctx) {
    final repeat = (params['repeatPerItem'] as num?)?.toInt() ?? 1;
    final withNote = params['withNote'] ?? ctx.boolConfig('readChinese', true);
    final out = <String>[];
    for (final e in items) {
      for (var r = 0; r < repeat.clamp(1, 5); r++) {
        out.add(e.text);
      }
      if (withNote == true && e.note.isNotEmpty) out.add(e.note);
    }
    return out;
  }

  List<String>? _stringList(Object? v) =>
      v is List ? [for (final e in v) '$e'.trim()].where((e) => e.isNotEmpty).toList() : null;

  String _summary(FlowMeta flow, _State st, int done, int skippedCount) {
    final head = flow.name.isEmpty ? '流程' : flow.name;
    // 交付过的东西**必须出现在回执里**：「完成 3 步」没有任何一样能拿去核对，
    // 用户不知道文件叫什么、在不在。改写过名字的更要当场说破。
    final tail = st.exported.isEmpty
        ? ''
        : '；已导出 ${st.exported.map((e) => e.fileName).join('、')}'
            '${_renameNote(st.exported)}';
    if (st.items.isNotEmpty) {
      final played = st.values['played'];
      if (played is int) return '$head：念了 $played 条（共 ${st.items.length} 条）$tail';
      return '$head：${st.items.length} 条$tail';
    }
    return '$head：完成 $done 步${skippedCount == 0 ? '' : '，跳过 $skippedCount 步'}$tail';
  }

  /// 名字被宿主改写过就说破（原名 → 真名）：悄悄改名是"我明明叫这个"那类困惑的来源。
  String _renameNote(List<ExportReceipt> receipts) {
    final changed = receipts.where((e) => e.renamedFrom != null && e.renamedFrom != e.fileName).toList();
    if (changed.isEmpty) return '';
    return '（文件名被改写过：${changed.map((e) => '"${e.renamedFrom}" → "${e.fileName}"').join('，')}）';
  }
}

final class _StepResult {
  const _StepResult({this.agentsStartedDelta = 0});
  final int agentsStartedDelta;
}

