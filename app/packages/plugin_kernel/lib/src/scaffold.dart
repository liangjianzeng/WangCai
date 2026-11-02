/// 脚手架（P3 作者体验）—— **只生成文本，不碰文件系统**。
///
/// 为什么放在内核而不是 app 的 `tool/`：生成物必须**当场能被自己的校验器判合格**，
/// 这件事要能在离线测试里钉住（`test/scaffold_test.dart`）。
/// 落盘由调用方做（app 的 `tool/plugins.dart`），内核保持纯 Dart。
///
/// 三条设计决定：
/// 1. `plugin.json` 由 [PluginManifest.toJson] 生成，**不手拼字符串** —— 生成器与解析器同源，永不漂移；
/// 2. 生成的模板**默认就合规**（权限齐全、贡献物挂了 effect、await 后复查取消令牌），
///    因为作者的第一份代码就是他的行为范本；
/// 3. 生成后立即自检（[selfCheckGenerated]），不合格就报错 —— 绝不发一个"跑不起来"的骨架给人。
library;

import 'dart:convert';

import 'package:plugin_sdk/plugin_sdk.dart';

enum ScaffoldKind { declarative, dart }

/// 一次脚手架请求。默认值就是「抽取 → 按间隔朗读」这套经过验证的形状（听写实例的骨架）。
final class ScaffoldSpec {
  ScaffoldSpec({
    required this.id,
    required this.name,
    required this.description,
    this.kind = ScaffoldKind.declarative,
    this.whenToUse = '',
    this.icon = 'icons.auto_stories_outlined',
    this.inject = const ['app.capture', 'llm.vision', 'app.interact', 'app.speak', 'app.store'],
    this.permissions = const [
      PluginPermission.camera,
      PluginPermission.photoLibrary,
      PluginPermission.llmVision,
      PluginPermission.speechSynthesis,
      PluginPermission.pluginStorage,
      // speak_sequence 隐含 network（Edge-TTS 要联网）—— 漏了它模板自己就过不了校验。
      PluginPermission.network,
    ],
    this.params,
    this.phases,
    this.steps,
    this.promptBody,
    this.ownerDataHint = '',
  });

  final String id;
  final String name;
  final String description;
  final ScaffoldKind kind;
  final String whenToUse;
  final String icon;
  final List<String> inject;
  final List<PluginPermission> permissions;
  final List<PluginParam>? params;
  final List<FlowPhase>? phases;
  final List<FlowStep>? steps;
  final String? promptBody;

  /// 给作者的注释性提示（写进 README，说明这个插件准备填哪个槽）。
  final String ownerDataHint;

  /// 生成用的 manifest（唯一真相：`plugin.json` 由它 toJson 出来）。
  PluginManifest manifest() => PluginManifest(
        id: id,
        name: name,
        description: description,
        whenToUse: whenToUse.isEmpty ? '需要「$name」时用' : whenToUse,
        icon: icon,
        trust: kind == ScaffoldKind.declarative ? PluginTrust.declarative : PluginTrust.trusted,
        inject: inject,
        permissions: permissions,
        params: params ?? defaultParams(),
        config: const {'gapSeconds': 5},
        flow: kind == ScaffoldKind.declarative ? flow() : null,
        promptFile: kind == ScaffoldKind.declarative ? 'prompt.md' : '',
      );

  /// 可编辑参数的默认集：`askAtStart` 的「间隔几秒」+ 一个易变值示范（易变值不算配置变更）。
  static List<PluginParam> defaultParams() => const [
        PluginParam(
          name: 'gapSeconds',
          label: '间隔秒数',
          type: PluginParamType.number,
          defaultValue: 5,
          min: 1,
          max: 60,
          step: 1,
          description: '每条之间等多久',
          askAtStart: true,
        ),
        PluginParam(
          name: 'readChinese',
          label: '念中文释义',
          type: PluginParamType.boolean,
          defaultValue: true,
        ),
        PluginParam(
          name: 'lastGapSeconds',
          label: '上次用的间隔',
          type: PluginParamType.number,
          defaultValue: 5,
          volatile: true,
        ),
      ];

