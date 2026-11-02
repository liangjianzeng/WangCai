import 'dart:async';

import 'package:plugin_kernel/plugin_kernel.dart';
import 'package:plugin_sdk/testing.dart';
import 'package:test/test.dart';

/// flow 引擎（P5）的行为钉死。
///
/// 这块是"作者不写一行 Dart 也能做插件"的全部风险所在：解释器一松，
/// 声明式插件就能变成"看起来跑完了其实什么都没干"。所以每条纪律都单独有用例。
const _reply = '{"items":[{"text":"苹果","note":"píng guǒ"},{"text":"香蕉","note":"xiāng jiāo"}]}';

FlowMeta _meta({List<FlowStep>? steps, String name = '生字听写'}) => FlowMeta(
      name: name,
      description: 'd',
      whenToUse: '用户要听写生字时',
      phases: const [FlowPhase(id: 'p1', title: '取材'), FlowPhase(id: 'p2', title: '播报')],
      steps: steps ??
          const [
            FlowStep(id: 'shoot', op: FlowStepOp.capture, phase: 'p1'),
            FlowStep(id: 'pick', op: FlowStepOp.llmExtract, phase: 'p1', params: {'maxTokens': 800}),
            FlowStep(id: 'confirm', op: FlowStepOp.review, phase: 'p1'),
            FlowStep(id: 'setup', op: FlowStepOp.askParams, phase: 'p1', params: {'names': ['gapSeconds']}),
            FlowStep(id: 'say', op: FlowStepOp.speakSequence, phase: 'p2'),
            FlowStep(id: 'keep', op: FlowStepOp.store, phase: 'p2', params: {'key': 'lastList'}),
          ],
    );

PluginManifest _manifest({List<PluginParam>? params, List<String>? inject, List<PluginPermission>? permissions}) => PluginManifest(
      id: 'zh-dictation',
      name: '中文生字听写',
      description: '拍语文课本的生字表，按间隔朗读',
      whenToUse: '用户要听写语文生字时',
      icon: 'icons.menu_book_outlined',
      trust: PluginTrust.declarative,
      inject: inject ??
          const ['app.capture', 'llm.vision', 'app.interact', 'app.speak', 'app.store'],
      permissions: permissions ??
          const [
            PluginPermission.camera,
            PluginPermission.photoLibrary,
            PluginPermission.llmVision,
            PluginPermission.llmChat, // 用户直接把词表打出来（无图）时走纯文本补全
            PluginPermission.fileExport,
            PluginPermission.speechSynthesis,
            PluginPermission.network,
            PluginPermission.pluginStorage,
          ],
      params: params ??
          const [
            PluginParam(
              name: 'gapSeconds',
              label: '间隔秒数',
              type: PluginParamType.number,
              defaultValue: 5,
              min: 1,
              max: 60,
              askAtStart: true,
            ),
            PluginParam(name: 'readChinese', label: '念拼音', type: PluginParamType.boolean, defaultValue: true),
          ],
      flow: _meta(),
    );

FakeCapabilityHarness _harness({String vision = _reply, List<String>? images, List<String>? choices, List<double>? numbers}) =>
    FakeCapabilityHarness()
      ..register(FakeCapture(images: images ?? const ['/sdcard/yuwen.jpg']))
      ..register(FakeLlmVision(response: vision))
      // 没图时引擎走纯文本补全（例如用户直接把词表打出来），也要能用。
      ..register(FakeLlmComplete(response: vision))
      ..register(FakeInteract(choices: choices ?? const ['继续'], numbers: numbers ?? const [9]))
      ..register(FakeSpeak(gapCap: const Duration(milliseconds: 1)))
      ..register(FakeStore());

PluginCtx _ctx(PluginManifest m, FakeCapabilityHarness h) => FakePluginCtx(
      manifest: m,
      harness: h,
      config: const {'gapSeconds': 5, 'readChinese': true},
    );

const _runner = FlowRunner();

