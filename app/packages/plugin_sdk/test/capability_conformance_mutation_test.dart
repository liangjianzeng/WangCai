import 'package:plugin_sdk/plugin_sdk.dart';
import 'package:plugin_sdk/testing.dart';
import 'package:test/test.dart';

/// 质检套件自己的质检。
///
/// `runCapabilityConformance` 是"第二实现上岗前的同一套体检"（离线朗读盖掉在线那份走的也是它）。
/// 但以前所有调用喂的都是**好实现** —— 只有"全绿"的证据，没有"坏实现必被拦下"的证据。
/// 门禁的锁没试过钥匙，等于没有锁。这里给每条检查配一份**故意坏**的实现，逐条证明它会红；
/// 再配一份"合法但看起来坏"的实现，证明它**不会误伤**（误伤比漏判更坏：作者会被自己的体检劝退）。
void main() {
  List<ConformanceCheck> fails(List<ConformanceCheck> all) => all.where((e) => !e.passed).toList();

  group('每条检查都必须拦得住对应的坏实现', () {
    test('能力 id 写歪（大写/下划线）→ 拦下，并点名是哪个 id', () async {
      final r = await runCapabilityConformance(_Demo(badId: true));
      expect(fails(r).map((e) => e.name), contains('能力 id 是点分小写（app.speak 这种）'),
          reason: 'id 写歪 = 插件 inject 永远解析不到，必须当场拦住');
      expect(fails(r).single.detail, contains('Bad_Speak'));
    });

    test('available 读取就抛 → 拦下（本函数还必须先给出这条，不能整体崩）', () async {
      final r = await runCapabilityConformance(_Demo(throwAvailable: true));
      expect(fails(r).map((e) => e.name), contains('available 读取不抛'));
      expect(r, isNotEmpty, reason: '连 available 都读不出时也要留下可读结论，不许抛出去');
    });

    test('unavailableReason 读取抛 → 拦下', () async {
      final r = await runCapabilityConformance(_Demo(throwReason: true));
      expect(fails(r).map((e) => e.name), contains('unavailableReason 读取不抛'));
    });

    test('不可用却说不出原因 → 拦下（面板与回落全靠这句话指路）', () async {
      final r = await runCapabilityConformance(_Demo(avail: false, reason: null));
      expect(
          fails(r).map((e) => e.name), contains('不可用时给出人话原因（面板与回落都要靠它）'));
      expect(fails(r).single.detail, contains('说不出为什么'), reason: 'detail 要直接说清缺了什么');
    });

    test('明明可用还挂着原因 → 拦下（面板两条口径会打架）', () async {
      final r = await runCapabilityConformance(_Demo(avail: true, reason: '我还挺好用'));
      expect(fails(r).map((e) => e.name), contains('可用时不乱给原因（免得面板两条口径打架）'));
    });

    test('probe 失败却不给出路 → 拦下', () async {
      final r = await runCapabilityConformance(_Demo(probeErr: true, probeHint: null));
      expect(fails(r).map((e) => e.name), contains('probe 失败时带 message 与出路'),
          reason: '面板「试一下」就是把这句念给用户；没有出路等于让用户自己猜');
    });

    test('probe 直接 throw → 拦下（异常必须折算成 Outcome）', () async {
      final r = await runCapabilityConformance(_Demo(throwProbe: true));
      expect(fails(r).map((e) => e.name), contains('probe() 永不 throw（异常必须折算成 Outcome）'));
    });

    test('第一次 probe 好好的、第二次炸 → 拦下（藏状态）', () async {
      final r = await runCapabilityConformance(_Demo(explodeOnSecondProbe: true));
      expect(fails(r).map((e) => e.name), contains('probe 可重复调用'));
    });

    test('warmUp throw → 拦下（预热失败只该影响性能，不该崩面板）', () async {
      final r = await runCapabilityConformance(_Demo(throwWarmUp: true));
      expect(fails(r).map((e) => e.name), contains('warmUp() 永不 throw（预热失败只该影响性能）'));
    });

    test('预热之后反而说自己不行了 → 拦下（只许"预热完才就绪"这一个方向）', () async {
      final r = await runCapabilityConformance(_Demo(dieAfterWarmUp: true));
      expect(fails(r).map((e) => e.name), contains('可用性是稳定的（不在 getter 里藏随机或副作用）'),
          reason: 'warmUp 把能用预热成不能用，注册表会先选它再全场回落 —— 必须判坏');
    });

    test('每读一次 available 就翻一次 → 拦下（getter 里藏随机/副作用）', () async {
      final r = await runCapabilityConformance(_Demo(flipEveryRead: true));
      expect(fails(r).map((e) => e.name), contains('可用性是稳定的（不在 getter 里藏随机或副作用）'),
          reason: '可用性抖一下，注册表就会一会儿选它一会儿回落，用户看到的是"时有时无"');
    });
  });

  group('合法实现不许被误伤', () {
    test('warmUp 之后才就绪（离线模型/音色表懒加载）判合格 —— 不能把最该来的实现挡在门外', () async {
      final r = await runCapabilityConformance(_Demo(availableAfterWarmUp: true));
      expect(fails(r), isEmpty,
          reason: '离线 TTS 这类实现天然"预热完才可用"；判它不合格等于把 P7 的第二实现挡在体检门外');
    });

    test('完全健康的实现全绿', () async {
      final r = await runCapabilityConformance(_Demo());
      expect(fails(r), isEmpty, reason: describeConformanceFailures(r));
      expect(r.map((e) => e.group).toSet(), {'状态与错误', '契约'});
    });
  });
}

