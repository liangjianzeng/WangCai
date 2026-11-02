/// 验收实例 A —— 英语听写（`en-dictation`）。
///
/// 它是**平台的第一块试金石**：整个文件只用 manifest + 能力 + 槽，
/// 不 import 任何宿主内部（架构门 B/C 当场盯着），也不给听写开任何专用通道
/// （§5.0 六条平台中立性自检）。听写能跑通 = 平台真的能装下"拍照→抽取→校对→逐条朗读"
/// 这类需求；下次用户提"我要中文生字听写"，应该是再写一个这样的目录，而不是改这里。
library;

import 'package:flutter/material.dart';
import 'package:plugin_kernel/plugin_kernel.dart';

import '../../plugin_input_icon.dart';
import '../../slot_outlet.dart';

/// 抽词提示词。声明式插件放 `prompt.md`，内置插件直接内联（同一份文案口径）。
const String _extractPrompt = '''
你是教材内容识别器。从图片中按**原始排版顺序**抽取需要听写的单词或短语。

只输出一个 JSON 对象，不要解释、不要代码围栏：
{"items":[{"text":"apple","note":"苹果","unit":"Unit 3"}]}

规则：
1. 顺序 = 课本出现顺序，不得重排、不得按字母排序。
2. 只抽词条本身。排除：例句整句、对话、页眉页脚、题号、音标、词性标注。
3. 看不清或不确定的条目**不要猜、不要补**，直接不输出。
4. 不输出图片里没有的内容，禁止用常见词表补全。

【附加要求】（来自用户，优先级最高）
{{userInstruction}}
''';

final class EnglishDictationPlugin implements AppPlugin {
  static const PluginManifest manifestDef = PluginManifest(
    id: 'en-dictation',
    name: '英语听写',
    description: '拍课本上的单词表，按间隔逐个朗读听写',
    whenToUse: '用户想听写/默写课本单词、需要拍照取词并按间隔播报时',
    icon: 'icons.graphic_eq_outlined',
    // 装完就出现在输入区，不用先进设置打开 —— 验收件如果默认关着，用户根本看不见入口
    // （2026-10-24 实测就是这个坑）。用户手动关掉过就**不再自动打开**（内核按 firstTimeSeen 记账）。
    enabledByDefault: true,
    inject: ['app.capture', 'llm.vision', 'app.interact', 'app.speak', 'app.store'],
    permissions: [
      PluginPermission.camera,
      PluginPermission.photoLibrary,
      PluginPermission.llmVision,
      PluginPermission.speechSynthesis,
      PluginPermission.network,
      PluginPermission.pluginStorage,
    ],
    trust: PluginTrust.trusted,
    params: [
      PluginParam(
        name: 'gapSeconds',
        label: '间隔秒数',
        type: PluginParamType.number,
        defaultValue: 5,
        min: 1,
        max: 60,
        step: 1,
        description: '念完一个词之后等多久再念下一个',
        askAtStart: true,
      ),
      PluginParam(
        name: 'repeatTimes',
        label: '每个词念几遍',
        type: PluginParamType.number,
        defaultValue: 1,
        min: 1,
        max: 3,
        step: 1,
      ),
      PluginParam(
        name: 'readChinese',
        label: '念中文释义',
        type: PluginParamType.boolean,
        defaultValue: true,
        description: '念完英文再念一遍中文，帮助确认没听错',
      ),
      PluginParam(
        name: 'voice',
        label: '音色',
        type: PluginParamType.text,
        defaultValue: '',
        description: '留空 = 按词条语言自动选（英文词走英文音色）',
      ),
      PluginParam(
        name: 'lastList',
        label: '上次听写内容',
        type: PluginParamType.text,
        defaultValue: '',
        volatile: true,
      ),
    ],
  );

  @override
  PluginManifest get manifest => manifestDef;

