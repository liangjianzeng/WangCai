// llm.* 宿主适配器的失败语义钉死（抽词路径：用户只看人话，技术细节进 cause）。
// 用 `flutter test test/plugins` 跑。端口是假的，不碰原生引擎与网络。
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:plugin_sdk/plugin_sdk.dart';
import 'package:tongyi_lite/plugins/host/host_llm.dart';
import 'package:tongyi_lite/plugins/slot_outlet.dart';

class _FakePort implements LlmTextPort {
  _FakePort({this.reply = '{"items":[{"text":"apple"}]}', this.routeResult, this.throws});

  final String reply;
  final PluginLlmRoute? routeResult;
  final Object? throws;

  String? lastSystem;
  String? lastUser;
  List<String> lastImages = const [];
  int calls = 0;

  @override
  Future<PluginLlmRoute> route() async {
    if (throws != null) throw throws!;
    return routeResult ?? const PluginLlmRoute(useApi: true, modelId: 'gpt-x', visionCapable: true);
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
    calls++;
    lastSystem = system;
    lastUser = user;
    lastImages = imagePaths;
    if (throws != null) throw throws!;
    return reply;
  }
}

void main() {
  group('llm.complete', () {
    test('正常返回原文（JSON 由插件自己解析，能力层不猜内容）', () async {
      final r = await HostLlmComplete(_FakePort()).complete(systemPrompt: '你是抽取器', userText: '抽词');
      expect(r.isOk, isTrue);
      expect(r.valueOrNull, contains('apple'));
    });

    test('模型空回复 → badContent + 下一步做什么（不是 Ok("") 让插件解析崩）', () async {
      final r = await HostLlmComplete(_FakePort(reply: '   ')).complete(systemPrompt: 's', userText: 'u');
      expect(r.isErr, isTrue);
      expect(r.failureOrNull!.code, PluginFailureKind.badContent);
      // `isNotEmpty` 等于没断：产品随便说两句都过。这两句是用户在听写拍到模糊课本后唯一看得见的指引。
      expect(r.failureOrNull!.message, contains('模型没给出内容'), reason: r.failureOrNull?.message);
      expect(r.failureOrNull!.hint, contains('换个模型或把要求写得更具体些'),
          reason: '空回复的两条出路（换模型 / 写清要求）必须都说全');
    });

    test('聊天正在生成 → busy，说"等它说完"（本地引擎只有一个生成流）', () async {
      final r = await HostLlmComplete(_FakePort(throws: PluginEngineBusyException()))
          .complete(systemPrompt: 's', userText: 'u');
      expect(r.failureOrNull!.code, PluginFailureKind.busy);
      expect(r.failureOrNull!.message, contains('模型正在回答上一条消息'),
          reason: '要说破"为什么 busy"——本地只有一个生成流，是聊天占着，不是模型坏了');
      expect(r.failureOrNull!.hint, contains('等它说完再试，或先点停止'),
          reason: '出路要给两个：等，或者主动停掉');
    });

    test('没配模型 → missingCapability + 去设置哪一页（技术原因进 cause）', () async {
      final r = await HostLlmComplete(_FakePort(throws: PluginNoModelException('API 接入未配置')))
          .complete(systemPrompt: 's', userText: 'u');
      expect(r.failureOrNull!.code, PluginFailureKind.missingCapability);
      expect(r.failureOrNull!.message, contains('没有可用的模型'), reason: r.failureOrNull?.message);
      expect(r.failureOrNull!.hint, contains('在 设置→模型管理 勾选默认模型，或在 设置→API 接入 配好接口'),
          reason: '「设置」两个字等于没指路：必须点名哪一页、勾什么');
      expect(r.failureOrNull!.cause, contains('API 接入未配置'));
    });

    test('底层异常不外泄原文：message 是人话，原文只在 cause', () async {
      final r = await HostLlmComplete(_FakePort(throws: Exception('SocketException: host lookup failed')))
          .complete(systemPrompt: 's', userText: 'u');
      // 认得出是哪一类就说得准一点（2026-10-24 真机：一律"没能…"什么也告诉不了），
      // 但**原文只许进 cause**，不许渗进 message。
      expect(r.failureOrNull!.message, '接口没连上');
      expect(r.failureOrNull!.message, isNot(contains('Socket')));
      expect(r.failureOrNull!.cause, contains('SocketException'));
    });
  });

  group('llm.vision', () {
    test('带图抽词：图片路径原样送到端口', () async {
      final port = _FakePort();
      final r = await HostLlmVision(port).completeWithImage(
        systemPrompt: '你是教材识别器',
        userText: '按顺序抽条目',
        imagePaths: const ['/sdcard/a.jpg'],
      );
      expect(r.isOk, isTrue);
      expect(port.lastImages, ['/sdcard/a.jpg']);
      expect(port.lastSystem, '你是教材识别器');
    });

    test('没图就调 → badContent（不是把空列表塞给模型）', () async {
      final r = await HostLlmVision(_FakePort())
          .completeWithImage(systemPrompt: 's', userText: 'u', imagePaths: const []);
      expect(r.failureOrNull!.code, PluginFailureKind.badContent);
      expect(r.failureOrNull!.message, contains('没有图片可看'), reason: r.failureOrNull?.message);
      expect(r.failureOrNull!.hint, contains('先拍照或从相册选一张'),
          reason: '听写插件最常见的误触：没图就点开始，得告诉他去点哪个按钮');
    });

    test('当前模型看不了图 → 说清该去哪改（本地提 mmproj，API 提视觉勾选）', () async {
      final local = await HostLlmVision(_FakePort(routeResult: const PluginLlmRoute(useApi: false, modelId: 'qwen')))
          .completeWithImage(systemPrompt: 's', userText: 'u', imagePaths: const ['/a.jpg']);
      expect(local.failureOrNull!.code, PluginFailureKind.missingCapability);
      expect(local.failureOrNull!.hint, contains('mmproj'));

      final api = await HostLlmVision(_FakePort(routeResult: const PluginLlmRoute(useApi: true, modelId: 'gpt')))
          .completeWithImage(systemPrompt: 's', userText: 'u', imagePaths: const ['/a.jpg']);
      expect(api.failureOrNull!.hint, contains('把这个模型勾成支持视觉'),
      reason: 'API 档的出路是「勾成支持视觉」这个具体开关，不是泛泛提一句「视觉」');
    });

    test('图里什么都没读出来 → badContent 并提示怎么重拍', () async {
      final r = await HostLlmVision(_FakePort(reply: ''))
          .completeWithImage(systemPrompt: 's', userText: 'u', imagePaths: const ['/a.jpg']);
      expect(r.failureOrNull!.code, PluginFailureKind.badContent);
      expect(r.failureOrNull!.message, '模型没从图里读出内容');
      expect(r.failureOrNull!.hint, contains('拍清楚一些再试（对齐课本条目、别逆光）'),
      reason: '一字「拍」太松：重拍建议要带上对齐课本条目、别逆光这类可执行细节');
    });
  });

  test('能力自述与 id 对齐契约', () {
    expect(HostLlmComplete(_FakePort()).key.id, 'llm.complete');
    expect(HostLlmVision(_FakePort()).key.id, 'llm.vision');
  });

group('看图失败的四种说法（不许都叫"没能从图里提取内容"）', () {
  test('本地引擎报错 → 说"本地模型看图没跑通"，并点名 mmproj / 模型管理', () async {
    final f = await _visionFail(FakePlatformException('E5', 'mtmd: mmproj not loaded'));
    expect(f.message, startsWith('本地模型看图这一步没跑通'));
    expect(f.hint, contains('多半是该模型没加载或没开视觉（需要 mmproj 投影器）：去 设置→模型管理 加载并开启视觉再试。引擎原话：'),
        reason: '不说 mmproj、不指 设置→模型管理，用户不知道该去开视觉');
    expect(f.hint, contains('模型管理'));
    expect(f.hint, contains('mtmd: mmproj not loaded'), reason: '技术原文要在界面上看得见');
    expect(f.cause, contains('mmproj'));
  });

  test('接口不通 → 说"视觉接口没连上"，指到 API 接入', () async {
    final f = await _visionFail(FakeDioException());
    expect(f.message, startsWith('接口没连上'));
    expect(f.hint, contains('检查 设置→API 接入 的地址、密钥与手机网络（走 API 时才需要网）。原文：'),
        reason: '走 API 才需要网：这句出路必须整句钉住，改成「检查网络」这种废话测不出来');
  });

  test('超时 → code 是 timeout，hint 教怎么减小负担', () async {
    final f = await _visionFail(FakeTimeoutException());
    expect(f.code, PluginFailureKind.timeout);
    expect(f.message, startsWith('等模型回话超时'));
    expect(f.hint, contains('图拍小一点（别一整页）、或换快一档的模型再试。原文：'));
  });

  test('认不出的异常 → 保底也说清"死在哪一段"，并把原文塞进 hint', () async {
    final f = await _visionFail(FakeBoom());
    expect(f.message, contains('没能从图里提取内容'));
    expect(f.message, contains('看图生成'), reason: '不标阶段，用户与我都分不清是路由死还是生成死');
    expect(f.hint, contains('检查模型与网络设置后再试一次。原文：something odd happened'),
        reason: '认不出的异常也要带下一步与原文，不许只剩一句没用的话');
  });

  test('真凶被包在 Exception("SocketException: …") 里也要认出来', () async {
    final f = await _visionFail(Exception('SocketException: Host unreachable'));
    expect(f.message, contains('接口没连上'),
        reason: '上层常常包一层再抛；只看 runtimeType 就退回那句没用的 catch-all');
  });

  test('死在路由阶段 → 标"准备模型"，与生成阶段区分开', () async {
    final r = await HostLlmVision(_FakePort(throws: FakeBoom())).completeWithImage(
      systemPrompt: 's',
      userText: 'u',
      imagePaths: const ['/sdcard/a.jpg'],
    );
    expect(r.failureOrNull!.message, '没能从图里提取内容（准备模型）',
        reason: '整句钉住：阶段标记与兜底文案都得在，用户与远程排查的人都分得清死在哪一段');
  });
});

group('模型没加载不许算"提取失败"（2026-10-24 真机首因）', () {
  test('已加载 → 放行', () async {
    final gate = LocalModelGate(isLoaded: () => true, load: (_) async => true);
    expect(await gate.ensure('qwen3.5-4b'), isNull);
  });

  test('没加载但能加载 → 放行（插件入口不要求用户先去聊一句）', () async {
    var loaded = false;
    final gate = LocalModelGate(
      isLoaded: () => loaded,
      load: (id) async {
        loaded = true;
        return true;
      },
    );
    expect(await gate.ensure('qwen3.5-4b'), isNull);
    expect(loaded, isTrue, reason: '说"放行"却没真加载，等于没这一步');
  });

  test('加载不动 → 说"模型还没加载起来" + 去哪儿加载，而不是"没能从图里提取内容"', () async {
    final gate = LocalModelGate(isLoaded: () => false, load: (_) async => false);
    final f = (await gate.ensure('qwen3.5-4b'))!;
    expect(f.code, PluginFailureKind.missingCapability);
    expect(f.message, contains('模型还没加载起来'));
    expect(f.hint, contains('要看图还得给该模型开启视觉（需要 mmproj 投影器），或改用支持视觉的模型'),
        reason: '出路必须整句钉住：只断「模型管理」这种四字词，改文案测不出来');
    expect(f.cause, contains('qwen3.5-4b'));
  });

  test('没指定模型 → 说人话指到模型管理/API 接入', () async {
    final gate = LocalModelGate(isLoaded: () => true, load: (_) async => true);
    final f = (await gate.ensure(''))!;
    expect(f.message, contains('没指定用哪个模型'));
    expect(f.hint, anyOf(contains('模型管理'), contains('API 接入')));
  });
});

group('失败要说"一句人话 + 下一步"（hint 不许在显示层被丢掉）', () {
  test('describePluginFailure 把 message 与 hint 拼一起', () {
    final f = PluginFailure(code: PluginFailureKind.badContent, message: '图里没认出单词', hint: '拍正一点');
    expect(describePluginFailure(f), '图里没认出单词\n拍正一点');
  });

  test('没有 hint 时不硬塞空行', () {
    // 用不带强制 hint 的失败码试：badContent 这类会被构造器按码兜一句 hint（那是另一条纪律，
    // 见 `PluginFailure` 的 _requiresHint）。
    final f = PluginFailure(code: PluginFailureKind.runtimeError, message: '没能完成补全');
    expect(describePluginFailure(f), '没能完成补全');
  });

  test('两个内置插件都走 describePluginFailure，不许再各自只贴 message', () {
    for (final p in <String>[
      'lib/plugins/builtin/en_dictation/en_dictation_plugin.dart',
      'lib/plugins/builtin/hello/hello_plugin.dart',
    ]) {
      final src = File(p).readAsStringSync();
      expect(src, contains('describePluginFailure'), reason: '$p 又把 hint 丢了');
      expect(src, isNot(contains('(f) => f.message')),
          reason: '$p 还在只贴 message：宿主分好的"下一步"界面上看不见');
    }
  });
});
}

