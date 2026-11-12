// 生图两态化状态机单测（2026-11-12 一实例三角色方案：先扩写→确认卡→生图）。
//
// 锚定 chat_provider.generateImageDirect / confirmImageGen /
// regenerateImageRewrite 与 groupMessages 的 ImageGenConfirmUnit 分流：
// ①扩写开 → 只出确认卡不起 job；②确认/用原话/编辑 → 同 id 置 confirmed
// 并按最终提示词起 job；③扩写关或扩写失败 → 直发（旧行为，永不阻塞）；
// ④重扩只刷新卡面不落 confirmed；⑤脏 genMeta 不当卡。
//
// 容器口径照 app_npu_flow_test（内存 SettingsService 替身、无 binding 不
// mock HttpClient）；生图/扩写全假件：ImageGenService.instanceOverrideForTest
// + ChatNotifier rewriter 注入，零真 HTTP。
import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

import 'package:wangcai/models/api_model.dart';
import 'package:wangcai/models/chat_message.dart';
import 'package:wangcai/platform/inference_backend.dart';
// storageServiceProvider 两文件同名可见，统一从 shared_providers 取。
import 'package:wangcai/providers/chat_provider.dart'
    hide storageServiceProvider;
import 'package:wangcai/providers/image_gen_provider.dart';
import 'package:wangcai/providers/project_provider.dart';
import 'package:wangcai/providers/settings_provider.dart';
import 'package:wangcai/providers/shared_providers.dart';
import 'package:wangcai/services/image_gen_service.dart';
import 'package:wangcai/services/image_prompt_rewriter.dart';
import 'package:wangcai/services/settings_service.dart';
import 'package:wangcai/services/storage_service.dart';
import 'package:wangcai/widgets/agent_workflow.dart';

class _InMemSettingsService extends SettingsService {
  _InMemSettingsService(this._current);
  InferenceSettings _current;
  @override
  Future<InferenceSettings> load() async => _current;
  @override
  Future<void> save(InferenceSettings s) async => _current = s;
}

/// 种子态 notifier：基类构造 super(const) + 异步 _load，同步窗口里读到
/// 的是 const 默认值（测试竞态源）。这里构造即置目标态；稍后 _load 落回
/// 内存服务同值，语义不变。
class _SeededNotifier extends SettingsNotifier {
  _SeededNotifier(super.service, InferenceSettings initial) {
    state = initial;
  }
}

class _NullInference implements InferenceBackend {
  @override
  dynamic noSuchMethod(Invocation invocation) =>
      throw UnimplementedError('生图状态机不触引擎');
}

/// 剧本化扩写器：按序回放结果，记录调用。
class _ScriptRewriter extends ImagePromptRewriter {
  _ScriptRewriter(this.results);
  final List<ImageRewriteResult> results;
  int calls = 0;
  String? lastPrompt;

  @override
  Future<ImageRewriteResult> rewrite(
      {required ApiModelConfig model, required String userPrompt}) async {
    lastPrompt = userPrompt;
    return results[calls < results.length ? calls++ : results.length - 1];
  }
}

/// 假生图服务：不起 HTTP；[gate] 非空则 generate 挂住等放行（测单飞互斥）。
class _FakeGen extends ImageGenService {
  final prompts = <String>[];
  final List<String> paths;
  Completer<void>? gate;
  _FakeGen({this.paths = const ['C:/fake/img.png']});

  @override
  Future<ImageGenResult> generate(
      {required ImageGenConfig config,
      required String prompt,
      String? size,
      String? negative,
      int? seed,
      int n = 1}) async {
    prompts.add(prompt);
    if (gate != null) await gate!.future;
    return ImageGenResult(
        paths: paths, seed: 42, size: size ?? '1024x1024', ms: 10);
  }
}

const _apiModel = ApiModelConfig(
  id: 'm1',
  name: '8899 chat',
  baseUrl: 'http://127.0.0.1:8899/v1',
  apiKey: '',
  model: 'Qwen3-VL-8B-Instruct',
);

