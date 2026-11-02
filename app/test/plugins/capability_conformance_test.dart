// 所有能力实现过**同一套**体检（conformance 的能力侧）。
//
// 平台最重要的承诺是"能力可替换"：离线朗读盖掉在线那份、将来第三方 trusted 插件换掉宿主实现。
// 那意味着**任何一份实现都必须过同一套检查**，否则"第二实现"就是特例免检 ——
// 一旦它"不能用却不说为什么"，注册表会把它选上然后全场失败；一旦 `probe()` 会 throw，
// 面板"试一下"一点就崩。所以这里既跑真实现（必须全绿），也跑两份**故意坏**的实现
// （必须被拦下）—— 只跑好实现的"全过"是没有说服力的。
import 'dart:io';

import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:plugin_kernel/plugin_kernel.dart';
import 'package:plugin_sdk/testing.dart';
import 'package:tongyi_lite/plugins/host/host_capture.dart';
import 'package:tongyi_lite/plugins/host/host_interact.dart';
import 'package:tongyi_lite/plugins/host/host_llm.dart';
import 'package:tongyi_lite/plugins/host/host_speak.dart';
import 'package:tongyi_lite/plugins/host/host_speak_offline.dart';

/// 体检只该碰契约面（available / unavailableReason / probe / warmUp），
/// 所以这些端口方法一律"没被调用"——真被调用了就是实现把 IO 漏进了可用性判断里。
class _StubPickPort implements ImagePickPort {
  @override
  Future<String?> takePhoto() => throw UnimplementedError();
  @override
  Future<List<String>> pickFromGallery({required int maxCount}) => throw UnimplementedError();
  @override
  Future<bool> ensureCameraPermission() => throw UnimplementedError();
}

class _StubTextPort implements LlmTextPort {
  @override
  Future<PluginLlmRoute> route() => throw UnimplementedError();
  @override
  Future<String> complete({
    required String system,
    required String user,
    List<String> imagePaths = const [],
    int? maxTokens,
    double temperature = 0.7,
    PluginCancelToken? cancelToken,
  }) =>
      throw UnimplementedError();
}

class _StubBackend implements OfflineTtsBackend {
  _StubBackend({required this.ready, this.reason});
  @override
  final bool ready;
  final String? reason; // 假件自己的字段：契约里没有 reason（真正被读的是 notReadyReason）
  @override
  String? get notReadyReason => reason; // 契约要求的口（删掉会报 Missing concrete implementation）
  @override
  bool supports(String text) => false;
  @override
  Future<File?> synthesizeToFile(String text, {required String voice, required int rate}) async => null;
  @override
  String? get lastFailureMessage => null;
}

class _StubPlayer implements TtsPlaybackPort {
  @override
  Future<int> begin(String key) async => 1;
  @override
  bool isCurrent(int seq) => true;
  @override
  void end(int seq) {}
  @override
  Future<void> stop() async {}
  @override
  Future<TtsClip?> synthesize(String text,
          {required String voice, required int rate, required int pitch, required int volume}) async =>
      null;
  @override
  Future<bool> play(int seq, TtsClip clip) async => true;
  @override
  String? get lastFailureMessage => null;
  @override
  bool get ready => true;
  @override
  String? get notReadyReason => null;
}

/// 故意坏：不能用，又说不出为什么 —— 正是"第二实现"最常见也最坑的写法。
class _Silent with CapabilityBase implements Speak {
  @override
  final ServiceKey<Speak> key = ServiceKeys.speak;
  @override
  bool get available => false;
  @override
  String? get unavailableReason => null; // 坏在这里
  @override
  Stream<SpeakProgress> speak(SpeakRequest request, PluginCancelToken cancelToken) async* {}
  @override
  Future<void> stop() async {}
  @override
  Future<bool> prewarm(List<String> texts, String voice) async => false;
}

/// 故意坏：probe 直接 throw（面板"试一下"一点就崩）。
class _Throws with CapabilityBase implements Interact {
  @override
  final ServiceKey<Interact> key = ServiceKeys.interact;
  @override
  bool get available => true;
  @override
  String? get unavailableReason => null;
  @override
  Future<Outcome<double?>> askNumber(
          {required String question, required double defaultValue, required double min, required double max}) async =>
      Ok<double?>(defaultValue);
  @override
  Future<Outcome<String?>> askChoice(
          {required String question, required List<String> options, String? defaultValue}) async =>
      Ok<String?>(defaultValue);
  @override
  Future<Outcome<void>> probe() => throw StateError('探测把自己搞崩了');
}

Future<void> expectConformanceGreen(Capability impl, String label) async {
  final checks = await runCapabilityConformance(impl);
  expect(checks, isNotEmpty, reason: '$label 一条检查都没跑，等于没体检');
  expect(
    checks.where((e) => !e.passed).toList(),
    isEmpty,
    reason: '$label：\n${describeConformanceFailures(checks)}',
  );
}

void main() {
  group('宿主能力实现必须过能力体检', () {
    test('在线朗读 / 离线朗读（就绪与未就绪）/ 拍照 / 两种补全 / 问答 全绿', () async {
      await expectConformanceGreen(HostSpeak(EdgeTtsPort(), resolveVoice: (_) => 'v'), 'EdgeTts 版 HostSpeak');
      await expectConformanceGreen(
        HostSpeak(
          OfflineTtsPort(backend: _StubBackend(ready: true, reason: null), fallback: _StubPlayer()),
          resolveVoice: (_) => 'v',
        ),
        '离线就绪那份',
      );
      await expectConformanceGreen(
        HostSpeak(
          OfflineTtsPort(backend: _StubBackend(ready: false, reason: '模型没就位'), fallback: _StubPlayer()),
          resolveVoice: (_) => 'v',
        ),
        '离线未就绪那份（更要说清为什么）',
      );
      await expectConformanceGreen(HostCapture(_StubPickPort()), '拍照');
      await expectConformanceGreen(HostLlmComplete(_StubTextPort()), '文本补全');
      await expectConformanceGreen(HostLlmVision(_StubTextPort()), '视觉抽词');
      await expectConformanceGreen(HostInteract(navigatorKey: GlobalKey<NavigatorState>()), '问答');
    });

    test('故意坏的两份必须被拦下（不然"全绿"没意义）', () async {
      final silent = await runCapabilityConformance(_Silent());
      expect(silent.where((e) => !e.passed).map((e) => e.name),
          contains('不可用时给出人话原因（面板与回落都要靠它）'));

      final boom = await runCapabilityConformance(_Throws());
      expect(
        boom.where((e) => !e.passed).map((e) => e.name),
        contains('probe() 永不 throw（异常必须折算成 Outcome）'),
        reason: '套件本身不许被坏实现搞崩 —— 它必须把 throw 折算成一条失败',
      );
    });

    test('能力 id 写歪（没点分）也拦得住', () async {
      final bad = await runCapabilityConformance(_Silent() as Speak);
      expect(bad.where((e) => e.passed).map((e) => e.name), contains('能力 id 是点分小写（app.speak 这种）'));
    });
  });
}