  FlowMeta flow() => FlowMeta(
        name: id,
        description: description,
        whenToUse: whenToUse.isEmpty ? '需要「$name」时用' : whenToUse,
        phases: phases ??
            const [
              FlowPhase(id: 'pick', title: '取材'),
              FlowPhase(id: 'extract', title: '抽取'),
              FlowPhase(id: 'run', title: '逐条朗读'),
            ],
        steps: steps ??
            const [
              FlowStep(id: 'capture', op: FlowStepOp.capture, phase: 'pick'),
              FlowStep(
                id: 'extract',
                op: FlowStepOp.llmExtract,
                phase: 'extract',
                params: {'promptFile': 'prompt.md'},
                onFailure: FlowStepFailure.abort,
              ),
              FlowStep(id: 'review', op: FlowStepOp.review, phase: 'extract'),
              FlowStep(id: 'ask', op: FlowStepOp.askParams, phase: 'run'),
              FlowStep(id: 'speak', op: FlowStepOp.speakSequence, phase: 'run'),
            ],
      );
}

/// 生成物：相对路径 → 文件内容。
Map<String, String> generatePluginFiles(ScaffoldSpec spec) {
  switch (spec.kind) {
    case ScaffoldKind.declarative:
      return {
        'plugin.json': const JsonEncoder.withIndent('  ').convert(spec.manifest().toJson()),
        'prompt.md': spec.promptBody ?? _defaultPrompt(spec),
        'README.md': _readme(spec, '声明式（只写 plugin.json + prompt.md，零 Dart）'),
      };
    case ScaffoldKind.dart:
      final file = '${_snake(spec.id)}_plugin.dart';
      return {
        file: dartSource(spec),
        'README.md': _readme(spec, '命令式（Dart 实现 AppPlugin）'),
      };
  }
}

/// 生成后立即自检（**作者拿到的第一份代码必须当场合格**）。
///
/// 返回生成的文件清单；发现问题就返回 Err，CLI 据此拒绝写盘。
Outcome<List<String>> selfCheckGenerated(
  Map<String, String> files, {
  Set<String>? knownCapabilityIds,
}) {
  // 默认按契约全集判（本机还没装的能力不该让脚手架拒绝生成 —— 那是门控的事）。
  final known = knownCapabilityIds ?? kKnownCapabilityIds;
  final names = files.keys.toList()..sort();
  final json = files['plugin.json'];
  if (json != null) {
    final report = validateManifestText(json, knownCapabilityIds: known);
    if (!report.ok) {
      final detail = report.errors.map((i) => '${i.path}：${i.message}').join('；');
      return Err<List<String>>(PluginFailure(
        code: PluginFailureKind.configInvalid,
        message: '生成的 plugin.json 没通过校验',
        hint: _clip(detail, 118),
      ));
    }
  }
  for (final e in files.entries) {
    if (!e.key.endsWith('.dart')) continue;
    final missing = <String>[
      if (!e.value.contains('ctx.effect(')) 'ctx.effect(贡献物注册没挂回收，禁用后会留幽灵)',
      if (!e.value.contains('Outcome<')) 'Outcome（插件不许 throw）',
      if (!e.value.contains('throwIfCancelled')) 'await 边界的取消令牌复查',
      if (e.value.contains('throw ')) '出现了 throw（一律返回 Outcome）',
    ];
    if (missing.isNotEmpty) {
      return Err<List<String>>(PluginFailure(
        code: PluginFailureKind.configInvalid,
        message: '生成的 ${e.key} 不符合作者纪律',
        hint: missing.join('；'),
      ));
    }
  }
  return Ok<List<String>>(names);
}

String _defaultPrompt(ScaffoldSpec spec) => '''
你是教材内容识别器。从图片中按**原始排版顺序**抽取需要练习的条目。

只输出一个 JSON 对象，不要解释、不要代码围栏：
{"items":[{"text":"apple","note":"苹果","unit":"Unit 3"}]}

规则：
1. 顺序 = 课本出现顺序，不得重排、不得按字母排序。
2. 只抽条目本身。排除：例句整句、对话、页眉页脚、题号、音标注音。
3. 看不清或不确定的条目**不要猜、不要补**，直接不输出。
4. 不输出图片里没有的内容，禁止用常见词表补全。

【附加要求】（来自用户，优先级最高）
{{userInstruction}}

—— 这是 ${spec.name} 的提示词脚手架，把上面几段改成你的场景即可（${spec.id}）。
''';

