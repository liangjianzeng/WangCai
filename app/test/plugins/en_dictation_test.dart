// 验收实例 A（英语听写）的行为钉死。
//
// 这个文件同时是**平台中立性的机检**：它只用 SDK 的 fake 能力驱动插件，
// 不需要任何宿主内部（真 TTS、真模型、真相机）就能跑完整流程。
// 哪天听写开始需要"平台帮个忙"，这个文件就会红。
import 'package:flutter_test/flutter_test.dart';
import 'package:plugin_sdk/plugin_sdk.dart';
import 'package:plugin_sdk/testing.dart';
import 'package:tongyi_lite/plugins/builtin/en_dictation/en_dictation_plugin.dart';

const _threeWords = '{"items":[{"text":"apple","note":"苹果"},{"text":"banana","note":"香蕉"},{"text":"cherry","note":"樱桃"}]}';

/// 默认问答脚本：先答「拍照」（取材方式那一问），再答「开始听写」（校对那一问）。
/// 2026-10-24 起取材多了一问"拍照还是从相册选" —— 少答一句，全流程就会停在"没选图，已取消"。
FakeCapabilityHarness harness({
  String visionReply = _threeWords,
  List<String> choices = const ['拍照', '开始听写'],
  FakeCapture? capture,
}) {
  return FakeCapabilityHarness()
    ..register(capture ?? FakeCapture(images: const ['/sdcard/page.jpg']))
    ..register(FakeLlmVision(response: visionReply))
    ..register(FakeInteract(choices: choices))
    ..register(FakeSpeak(gapCap: const Duration(milliseconds: 2)))
    ..register(FakeStore());
}

FakePluginCtx ctxOf(FakeCapabilityHarness h, {Map<String, Object?>? config}) => FakePluginCtx(
      manifest: EnglishDictationPlugin().manifest,
      harness: h,
      config: config ?? const {'gapSeconds': 5, 'repeatTimes': 1, 'readChinese': true},
    );