/// 可配置的实现：每个开关对应一种"坏法"。
final class _Demo implements Capability {
  _Demo({
    this.avail = true,
    this.reason,
    this.badId = false,
    this.throwAvailable = false,
    this.throwReason = false,
    this.probeErr = false,
    this.probeHint,
    this.throwProbe = false,
    this.explodeOnSecondProbe = false,
    this.throwWarmUp = false,
    this.flipEveryRead = false,
    this.availableAfterWarmUp = false,
    this.dieAfterWarmUp = false,
  });

  final bool avail;
  final String? reason;
  final bool badId;
  final bool throwAvailable;
  final bool throwReason;
  final bool probeErr;
  final String? probeHint;
  final bool throwProbe;
  final bool explodeOnSecondProbe;
  final bool throwWarmUp;
  final bool flipEveryRead;
  final bool availableAfterWarmUp;
  final bool dieAfterWarmUp;

  int _reads = 0;
  int _probes = 0;
  bool _warmed = false;

  @override
  ServiceKey get key =>
      ServiceKey<Capability>(badId ? 'Bad_Speak' : 'demo.thing', contractVersion: 'v1');

  @override
  bool get available {
    if (throwAvailable) throw StateError('available 炸了');
    if (flipEveryRead) return (_reads++ % 2) == 0;
    if (availableAfterWarmUp) return _warmed;
    if (dieAfterWarmUp) return !_warmed;
    return avail;
  }

  @override
  String? get unavailableReason {
    if (throwReason) throw StateError('reason 炸了');
    if (availableAfterWarmUp && !_warmed) return '模型还没加载';
    return reason;
  }

  @override
  Future<void> warmUp() async {
    if (throwWarmUp) throw StateError('预热炸了');
    _warmed = true;
  }

  @override
  Future<Outcome<void>> probe() async {
    if (throwProbe) throw StateError('probe 直接抛');
    _probes++;
    if (explodeOnSecondProbe && _probes >= 2) throw StateError('第二次炸');
    if (probeErr) {
      return Outcome.err<void>(
        code: PluginFailureKind.runtimeError,
        message: '连不上',
        hint: probeHint,
      );
    }
    return const Ok<void>(null);
  }
}