String _readme(ScaffoldSpec spec, String kindText) => '''
# ${spec.name}（`${spec.id}`）

${spec.description}

形态：**$kindText**

## 怎么让它跑起来

- 声明式：把整个目录推到手机的 `文档/plugins/${spec.id}/`，
  设置 → 插件 里「重新扫描」并打开开关即可（不需要改 app 一行代码）。
  ```bash
  adb push ./plugins/${spec.id} /storage/emulated/0/Android/data/<包名>/documents/plugins/
  ```
- 命令式：把生成的 `.dart` 放进 `lib/plugins/builtin/${spec.id}/`，
  并在 `lib/plugins/plugin_host.dart` 的 `builtin.register(...)` 旁边加一行注册。

## 先自检再装机

```bash
dart run tool/plugins.dart validate ./plugins/${spec.id}
dart run tool/plugins.dart scan --plugins-dir ./plugins
```

## 作者纪律（7 条，违反会被 conformance 套件当场拦）

1. 永不 `throw`，一律返回 `Outcome`；
2. `apply()` 里只注册贡献物，不调能力、不做 IO；
3. 每个注册必须 `ctx.effect(...)`；
4. 每个 await 之后复查 `ctx.cancelToken`；
5. 先 `isAvailable` 再 `require`，把 `unavailableReason` 说给用户；
6. 只在自己的 `${spec.id}.*` 命名空间声明槽；
7. 用户可见文案 `message` ≤ 120 字、说人话，技术细节进 `cause`。

${spec.ownerDataHint.isEmpty ? '' : '## 备注\n\n${spec.ownerDataHint}\n'}
''';