void main() {
  group('原语参数不许静默失效', () {
    // —— 空清单与空内容的两条守卫：以前只被跑过，没人断过它说了什么 ——
    test('没有可朗读的内容：要说"没有可朗读的内容"，不许默默念个空', () async {
      final h = FakeCapabilityHarness()
        ..register(FakeSpeak(gapCap: const Duration(milliseconds: 1)));
      final flow = _meta(steps: const [FlowStep(id: 'say', op: FlowStepOp.speakSequence, phase: 'p1')]);
      final r = await _runner.run(
        _ctx(_manifest(), h),
        const PluginInput(entry: PluginEntryKind.composerAction),
        flow: flow,
      );
      expect(r.isErr, isTrue, reason: '前面没有抽词步骤，无内容可念就是失败');
      expect(r.failureOrNull?.message, contains('没有可朗读的内容'),
          reason: r.failureOrNull?.message);
      expect((h.byId['app.speak']! as FakeSpeak).requests, isEmpty,
          reason: '不许为了"看起来干了活"去念空串');
    });

    test('ask_params 拿到越界值不许默默采纳（越界 = 宿主实现违约，判词要指到该改的人）', () async {
      // gapSeconds 声明的是 1–60；这个宿主实现偏要返回 900（真机上就是"念一次等 15 分钟"那种故障）。
      final h = FakeCapabilityHarness()
        ..register(FakeCapture())
        ..register(FakeLlmComplete(response: _reply))
        ..register(_BadInteract(900))
        ..register(FakeSpeak(gapCap: const Duration(milliseconds: 1)))
        ..register(FakeStore());
      final flow = _meta(steps: const [
        FlowStep(id: 'pick', op: FlowStepOp.llmExtract, phase: 'p1', params: {'maxTokens': 800}),
        FlowStep(id: 'setup', op: FlowStepOp.askParams, phase: 'p1', params: {'names': ['gapSeconds']}),
        FlowStep(id: 'say', op: FlowStepOp.speakSequence, phase: 'p2'),
      ]);
      final r = await _runner.run(
        _ctx(_manifest(), h),
        const PluginInput(entry: PluginEntryKind.composerAction),
        flow: flow,
      );
      expect(r.isErr, isTrue, reason: '越界的 900 秒绝不能变成朗读间隔');
      expect(r.failureOrNull!.message, contains('900'), reason: '要说清到底拿到了什么值');
      expect(r.failureOrNull!.message, contains('1'), reason: '也要说清允许的区间');
      expect(r.failureOrNull!.hint, contains('宿主实现违约'),
          reason: '判词必须指到该改的那个人：这是**宿主实现违约**（它必须自己钳制），不是插件写错也不是用户填错');
      expect(r.failureOrNull!.hint, contains('必须自己钳制或拒收'),
          reason: '还要说清违约方该干什么，否则平台只是甩锅');
      expect((h.byId['app.speak']! as FakeSpeak).requests, isEmpty, reason: '更不许带着坏值继续往下跑');
    });

    test('agent_handoff 受理了却一个回合都没起 → 算失败（不许"看起来成功"）', () async {
      const runner = FlowRunner(host: FlowHost(startAgent: _zeroStartAgent));
      final h = _harness();
      final r = await runner.run(
        _ctx(_manifest(), h),
        const PluginInput(entry: PluginEntryKind.composerAction),
        flow: _meta(steps: const [
          FlowStep(id: 'hand', op: FlowStepOp.agentHandoff, params: {'prompt': '出 5 道练习题'}),
        ]),
      );
      expect(r.isErr, isTrue, reason: '返回 0 就等于没受理，记成成功是骗用户');
      expect(r.failureOrNull!.message, contains('一个回合都没开始'));
      expect(r.failureOrNull!.hint, contains('startAgent'), reason: '出路要指到实现侧');
    });

    test('review 的 title 必须出现在用户看到的问题里（作者写的话不能半路蒸发）', () async {
      final h = _harness();
      final flow = _meta(steps: const [
        FlowStep(id: 'pick', op: FlowStepOp.llmExtract, phase: 'p1', params: {'maxTokens': 800}),
        FlowStep(id: 'confirm', op: FlowStepOp.review, phase: 'p1', params: {'title': '先看一眼有没有认错的'}),
      ]);
      final r = await _runner.run(
        _ctx(_manifest(), h),
        const PluginInput(entry: PluginEntryKind.composerAction),
        flow: flow,
      );
      expect(r.isOk, isTrue, reason: r.failureOrNull?.message);
      final q = (h.byId['app.interact']! as FakeInteract).lastQuestion!;
      expect(q, contains('先看一眼有没有认错的'), reason: '以前 title 被丢掉，用户只看到"共 N 条"，不知道该确认什么');
      expect(q, contains('共 2 条'), reason: '系统信息也不能被作者的 title 挤掉');
    });

    test('store 在没东西可存时不许报成功（存个空壳 = 用户以为"记住了上次那批"）', () async {
      final h = _harness();
      final flow = _meta(steps: const [
        FlowStep(id: 'keep', op: FlowStepOp.store, phase: 'p2', params: {'key': 'lastList'}),
      ]);
      final r = await _runner.run(
        _ctx(_manifest(), h),
        const PluginInput(entry: PluginEntryKind.composerAction),
        flow: flow,
      );
      expect(r.isErr, isTrue, reason: 'items 与步骤值都是空的，写进去就是个空壳');
      expect(r.failureOrNull!.message, contains('没东西可存'));
      expect(r.failureOrNull!.hint, contains('llm_extract'), reason: '要说下一步做什么');
      expect(h.calls.where((c) => c.capabilityId == 'app.store'), isEmpty, reason: '更不许真去写一个空值');
    });

    test('params.value 显式给了就不算空（作者存固定文本是合法用法）', () async {
      final h = _harness();
      final flow = _meta(steps: const [
        FlowStep(id: 'keep', op: FlowStepOp.store, phase: 'p2', params: {'key': 'tip', 'value': '明天复习第五单元'}),
      ]);
      final r = await _runner.run(
        _ctx(_manifest(), h),
        const PluginInput(entry: PluginEntryKind.composerAction),
        flow: flow,
      );
      expect(r.isOk, isTrue, reason: r.failureOrNull?.message);
      final store = h.byId['app.store']! as FakeStore;
      // 键就是声明里写的那个：`plugin:<id>:` 分域前缀由**宿主的 Store 实现**加（真机侧），
      // 假能力不加前缀 —— 这里断言的是"流程确实把值交出去了"。
      expect(store.data['tip'], '明天复习第五单元');
    });
  });

  group('声明式全流程', () {
    test('拍照→抽取→确认→问间隔→朗读→记账：六步全绿', () async {
      final h = _harness();
      final r = await _runner.run(_ctx(_manifest(), h), const PluginInput(entry: PluginEntryKind.composerAction), flow: _meta());
      expect(r.isOk, isTrue, reason: r.failureOrNull?.message);
      final d = r.valueOrNull!.data;
      expect(d['completedSteps'], ['shoot', 'pick', 'confirm', 'setup', 'say', 'keep']);
      expect(d['skippedSteps'], isEmpty);
      expect(r.valueOrNull!.summary, contains('念了 4 条'), reason: '2 个生字 + 2 条拼音');
      expect(h.calls.map((c) => c.capabilityId).toSet(),
          containsAll(<String>['app.capture', 'llm.vision', 'app.interact', 'app.speak', 'app.store']));
    });

    test('ask_params 的答案覆盖静态配置（问出来的 9 秒说了算，不是默认 5 秒）', () async {
      final h = _harness(numbers: const [9]);
      await _runner.run(_ctx(_manifest(), h), const PluginInput(entry: PluginEntryKind.composerAction), flow: _meta());
      expect((h.byId['app.speak']! as FakeSpeak).requests.single.gap, const Duration(seconds: 9));
    });

    test('入口已带图就不再拉相机', () async {
      final h = _harness();
      await _runner.run(
        _ctx(_manifest(), h),
        const PluginInput(entry: PluginEntryKind.composerAction, imagePaths: ['/sdcard/already.jpg']),
        flow: _meta(),
      );
      expect(h.calls.where((c) => c.capabilityId == 'app.capture'), isEmpty);
      expect((h.byId['llm.vision']! as FakeLlmVision).lastImagePaths, ['/sdcard/already.jpg']);
    });

    test('用户输入的"基本要求"进提示词（{{userInstruction}}）', () async {
      final h = _harness();
      await _runner.run(
        _ctx(_manifest(), h),
        const PluginInput(entry: PluginEntryKind.composerAction, text: '只要第三单元的'),
        flow: _meta(),
        promptText: '抽取生字。【附加要求】{{userInstruction}}',
      );
      // 附加要求确实进了模型侧（用 fake 记录的入参验，不看 UI）。
      final call = h.calls.firstWhere((c) => c.method == 'completeWithImage');
      expect(call.args['system'], contains('只要第三单元的'));
    });

    test('ask_params 问到的值可以进提示词（{{count}} 这类运行时占位符）', () async {
      final h = _harness(numbers: const [8]);
      final r = await _runner.run(
        _ctx(_manifest(), h),
        const PluginInput(entry: PluginEntryKind.composerAction),
        flow: _meta(steps: const [
          FlowStep(id: 'setup', op: FlowStepOp.askParams, params: {'names': ['gapSeconds']}),
          FlowStep(id: 'pick', op: FlowStepOp.llmExtract),
        ]),
        promptText: '只要 {{gapSeconds}} 条，剩下的不要。',
      );
      expect(r.isOk, isTrue, reason: r.failureOrNull?.message);
      final call = h.calls.firstWhere((c) => c.method == 'complete');
      expect(call.args['system'], '只要 8 条，剩下的不要。', reason: '落整不带 .0，且不留占位符');
    });

    test('插件没声明 llm:vision 时，塞了图也不调视觉模型（权限说了算）', () async {
      final h = _harness();
      final ctx = FakePluginCtx(
        manifest: _manifest(),
        harness: h,
        permissions: const {'camera', 'photo_library', 'tts', 'storage:plugin', 'network', 'llm:chat'},
        config: const {'gapSeconds': 5, 'readChinese': true},
      );
      final r = await _runner.run(ctx, const PluginInput(
        entry: PluginEntryKind.composerAction,
        imagePaths: ['/sdcard/偷拍.jpg'],
      ), flow: _meta(steps: const [FlowStep(id: 'pick', op: FlowStepOp.llmExtract)]));
      expect(r.isOk, isTrue, reason: r.failureOrNull?.message);
      expect(h.calls.where((c) => c.capabilityId == 'llm.vision'), isEmpty);
      expect(h.calls.where((c) => c.capabilityId == 'llm.complete'), isNotEmpty);
    });

    test('withNote=false 时只念正文，不念释义', () async {
      final h = _harness();
      final r = await _runner.run(
        _ctx(_manifest(), h),
        const PluginInput(entry: PluginEntryKind.composerAction),
        flow: _meta(steps: const [
          FlowStep(id: 'pick', op: FlowStepOp.llmExtract, params: {'withNote': false}),
          FlowStep(id: 'say', op: FlowStepOp.speakSequence),
        ]),
      );
      expect(r.isOk, isTrue, reason: r.failureOrNull?.message);
      expect((h.byId['app.speak']! as FakeSpeak).requests.single.items, ['苹果', '香蕉']);
    });
  });

  group('三态终局（不允许"半途而废当成功"）', () {
    test('用户放弃校对 → 终局 cancelled，已完成步骤照实记录', () async {
      final h = _harness(choices: const ['算了']);
      final r = await _runner.run(_ctx(_manifest(), h), const PluginInput(entry: PluginEntryKind.composerAction), flow: _meta());
      expect(r.isOk, isTrue, reason: '用户自己放弃不是失败');
      expect(r.valueOrNull!.userVisible, isFalse);
      expect(r.valueOrNull!.data['cancelled'], isTrue);
      expect(r.valueOrNull!.data['completedSteps'], ['shoot', 'pick']);
      expect(h.calls.where((c) => c.capabilityId == 'app.speak'), isEmpty);
    });

    test('没选图 → cancelled，并告诉用户怎么重来', () async {
      final h = _harness(images: const []);
      final r = await _runner.run(_ctx(_manifest(), h), const PluginInput(entry: PluginEntryKind.composerAction), flow: _meta());
      expect(r.valueOrNull!.data['cancelled'], isTrue);
      expect(r.valueOrNull!.summary, contains('没选图片'));
    });

    test('抽不出内容 → error（badContent）+ 重拍建议，绝不"念 0 个词"充数', () async {
      final h = _harness(vision: '这张图我看不太清');
      final r = await _runner.run(_ctx(_manifest(), h), const PluginInput(entry: PluginEntryKind.composerAction), flow: _meta());
      expect(r.isErr, isTrue);
      expect(r.failureOrNull!.code, PluginFailureKind.badContent);
      // 实测真话是这句（第一版我照基线里另一处「拍一张课本单词表…」脑补，红给我看了）：
      expect(r.failureOrNull!.hint, contains('拍正、拍全，别逆光或只拍半页'),
          reason: '单字「拍」太松：抽不出词时的重拍建议必须具体（正/全/光线/别只拍半页）');
      expect(h.calls.where((c) => c.capabilityId == 'app.speak'), isEmpty);
    });

    test('abort（默认）：一步炸就整条停，面板能看出停在哪一步', () async {
      final h = _harness();
            h.register(FakeLlmVision(failWith: PluginFailure(code: PluginFailureKind.busy, message: '模型正忙', hint: '等上一条回答完再试')));
      final r = await _runner.run(_ctx(_manifest(), h), const PluginInput(entry: PluginEntryKind.composerAction), flow: _meta());
      expect(r.isErr, isTrue);
      expect(r.failureOrNull!.step, 'step:pick');
      expect(r.failureOrNull!.pluginId, 'zh-dictation');
    });

    test('skipWithWarning：坏步跳过但终局照常交差，跳过原因进台账', () async {
      final h = _harness();
      final r = await _runner.run(
        _ctx(_manifest(), h),
        const PluginInput(entry: PluginEntryKind.composerAction),
        flow: _meta(steps: const [
          FlowStep(id: 'pick', op: FlowStepOp.llmExtract),
          // 可选步（交回智能体出练习题）：宿主没接线就跳过，不许拖垮整条流程。
          FlowStep(id: 'hand', op: FlowStepOp.agentHandoff, onFailure: FlowStepFailure.skipWithWarning),
          FlowStep(id: 'say', op: FlowStepOp.speakSequence),
        ]),
      );
      expect(r.isOk, isTrue, reason: r.failureOrNull?.message);
      expect(r.valueOrNull!.data['skippedSteps'], hasLength(1));
      expect((r.valueOrNull!.data['skippedSteps'] as List).first, contains('hand'));
      expect(h.calls.where((c) => c.capabilityId == 'app.speak'), isNotEmpty, reason: '后面的步照跑');
    });

    test('超时：步内等太久 → timeout，不无限挂着', () async {
      final h = FakeCapabilityHarness()
        ..register(FakeCapture())
        ..register(_HangingVision())
        ..register(FakeInteract())
        ..register(FakeSpeak())
        ..register(FakeStore());
      final r = await _runner.run(
        _ctx(_manifest(), h),
        const PluginInput(entry: PluginEntryKind.composerAction, imagePaths: ['/a.jpg']),
        flow: _meta(steps: const [
          FlowStep(id: 'pick', op: FlowStepOp.llmExtract, timeoutSeconds: 1),
        ]),
      );
      expect(r.isErr, isTrue);
      expect(r.failureOrNull!.code, PluginFailureKind.timeout);
      expect(r.failureOrNull!.message, contains('等了 1 秒没结果'),
          reason: '只断「1 秒」等于什么都没说：要连"哪个动作等了多久"这句整话一起钉住');
    });
  });

  group('入口没接通与空交付（审计出来的零覆盖守卫）', () {
    test('宿主没接 startAgent → 必须说"这台机器还没接通智能体交接"', () async {
      final h = _harness();
      final r = await _runner.run( // _runner 不带 host：交接这条路本机就没接
        _ctx(_manifest(), h),
        const PluginInput(entry: PluginEntryKind.composerAction),
        flow: _meta(steps: const [
          FlowStep(id: 'hand', op: FlowStepOp.agentHandoff, params: {'prompt': '出 5 道练习题'}),
        ]),
      );
      expect(r.isErr, isTrue);
      expect(r.failureOrNull!.message, contains('还没接通智能体交接'),
          reason: '"交接了但没开始跑"与"这台机器根本没接交接"是两件事，'
              '混成一句用户就永远不知道该去哪儿开；前者是宿主没干活，后者是宿主压根没有这条路');
      expect(r.failureOrNull!.code, PluginFailureKind.missingCapability);
    });

    test('没东西可导出 → 算失败，而且不许偷偷调用宿主的落盘', () async {
      var delivered = 0;
      final runner = FlowRunner(
        host: FlowHost(renderExport: (ctx, filename, content) async {
          delivered++;
          return const Ok<ExportReceipt>(ExportReceipt(uri: 'file:///x', fileName: 'x.txt'));
        }),
      );
      final r = await runner.run(
        _ctx(_manifest(), _harness()),
        const PluginInput(entry: PluginEntryKind.composerAction),
        flow: _meta(steps: const [
          FlowStep(id: 'exp', op: FlowStepOp.export, params: {'filename': '练习单.txt'}),
        ]),
      );
      expect(r.isErr, isTrue, reason: '前面一步都没产出内容，导出这一步"完成 1 步"就是假成功');
      expect(r.failureOrNull!.message, contains('没有可导出的内容'));
      expect(delivered, 0, reason: '内容为空时连宿主的落盘都不许调 —— 空文件写进"下载"目录比报错更坏');
    });
  });

  group('纪律与白名单', () {
    test('每个 await 之后复查取消：预取消 ⇒ 一个能力都不碰', () async {
      final h = _harness();
      final ctx = _ctx(_manifest(), h);
      ctx.cancelToken.cancel('用户按了停止');
      final r = await _runner.run(ctx, const PluginInput(entry: PluginEntryKind.composerAction), flow: _meta());
      expect(r.isOk, isTrue);
      expect(h.calls, isEmpty, reason: '取消了就不该再打任何能力');
    });

    test('问一个没声明的参数 → configInvalid（作者写错当场知道）', () async {
      final h = _harness();
      final r = await _runner.run(
        _ctx(_manifest(), h),
        const PluginInput(entry: PluginEntryKind.composerAction),
        flow: _meta(steps: const [
          FlowStep(id: 'setup', op: FlowStepOp.askParams, params: {'names': ['nope']}),
        ]),
      );
      expect(r.isErr, isTrue);
      expect(r.failureOrNull!.code, PluginFailureKind.configInvalid);
      expect(r.failureOrNull!.hint, contains('params'));
    });

    test('review 排在抽取之前 → 明确报错，不静默跳过', () async {
      final h = _harness();
      final r = await _runner.run(
        _ctx(_manifest(), h),
        const PluginInput(entry: PluginEntryKind.composerAction),
        flow: _meta(steps: const [FlowStep(id: 'confirm', op: FlowStepOp.review)]),
      );
      expect(r.isErr, isTrue);
      expect(r.failureOrNull!.message, contains('还没有可校对的内容'));
    });

    test('agent_handoff 宿主没接线 → missingCapability（并提示可 skipWithWarning）', () async {
      final h = _harness();
      final r = await _runner.run(
        _ctx(_manifest(), h),
        const PluginInput(entry: PluginEntryKind.composerAction),
        flow: _meta(steps: const [FlowStep(id: 'hand', op: FlowStepOp.agentHandoff)]),
      );
      expect(r.isErr, isTrue);
      expect(r.failureOrNull!.code, PluginFailureKind.missingCapability);
      expect(r.failureOrNull!.hint, contains('skipWithWarning'));
    });

    test('agent_handoff 接上了 → agentsStarted 计入结果', () async {
      const runner = FlowRunner(host: FlowHost(startAgent: _fakeStartAgent));
      final h = _harness();
      final r = await runner.run(
        _ctx(_manifest(), h),
        const PluginInput(entry: PluginEntryKind.composerAction),
        flow: _meta(steps: const [FlowStep(id: 'hand', op: FlowStepOp.agentHandoff, params: {'prompt': '出 5 道练习题'})]),
      );
      expect(r.isOk, isTrue, reason: r.failureOrNull?.message);
      expect(r.valueOrNull!.data['agentsStarted'], 2);
    });

    test('export 不落盘：内容交给宿主（payloads），平台不偷偷写文件', () async {
      final h = _harness();
      final r = await _runner.run(
        _ctx(_manifest(), h),
        const PluginInput(entry: PluginEntryKind.composerAction),
        flow: _meta(steps: const [
          FlowStep(id: 'pick', op: FlowStepOp.llmExtract),
          FlowStep(id: 'sheet', op: FlowStepOp.export, params: {'filename': '生字练习单.txt'}),
        ]),
      );
      expect(r.isOk, isTrue);
      final sheet = r.valueOrNull!.payloads.single as Map;
      expect(sheet['filename'], '生字练习单.txt');
      expect('${sheet['content']}', contains('苹果'));
      expect(h.calls.where((c) => c.capabilityId == 'app.store'), isEmpty);
    });

    test('宿主接了 renderExport：内容交给它，且只交一次', () async {
      final seen = <String>[];
      final runner = FlowRunner(
        host: FlowHost(renderExport: (ctx, filename, content) async {
          seen.add('$filename|$content');
          return const Ok<ExportReceipt>(
              ExportReceipt(uri: 'content://download/生字练习单.txt', fileName: '生字练习单.txt'),
            );
        }),
      );
      final h = _harness();
      final r = await runner.run(
        _ctx(_manifest(), h),
        const PluginInput(entry: PluginEntryKind.composerAction),
        flow: _meta(steps: const [
          FlowStep(id: 'pick', op: FlowStepOp.llmExtract),
          FlowStep(id: 'sheet', op: FlowStepOp.export, params: {'filename': '生字练习单.txt'}),
        ]),
      );
      expect(r.isOk, isTrue);
      expect(seen.length, 1);
      expect(seen.single, startsWith('生字练习单.txt|'));
      expect(seen.single, contains('苹果'));
    });

    test('回执报的是**真正落盘的文件名**，不是作者要的那个（改名要说破）', () async {
      final runner = FlowRunner(
        host: FlowHost(renderExport: (ctx, filename, content) async => const Ok<ExportReceipt>(
              // 宿主把 `第三单元:生字.xlsx` 改写成安全名。
              ExportReceipt(
                uri: 'content://download/第三单元_生字.xlsx',
                fileName: '第三单元_生字.xlsx',
                renamedFrom: '第三单元:生字.xlsx',
              ),
            )),
      );
      final h = _harness();
      final r = await runner.run(
        _ctx(_manifest(), h),
        const PluginInput(entry: PluginEntryKind.composerAction),
        flow: _meta(steps: const [
          FlowStep(id: 'pick', op: FlowStepOp.llmExtract),
          FlowStep(id: 'sheet', op: FlowStepOp.export, params: {'filename': '第三单元:生字.xlsx'}),
        ]),
      );
      final summary = r.valueOrNull!.summary;
      expect(summary, contains('第三单元_生字.xlsx'), reason: '用户手上只有这个名字');
      // 主回执（「已导出 …」那一段）只许报真名；原名只许出现在「被改写过」的说明里。
      expect(summary.split('；已导出 ').last.split('（').first, '第三单元_生字.xlsx',
          reason: '把作者要的名当交付名报 = 跑成功了但功能是坏的');
      expect(summary, contains('文件名被改写过'), reason: '悄悄改名是"我明明填了这个"那类困惑的来源');
    });

    test('宿主说成功但给不出文件名/位置 = 没交付（按失败处理）', () async {
      for (final bad in const [
        ExportReceipt(uri: '', fileName: 'a.txt'),
        ExportReceipt(uri: 'content://x', fileName: ''),
        ExportReceipt(uri: '  ', fileName: '  '),
      ]) {
        final runner = FlowRunner(
          host: FlowHost(renderExport: (ctx, filename, content) async => Ok<ExportReceipt>(bad)),
        );
        final h = _harness();
        final r = await runner.run(
          _ctx(_manifest(), h),
          const PluginInput(entry: PluginEntryKind.composerAction),
          flow: _meta(steps: const [
            FlowStep(id: 'pick', op: FlowStepOp.llmExtract),
            FlowStep(id: 'sheet', op: FlowStepOp.export, params: {'filename': '生字练习单.txt'}),
          ]),
        );
        expect(r.isErr, isTrue, reason: '空 URI / 空名字都不是交付（与"空串不是 URI"同族）');
        expect(r.failureOrNull?.message, contains('导出没拿到凭据：宿主没给回文件名与位置'),
            reason: '两字「凭据」太松：这句话的责任划分（是宿主没给回，不是作者没写）必须原样钉住');
      }
    });

    test('引擎在朗读前把后面的条目交给 prewarm（这条口子以前没人调用）', () async {
      final h = _harness();
      final r = await _runner.run(
        _ctx(_manifest(), h),
        const PluginInput(entry: PluginEntryKind.composerAction),
        flow: _meta(steps: const [
          FlowStep(id: 'pick', op: FlowStepOp.llmExtract),
          FlowStep(id: 'say', op: FlowStepOp.speakSequence),
        ]),
      );
      expect(r.isOk, isTrue);
      final calls = h.calls.where((c) => c.capabilityId == 'app.speak').toList();
      final spoken = calls.firstWhere((c) => c.method == 'speak').args['items'] as int;
      final prewarms = calls.where((c) => c.method == 'prewarm').toList();
      expect(prewarms, hasLength(1), reason: '有下一条就该预热 —— 否则每条都现合成，用户等的是下载音频的时间');
      // 首条正在播，不必预热；剩下的都该提前合成。
      expect(prewarms.single.args['count'], spoken - 1, reason: '预热要盖住除首条外的每一条，且不许把首条也算进去白等');
    });

    test('宿主导出失败：这一步如实报错，不假装交付了', () async {
      final runner = FlowRunner(
        host: FlowHost(renderExport: (ctx, filename, content) async => Outcome.err<ExportReceipt>(
              code: PluginFailureKind.runtimeError,
              message: '下载目录写不进去',
              pluginId: ctx.manifest.id,
            )),
      );
      final h = _harness();
      final r = await runner.run(
        _ctx(_manifest(), h),
        const PluginInput(entry: PluginEntryKind.composerAction),
        flow: _meta(steps: const [
          FlowStep(id: 'pick', op: FlowStepOp.llmExtract),
          FlowStep(id: 'sheet', op: FlowStepOp.export),
        ]),
      );
      expect(r.isErr, isTrue);
      // 参谋保留：这句 message 来自测试桩 renderExport 自己造的错误，断的是「宿主错误原样透传、runner 不吞不改写」；
      // 把桩的文案钉死反而变成自证（真宿主的文案由 host_export_test 那边断）。
      expect(r.failureOrNull!.message, contains('下载目录'));
    });
  });
}