InferenceSettings _settings({bool rewrite = true, String? rewriteModelId}) =>
    InferenceSettings(
      imageGenEnabled: true,
      imageGenBaseUrl: 'http://127.0.0.1:8899',
      imageGenRewriteEnabled: rewrite,
      imageGenRewriteModelId: rewriteModelId ?? 'm1',
      apiModels: const [_apiModel],
      activeApiModelId: 'm1',
    );

Future<List<ChatMessage>> _msgs(StorageService s) => s.getAllMessages('c1');

/// 是否确认卡消息（imga_ 结果消息也带 genMeta=seed，不能只判 null）。
bool _isCard(ChatMessage m) {
  if (m.genMeta == null) return false;
  try {
    final j = jsonDecode(m.genMeta!);
    return j is Map && j['pendingImageGen'] == true;
  } catch (_) {
    return false;
  }
}

void main() {
  late Directory tmp;
  late StorageService storage;

  setUpAll(() {
    sqfliteFfiInit();
    databaseFactory = databaseFactoryFfi;
  });

  setUp(() {
    tmp = Directory.systemTemp.createTempSync('wc_imgpending_');
    StorageService.dbPathOverrideForTest = '${tmp.path}/test.db';
    storage = StorageService();
  });

  tearDown(() async {
    ImageGenService.instanceOverrideForTest = null;
    StorageService.dbPathOverrideForTest = null;
    await StorageService.closeForTest();
    if (tmp.existsSync()) tmp.deleteSync(recursive: true);
  });

  ProviderContainer make(
      {InferenceSettings? settings,
      ImagePromptRewriter? rewriter,
      _FakeGen? gen}) {
    ImageGenService.instanceOverrideForTest = gen ?? _FakeGen();
    final s = settings ?? _settings();
    final svc = _InMemSettingsService(s);
    return ProviderContainer(overrides: [
      storageServiceProvider.overrideWithValue(storage),
      activeProjectIdProvider.overrideWith((ref) => 'p_default'),
      inferenceServiceProvider.overrideWithValue(_NullInference()),
      settingsProvider.overrideWith((ref) => _SeededNotifier(svc, s)),
      chatNotifierProvider.overrideWith((ref) => ChatNotifier(
            ref,
            ref.read(inferenceServiceProvider),
            ref.read(storageServiceProvider),
            rewriter: rewriter,
          )),
    ]);
  }

  ChatNotifier notifier(ProviderContainer c) =>
      c.read(chatNotifierProvider.notifier);

  test('扩写开：只落 user + 确认卡，不起 job', () async {
    final gen = _FakeGen();
    final rw = _ScriptRewriter([
      const ImageRewriteResult(original: '画只猫', rewritten: '一只橘猫特写，柔光')
    ]);
    final c = make(rewriter: rw, gen: gen);
    addTearDown(c.dispose);

    await notifier(c).generateImageDirect('c1', '/图 画只猫');

    expect(gen.prompts, isEmpty, reason: '确认前绝不起 job');
    expect(c.read(imageGenJobsProvider), isEmpty);
    final msgs = await _msgs(storage);
    expect(msgs.map((m) => m.role).toList(),
        [MessageRole.user, MessageRole.assistant]);
    expect(msgs[0].content, '画只猫', reason: '「/图 」前缀已剥');
    final meta = jsonDecode(msgs[1].genMeta!) as Map<String, dynamic>;
    expect(meta['pendingImageGen'], true);
    expect(meta['confirmed'], false);
    expect(meta['original'], '画只猫');
    expect(meta['rewritten'], '一只橘猫特写，柔光');
    expect(meta['modelId'], 'm1');
    expect(msgs[1].content, '一只橘猫特写，柔光');
  });

  test('确认（编辑稿）：同 id 置 confirmed，按编辑后提示词生图', () async {
    final gen = _FakeGen();
    final rw = _ScriptRewriter([
      const ImageRewriteResult(original: '画只猫', rewritten: '一只橘猫特写，柔光')
    ]);
    final c = make(rewriter: rw, gen: gen);
    addTearDown(c.dispose);

    await notifier(c).generateImageDirect('c1', '画只猫');
    var msgs = await _msgs(storage);
    final card = msgs.firstWhere((m) => _isCard(m));

    await notifier(c)
        .confirmImageGen('c1', card.id, editedPrompt: '一只暹罗猫，雪景');

    expect(gen.prompts, ['一只暹罗猫，雪景']);
    msgs = await _msgs(storage);
    final confirmed = msgs.firstWhere((m) => m.id == card.id);
    final meta = jsonDecode(confirmed.genMeta!) as Map<String, dynamic>;
    expect(meta['confirmed'], true);
    expect(meta['finalPrompt'], '一只暹罗猫，雪景');
    final result = msgs.firstWhere((m) => m.id.startsWith('imga_'));
    expect(result.imagePaths, ['C:/fake/img.png']);
    expect(c.read(imageGenJobsProvider), isEmpty);
  });

  test('用原话：原始提示词直发生图', () async {
    final gen = _FakeGen();
    final rw = _ScriptRewriter([
      const ImageRewriteResult(original: '画只猫', rewritten: '一只橘猫特写，柔光')
    ]);
    final c = make(rewriter: rw, gen: gen);
    addTearDown(c.dispose);

    await notifier(c).generateImageDirect('c1', '画只猫');
    final card = (await _msgs(storage)).firstWhere((m) => _isCard(m));
    await notifier(c).confirmImageGen('c1', card.id, useOriginal: true);

    expect(gen.prompts, ['画只猫']);
  });

  test('扩写关 = 旧直发行为（不出卡）', () async {
    final gen = _FakeGen();
    var rewriterTouched = false;
    final rw = _ScriptRewriter([]);
    final c = make(
        settings: _settings(rewrite: false),
        rewriter: _ProxyRewriter(rw, () => rewriterTouched = true),
        gen: gen);
    addTearDown(c.dispose);

    await notifier(c).generateImageDirect('c1', '画只猫');

    expect(rewriterTouched, isFalse);
    expect(gen.prompts, ['画只猫']);
    expect((await _msgs(storage)).where(_isCard), isEmpty);
  });

  test('扩写失败 → 降级直发（永不阻塞）', () async {
    final gen = _FakeGen();
    final rw = _ScriptRewriter([
      const ImageRewriteResult(original: '画只猫', rewritten: '画只猫', failed: true)
    ]);
    final c = make(rewriter: rw, gen: gen);
    addTearDown(c.dispose);

    await notifier(c).generateImageDirect('c1', '画只猫');

    expect(gen.prompts, ['画只猫']);
    expect((await _msgs(storage)).where(_isCard), isEmpty);
  });

  test('扩写模型解析不到 → 直发（activeApiModel 为 null）', () async {
    final gen = _FakeGen();
    final rw = _ScriptRewriter([
      const ImageRewriteResult(original: 'x', rewritten: 'y')
    ]);
    final c = make(
        settings: InferenceSettings(
          imageGenEnabled: true,
          imageGenBaseUrl: 'http://127.0.0.1:8899',
          imageGenRewriteEnabled: true,
          imageGenRewriteModelId: 'ghost', // 不在 apiModels 里
          apiModels: const [_apiModel],
          // 不设 activeApiModelId → activeApiModel() null → 本地主模型语义
        ),
        rewriter: rw,
        gen: gen);
    addTearDown(c.dispose);

    await notifier(c).generateImageDirect('c1', '画只猫');

    expect(gen.prompts, ['画只猫']);
  });

  test('重扩：刷新卡面扩写文，不落 confirmed、不起 job', () async {
    final gen = _FakeGen();
    final rw = _ScriptRewriter([
      const ImageRewriteResult(original: '画只猫', rewritten: '第一版'),
      const ImageRewriteResult(original: '画只猫', rewritten: '第二版'),
    ]);
    final c = make(rewriter: rw, gen: gen);
    addTearDown(c.dispose);

    await notifier(c).generateImageDirect('c1', '画只猫');
    final card = (await _msgs(storage)).firstWhere((m) => _isCard(m));
    await notifier(c).regenerateImageRewrite('c1', card.id);

    expect(rw.lastPrompt, '画只猫', reason: '重扩永远对 original，不滚雪球');
    final updated =
        (await _msgs(storage)).firstWhere((m) => m.id == card.id);
    final meta = jsonDecode(updated.genMeta!) as Map<String, dynamic>;
    expect(meta['rewritten'], '第二版');
    expect(meta['confirmed'], false);
    expect(gen.prompts, isEmpty);
  });

  test('单飞互斥：job 在飞时再发 → 只回「已有任务」提示', () async {
    final gen = _FakeGen()..gate = Completer<void>();
    final rw = _ScriptRewriter([
      const ImageRewriteResult(original: 'p1', rewritten: 'r1'),
      const ImageRewriteResult(original: 'p2', rewritten: 'r2'),
    ]);
    final c = make(rewriter: rw, gen: gen);
    addTearDown(c.dispose);

    // 扩写开 → 先出确认卡，confirm 起 job（gate 挂住 generate 制造在飞态）。
    await notifier(c).generateImageDirect('c1', '画猫');
    final card = (await _msgs(storage)).firstWhere(_isCard);
    final running = notifier(c).confirmImageGen('c1', card.id);
    for (var i = 0; i < 200 && gen.prompts.isEmpty; i++) {
      await Future<void>.delayed(const Duration(milliseconds: 5));
    }
    await notifier(c).generateImageDirect('c1', '画狗');

    expect(gen.prompts, ['r1'], reason: '第二单没排队进去');
    var msgs = await _msgs(storage);
    expect(
        msgs.any((m) => m.content.contains('已有生图任务')), isTrue,
        reason: 'busy 提示已落库');

    gen.gate!.complete();
    await running;
    msgs = await _msgs(storage);
    expect(c.read(imageGenJobsProvider), isEmpty);
  });

  group('groupMessages 确认卡分流', () {
    ChatMessage card(String id, {bool confirmed = false, String? dirty}) =>
        ChatMessage(
          id: id,
          conversationId: 'c1',
          role: MessageRole.assistant,
          content: '一只橘猫特写，柔光',
          genMeta: dirty ??
              jsonEncode({
                'pendingImageGen': true,
                'original': '画只猫',
                'rewritten': '一只橘猫特写，柔光',
                'confirmed': confirmed,
              }),
        );

    test('干净单卡回合 → ImageGenConfirmUnit', () {
      final units = groupMessages([
        ChatMessage(
            id: 'u1',
            conversationId: 'c1',
            role: MessageRole.user,
            content: '画只猫'),
        card('p1'),
      ]);
      expect(units.length, 2);
      expect(units[0], isA<UserUnit>());
      expect(units[1], isA<ImageGenConfirmUnit>());
    });

    test('confirmed 后回归普通回答（TurnUnit）', () {
      final units = groupMessages([card('p1', confirmed: true)]);
      expect(units.single, isA<TurnUnit>());
    });

    test('脏 genMeta 不当卡；isPendingImageGenCard 校验', () {
      expect(isPendingImageGenCard(card('p1', dirty: '{坏 json')), isFalse);
      expect(isPendingImageGenCard(ChatMessage(
          id: 'n',
          conversationId: 'c1',
          role: MessageRole.assistant,
          content: '普通回答')), isFalse);
    });
  });
}

/// 记录是否被真正调用的转发代理（区分「没配模型」与「配了没跑」）。
class _ProxyRewriter extends ImagePromptRewriter {
  _ProxyRewriter(this._inner, this._onCall);
  final ImagePromptRewriter _inner;
  final void Function() _onCall;

  @override
  Future<ImageRewriteResult> rewrite(
      {required ApiModelConfig model, required String userPrompt}) {
    _onCall();
    return _inner.rewrite(model: model, userPrompt: userPrompt);
  }
}