/// 命令式插件骨架（默认填 `app.input.right`，并示范自己的槽）。
String dartSource(ScaffoldSpec spec) {
  final cls = _pascal(spec.id);
  return '''
/// ${spec.name}（`${spec.id}`）—— 由 tool/plugins.dart scaffold 生成。
///
/// 方向纪律：这里只准 import `plugin_kernel`（+ 本目录），
/// 不碰 screens/providers/agent/tts/services —— 架构门会当场拦住。
library;

import 'package:plugin_kernel/plugin_kernel.dart';

final class ${cls}Plugin implements AppPlugin {
  static const PluginManifest manifestDef = PluginManifest(
    id: '${spec.id}',
    name: '${spec.name}',
    description: '${spec.description}',
    whenToUse: '${spec.whenToUse.isEmpty ? '需要「${spec.name}」时用' : spec.whenToUse}',
    inject: [${spec.inject.map((e) => "'$e'").join(', ')}],
    permissions: [${spec.permissions.map((e) => 'PluginPermission.${e.name}').join(', ')}],
    trust: PluginTrust.trusted,
    params: [
      PluginParam(
        name: 'gapSeconds',
        label: '间隔秒数',
        type: PluginParamType.number,
        defaultValue: 5,
        min: 1,
        max: 60,
        askAtStart: true,
      ),
    ],
  );

  @override
  PluginManifest get manifest => manifestDef;

  @override
  Outcome<Disposable?> apply(PluginCtx ctx) {
    // apply 只注册、不做任何能力调用（conformance 的「生命周期」组数得出来）；
    // 但**要先声明能力齐不齐** —— 缺就当场失败，面板显示"缺：xxx"，别等 run 才炸。
    final ready = ensureDeclaredCapabilities(ctx);
    if (ready.isErr) return Err<Disposable?>(ready.failureOrNull!);

    final ownSlot = ctx.slots.declare(const SlotDef(
      id: '${spec.id}.action',
      kind: SlotKind.list,
      scope: SlotScope.session,
      ownerPluginId: '${spec.id}',
      description: '本插件自己的动作位（别人也可以来填）',
    ));
    if (ownSlot.isErr) return Err<Disposable?>(ownSlot.failureOrNull!);

    final chip = ctx.slots.register(SlotContribution<Object?>(
      slotId: 'app.input.right',
      pluginId: ctx.manifest.id,
      id: 'chip',
      label: '${spec.name}',
      payload: '${spec.name}',
    ));
    if (chip.isErr) return Err<Disposable?>(chip.failureOrNull!);

    // 贡献物必须挂进 effect，否则关掉插件后槽里留幽灵。
    ctx.effect(chip.valueOrNull!);
    return const Ok<Disposable?>(null);
  }

  @override
  Future<Outcome<PluginRunResult>> run(PluginCtx ctx, PluginInput input) async {
    // ① 先判可用性再取，把"本机没有"的原因原样转达（别静默失败）。
    if (!ctx.capabilities.isAvailable(ServiceKeys.speak.id)) {
      return Outcome.err<PluginRunResult>(
        code: PluginFailureKind.missingCapability,
        message: '${spec.name}需要朗读能力，本机还没有',
        hint: ctx.capabilities.unavailableReason(ServiceKeys.speak.id) ?? '检查朗读相关设置',
        pluginId: ctx.manifest.id,
      );
    }
    final speak = ctx.capabilities.require<Speak>(ServiceKeys.speak);
    if (speak.isErr) return Err<PluginRunResult>(speak.failureOrNull!);

    final gap = ctx.numberConfig('gapSeconds', 5);
    final items = _itemsOf(input);
    if (items.isEmpty) {
      return Outcome.err<PluginRunResult>(
        code: PluginFailureKind.badContent,
        message: '没有可朗读的内容',
        hint: '先选一张图或输入要念的内容',
        pluginId: ctx.manifest.id,
      );
    }

    // ② 朗读交给能力：间隔/合成/播放都在 Speak 内部（含"播完再等"），
    //    插件只消费进度流 —— 自己 sleep 会和能力的 gap 叠加成双倍间隔（作者常犯的错）。
    final stream = speak.valueOrNull!.speak(
      SpeakRequest(
        items: items,
        voice: ctx.stringConfig('voice', ''),
        gap: Duration(seconds: gap.round()),
      ),
      ctx.cancelToken,
    );
    var done = 0;
    final skipped = <String>[];
    await for (final progress in stream) {
      // 每个 await 边界都复查取消：用户按停止必须真停得下来。
      ctx.cancelToken.throwIfCancelled();
      switch (progress.phase) {
        case SpeakPhase.playing:
          done += 1;
        case SpeakPhase.skipped:
          // 个别条目念不成不中断整场，最后一起报给用户。
          skipped.add(progress.text);
        case SpeakPhase.synthesizing:
        case SpeakPhase.gap:
          break;
      }
    }

    // ③ 被用户中途停掉：如实报"停在哪"，但不写易变值、不报喜（userVisible=false 由调用方决定显不显示）。
    if (ctx.cancelToken.isCancelled) {
      return Ok<PluginRunResult>(PluginRunResult(
        summary: '已停止（读到第 \$done 条）',
        data: {'count': done, 'skipped': skipped},
        userVisible: false,
      ));
    }

    // ④ 记下易变值（volatile 参数不算配置变更，不会诱发重载）。
    final store = ctx.capabilities.isAvailable(ServiceKeys.store.id)
        ? ctx.capabilities.require<Store>(ServiceKeys.store)
        : null;
    if (store != null && store.isOk) {
      await store.valueOrNull!.write('lastGapSeconds', '\$gap');
    }

    ctx.log.info('读完 \${done}/\${items.length} 条（间隔 \${gap}s，入口 \${input.entry.name}）');
    final tail = skipped.isEmpty ? '' : '，\${skipped.length} 条没念成';
    return Ok<PluginRunResult>(
      PluginRunResult(summary: '读完 \$done 条\$tail', data: {'count': done, 'skipped': skipped}),
    );
  }

  /// 入口内容：优先 args 里的显式列表，其次把 text 按分隔拆开。
  static List<String> _itemsOf(PluginInput input) {
    final fromArgs = input.args['items'];
    if (fromArgs is List) {
      return [for (final e in fromArgs) '\$e'.trim()].where((e) => e.isNotEmpty).toList();
    }
    return input.text
        .split(RegExp(r'[、,，;；\n]'))
        .map((e) => e.trim())
        .where((e) => e.isNotEmpty)
        .toList();
  }
}
''';
}

String _clip(String value, int max) => value.length <= max ? value : value.substring(0, max) + '…';

String _snake(String id) => id.replaceAll('-', '_');

String _pascal(String id) => id
    .split(RegExp(r'[-_]'))
    .where((s) => s.isNotEmpty)
    .map((s) => s[0].toUpperCase() + s.substring(1))
    .join();