Future<Outcome<int>> _fakeStartAgent(PluginCtx ctx, String prompt, String context) async => const Ok<int>(2);

/// 受理了但一个回合都没起的宿主（专测 `agent_handoff` 不许把"没干活"记成成功）。
Future<Outcome<int>> _zeroStartAgent(PluginCtx ctx, String prompt, String context) async => const Ok<int>(0);

/// 违约的 `app.interact`：明知道 min/max 还返回越界值（真机上就是这类实现把听写变成"等 15 分钟"）。
final class _BadInteract extends FakeCapability implements Interact {
  _BadInteract(this.answer) : super(ServiceKeys.interact, available: true);
  final double answer;

  @override
  Future<Outcome<double?>> askNumber({required String question, required double defaultValue, required double min, required double max}) async =>
      Ok<double?>(answer);

  @override
  Future<Outcome<String?>> askChoice({required String question, required List<String> options, String? defaultValue}) async =>
      Ok<String?>(options.isEmpty ? null : options.first);
}

/// 永远不回话的视觉模型（验超时，而不是验 fake 自己）。
final class _HangingVision extends FakeCapability implements LlmVision {
  _HangingVision() : super(ServiceKeys.llmVision, available: true);

  @override
  Future<Outcome<String>> completeWithImage({
    required String systemPrompt,
    required String userText,
    required List<String> imagePaths,
    int? maxTokens,
    double? temperature,
    PluginCancelToken? cancelToken,
  }) =>
      Completer<Outcome<String>>().future;
}