  @override
  Outcome<Disposable?> apply(PluginCtx ctx) {
    final ready = ensureDeclaredCapabilities(ctx);
    if (ready.isErr) return Err<Disposable?>(ready.failureOrNull!);

    // 输入区右侧图标位（宿主契约槽，插件不许声明宿主命名空间）。
    final chip = ctx.slots.register(SlotContribution<Object?>(
      slotId: 'app.input.right',
      pluginId: ctx.manifest.id,
      id: 'chip',
      label: '英语听写',
      payload: const _DictationChip(),
      priority: 30,
    ));
    if (chip.isErr) return Err<Disposable?>(chip.failureOrNull!);

    // 播报中的状态条：只在有上次记录时露一行，不抢输入区。
    final activity = ctx.slots.register(SlotContribution<Object?>(
      slotId: 'app.input.activity',
      pluginId: ctx.manifest.id,
      id: 'activity',
      label: '上次听写',
      payload: const _LastListLine(),
      priority: 20,
    ));
    if (activity.isErr) return Err<Disposable?>(activity.failureOrNull!);

    // 注册必须挂进 effect，否则关掉插件后图标变幽灵。
    ctx.effect(chip.valueOrNull!);
    ctx.effect(activity.valueOrNull!);
    return const Ok<Disposable?>(null);
  }