// ── 2026-10-24 真机：「一直报没能从图里提取内容」的失败面钉死 ──────────────────
//
// 那句红条之所以没用：所有异常都掉进同一句 catch-all，真凶只进 `cause`，而界面上连 cause 都不显示
// ——模型没加载、没开视觉（mmproj）、断网、超时，在用户眼里长得一模一样。
// 现在：**分阶段 + 分类**说人话，`hint` 带下一步也带技术原文，SnackBar 必须把 hint 显示出来。

/// 只在 `complete` 里抛的端口：route 过了才算"死在看图生成"，用来验分阶段说法。
class _ThrowOnCompletePort implements LlmTextPort {
  _ThrowOnCompletePort(this.boom);
  final Object boom;

  @override
  Future<PluginLlmRoute> route() async =>
      const PluginLlmRoute(useApi: false, modelId: 'qwen-v', visionCapable: true);

  @override
  Future<String> complete({
    required String system,
    required String user,
    List<String> imagePaths = const [],
    int? maxTokens,
    double temperature = 0,
    PluginCancelToken? cancelToken,
  }) async {
    throw boom;
  }
}

// 类名里带真凶的标记词：宿主按类型名认异常（不 import dio / services），假异常照样能测。
class FakePlatformException implements Exception {
  FakePlatformException(this.code, this.message);
  final String code;
  final String message;
  @override
  String toString() => 'PlatformException($code): $message';
}

class FakeDioException implements Exception {
  @override
  String toString() => 'DioException [connection error]: connection refused';
}

class FakeTimeoutException implements Exception {
  @override
  String toString() => 'TimeoutException after 0:01:00';
}

class FakeBoom implements Exception {
  @override
  String toString() => 'something odd happened';
}

Future<PluginFailure> _visionFail(Object boom) async {
  final r = await HostLlmVision(_ThrowOnCompletePort(boom)).completeWithImage(
    systemPrompt: 's',
    userText: 'u',
    imagePaths: const ['/sdcard/a.jpg'],
  );
  expect(r.isErr, isTrue, reason: '端口抛了却返回 Ok，等于把失败吞了');
  return r.failureOrNull!;

}