void main() {
  // 第 90 轮：用户实测「连入口都找不到」—— 入口这件事本身以前**没有任何测试钉过**。
  // 平台 90 轮测试全绿而真机上图标一个都没有，就是因为"默认启用"没人断言过。
  group('入口契约（装完就得看得见，不许靠用户去设置里翻）', () {
    test('默认就是启用的：新装 app 第一次扫到自动打开', () {
      expect(
        EnglishDictationPlugin.manifestDef.enabledByDefault,
        isTrue,
        reason: '验收件默认关着 = 输入区那个洞永远是空的，用户不知道有这个东西'
            '（2026-10-24 真机就是这个坑）。用户手动关掉过不会再被打开：内核按 firstTimeSeen 记账。',
      );
    });
  });

  group('抽词解析（端侧模型脏输出的兜底）', () {
    test('干净 JSON', () {
      final w = parseWords(_threeWords);
      expect(w.map((e) => e.text), ['apple', 'banana', 'cherry']);
      expect(w.first.note, '苹果');
    });

    test('带 ```json 围栏 + 前后解释文字', () {
      final w = parseWords('好的，识别结果如下：\n```json\n$_threeWords\n```\n希望有帮助');
      expect(w, hasLength(3));
    });

    test('裸数组 / 单引号 / 尾逗号都要能救回来', () {
      expect(parseWords("[{'text':'apple','note':'苹果'},{'text':'pear'},]"), hasLength(2));
    });

    test('键名漂移（word/zh）也认', () {
      final w = parseWords('{"words":[{"word":"dog","zh":"狗"}]}');
      expect(w.single.text, 'dog');
      expect(w.single.note, '狗');
    });

    test('认不出来就返回空表 —— **绝不编数据**（上层会说"图里没认出单词"）', () {
      expect(parseWords('抱歉，我看不清这张图'), isEmpty);
      expect(parseWords('{"items":[]}'), isEmpty);
      expect(parseWords('{"items":[{"text":""}]}'), isEmpty);
    });
  });

  group('听写全流程（全 fake 能力，不碰宿主）', () {
    test('拍照→抽词→确认→按间隔朗读→记账', () async {
      final h = harness();
      final r = await EnglishDictationPlugin().run(ctxOf(h), const PluginInput(entry: PluginEntryKind.composerAction));
      expect(r.isOk, isTrue, reason: r.failureOrNull?.message);
      expect(r.valueOrNull!.summary, contains('念完 3 个词'));

      final speak = h.byId['app.speak']! as FakeSpeak;
      expect(speak.lastRequest!.items, ['apple', '苹果', 'banana', '香蕉', 'cherry', '樱桃'],
          reason: '英文（可重复）+ 中文释义，顺序不能乱');
      expect(speak.lastRequest!.gap, const Duration(seconds: 5));
      expect((h.byId['app.store']! as FakeStore).data['lastList'], contains('apple=苹果'));

      // 中立性证据：用到的能力全是平台能力，没有任何宿主直连。
      expect(h.calls.map((c) => c.capabilityId).toSet(),
          containsAll(<String>['app.capture', 'llm.vision', 'app.interact', 'app.speak', 'app.store']));
    });

    test('入口已带图就不再拉相机（用户选好图就别再打扰）', () async {
      // 带图进来就不再问"拍照还是相册"，所以问答脚本里只有校对那一问。
      final h = harness(choices: const ['开始听写']);
      final r = await EnglishDictationPlugin().run(ctxOf(h), const PluginInput(
        entry: PluginEntryKind.composerAction,
        imagePaths: ['/sdcard/already.jpg'],
      ));
      expect(r.isOk, isTrue, reason: r.failureOrNull?.message);
      expect(h.calls.where((c) => c.capabilityId == 'app.capture'), isEmpty,
          reason: '用户已经选好图了还拉相机 = 白打扰一次');
      expect((h.byId['llm.vision']! as FakeLlmVision).lastImagePaths, ['/sdcard/already.jpg']);
    });

    // 2026-10-24 用户实测：真机上**只能拍照**，课本单词表明明在相册里。
    // 取材方式那一问必须真的落到 `preferCamera` 上 —— 只在插件里"问了"却没用上答案，
    // 也是一种受理了没干活。
    test('选「从相册选」就走相册（preferCamera=false），不许偷偷拉相机', () async {
      final h = harness(choices: const ['从相册选', '开始听写']);
      final r = await EnglishDictationPlugin().run(ctxOf(h), const PluginInput(entry: PluginEntryKind.composerAction));
      expect(r.isOk, isTrue, reason: r.failureOrNull?.message);
      final caps = h.calls.where((c) => c.capabilityId == 'app.capture').toList();
      expect(caps, hasLength(1), reason: '问一次取一次，不许两个通道都拉一遍');
      expect(caps.single.args['camera'], isFalse, reason: '答了相册就必须走相册');
    });

    test('相机权限被拒 → 自己改走相册兜一次（不把用户堵死，也不假装成功）', () async {
      final h = harness(
        choices: const ['拍照', '开始听写'],
        capture: FakeCapture(
          images: const ['/sdcard/from_gallery.jpg'],
          failCameraWith: PluginFailure(
            code: PluginFailureKind.permissionDenied,
            message: '相机权限被拒绝',
            hint: '在系统设置里允许本应用使用相机，或改用相册选图',
          ),
        ),
      );
      final r = await EnglishDictationPlugin().run(ctxOf(h), const PluginInput(entry: PluginEntryKind.composerAction));
      expect(r.isOk, isTrue, reason: '权限被拒应当兜到相册，而不是整单失败：${r.failureOrNull?.message}');
      final caps = h.calls.where((c) => c.capabilityId == 'app.capture').toList();
      expect(caps.map((c) => c.args['camera']), [true, false],
          reason: '先按用户选的拍照，被拒后自动补一趟相册');
      expect((h.byId['llm.vision']! as FakeLlmVision).lastImagePaths, ['/sdcard/from_gallery.jpg']);
    });

    test('用户在校对时点"算了"：不朗读、不记账、不报喜', () async {
      final h = harness(choices: const ['拍照', '算了']);
      final r = await EnglishDictationPlugin().run(ctxOf(h), const PluginInput(entry: PluginEntryKind.composerAction));
      expect(r.isOk, isTrue);
      expect(r.valueOrNull!.userVisible, isFalse);
      expect(h.calls.where((c) => c.capabilityId == 'app.speak'), isEmpty);
      expect((h.byId['app.store']! as FakeStore).data, isEmpty);
    });

    test('每个词念 3 遍 + 不念中文：条数与内容照配置来', () async {
      final h = harness();
      await EnglishDictationPlugin().run(
        ctxOf(h, config: const {'gapSeconds': 2, 'repeatTimes': 3, 'readChinese': false}),
        const PluginInput(entry: PluginEntryKind.composerAction, imagePaths: ['/a.jpg']),
      );
      final speak = h.byId['app.speak']! as FakeSpeak;
      expect(speak.lastRequest!.items, hasLength(9));
      expect(speak.lastRequest!.items.first, 'apple');
      expect(speak.lastRequest!.gap, const Duration(seconds: 2));
    });

    test('图里没认出单词 → badContent + 怎么重拍（不是"念完 0 个词"）', () async {
      final h = harness(visionReply: '这张图我看不清');
      final r = await EnglishDictationPlugin().run(ctxOf(h), const PluginInput(entry: PluginEntryKind.composerAction, imagePaths: ['/a.jpg']));
      expect(r.isErr, isTrue);
      expect(r.failureOrNull!.code, PluginFailureKind.badContent);
      expect(r.failureOrNull!.hint, contains('把单词表拍正、拍全（别逆光、别只拍半页）'),
          reason: '一个字「拍」等于没断：这是实例 A 自己写的重拍指引，用户照着做就能拍出可用的图；'
              '注意它与 flow_runner 那句「拍正、拍全，别逆光或只拍半页」是【两句不同的话】（一个管取材拍图、一个管抽不出词），不许互相抄');
      // 2026-10-24 真机：用户"一直报没能从图里提取内容"却无从下手 —— 红条只说没认出，
      // 分不清是拍糊了、模型不肯按 JSON 回、还是这张图本来就没单词。模型原话必须上界面。
      expect(r.failureOrNull!.hint, contains('这张图我看不清'),
          reason: 'hint 里要带上模型到底回了什么，用户（和远程排查的我）才知道下一步该改图还是改提示词');
    });

    test('视觉能力缺失 → apply 阶段就失败（面板显示"缺：llm.vision"）', () async {
      final h = FakeCapabilityHarness()
        ..register(FakeCapture())
        ..register(FakeInteract())
        ..register(FakeSpeak(gapCap: const Duration(milliseconds: 2)))
        ..register(FakeStore());
      final apply = EnglishDictationPlugin().apply(ctxOf(h));
      expect(apply.isErr, isTrue);
      expect(apply.failureOrNull!.code, PluginFailureKind.missingCapability);
      expect(apply.failureOrNull!.message, contains('llm.vision'));
    });

    test('取消令牌一按，不再往下跑（取消是正常终态）', () async {
      final h = harness();
      final ctx = ctxOf(h);
      ctx.cancelToken.cancel('用户按了停止');
      final r = await EnglishDictationPlugin().run(ctx, const PluginInput(entry: PluginEntryKind.composerAction, imagePaths: ['/a.jpg']));
      expect(r.isOk, isTrue, reason: '取消不该报成失败');
      expect(r.valueOrNull!.summary, matches(RegExp(r'已(取消|停止)')),
          reason: '念之前取消说"已取消"，念到一半说"已停止"，都是正常终态');
      expect((h.byId['app.store']! as FakeStore).data, isEmpty);
    });
  });

  group('平台体检', () {
    test('六组检查零失败（内置件与第三方同一把尺子）', () async {
      final all = await runConformance(
        EnglishDictationPlugin.new,
        harness: harness(),
        config: const {'gapSeconds': 5, 'repeatTimes': 1, 'readChinese': true},
        input: const PluginInput(entry: PluginEntryKind.composerAction, imagePaths: ['/a.jpg']),
      );
      expect(all.where((c) => !c.passed).map((c) => '${c.group}/${c.name}：${c.detail}'), isEmpty);
    });
  });
}