  @override
  Future<Outcome<PluginRunResult>> run(PluginCtx ctx, PluginInput input) async {
    final ctxErr = _guard(ctx);
    if (ctxErr != null) return Err<PluginRunResult>(ctxErr);

    // ① 取材：入口带了图就用它（用户已经选好了），否则先问一句"拍照还是从相册选"。
    //    以前这里写死 `preferCamera: true`，真机第一句反馈就是**没法从相册选图** ——
    //    课本单词表九成是早就拍好躺在相册里的照片，只给拍照等于不能用（2026-10-24 用户实测）。
    //    问句走 `app.interact`（平台既有能力，宿主换 UI 插件不用改），插件自己不弹框。
    var imagePaths = input.imagePaths;
    if (imagePaths.isEmpty) {
      final cap = ctx.capabilities.require<Capture>(ServiceKeys.capture);
      if (cap.isErr) return Err<PluginRunResult>(cap.failureOrNull!);
      final picker = ctx.capabilities.require<Interact>(ServiceKeys.interact);
      if (picker.isErr) return Err<PluginRunResult>(picker.failureOrNull!);
      final how = await picker.valueOrNull!.askChoice(
        question: '单词表怎么取？',
        options: const ['拍照', '从相册选'],
      );
      if (how.isErr) return Err<PluginRunResult>(how.failureOrNull!);
      if (how.valueOrNull == null) {
        // 问句里点取消：与"拍一半放弃"同口径 —— 空，不是错误。
        return Ok<PluginRunResult>(PluginRunResult(summary: '没选图，已取消', userVisible: false));
      }
      if (ctx.cancelToken.isCancelled) return _stopped();
      final preferCamera = how.valueOrNull == '拍照';
      var picked = await cap.valueOrNull!.pickImages(maxCount: 3, preferCamera: preferCamera);
      // 相机权限被拒不把用户堵死：同一次取材兜一次相册（不再问第二遍，也不假装成功）。
      if (preferCamera &&
          picked.isErr &&
          picked.failureOrNull!.code == PluginFailureKind.permissionDenied) {
        picked = await cap.valueOrNull!.pickImages(maxCount: 3, preferCamera: false);
      }
      if (picked.isErr) return Err<PluginRunResult>(picked.failureOrNull!);
      imagePaths = picked.valueOrNull!;
      if (imagePaths.isEmpty) {
        return Ok<PluginRunResult>(PluginRunResult(summary: '没选图，已取消', userVisible: false));
      }
    }
    if (ctx.cancelToken.isCancelled) return _stopped();

    // ② 抽取：一次性带图补全（不进聊天上下文、不带工具，见 §5.4）。
    final vision = ctx.capabilities.require<LlmVision>(ServiceKeys.llmVision);
    if (vision.isErr) return Err<PluginRunResult>(vision.failureOrNull!);
    final instruction = input.text.trim();
    final raw = await vision.valueOrNull!.completeWithImage(
      systemPrompt: _extractPrompt.replaceAll('{{userInstruction}}', instruction.isEmpty ? '无' : instruction),
      userText: instruction.isEmpty ? '请按规则抽取图片里的听写词条。' : instruction,
      imagePaths: imagePaths,
      maxTokens: 1200,
      cancelToken: ctx.cancelToken,
    );
    if (raw.isErr) return Err<PluginRunResult>(raw.failureOrNull!);
    if (ctx.cancelToken.isCancelled) return _stopped();

    final words = parseWords(raw.valueOrNull!);
    if (words.isEmpty) {
      final said = raw.valueOrNull!.trim();
      final peek = said.length <= 90 ? said : '${said.substring(0, 90)}…';
      return Outcome.err<PluginRunResult>(
        code: PluginFailureKind.badContent,
        message: '图里没认出单词',
        // 把**模型到底回了什么**贴在 hint 上：只说"没认出"，用户无从分辨是拍糊了、
        // 模型不肯按 JSON 回、还是这张图本来就没单词
        // ——2026-10-24 真机"一直报没能提取"就是卡在这种无信息的红条上。
        hint: '把单词表拍正、拍全（别逆光、别只拍半页）。模型回的是：'
            '${peek.isEmpty ? '（空回复）' : peek}',
        pluginId: ctx.manifest.id,
      );
    }

    // ③ 校对：抽多了/抽错了让用户当场决定，而不是硬着头皮念。
    final interact = ctx.capabilities.require<Interact>(ServiceKeys.interact);
    if (interact.isErr) return Err<PluginRunResult>(interact.failureOrNull!);
    final preview = words.take(6).map((w) => w.text).join('、') + (words.length > 6 ? ' …' : '');
    final verdict = await interact.valueOrNull!.askChoice(
      // 提问复用宿主既有的 ask_user 通道（HostInteract），不造第二套提问机制。
      question: '抽到 ${words.length} 个词：$preview',
      options: const ['开始听写', '只念英文', '算了'],
    );
    if (verdict.isErr) return Err<PluginRunResult>(verdict.failureOrNull!);
    final choice = verdict.valueOrNull;
    if (choice == null || choice == '算了') {
      return Ok<PluginRunResult>(PluginRunResult(summary: '没听写，已取消', userVisible: false));
    }
    if (ctx.cancelToken.isCancelled) return _stopped();

    // ④ 排条：英文（可重复）+ 可选中文释义。间隔交给 Speak，插件绝不自己 sleep。
    final readChinese = choice == '开始听写' && ctx.boolConfig('readChinese', true);
    final repeat = ctx.numberConfig('repeatTimes', 1).round().clamp(1, 3);
    final lines = <String>[];
    for (final w in words) {
      for (var r = 0; r < repeat; r++) {
        lines.add(w.text);
      }
      if (readChinese && w.note.isNotEmpty) lines.add(w.note);
    }

    final gap = ctx.numberConfig('gapSeconds', 5);
    final speak = ctx.capabilities.require<Speak>(ServiceKeys.speak);
    if (speak.isErr) return Err<PluginRunResult>(speak.failureOrNull!);

    final stream = speak.valueOrNull!.speak(
      SpeakRequest(
        items: lines,
        voice: ctx.stringConfig('voice', ''),
        gap: Duration(seconds: gap.round()),
      ),
      ctx.cancelToken,
    );
    var played = 0;
    final failed = <String>[];
    await for (final p in stream) {
      if (ctx.cancelToken.isCancelled) break; // 停了就收工，剩下交给下面的"已停止"汇总
      switch (p.phase) {
        case SpeakPhase.playing:
          played += 1;
        case SpeakPhase.skipped:
          failed.add(p.text);
        case SpeakPhase.synthesizing:
        case SpeakPhase.gap:
          break;
      }
    }

    // ⑤ 记账（易变值，不算配置变更）：下次进来能看到"上次念了哪些"。
    final store = ctx.capabilities.require<Store>(ServiceKeys.store);
    if (store.isOk && !ctx.cancelToken.isCancelled) {
      await store.valueOrNull!
          .write('lastList', words.map((w) => '${w.text}=${w.note}').join('、'));
    }

    final tail = failed.isEmpty ? '' : '，${failed.length} 个没念成';
    final head = ctx.cancelToken.isCancelled ? '已停止' : '念完';
    ctx.log.info('听写 ${words.length} 词（间隔 ${formatCount(gap)}s，念 $played 条）');
    return Ok<PluginRunResult>(PluginRunResult(
      summary: '$head ${words.length} 个词'
          '（每条 ${formatCount(gap)}s${readChinese ? '，含中文' : ''}）$tail',
      data: {
        'words': [for (final w in words) {'text': w.text, 'note': w.note}],
        'played': played,
        'failed': failed,
      },
    ));
  }

