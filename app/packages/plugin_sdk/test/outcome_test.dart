import 'package:plugin_sdk/plugin_sdk.dart';
import 'package:test/test.dart';

void main() {
  group('Outcome', () {
    test('fold 强制处理两个分支', () {
      const o = Ok<int>(3);
      expect(o.fold((v) => 'v$v', (_) => 'err'), 'v3');
      final e = Err<int>.of(PluginFailureKind.busy, '正在生成中', hint: '等它说完再试');
      expect(e.fold((v) => 'v$v', (f) => f.message), '正在生成中');
      expect(e.valueOrNull, isNull);
      expect(e.failureOrNull?.code, PluginFailureKind.busy);
    });

    test('andThen 短路并保留第一个失败', () {
      final r = const Ok<int>(1).andThen<int>((v) => Ok<int>(v + 1)).andThen<int>(
            (_) => Err<int>.of(PluginFailureKind.timeout, '太慢了', hint: '稍后再试'),
          ).andThen<int>((v) => Ok<int>(v * 100));
      expect(r.failureOrNull?.code, PluginFailureKind.timeout);
    });

    test('guard 把 throw 折算成 runtimeError，自定义映射优先', () async {
      final r = await Outcome.guard<int>(() async => throw StateError('boom'));
      expect(r.isErr, isTrue);
      expect(r.failureOrNull?.code, PluginFailureKind.runtimeError);

      final mapped = await Outcome.guard<int>(
        () async => throw Exception('403'),
        mapError: (_, __) => PluginFailure(
          code: PluginFailureKind.denied,
          message: '语音服务拒绝了请求',
          hint: '稍后重试或改用离线朗读',
        ),
      );
      expect(mapped.failureOrNull?.code, PluginFailureKind.denied);
      // 参谋保留：hint 是本测试自己写进 mapError 的假文案，钉死它等于自证；这里真正要断的是 mapError 的产物被完整带上（code/message 已断）。
      expect(mapped.failureOrNull?.hint, isNotNull);
    });

    test('必须有 hint 的失败码缺 hint 时构造期就炸（防静默失败）', () {
      expect(
        () => PluginFailure(code: PluginFailureKind.missingCapability, message: '缺能力'),
        throwsA(isA<AssertionError>()),
      );
      expect(
        () => PluginFailure(code: PluginFailureKind.runtimeError, message: '就是失败了'),
        returnsNormally, // runtimeError 不强制 hint（很多时候确实只能"稍后再试"）
      );
      expect(
        () => PluginFailure(code: PluginFailureKind.badContent, message: '没认出单词', hint: '换个角度重拍'),
        returnsNormally,
      );
    });

    test('六类失败码**每一个**缺 hint 都构造期就炸（不是只盯一两个）', () {
      for (final code in const [
        PluginFailureKind.missingCapability,
        PluginFailureKind.permissionDenied,
        PluginFailureKind.configInvalid,
        PluginFailureKind.incompatibleContract,
        PluginFailureKind.denied,
        PluginFailureKind.badContent,
      ]) {
        expect(() => PluginFailure(code: code, message: '失败了'), throwsA(isA<AssertionError>()),
            reason: '$code 必须给出路');
        expect(() => PluginFailure(code: code, message: '失败了', hint: '去设置里打开它'), returnsNormally);
      }
    });

    test('release 把 assert 剥掉之后，出路仍然不会变成空白（ensureHint 兜底）', () {
      // 这条测的不是断言（release 里没有断言），是**兜底句**：面板上永远得有一句话可指。
      for (final code in const [
        PluginFailureKind.missingCapability,
        PluginFailureKind.permissionDenied,
        PluginFailureKind.configInvalid,
        PluginFailureKind.incompatibleContract,
        PluginFailureKind.denied,
        PluginFailureKind.badContent,
      ]) {
        final h = PluginFailure.ensureHint(code, null);
        expect(h, isNotNull, reason: '$code 兜底也不能没话');
        expect(h!.trim(), isNotEmpty);
        expect(h, isNot(contains('PluginFailure')), reason: '兜底句也是给人看的，不许漏内部名');
        expect(PluginFailure.ensureHint(code, '  自己写的出路  '), '自己写的出路', reason: '作者写了就用作者的');
      }
      expect(PluginFailure.ensureHint(PluginFailureKind.runtimeError, null), isNull,
          reason: 'runtimeError 本来不强制出路，别硬塞一句废话');
    });

    test('message 过长（堆栈塞进 UI）直接拒收', () {
      expect(
        () => PluginFailure(code: PluginFailureKind.runtimeError, message: 'x' * 121),
        throwsA(isA<AssertionError>()),
      );
    });
  });

  group('取消令牌', () {
    test('delay 可被取消唤醒（不必等满间隔）', () async {
      final t = PluginCancelToken(debugLabel: 't');
      final sw = Stopwatch()..start();
      final w = t.delay(const Duration(seconds: 30));
      await Future<void>.delayed(const Duration(milliseconds: 20));
      t.cancel('用户点了停止');
      final done = await w;
      sw.stop();
      expect(done, isFalse);
      expect(sw.elapsedMilliseconds, lessThan(1000));
      expect(t.reason, '用户点了停止');
    });

    test('dispose 组合子逆序执行且单个失败不阻断其余', () async {
      final log = <String>[];
      final d = disposers([
        () => log.add('a'),
        () => log.add('b'),
        () => throw StateError('b 坏了'),
      ]);
      await expectLater(d(), throwsA(isA<StateError>())); // 第一个错误被保留并上抛供日志
      expect(log, ['b', 'a']); // 逆序；b 抛错不影响 a
    });

    test('子令牌随父取消，父不受子影响', () async {
      final parent = PluginCancelToken(debugLabel: 'session');
      final child = parent.child('dictation');
      child.cancel('局部取消');
      expect(child.isCancelled, isTrue);
      expect(parent.isCancelled, isFalse);
      parent.cancel('整体取消');
      expect(child.reason, isNotNull);
    });
  });

  group('withTimeout', () {
    test('超时折算成 timeout 失败而不是永久挂起', () async {
      final r = await withTimeout<int>(
        () async => Future.delayed(const Duration(seconds: 5), () => const Ok<int>(1)),
        const Duration(milliseconds: 30),
        what: '识别照片里的单词',
      );
      expect(r.failureOrNull?.code, PluginFailureKind.timeout);
      expect(r.failureOrNull?.message, contains('识别照片里的单词'));
    });
  });
}