  /// 用户中途取消：正常终态（不报失败、不弹喜报）。
  Ok<PluginRunResult> _stopped() => Ok<PluginRunResult>(
        PluginRunResult(summary: '已取消', data: const {'cancelled': true}, userVisible: false),
      );

  /// 能力齐不齐（缺就当场给一句话，别等跑到一半炸）。
  PluginFailure? _guard(PluginCtx ctx) {
    final ready = ensureDeclaredCapabilities(ctx);
    return ready.failureOrNull;
  }
}

/// 一个听写条目。
final class WordItem {
  const WordItem(this.text, this.note);
  final String text;
  final String note;

  @override
  String toString() => note.isEmpty ? text : '$text($note)';
}

/// 容错解析模型输出：**解析口径由 SDK 统一**（`extractItems`），
/// 声明式 flow 与手写插件因此永远得到同样的结果 —— 两边各写一份必然漂移。
List<WordItem> parseWords(String modelOutput) =>
    [for (final e in extractItems(modelOutput)) WordItem(e.text, e.note)];

/// 输入区图标（点击开跑）。payload 是 Widget 时由 [SlotOutlet] 直接渲染。
final class _DictationChip extends StatelessWidget {
  const _DictationChip();

  @override
  Widget build(BuildContext context) {
    final dispatcher = PluginDispatcherScope.of(context);
    // 外壳用宿主的 `PluginInputIcon`：尺寸/密度/间距跟输入区其它功能图标（附件「+」等）一套规矩。
    return PluginInputIcon(
      tooltip: '英语听写（拍照或从相册选，按间隔朗读）',
      icon: Icons.graphic_eq_outlined,
      onPressed: dispatcher == null
          ? null
          : () async {
              final r = await dispatcher.run(
                'en-dictation',
                const PluginInput(entry: PluginEntryKind.composerAction),
              );
              if (!context.mounted) return;
              // 成功/失败都说一句人话，而且**把 hint（下一步）一起显示** —— 只贴 message
              // 就等于把"去开视觉/去加载模型"这些话吞掉（2026-10-24 真机红条无信息的根因）。
              ScaffoldMessenger.of(context).showSnackBar(
                SnackBar(
                  content: Text(r.fold((v) => v.summary, describePluginFailure)),
                  duration: const Duration(seconds: 4),
                ),
              );
            },
    );
  }
}

/// 活动条：显示上次听写的词表（只读，不抢输入区）。
final class _LastListLine extends StatelessWidget {
  const _LastListLine();

  @override
  Widget build(BuildContext context) {
    final dispatcher = PluginDispatcherScope.of(context);
    return FutureBuilder<String?>(
      future: dispatcher?.readPluginValue('en-dictation', 'lastList'),
      builder: (context, snap) {
        final v = snap.data;
        if (v == null || v.isEmpty) return const SizedBox.shrink();
        return Padding(
          padding: const EdgeInsets.symmetric(horizontal: 4, vertical: 2),
          child: Text(
            '上次听写：$v',
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            style: Theme.of(context).textTheme.bodySmall,
          ),
        );
      },
    );
  }
}
